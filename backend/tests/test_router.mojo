"""Unit tests for mobin HTTP router and handlers.

Drives the v0.7 ``flare.Router``-based mobin handler with synthetic
``Request`` objects against per-test temp-file SQLite databases. No
network sockets are opened.

Each test allocates a unique DB file under ``/tmp/mobin_test_<uuid>.db``
because the new router opens a fresh SQLite connection per request from
``state.db_path`` — the previous ``Database(":memory:")`` shape would
hand each per-request connection a brand-new empty database, so we need
a real on-disk file with WAL mode enabled. The OS reaper handles the
``/tmp`` cleanup; tests stay deterministic because the path is unique.
"""

from std.testing import assert_equal, assert_true
from sqlite import Database
from uuid import uuid4
from flare.http import Request, Response, Status, Method
from mobin.db import init_db
from mobin.models import Paste, MobinConfig
from mobin.router import AppState, MobinApp, build_router


# A canonical browser ``Origin`` for CORS-relevant tests. flare's ``Cors``
# middleware short-circuits to the inner handler when ``Origin`` is absent
# (per the CORS spec — the preflight only kicks in for cross-origin
# requests), so the OPTIONS-preflight assertions below must spell it out.
comptime _TEST_ORIGIN: String = "http://localhost:3000"


def _cfg(db_path: String) -> MobinConfig:
    """Return a test ``MobinConfig`` pointing at ``db_path``."""
    return MobinConfig(
        host="127.0.0.1",
        port=8080,
        ws_port=8081,
        db_path=db_path,
        max_size=65536,
        ttl_days=7,
    )


