"""HTTP request router for mobin pastebin.

Routes incoming HTTP requests to their appropriate handler based on method
and URL path. Also handles CORS preflight OPTIONS requests.

This is the v0.1-shape hand-rolled dispatcher kept transitional in v0.7.x:
the next refactor (Commit 5) replaces it with a ``flare.Router`` declared
via ``r.get / r.post / r.put / r.delete`` and routes via ``:id`` path
parameters. CORS preflight will move to the ``flare.Cors`` middleware in
Commit 6.
"""

from flare.prelude import *
from sqlite import Database
from .models import MobinConfig
from .handlers import (
    health_handler,
    create_paste_handler,
    get_paste_handler,
    update_paste_handler,
    delete_paste_handler,
    list_pastes_handler,
    stats_handler,
)
from .static import serve_index


def _parse_path_query(url: String) -> Tuple[String, String]:
    """Split a URL into path and query components.

    Args:
        url: Raw URL string, e.g. ``"/pastes?limit=20&offset=0"``.

    Returns:
        Tuple of (path, query) where query is "" if absent.
    """
    var q_idx = url.find("?")
    if q_idx < 0:
        return (url, "")
    return (
        String(from_utf8_lossy=url[byte=:q_idx].as_bytes()),
        String(from_utf8_lossy=url[byte=q_idx + 1 :].as_bytes()),
    )


def _method_not_allowed() raises -> Response:
    """Return a 405 Method Not Allowed response with text/plain body."""
    var resp = Response(
        status=Status.METHOD_NOT_ALLOWED,
        reason="Method Not Allowed",
    )
    resp.headers.set("Content-Type", "text/plain; charset=utf-8")
    return resp^


def _bad_request_id() raises -> Response:
    """Return a 400 Bad Request for the missing-paste-id case."""
    return bad_request("missing paste id")


def router(req: Request, db: Database, cfg: MobinConfig) raises -> Response:
    """Central HTTP request router.

    Dispatches to the appropriate handler based on HTTP method and URL path.
    Handles CORS preflight (OPTIONS) for all routes. Returns 404 for
    unrecognised paths and 405 for wrong methods on known paths.

    Routes:
        GET    /              → serve embedded frontend HTML
        GET    /health        → liveness probe
        GET    /stats         → aggregate statistics
        GET    /pastes        → paginated paste list
        POST   /paste         → create a new paste
        GET    /paste/{id}    → retrieve a paste (increments views)
        PUT    /paste/{id}    → update a paste (requires X-Delete-Token)
        DELETE /paste/{id}    → delete a paste (requires X-Delete-Token)
        OPTIONS *             → CORS preflight

    Args:
        req: Incoming HTTP request.
        db:  Open SQLite database connection.
        cfg: Server configuration.

    Returns:
        An HTTP Response appropriate for the request.

    Raises:
        Error: Propagated from database operations on unexpected failures.
    """
    var pq = _parse_path_query(req.url)
    var path = pq[0]
    var query = pq[1]

    # CORS preflight — kept transitional until ``flare.Cors`` middleware
    # takes over in Commit 6.
    if req.method == Method.OPTIONS:
        var r = Response(status=Status.NO_CONTENT, reason="")
        r.headers.set("Access-Control-Allow-Origin", "*")
        r.headers.set(
            "Access-Control-Allow-Methods",
            "GET, POST, PUT, DELETE, OPTIONS",
        )
        r.headers.set(
            "Access-Control-Allow-Headers", "Content-Type, X-Delete-Token"
        )
        return r^

    # Static / frontend
    if path == "/" or path == "/index.html":
        return serve_index()

    # Health check
    if path == "/health":
        return health_handler(req)

    # Statistics
    if path == "/stats":
        if req.method == Method.GET:
            return stats_handler(req, db)
        return _method_not_allowed()

    # Paste list
    if path == "/pastes":
        if req.method == Method.GET:
            return list_pastes_handler(req, db, query)
        return _method_not_allowed()

    # Create paste
    if path == "/paste":
        if req.method == Method.POST:
            return create_paste_handler(req, db, cfg)
        return _method_not_allowed()

    # Paste by ID: /paste/<uuid>
    comptime _PREFIX: String = "/paste/"
    if path.startswith(_PREFIX):
        var paste_id = String(
            from_utf8_lossy=path.removeprefix(_PREFIX).as_bytes()
        )
        if paste_id.byte_length() == 0:
            return _bad_request_id()
        if req.method == Method.GET:
            var accept = req.headers.get("Accept")
            if accept.find("text/html") >= 0:
                return serve_index()
            return get_paste_handler(req, db, paste_id)
        if req.method == Method.PUT:
            return update_paste_handler(req, db, cfg, paste_id)
        if req.method == Method.DELETE:
            return delete_paste_handler(req, db, paste_id)
        return _method_not_allowed()

    return not_found(path)
