"""HTTP request router for mobin pastebin.

Routes incoming HTTP requests to their appropriate handler based on method
and URL path. Also handles CORS preflight OPTIONS requests.
"""

from flare.http import Request, Response, Status, Method
from sqlite import Database
from .models import ServerConfig
from .handlers import (
    health_handler,
    create_paste_handler,
    get_paste_handler,
    delete_paste_handler,
    list_pastes_handler,
    stats_handler,
    error_response,
    json_response,
)
from .static import serve_index


def _parse_path_query(url: String) -> Tuple[String, String]:
    """Split a URL into path and query components.

    Args:
        url: Raw URL string, e.g. "/pastes?limit=20&offset=0".

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


def router(
    req: Request, db: Database, cfg: ServerConfig
) raises -> Response:
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
        DELETE /paste/{id}    → delete a paste
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

    # CORS preflight
    if req.method == Method.OPTIONS:
        var r = Response(status=Status.NO_CONTENT, reason="")
        r.headers.set("Access-Control-Allow-Origin", "*")
        r.headers.set(
            "Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"
        )
        r.headers.set("Access-Control-Allow-Headers", "Content-Type")
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
        return error_response(Status.METHOD_NOT_ALLOWED, "method not allowed")

    # Paste list
    if path == "/pastes":
        if req.method == Method.GET:
            return list_pastes_handler(req, db, query)
        return error_response(Status.METHOD_NOT_ALLOWED, "method not allowed")

    # Create paste
    if path == "/paste":
        if req.method == Method.POST:
            return create_paste_handler(req, db, cfg)
        return error_response(Status.METHOD_NOT_ALLOWED, "method not allowed")

    # Paste by ID: /paste/<uuid>
    comptime _PREFIX: String = "/paste/"
    if path.startswith(_PREFIX):
        var paste_id = String(from_utf8_lossy=path.removeprefix(_PREFIX).as_bytes())
        if paste_id.byte_length() == 0:
            return error_response(Status.BAD_REQUEST, "missing paste id")
        if req.method == Method.GET:
            return get_paste_handler(req, db, paste_id)
        if req.method == Method.DELETE:
            return delete_paste_handler(req, db, paste_id)
        return error_response(Status.METHOD_NOT_ALLOWED, "method not allowed")

    return error_response(Status.NOT_FOUND, "not found: " + path)
