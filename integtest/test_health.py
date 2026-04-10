"""Smoke tests for mobin health and stats endpoints."""

import httpx


def test_health_ok(client: httpx.Client) -> None:
    """GET /health returns 200 with {"status":"ok"}."""
    r = client.get("/health")
    assert r.status_code == 200
    data = r.json()
    assert data.get("status") == "ok"


def test_health_content_type(client: httpx.Client) -> None:
    """GET /health returns application/json content type."""
    r = client.get("/health")
    assert "application/json" in r.headers.get("content-type", "")


def test_stats_returns_200(client: httpx.Client) -> None:
    """GET /stats returns 200 with expected keys."""
    r = client.get("/stats")
    assert r.status_code == 200
    data = r.json()
    assert "total" in data
    assert "today" in data
    assert "total_views" in data


def test_stats_types(client: httpx.Client) -> None:
    """GET /stats fields are integers."""
    r = client.get("/stats")
    data = r.json()
    assert isinstance(data["total"], int)
    assert isinstance(data["today"], int)
    assert isinstance(data["total_views"], int)


def test_index_returns_html(client: httpx.Client) -> None:
    """GET / returns the frontend HTML page."""
    r = client.get("/")
    assert r.status_code == 200
    assert "text/html" in r.headers.get("content-type", "")
    assert "mobin" in r.text.lower()


def test_cors_headers(client: httpx.Client) -> None:
    """All API responses include CORS headers."""
    r = client.get("/health")
    assert r.headers.get("access-control-allow-origin") == "*"


def test_options_preflight(client: httpx.Client) -> None:
    """OPTIONS /paste returns 204 for CORS preflight."""
    r = client.options("/paste")
    assert r.status_code == 204
