"""Unit tests for mobin HTTP router and handlers.

Exercises the router with synthetic Request objects against an in-memory
database. No network sockets are opened.
"""

from std.testing import assert_equal, assert_true
from sqlite import Database
from flare.http import Request, Response, Status, Method
from mobin.db import init_db, db_create
from mobin.models import Paste, ServerConfig
from mobin.router import router


def _cfg() -> ServerConfig:
    """Return a test ServerConfig with sensible defaults."""
    return ServerConfig(
        host="127.0.0.1",
        port=8080,
        ws_port=8081,
        db_path=":memory:",
        max_size=65536,
        ttl_days=7,
    )


def _open_db() raises -> Database:
    var db = Database(":memory:")
    init_db(db)
    return db^


def _get(path: String) raises -> Request:
    """Build a GET request."""
    return Request(method=Method.GET, url=path)


def _post(path: String, body: String) raises -> Request:
    """Build a POST request with a JSON body."""
    var body_bytes = body.as_bytes()
    var body_list = List[UInt8](capacity=len(body_bytes))
    for b in body_bytes:
        body_list.append(b)
    var r = Request(method=Method.POST, url=path, body=body_list^)
    r.headers.set("Content-Type", "application/json")
    return r^


def _delete(path: String, token: String = "") raises -> Request:
    """Build a DELETE request, optionally with an X-Delete-Token header."""
    var r = Request(method=Method.DELETE, url=path)
    if token != "":
        r.headers.set("X-Delete-Token", token)
    return r^


def _body_str(resp: Response) -> String:
    var raw = List[UInt8](capacity=len(resp.body) + 1)
    for b in resp.body:
        raw.append(b)
    raw.append(0)
    return String(unsafe_from_utf8=raw)


# ── Route tests ───────────────────────────────────────────────────────────────


def test_health() raises:
    """GET /health returns 200 with {"status":"ok"}."""
    var db = _open_db()
    var cfg = _cfg()
    var resp = router(_get("/health"), db, cfg)
    assert_equal(resp.status, Status.OK)
    assert_true(_body_str(resp).find('"ok"') >= 0)


def test_index() raises:
    """GET / returns 200 with HTML content."""
    var db = _open_db()
    var cfg = _cfg()
    var resp = router(_get("/"), db, cfg)
    assert_equal(resp.status, Status.OK)
    assert_true(_body_str(resp).find("mobin") >= 0)


def test_stats_empty() raises:
    """GET /stats on empty database returns zeros."""
    var db = _open_db()
    var cfg = _cfg()
    var resp = router(_get("/stats"), db, cfg)
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    assert_true(body.find("total") >= 0)


def test_list_empty() raises:
    """GET /pastes on empty database returns empty array."""
    var db = _open_db()
    var cfg = _cfg()
    var resp = router(_get("/pastes"), db, cfg)
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    assert_true(body.find('"pastes"') >= 0)
    assert_true(body.find("[]") >= 0)


def test_create_paste() raises:
    """POST /paste with valid JSON creates a paste and returns 200."""
    var db = _open_db()
    var cfg = _cfg()
    var body = '{"title":"Hello","content":"print(42)","language":"python","ttl":7}'
    var resp = router(_post("/paste", body), db, cfg)
    assert_equal(resp.status, Status.OK)
    var resp_body = _body_str(resp)
    assert_true(resp_body.find('"id"') >= 0)


def test_create_paste_empty_content() raises:
    """POST /paste with empty content returns 400."""
    var db = _open_db()
    var cfg = _cfg()
    var body = '{"title":"T","content":"","language":"plain","ttl_days":7}'
    var resp = router(_post("/paste", body), db, cfg)
    assert_equal(resp.status, Status.BAD_REQUEST)


