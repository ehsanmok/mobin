"""End-to-end smoke tests for the v0.7 mobin surface.

Exercises the new flare v0.7 features wired up in commits 6, 9, 10 of
the modernization plan against a live ``mobin-backend`` binary:

- ``Cors`` middleware preflight (``OPTIONS`` + ``Origin`` +
  ``Access-Control-Request-Method`` → 204 with the correct
  ``Access-Control-*`` headers).
- ``RequestId`` middleware round-trip (inbound ``X-Request-Id``
  echoed; absent header gets auto-generated).
- ``Logger`` middleware visibility (every request shows up in the
  backend log; we don't parse the log here, but absence of logging
  would be visible in the conftest ``=== Backend log ===`` dump).
- Multi-worker HTTP concurrency: ``num_workers=default_worker_count()``
  (commit 9) — drive ``N`` concurrent ``GET /health`` requests and
  assert all succeed within a generous deadline.
- WebSocket live feed: confirm the WS port is reachable and a
  connected client receives at least one heartbeat / paste message
  within a few seconds.

The conftest fixture ``backend_url`` continues to start the prebuilt
``mobin-backend`` binary for the test session (that's the right shape
for Python-side integration; ``flare.testing.fork_server`` is a Mojo-
in-Mojo helper). The smoke tests share that same session-scoped
backend, so they run after ``test_api.py`` etc. with no extra spin-up
cost.
"""

from __future__ import annotations

import asyncio
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import httpx
import pytest

try:
    import websockets

    HAS_WS = True
except ImportError:  # pragma: no cover - optional dep
    HAS_WS = False

# Re-use the conftest's WS_URL so the smoke tests dial the same port
# the conftest started the backend on.
from conftest import WS_URL


# ── CORS preflight ──────────────────────────────────────────────────────────


_BROWSER_ORIGIN = "http://localhost:3000"


class TestCorsPreflight:
    """``Cors`` middleware (commit 6) handles the OPTIONS preflight.

    Uses an explicit ``Origin`` + ``Access-Control-Request-Method`` so
    flare's ``Cors`` short-circuits the request to the preflight
    response (204) instead of forwarding to the inner router.
    """

    def test_options_paste_returns_204(self, client: httpx.Client) -> None:
        r = client.request(
            "OPTIONS",
            "/paste",
            headers={
                "Origin": _BROWSER_ORIGIN,
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "Content-Type",
            },
        )
        assert r.status_code == 204, r.text
        # ``allowed_origins=["*"]`` + credentials off → wildcard echo.
        assert r.headers.get("Access-Control-Allow-Origin") == "*"
        # POST is in the allowed-methods list (see ``_cors_config``).
        allow_methods = r.headers.get("Access-Control-Allow-Methods", "")
        assert "POST" in allow_methods, allow_methods

    def test_options_paste_id_includes_put_and_delete(
        self, client: httpx.Client
    ) -> None:
        r = client.request(
            "OPTIONS",
            "/paste/some-id",
            headers={
                "Origin": _BROWSER_ORIGIN,
                "Access-Control-Request-Method": "PUT",
            },
        )
        assert r.status_code == 204, r.text
        allow_methods = r.headers.get("Access-Control-Allow-Methods", "")
        assert "PUT" in allow_methods, allow_methods
        assert "DELETE" in allow_methods, allow_methods


# ── RequestId middleware ────────────────────────────────────────────────────


class TestRequestIdMiddleware:
    """``RequestId`` middleware (commit 6) preserves or mints
    ``X-Request-Id`` on every response.
    """

    def test_inbound_id_echoed(self, client: httpx.Client) -> None:
        rid = "smoke-test-" + str(int(time.time() * 1_000_000))
        r = client.get("/health", headers={"X-Request-Id": rid})
        assert r.status_code == 200, r.text
        assert r.headers.get("X-Request-Id") == rid

    def test_missing_id_generated(self, client: httpx.Client) -> None:
        r = client.get("/health")
        assert r.status_code == 200, r.text
        rid = r.headers.get("X-Request-Id", "")
        # Auto-mint is derived from ``perf_counter_ns`` — non-empty
        # is the only guarantee documented in the middleware.
        assert rid, "expected RequestId to mint an X-Request-Id header"


# ── Multi-worker HTTP concurrency ───────────────────────────────────────────


class TestMultiWorkerHttp:
    """``HttpServer.serve(handler, num_workers=N)`` (commit 9) handles
    concurrent requests across CPUs.

    The backend is started with ``num_workers=default_worker_count()``
    by ``main.mojo`` (overridable via ``MOBIN_HTTP_WORKERS``). This
    test fans out ``N`` concurrent ``GET /health`` calls and asserts
    every one returns 200 within a generous timeout — a single-threaded
    reactor would still pass this test, but it's the same shape that
    catches per-worker state corruption (e.g. shared connection
    handles) and per-worker startup races.
    """

    @pytest.mark.parametrize("concurrency", [16, 64])
    def test_concurrent_health_checks(
        self, backend_url: str, concurrency: int
    ) -> None:
        deadline = time.monotonic() + 30.0

        def hit() -> int:
            with httpx.Client(base_url=backend_url, timeout=10.0) as c:
                return c.get("/health").status_code

        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            futures = [pool.submit(hit) for _ in range(concurrency)]
            for f in as_completed(futures):
                assert time.monotonic() < deadline, (
                    f"timed out after 30s waiting for {concurrency} "
                    "concurrent /health responses"
                )
                assert f.result() == 200


# ── WebSocket live feed ─────────────────────────────────────────────────────


@pytest.mark.skipif(not HAS_WS, reason="websockets not installed")
class TestWebSocketFeed:
    """Smoke-test the WS child (commit 10).

    The WS feed loop in ``backend/mobin/feed.mojo`` polls the DB every
    500 ms and broadcasts new pastes (or a ping frame to keep the
    connection alive). After creating a paste over HTTP, a connected
    WS client should see *some* frame within a few seconds — content
    or heartbeat, either is proof the WS server is alive and shares
    the same DB as the HTTP parent.
    """

    def test_feed_emits_frame_after_create(
        self, client: httpx.Client
    ) -> None:
        async def _drive() -> dict[str, Any] | str:
            async with websockets.connect(WS_URL, open_timeout=5.0) as ws:
                # Trigger a write so the feed broadcasts a paste-id frame
                # (the broadcast loop also emits periodic ping frames, so
                # any received message is a positive signal).
                resp = client.post(
                    "/paste",
                    json={
                        "content": "smoke-test ws feed",
                        "title": "smoke",
                        "language": "plain",
                        "ttl": 60,
                    },
                )
                assert resp.status_code == 200, resp.text
                # Wait up to 5s for any WS frame to arrive.
                msg = await asyncio.wait_for(ws.recv(), timeout=5.0)
                if isinstance(msg, bytes):
                    return msg.decode("utf-8", errors="replace")
                return msg

        msg = asyncio.run(_drive())
        # Any frame is a pass — content frames are JSON, heartbeats are
        # the ping payload string. Just assert non-empty.
        assert msg, "expected at least one WS frame within 5s"