def _setup() raises -> MobinApp:
    """Build a fresh router pointing at a per-test temp DB file.

    The DB schema is initialised once via a temporary ``Database`` handle
    that drops at function exit (so the file is closed before the first
    handler request opens its own connection). WAL mode is set so the
    per-request connections opened later by the handlers can interleave
    safely.
    """
    var db_path = "/tmp/mobin_test_" + String(uuid4()) + ".db"
    var db = Database(db_path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    init_db(db)
    var state = AppState(db_path=db_path, cfg=_cfg(db_path))
    return build_router(state)


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


def _put(path: String, body: String, token: String = "") raises -> Request:
    """Build a PUT request with a JSON body and optional X-Delete-Token."""
    var body_bytes = body.as_bytes()
    var body_list = List[UInt8](capacity=len(body_bytes))
    for b in body_bytes:
        body_list.append(b)
    var r = Request(method=Method.PUT, url=path, body=body_list^)
    r.headers.set("Content-Type", "application/json")
    if token != "":
        r.headers.set("X-Delete-Token", token)
    return r^


def _body_str(resp: Response) -> String:
    return String(from_utf8_lossy=resp.body)


# ── Route tests ───────────────────────────────────────────────────────────────


def test_health() raises:
    """GET /health returns 200 with {"status":"ok"}."""
    var router = _setup()
    var resp = router.serve(_get("/health"))
    assert_equal(resp.status, Status.OK)
    assert_true(_body_str(resp).find('"ok"') >= 0)


def test_index() raises:
    """GET / returns 200 with HTML content."""
    var router = _setup()
    var resp = router.serve(_get("/"))
    assert_equal(resp.status, Status.OK)
    assert_true(_body_str(resp).find("mobin") >= 0)


def test_stats_empty() raises:
    """GET /stats on empty database returns zeros."""
    var router = _setup()
    var resp = router.serve(_get("/stats"))
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    assert_true(body.find("total") >= 0)


def test_list_empty() raises:
    """GET /pastes on empty database returns empty array."""
    var router = _setup()
    var resp = router.serve(_get("/pastes"))
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    assert_true(body.find('"pastes"') >= 0)
    assert_true(body.find("[]") >= 0)


def test_create_paste() raises:
    """POST /paste with valid JSON creates a paste and returns 200."""
    var router = _setup()
    var body = '{"title":"Hello","content":"print(42)","language":"python","ttl_secs":604800}'
    var resp = router.serve(_post("/paste", body))
    assert_equal(resp.status, Status.OK)
    var resp_body = _body_str(resp)
    assert_true(resp_body.find('"id"') >= 0)


def test_create_paste_empty_content() raises:
    """POST /paste with empty content returns 400."""
    var router = _setup()
    var body = '{"title":"T","content":"","language":"plain","ttl_secs":604800}'
    var resp = router.serve(_post("/paste", body))
    assert_equal(resp.status, Status.BAD_REQUEST)


def test_create_and_get_paste() raises:
    """Creating a paste and then fetching by ID returns the same content."""
    var router = _setup()

    var create_body = (
        '{"title":"My Paste","content":"hello'
        ' world","language":"plain","ttl_secs":604800}'
    )
    var create_resp = router.serve(_post("/paste", create_body))
    assert_equal(create_resp.status, Status.OK)

    # Extract id from response
    var create_body_str = _body_str(create_resp)
    var id_start = create_body_str.find('"id":"') + 6
    var id_end = create_body_str.find('"', id_start)
    var paste_id = String(
        from_utf8_lossy=create_body_str[byte=id_start:id_end].as_bytes()
    )

    var get_resp = router.serve(_get("/paste/" + paste_id))
    assert_equal(get_resp.status, Status.OK)
    var get_body = _body_str(get_resp)
    assert_true(get_body.find("hello world") >= 0)
    assert_true(get_body.find("My Paste") >= 0)


def test_get_nonexistent_paste() raises:
    """GET /paste/missing returns 404."""
    var router = _setup()
    var resp = router.serve(_get("/paste/nonexistent-id"))
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
    return String(from_utf8_lossy=body[byte=start:end].as_bytes())


def test_delete_paste() raises:
    """Checks DELETE /paste/{id} with correct token removes paste; subsequent GET returns 404.
    """
    var router = _setup()

    var create_body = (
        '{"title":"T","content":"x","language":"plain","ttl_secs":604800}'
    )
    var create_resp = router.serve(_post("/paste", create_body))
    var resp_str = _body_str(create_resp)
    var paste_id = _extract_field(resp_str, "id")
    var delete_token = _extract_field(resp_str, "delete_token")

    # Wrong / missing token → 401 / 403
    var no_token_resp = router.serve(_delete("/paste/" + paste_id))
    assert_equal(no_token_resp.status, Status.UNAUTHORIZED)

    var wrong_token_resp = router.serve(
        _delete("/paste/" + paste_id, "bad-token")
    )
    assert_equal(wrong_token_resp.status, Status.FORBIDDEN)

    # Correct token → 200 + subsequent GET → 404
    var del_resp = router.serve(_delete("/paste/" + paste_id, delete_token))
    assert_equal(del_resp.status, Status.OK)

    var get_resp = router.serve(_get("/paste/" + paste_id))
    assert_equal(get_resp.status, Status.NOT_FOUND)


def test_not_found() raises:
    """GET /unknown returns 404."""
    var router = _setup()
    var resp = router.serve(_get("/unknown/path"))
    assert_equal(resp.status, Status.NOT_FOUND)


def test_options_preflight() raises:
    """OPTIONS preflight returns 204 with CORS headers when Origin is set.

    flare's ``Cors`` middleware follows the spec: a preflight is only
    triggered when the inbound request carries both ``Origin`` and
    ``Access-Control-Request-Method``. Bare ``OPTIONS`` requests fall
    through to the inner router (where they 405 — no OPTIONS routes are
    registered), which matches real-browser CORS behaviour.
    """
    var router = _setup()
    var req = Request(method=Method.OPTIONS, url="/paste")
    req.headers.set("Origin", _TEST_ORIGIN)
    req.headers.set("Access-Control-Request-Method", "POST")
    var resp = router.serve(req)
    assert_equal(resp.status, Status.NO_CONTENT)
    # ``Cors`` echoes ``*`` when ``allowed_origins == ["*"]`` and
    # credentials are off (the spec-correct shortcut for public APIs);
    # see ``flare.http.cors._attach_origin``.
    assert_equal(resp.headers.get("Access-Control-Allow-Origin"), "*")


def test_list_pagination() raises:
    """GET /pastes?limit=2 returns at most 2 pastes."""
    var router = _setup()

    # Create 4 pastes
    for i in range(4):
        var b = (
            '{"title":"T","content":"content'
            + String(i)
            + '","language":"plain","ttl_secs":604800}'
        )
        _ = router.serve(_post("/paste", b))

    var resp = router.serve(_get("/pastes?limit=2"))
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    # count should be 2
    assert_true(body.find('"count":2') >= 0)


def test_update_paste() raises:
    """Checks that PUT /paste/{id} with correct token updates the paste content.
    """
    var router = _setup()

    # Create a paste
    var create_body = (
        '{"title":"Original","content":"old'
        ' content","language":"plain","ttl_days":7}'
    )
    var create_resp = router.serve(_post("/paste", create_body))
    assert_equal(create_resp.status, Status.OK)
    var resp_str = _body_str(create_resp)
    var paste_id = _extract_field(resp_str, "id")
    var delete_token = _extract_field(resp_str, "delete_token")

    # Update without token → 401
    var no_token_resp = router.serve(
        _put("/paste/" + paste_id, '{"content":"new content"}')
    )
    assert_equal(no_token_resp.status, Status.UNAUTHORIZED)

    # Update with wrong token → 403
    var bad_token_resp = router.serve(
        _put("/paste/" + paste_id, '{"content":"new content"}', "wrong")
    )
    assert_equal(bad_token_resp.status, Status.FORBIDDEN)

    # Update with correct token → 200 with updated content
    var update_body = (
        '{"title":"Updated","content":"new content","language":"python"}'
    )
    var update_resp = router.serve(
        _put("/paste/" + paste_id, update_body, delete_token)
    )
    assert_equal(update_resp.status, Status.OK)
    var update_str = _body_str(update_resp)
    assert_true(update_str.find("new content") >= 0)
    assert_true(update_str.find("Updated") >= 0)
    assert_true(update_str.find("python") >= 0)

    # GET /paste/{id} should now reflect updated content. Use the JSON
    # accept header so the SPA-shell branch in _GetPasteHandler doesn't
    # short-circuit — browsers get the embedded HTML, automated clients
    # get the paste JSON.
    var get_req = _get("/paste/" + paste_id)
    get_req.headers.set("Accept", "application/json")
    var get_resp = router.serve(get_req)
    assert_equal(get_resp.status, Status.OK)
    var get_str = _body_str(get_resp)
    assert_true(get_str.find("new content") >= 0)


def test_update_paste_partial() raises:
    """Checks that omitting fields in the PUT body preserves current values."""
    var router = _setup()

    var create_body = (
        '{"title":"Keep","content":"keep me","language":"go","ttl_days":7}'
    )
    var create_resp = router.serve(_post("/paste", create_body))
    var resp_str = _body_str(create_resp)
    var paste_id = _extract_field(resp_str, "id")
    var delete_token = _extract_field(resp_str, "delete_token")

    # Only update content; title and language should stay the same
    var update_resp = router.serve(
        _put("/paste/" + paste_id, '{"content":"changed"}', delete_token)
    )
    assert_equal(update_resp.status, Status.OK)
    var body = _body_str(update_resp)
    assert_true(body.find("changed") >= 0)
    assert_true(body.find("Keep") >= 0)
    assert_true(body.find('"go"') >= 0)


def test_update_nonexistent_paste() raises:
    """Checks that PUT /paste/missing returns 404."""
    var router = _setup()
    var resp = router.serve(
        _put("/paste/does-not-exist", '{"content":"x"}', "any-token")
    )
    assert_equal(resp.status, Status.NOT_FOUND)


def test_list_search() raises:
    """Checks that GET /pastes?q=<term> returns only matching pastes."""
    var router = _setup()

    _ = router.serve(
        _post(
            "/paste",
            (
                '{"title":"Python guide","content":"print'
                ' hello","language":"python","ttl_days":7}'
            ),
        )
    )
    _ = router.serve(
        _post(
            "/paste",
            (
                '{"title":"Mojo intro","content":"var x ='
                ' 1","language":"mojo","ttl_days":7}'
            ),
        )
    )

    var resp = router.serve(_get("/pastes?q=Python"))
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    assert_true(body.find("Python guide") >= 0)
    assert_true(body.find('"count":1') >= 0)


def test_options_includes_put() raises:
    """OPTIONS preflight response must include PUT in Allow-Methods."""
    var router = _setup()
    var req = Request(method=Method.OPTIONS, url="/paste/some-id")
    req.headers.set("Origin", _TEST_ORIGIN)
    req.headers.set("Access-Control-Request-Method", "PUT")
    var resp = router.serve(req)
    assert_equal(resp.status, Status.NO_CONTENT)
    var allow = resp.headers.get("Access-Control-Allow-Methods")
    assert_true(allow.find("PUT") >= 0)


def test_request_id_echoed() raises:
    """Inbound ``X-Request-Id`` header is echoed back on the response.

    Locks in the ``RequestId`` middleware: the inbound ``X-Request-Id``
    is preserved verbatim on the outbound response so a request can be
    traced through a load balancer + this server.
    """
    var router = _setup()
    var req = _get("/health")
    req.headers.set("X-Request-Id", "req-test-1234")
    var resp = router.serve(req)
    assert_equal(resp.status, Status.OK)
    assert_equal(resp.headers.get("X-Request-Id"), "req-test-1234")


def test_request_id_generated() raises:
    """Missing ``X-Request-Id`` is auto-generated by the middleware.

    Locks in the second branch of ``RequestId``: when the inbound
    request has no ``X-Request-Id``, the middleware mints one derived
    from ``perf_counter_ns`` and attaches it to the response.
    """
    var router = _setup()
    var resp = router.serve(_get("/health"))
    assert_equal(resp.status, Status.OK)
    assert_true(resp.headers.get("X-Request-Id").byte_length() > 0)


def test_invalid_query_int_returns_400() raises:
    """``?limit=abc`` short-circuits at the typed-extractor edge.

    ``OptionalQueryInt["limit"]`` parses the query string into an
    ``Optional[Int]`` and raises when the value is non-numeric. The
    per-route ``Handler.serve`` wraps the extractor calls in
    ``try/except e: return bad_request(String(e))`` so the route turns
    into a 400 instead of a 500 — the v0.7 typed-extractor failure
    contract this test locks in.
    """
    var router = _setup()
    var resp = router.serve(_get("/pastes?limit=not-a-number"))
    assert_equal(resp.status, Status.BAD_REQUEST)


def test_invalid_query_offset_returns_400() raises:
    """``?offset=`` non-int value returns 400 via the same path as
    ``?limit``. Covers the second extractor on the list route to make
    sure the try/except guard wraps every extractor call, not just the
    first one."""
    var router = _setup()
    var resp = router.serve(_get("/pastes?offset=xyz"))
    assert_equal(resp.status, Status.BAD_REQUEST)


def test_invalid_json_body_returns_400() raises:
    """``POST /paste`` with a malformed JSON body returns 400.

    The handler runs ``morph.json.read[CreateRequest,
    default_if_missing=True](body)`` after the router-level extractors
    have pulled the body string out — when the parser raises on
    invalid JSON, ``create_paste_handler`` returns
    ``bad_request("invalid JSON: " + ...)`` so the caller sees a 400
    instead of a generic 500.
    """
    var router = _setup()
    var resp = router.serve(_post("/paste", "{ this is not json"))
    assert_equal(resp.status, Status.BAD_REQUEST)


def test_empty_body_create_returns_400() raises:
    """``POST /paste`` with an empty body returns 400.

    Empty body parses to a default-initialised ``CreateRequest`` (all
    fields blank) and fails the ``content cannot be empty`` validation
    check — converted to 400 via ``bad_request`` in
    ``create_paste_handler``.
    """
    var router = _setup()
    var resp = router.serve(_post("/paste", ""))
    assert_equal(resp.status, Status.BAD_REQUEST)


def test_update_empty_body_returns_400() raises:
    """PUT with an empty body returns 400.

    ``update_paste_handler`` short-circuits to
    ``bad_request("request body is required")`` when ``body`` is
    empty — exercises the same body-required guard as POST while
    also locking in the auth-check ordering: the empty body is
    rejected only AFTER the X-Delete-Token check passes (so the
    response is 400, not 401, when the caller supplied a valid
    token).
    """
    var router = _setup()
    var create_body = (
        '{"title":"T","content":"x","language":"plain","ttl_secs":604800}'
    )
    var create_resp = router.serve(_post("/paste", create_body))
    var resp_str = _body_str(create_resp)
    var paste_id = _extract_field(resp_str, "id")
    var delete_token = _extract_field(resp_str, "delete_token")

    var resp = router.serve(_put("/paste/" + paste_id, "", delete_token))
    assert_equal(resp.status, Status.BAD_REQUEST)


def test_get_paste_browser_returns_spa() raises:
    """``Accept: text/html`` on /paste/:id returns the SPA shell, not JSON.

    This is the SPA-deep-link branch in ``_GetPasteHandler``: a browser
    navigating directly to ``/paste/<id>`` should get the embedded HTML
    page (the SPA fetches the paste client-side via the JSON API). This
    test ensures we keep that behaviour after the v0.7 router rewrite.
    """
    var router = _setup()
    var req = _get("/paste/whatever")
    req.headers.set("Accept", "text/html")
    var resp = router.serve(req)
    assert_equal(resp.status, Status.OK)
    var body = _body_str(resp)
    # Embedded HTML contains the literal "mobin" string in its title.
    assert_true(body.find("mobin") >= 0)


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
    test_update_paste()
    test_update_paste_partial()
    test_update_nonexistent_paste()
    test_list_search()
    test_options_includes_put()
    test_request_id_echoed()
    test_request_id_generated()
    test_invalid_query_int_returns_400()
    test_invalid_query_offset_returns_400()
    test_invalid_json_body_returns_400()
    test_empty_body_create_returns_400()
    test_update_empty_body_returns_400()
    test_get_paste_browser_returns_spa()
    print("test_router: all tests passed")