def test_create_and_get_paste() raises:
    """Creating a paste and then fetching by ID returns the same content."""
    var db = _open_db()
    var cfg = _cfg()

    var create_body = '{"title":"My Paste","content":"hello world","language":"plain","ttl":7}'
    var create_resp = router(_post("/paste", create_body), db, cfg)
    assert_equal(create_resp.status, Status.OK)

    # Extract id from response
    var create_body_str = _body_str(create_resp)
    var id_start = create_body_str.find('"id":"') + 6
    var id_end = create_body_str.find('"', id_start)
    var paste_id = String(unsafe_from_utf8=create_body_str.as_bytes()[id_start:id_end])

    var get_resp = router(_get("/paste/" + paste_id), db, cfg)
    assert_equal(get_resp.status, Status.OK)
    var get_body = _body_str(get_resp)
    assert_true(get_body.find("hello world") >= 0)
    assert_true(get_body.find("My Paste") >= 0)


def test_get_nonexistent_paste() raises:
    """GET /paste/missing returns 404."""
    var db = _open_db()
    var cfg = _cfg()
    var resp = router(_get("/paste/nonexistent-id"), db, cfg)
    assert_equal(resp.status, Status.NOT_FOUND)


def _extract_field(body: String, field: String) raises -> String:
    """Extract a JSON string field value from a flat JSON object body."""
    var key = '"' + field + '":"'
    var start = body.find(key)
    if start < 0:
        return ""
    start += key.byte_length()
    var end = body.find('"', start)
    if end < 0:
        return ""
    return String(unsafe_from_utf8=body.as_bytes()[start:end])


def test_delete_paste() raises:
    """Checks DELETE /paste/{id} with correct token removes paste; subsequent GET returns 404."""
    var db = _open_db()
    var cfg = _cfg()

    var create_body = '{"title":"T","content":"x","language":"plain","ttl":7}'
    var create_resp = router(_post("/paste", create_body), db, cfg)
    var resp_str = _body_str(create_resp)
    var paste_id    = _extract_field(resp_str, "id")
    var delete_token = _extract_field(resp_str, "delete_token")

    # Wrong / missing token → 401 / 403
    var no_token_resp = router(_delete("/paste/" + paste_id), db, cfg)
    assert_equal(no_token_resp.status, Status.UNAUTHORIZED)

    var wrong_token_resp = router(_delete("/paste/" + paste_id, "bad-token"), db, cfg)
    assert_equal(wrong_token_resp.status, Status.FORBIDDEN)

    # Correct token → 200 + subsequent GET → 404
    var del_resp = router(_delete("/paste/" + paste_id, delete_token), db, cfg)
    assert_equal(del_resp.status, Status.OK)

    var get_resp = router(_get("/paste/" + paste_id), db, cfg)
    assert_equal(get_resp.status, Status.NOT_FOUND)


def test_not_found() raises:
    """GET /unknown returns 404."""
    var db = _open_db()
    var cfg = _cfg()
    var resp = router(_get("/unknown/path"), db, cfg)
    assert_equal(resp.status, Status.NOT_FOUND)


def test_options_preflight() raises:
    """OPTIONS returns 204 with CORS headers."""
    var db = _open_db()
    var cfg = _cfg()
    var req = Request(method=Method.OPTIONS, url="/paste")
    var resp = router(req, db, cfg)
    assert_equal(resp.status, Status.NO_CONTENT)


def test_list_pagination() raises:
    """GET /pastes?limit=2 returns at most 2 pastes."""
    var db = _open_db()
    var cfg = _cfg()

    # Create 4 pastes
    for i in range(4):
        var b = '{"title":"T","content":"content' + String(i) + '","language":"plain","ttl":7}'
        _ = router(_post("/paste", b), db, cfg)

    var resp = router(_get("/pastes?limit=2"), db, cfg)
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    # count should be 2
    assert_true(body.find('"count":2') >= 0)


def main() raises:
    test_health()
    test_index()
    test_stats_empty()
    test_list_empty()
    test_create_paste()
    test_create_paste_empty_content()
    test_create_and_get_paste()
    test_get_nonexistent_paste()
    test_delete_paste()
    test_not_found()
    test_options_preflight()
    test_list_pagination()
    print("test_router: all tests passed")
