"""Smoke tests for the frontend nginx container (port 3000).

These tests verify the *full compose stack* — not just the backend API —
by hitting the nginx-served frontend at its public port.  They are the
first line of defence against the frontend container being unhealthy or
misconfigured.
"""

import httpx
import pytest

# The nginx frontend is always at :3000 in the local compose stack.
FRONTEND_URL = "http://localhost:3000"


@pytest.fixture(scope="module")
def frontend() -> httpx.Client:
    with httpx.Client(base_url=FRONTEND_URL, timeout=10) as c:
        yield c


class TestFrontendContainer:
    def test_root_returns_200(self, frontend: httpx.Client) -> None:
        """nginx at :3000 serves the index page."""
        r = frontend.get("/")
        assert r.status_code == 200, (
            f"Frontend not reachable at {FRONTEND_URL}. "
            "Is `docker compose up` running with the frontend service?"
        )

    def test_root_is_html(self, frontend: httpx.Client) -> None:
        """nginx serves text/html."""
        r = frontend.get("/")
        assert "text/html" in r.headers.get("content-type", "")

    def test_root_contains_mobin(self, frontend: httpx.Client) -> None:
        """The HTML page mentions 'mobin' — guards against a blank/default nginx page."""
        r = frontend.get("/")
        assert "mobin" in r.text.lower(), "Frontend HTML doesn't look like the mobin UI"

    def test_paste_route_returns_html(self, frontend: httpx.Client) -> None:
        """SPA route /paste/<id> returns index.html (nginx try_files fallback)."""
        r = frontend.get("/paste/some-fake-id")
        assert r.status_code == 200
        assert "text/html" in r.headers.get("content-type", "")

    def test_api_reachable_from_expected_port(self) -> None:
        """Backend API at :8080 is up — the port the frontend JS will call."""
        with httpx.Client(base_url="http://localhost:8080", timeout=5) as api:
            r = api.get("/health")
            assert r.status_code == 200, (
                "Backend API at :8080 is down. The frontend will fail to create pastes."
            )

    def test_api_cors_allows_frontend_origin(self) -> None:
        """Backend returns CORS headers for the frontend origin (:3000)."""
        with httpx.Client(base_url="http://localhost:8080", timeout=5) as api:
            r = api.get("/health", headers={"Origin": FRONTEND_URL})
            acao = r.headers.get("access-control-allow-origin", "")
            assert acao in ("*", FRONTEND_URL), (
                f"Backend CORS does not allow {FRONTEND_URL}: got '{acao}'"
            )
