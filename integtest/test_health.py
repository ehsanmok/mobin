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
    """flare v0.7's ``Cors`` middleware only attaches
    ``Access-Control-Allow-Origin`` when the request carries an
    ``Origin`` header — same-origin / curl-style requests pass through
    unchanged. So we send a browser-shaped ``Origin`` here and assert
    the wildcard echo back."""
    r = client.get("/health", headers={"Origin": "http://localhost:3000"})
    assert r.headers.get("access-control-allow-origin") == "*"


def test_options_preflight(client: httpx.Client) -> None:
    """flare v0.7's ``Cors`` middleware short-circuits OPTIONS only
    when the request looks like a real CORS preflight: ``Origin`` +
    ``Access-Control-Request-Method``. Without those headers the
    request reaches the router which returns 405 (no OPTIONS route),
    matching the spec's distinction between a same-origin OPTIONS and
    a CORS preflight."""
    r = client.options(
        "/paste",
        headers={
            "Origin": "http://localhost:3000",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "Content-Type",
        },
    )
    assert r.status_code == 204
    assert r.headers.get("access-control-allow-origin") == "*"
    assert "POST" in r.headers.get("access-control-allow-methods", "")
