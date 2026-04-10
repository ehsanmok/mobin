"""Integration tests for all mobin HTTP API routes and WebSocket feed.

Routes tested:
    POST   /paste          — create paste
    GET    /paste/{id}     — get paste by ID
    DELETE /paste/{id}     — delete paste
    GET    /pastes         — list pastes (paginated)
    GET    /stats          — global stats
    GET    /health         — health check (in test_health.py)
    GET    /               — frontend HTML
    WS     ws://:18081/feed — live feed WebSocket
"""

import asyncio
import time
from typing import Any

import httpx
import pytest

try:
    import websockets
    HAS_WS = True
except ImportError:
    HAS_WS = False

# Import port constants from conftest so inline HTTP calls use the right port
from conftest import HTTP_PORT, WS_URL


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def create_paste(
    client: httpx.Client,
    content: str = "hello world",
    title: str = "test paste",
    language: str = "plain",
    ttl: int = 1,
) -> dict[str, Any]:
    """Create a paste and return the parsed JSON body."""
    r = client.post(
        "/paste",
        json={"content": content, "title": title, "language": language, "ttl": ttl},
    )
    assert r.status_code == 200, f"create failed: {r.text}"
    data = r.json()
    assert "id" in data, f"response missing id: {data}"
    return data


# ---------------------------------------------------------------------------
# POST /paste
# ---------------------------------------------------------------------------

class TestCreatePaste:
    def test_create_returns_200(self, client: httpx.Client) -> None:
        r = client.post("/paste", json={"content": "fn main(): pass"})
        assert r.status_code == 200

    def test_create_returns_id(self, client: httpx.Client) -> None:
        data = create_paste(client)
        assert isinstance(data["id"], str)
        assert len(data["id"]) == 36, "Expected UUID format (36 chars)"

    def test_create_defaults(self, client: httpx.Client) -> None:
        """Minimal payload: only content required."""
        r = client.post("/paste", json={"content": "minimal"})
        assert r.status_code == 200
        data = r.json()
        assert data["content"] == "minimal"
        assert data["language"] == "plain"
        assert data["title"] == ""

    def test_create_with_language(self, client: httpx.Client) -> None:
        data = create_paste(client, content="x = 1", language="python")
        assert data["language"] == "python"

    def test_create_with_title(self, client: httpx.Client) -> None:
        data = create_paste(client, title="My Script")
        assert data["title"] == "My Script"

    def test_create_missing_content_returns_error(self, client: httpx.Client) -> None:
        r = client.post("/paste", json={"title": "no content"})
        assert r.status_code in (400, 422)

    def test_create_empty_content_returns_error(self, client: httpx.Client) -> None:
        r = client.post("/paste", json={"content": ""})
        assert r.status_code in (400, 422)

    def test_create_timestamps_present(self, client: httpx.Client) -> None:
        data = create_paste(client)
        assert "created_at" in data
        assert "expires_at" in data
        assert isinstance(data["created_at"], int)
        assert isinstance(data["expires_at"], int)
        assert data["expires_at"] > data["created_at"]

    def test_create_views_starts_at_zero(self, client: httpx.Client) -> None:
        data = create_paste(client)
        assert data["views"] == 0

    def test_create_content_preserved(self, client: httpx.Client) -> None:
        long_content = "x = 1\n" * 100
        data = create_paste(client, content=long_content)
        assert data["content"] == long_content


# ---------------------------------------------------------------------------
# GET /paste/{id}
# ---------------------------------------------------------------------------

class TestGetPaste:
    def test_get_returns_200(self, client: httpx.Client) -> None:
        created = create_paste(client)
        r = client.get(f"/paste/{created['id']}")
        assert r.status_code == 200

    def test_get_returns_correct_id(self, client: httpx.Client) -> None:
        created = create_paste(client)
        r = client.get(f"/paste/{created['id']}")
        assert r.json()["id"] == created["id"]

    def test_get_returns_correct_content(self, client: httpx.Client) -> None:
        created = create_paste(client, content="unique content 12345")
        r = client.get(f"/paste/{created['id']}")
        assert r.json()["content"] == "unique content 12345"

    def test_get_increments_views(self, client: httpx.Client) -> None:
        created = create_paste(client)
        paste_id = created["id"]
        r1 = client.get(f"/paste/{paste_id}")
        r2 = client.get(f"/paste/{paste_id}")
        assert r2.json()["views"] == r1.json()["views"] + 1

    def test_get_nonexistent_returns_404(self, client: httpx.Client) -> None:
        r = client.get("/paste/00000000-0000-0000-0000-000000000000")
        assert r.status_code == 404

    def test_get_all_fields_present(self, client: httpx.Client) -> None:
        created = create_paste(client, content="test", title="t", language="python")
        r = client.get(f"/paste/{created['id']}")
        data = r.json()
        for field in ("id", "title", "content", "language", "created_at", "expires_at", "views"):
            assert field in data, f"Missing field: {field}"


# ---------------------------------------------------------------------------
# DELETE /paste/{id}
# ---------------------------------------------------------------------------

