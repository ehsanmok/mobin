"""HTTP request handlers for mobin pastebin API.

Each handler corresponds to one API endpoint. Handlers read from the Request,
interact with the database, and return a Response. JSON bodies use morph for
struct serialization/deserialization.
"""

from flare.http import Request, Response, Status
from sqlite import Database
from morph.json import write, read
from uuid import uuid4
from .models import Paste, PasteStats, ServerConfig, new_paste
from .db import (
    db_create,
    db_get,
    db_check_token,
    db_inc_views,
    db_delete,
    db_list,
    db_stats,
)


# ── Request DTO ───────────────────────────────────────────────────────────────


@fieldwise_init
struct CreateRequest(Defaultable, Movable):
    """JSON body for POST /paste.

    Fields:
        title:    Optional title (defaults to 'Untitled').
        content:  Paste body text or code (required).
        language: Syntax highlight hint (defaults to 'plain').
        ttl_days: Expiry in days (defaults to 7).
    """

    var title: String
    var content: String
    var language: String
    var ttl_days: Int

    def __init__(out self):
        self.title = ""
        self.content = ""
        self.language = "plain"
        self.ttl_days = 7


# ── Response helpers ──────────────────────────────────────────────────────────


def _to_bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] for use as a Response body.

    Uses byte_length() explicitly to exclude the null terminator that
    String.as_bytes() includes in its underlying buffer.

    Args:
        s: String to convert.

    Returns:
        Byte list copy of the string's UTF-8 encoding (no null terminator).
    """
    var n = s.byte_length()
    var b = s.as_bytes()
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(b[i])
    return out^


def json_response(status: Int, body: String) raises -> Response:
    """Build a JSON Response with CORS headers.

    Args:
        status: HTTP status code.
        body:   JSON string body.

    Returns:
        A Response with Content-Type: application/json and CORS headers.
    """
    var r = Response(status=status, reason="", body=_to_bytes(body))
    r.headers.set("Content-Type", "application/json; charset=utf-8")
    r.headers.set("Access-Control-Allow-Origin", "*")
    r.headers.set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
    r.headers.set("Access-Control-Allow-Headers", "Content-Type")
    return r^


def error_response(status: Int, msg: String) raises -> Response:
    """Build a JSON error Response.

    Args:
        status: HTTP error status code.
        msg:    Human-readable error message.

    Returns:
        A Response with body {"error": "<msg>"}.
    """
    return json_response(status, '{"error":"' + msg + '"}')


def _paste_to_json(paste: Paste) raises -> String:
    """Serialize a Paste struct to a JSON string via morph.

    Args:
        paste: The Paste to serialize.

    Returns:
        JSON string representation of the paste.
    """
    return write(paste)


def _pastes_to_json_array(pastes: List[Paste]) raises -> String:
    """Serialize a list of Paste structs to a JSON array string.

    Args:
        pastes: List of Paste objects to serialize.

    Returns:
        JSON array string, e.g. '[{"id":"..."},...]'.
    """
    var out = String("[")
    for i in range(len(pastes)):
        if i > 0:
            out += ","
        out += write(pastes[i])
    out += "]"
    return out^


# ── Handlers ──────────────────────────────────────────────────────────────────


def health_handler(req: Request) raises -> Response:
    """Handle GET /health — liveness probe.

    Args:
        req: Incoming HTTP request (unused).

    Returns:
        200 OK with {"status":"ok"}.
    """
    return json_response(Status.OK, '{"status":"ok"}')


def create_paste_handler(
    req: Request, db: Database, cfg: ServerConfig
) raises -> Response:
    """Handle POST /paste — create a new paste.

    Reads CreateRequest JSON from the request body, validates size,
    creates a Paste, inserts into the database, and returns the new ID.

    Args:
        req: HTTP request with JSON body.
        db:  Open database connection.
        cfg: Server configuration (max_size, ttl_days).

    Returns:
        200 OK with the full paste JSON object,
        or an error response on validation failure.
    """
    if len(req.body) == 0:
        return error_response(Status.BAD_REQUEST, "request body is required")

    # from_utf8_lossy replaces invalid UTF-8 bytes with U+FFFD rather than
    # crashing; the JSON parser will reject structurally invalid input anyway.
    var body = String(from_utf8_lossy=req.body)

    var cr: CreateRequest
    try:
        cr = read[CreateRequest, default_if_missing=True](body)
    except e:
        return error_response(Status.BAD_REQUEST, "invalid JSON: " + String(e))

    if cr.content.byte_length() == 0:
        return error_response(Status.BAD_REQUEST, "content is required")
    if cr.content.byte_length() > cfg.max_size:
        return error_response(Status.CONTENT_TOO_LARGE, "content too large")

    # Reject null bytes — they are legal in JSON (\u0000) but cause silent
    # truncation in downstream C string handling and most text editors.
    var content_bytes = cr.content.as_bytes()
    for i in range(cr.content.byte_length()):
        if content_bytes[i] == 0:
            return error_response(
                Status.BAD_REQUEST, "content must not contain null bytes"
            )

    var ttl = cr.ttl_days if cr.ttl_days > 0 else cfg.ttl_days
    ttl = min(ttl, 365)

    var paste = new_paste(cr.title, cr.content, cr.language, ttl)
    # Generate an unguessable delete token — returned once at create time
    # and stored in the DB. Required as X-Delete-Token header to delete.
    var delete_token = String(uuid4())
    db_create(db, paste, delete_token)

    # Append delete_token to the response JSON. It is intentionally omitted
    # from GET/LIST responses so it is only ever visible to the creator.
    var paste_json = _paste_to_json(paste)
    # Strip the trailing "}" and inject the delete_token field.
    var response_json = (
        String(from_utf8_lossy=paste_json[byte=: paste_json.byte_length() - 1].as_bytes())
        + ',"delete_token":"' + delete_token + '"}'
    )
    return json_response(Status.OK, response_json)


def get_paste_handler(
    req: Request, db: Database, paste_id: String
) raises -> Response:
    """Handle GET /paste/{id} — retrieve and view a paste.

    Increments the view counter on each successful fetch.

    Args:
        req:      HTTP request (unused beyond routing).
        db:       Open database connection.
        paste_id: UUID string of the paste to fetch.

    Returns:
        200 OK with Paste JSON, or 404 Not Found.
    """
    var paste_opt = db_get(db, paste_id)
    if not paste_opt:
        return error_response(Status.NOT_FOUND, "paste not found")
    var paste = paste_opt.take()
    db_inc_views(db, paste_id)
    paste.views += 1
    return json_response(Status.OK, _paste_to_json(paste))


def delete_paste_handler(
    req: Request, db: Database, paste_id: String
) raises -> Response:
    """Handle DELETE /paste/{id} — remove a paste.

    Requires the ``X-Delete-Token`` header containing the token that was
    returned when the paste was created. Returns 401 if the header is
    missing, 403 if the token is present but incorrect, 404 if the paste
    does not exist.

    Args:
        req:      HTTP request — must carry X-Delete-Token header.
        db:       Open database connection.
        paste_id: UUID string of the paste to delete.

    Returns:
        200 OK on success, or an appropriate error response.
    """
    var token = req.headers.get("X-Delete-Token")
    if token == "":
        return error_response(Status.UNAUTHORIZED, "X-Delete-Token header required")

    var paste_opt = db_get(db, paste_id)
    if not paste_opt:
        return error_response(Status.NOT_FOUND, "paste not found")

    if not db_check_token(db, paste_id, token):
        return error_response(Status.FORBIDDEN, "invalid delete token")

    db_delete(db, paste_id)
    return json_response(Status.OK, '{"deleted":true}')


def list_pastes_handler(
    req: Request, db: Database, query: String
) raises -> Response:
    """Handle GET /pastes — paginated list of recent non-expired pastes.

    Query parameters:
        limit:  Number of results (default 20, max 100).
        offset: Pagination offset (default 0).

    Args:
        req:   HTTP request (unused beyond routing).
        db:    Open database connection.
        query: URL query string, e.g. "limit=20&offset=0".

    Returns:
        200 OK with {"pastes":[...],"count":<n>}.
    """
    var limit = _parse_query_int(query, "limit", 20)
    var offset = _parse_query_int(query, "offset", 0)
    var pastes = db_list(db, limit, offset)
    var arr = _pastes_to_json_array(pastes)
    var body = '{"pastes":' + arr + ',"count":' + String(len(pastes)) + "}"
    return json_response(Status.OK, body)


def stats_handler(req: Request, db: Database) raises -> Response:
    """Handle GET /stats — aggregate statistics.

    Args:
        req: HTTP request (unused).
        db:  Open database connection.

    Returns:
        200 OK with {"total":<n>,"today":<n>,"total_views":<n>}.
    """
    var stats = db_stats(db)
    var body = (
        '{"total":'
        + String(stats.total)
        + ',"today":'
        + String(stats.today)
        + ',"total_views":'
        + String(stats.total_views)
        + "}"
    )
    return json_response(Status.OK, body)


# ── Query string helpers ──────────────────────────────────────────────────────


def _parse_query_int(query: String, key: String, default_val: Int) -> Int:
    """Extract an integer value from a URL query string.

    Args:
        query:       Raw query string, e.g. "limit=20&offset=0".
        key:         Parameter name to look up.
        default_val: Value to return if the key is missing or invalid.

    Returns:
        Parsed integer value or default_val on missing/invalid input.
    """
    var search = key + "="
    var idx = query.find(search)
    if idx < 0:
        return default_val
    var start = idx + search.byte_length()
    var end = query.find("&", start)
    var val_str = (
        String(from_utf8_lossy=query[byte=start:].as_bytes())
        if end < 0
        else String(from_utf8_lossy=query[byte=start:end].as_bytes())
    )
    try:
        return Int(val_str)
    except:
        return default_val