class TestDeletePaste:
    def test_delete_returns_200(self, client: httpx.Client) -> None:
        created = create_paste(client)
        r = client.delete(f"/paste/{created['id']}")
        assert r.status_code == 200

    def test_delete_removes_paste(self, client: httpx.Client) -> None:
        created = create_paste(client)
        paste_id = created["id"]
        client.delete(f"/paste/{paste_id}")
        r = client.get(f"/paste/{paste_id}")
        assert r.status_code == 404

    def test_delete_nonexistent_returns_404(self, client: httpx.Client) -> None:
        r = client.delete("/paste/00000000-0000-0000-0000-000000000000")
        assert r.status_code == 404

    def test_delete_twice_returns_404(self, client: httpx.Client) -> None:
        created = create_paste(client)
        paste_id = created["id"]
        client.delete(f"/paste/{paste_id}")
        r = client.delete(f"/paste/{paste_id}")
        assert r.status_code == 404


# ---------------------------------------------------------------------------
# GET /pastes
# ---------------------------------------------------------------------------

def _list_items(client: httpx.Client, params: str = "") -> list[dict[str, Any]]:
    """Fetch /pastes and return the pastes array from the response dict."""
    url = f"/pastes{params}"
    r = client.get(url)
    assert r.status_code == 200, f"list failed: {r.text}"
    data = r.json()
    assert "pastes" in data, f"response missing 'pastes' key: {data}"
    return data["pastes"]


class TestListPastes:
    def test_list_returns_200(self, client: httpx.Client) -> None:
        r = client.get("/pastes")
        assert r.status_code == 200

    def test_list_returns_dict_with_pastes_and_count(self, client: httpx.Client) -> None:
        data = client.get("/pastes").json()
        assert isinstance(data, dict)
        assert "pastes" in data
        assert "count" in data
        assert isinstance(data["pastes"], list)
        assert isinstance(data["count"], int)

    def test_list_contains_created_paste(self, client: httpx.Client) -> None:
        created = create_paste(client, content="find me in list")
        paste_id = created["id"]
        ids = [p["id"] for p in _list_items(client)]
        assert paste_id in ids

    def test_list_pagination_limit(self, client: httpx.Client) -> None:
        # Create 5 pastes, request limit=3
        for i in range(5):
            create_paste(client, content=f"paste {i}")
        items = _list_items(client, "?limit=3")
        assert len(items) <= 3

    def test_list_pagination_offset(self, client: httpx.Client) -> None:
        items0 = _list_items(client, "?limit=5&offset=0")
        items1 = _list_items(client, "?limit=5&offset=5")
        ids0 = {p["id"] for p in items0}
        ids1 = {p["id"] for p in items1}
        # No overlap between pages
        assert ids0.isdisjoint(ids1)

    def test_list_fields_present(self, client: httpx.Client) -> None:
        create_paste(client)
        items = _list_items(client, "?limit=1")
        if items:
            item = items[0]
            for field in ("id", "title", "language", "created_at"):
                assert field in item, f"Missing field in list item: {field}"

    def test_deleted_paste_not_in_list(self, client: httpx.Client) -> None:
        created = create_paste(client)
        paste_id = created["id"]
        client.delete(f"/paste/{paste_id}")
        ids = [p["id"] for p in _list_items(client)]
        assert paste_id not in ids


# ---------------------------------------------------------------------------
# GET /stats
# ---------------------------------------------------------------------------

class TestStats:
    def test_stats_increases_on_create(self, client: httpx.Client) -> None:
        before = client.get("/stats").json()["total"]
        create_paste(client)
        after = client.get("/stats").json()["total"]
        assert after == before + 1

    def test_stats_views_increases_on_get(self, client: httpx.Client) -> None:
        created = create_paste(client)
        before_views = client.get("/stats").json()["total_views"]
        client.get(f"/paste/{created['id']}")
        after_views = client.get("/stats").json()["total_views"]
        assert after_views == before_views + 1

    def test_stats_today_non_negative(self, client: httpx.Client) -> None:
        data = client.get("/stats").json()
        assert data["today"] >= 0


# ---------------------------------------------------------------------------
# WebSocket /feed
# ---------------------------------------------------------------------------

@pytest.mark.skipif(not HAS_WS, reason="websockets package not installed")
class TestWebSocketFeed:
    def test_ws_connects(self) -> None:
        """WebSocket handshake succeeds and connection can be closed cleanly."""
        async def _run() -> None:
            async with websockets.connect(WS_URL, open_timeout=5) as ws:
                # Connection established; nothing required yet
                pass
        asyncio.run(_run())

    def test_ws_receives_new_paste(self) -> None:
        """Creating a paste while connected to the feed results in a message."""
        received: list[str] = []

        async def _run() -> None:
            async with websockets.connect(WS_URL, open_timeout=5) as ws:
                # Create a paste via HTTP from a thread
                async def _create() -> None:
                    await asyncio.sleep(0.3)  # small delay so WS is listening
                    async with httpx.AsyncClient() as c:
                        await c.post(
                            f"http://localhost:{HTTP_PORT}/paste",
                            json={"content": "ws live feed test", "language": "mojo"},
                        )

                create_task = asyncio.create_task(_create())
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=5.0)
                    received.append(msg)
                except asyncio.TimeoutError:
                    pass
                await create_task

        asyncio.run(_run())
        assert received, "Expected at least one WS message after creating a paste"
        import json
        data = json.loads(received[0])
        assert "id" in data
        assert data.get("content") == "ws live feed test"
