"""HTTP request handlers for mobin pastebin API.

Each handler corresponds to one API endpoint. Handler functions receive
already-typed parameters — primitives, parsed body strings, validated
header tokens — produced by the typed extractors registered on the
per-route ``Handler`` structs in ``router.mojo``. There is no
``Request``-poking inside this file: query strings, headers, path
captures, and JSON bodies are all extracted once at the routing edge,
so an unexpected body shape, a non-integer ``limit``, or a missing
``X-Delete-Token`` is a 400 / 401 from the router, never a runtime
crash inside the handler.

Builds on the v0.7 ``flare.prelude`` surface — every response goes
through ``ok`` / ``ok_json`` / ``bad_request`` / ``not_found`` /
``internal_error``; no per-handler ``Content-Type`` plumbing or
hand-rolled byte-list builders remain. CORS headers are added by the
``Cors`` middleware in ``router.mojo``, so handler bodies stay focused
on application logic.
"""

from flare.prelude import *
from sqlite import Database
from morph.json import write, read
from uuid import uuid4
from tempo import Timestamp
from .models import Paste, PasteStats, MobinConfig, new_paste
from .db import (
    db_create,
    db_get,
    db_check_token,
    db_inc_views,
    db_delete,
    db_update,
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
        ttl_secs: Expiry in seconds (defaults to 3600 = 1 hour,
                  max 2592000 = 30 days).
    """

    var title: String
    var content: String
    var language: String
    var ttl_secs: Int

    def __init__(out self):
        self.title = ""
        self.content = ""
        self.language = "plain"
        self.ttl_secs = 3600


@fieldwise_init
struct UpdateRequest(Defaultable, Movable):
    """JSON body for PUT /paste/{id}.

    All fields are optional: omitted fields (empty string / zero) preserve
    the current value.  At least one of ``title``, ``content``, or
    ``language`` should differ from the current value to be useful.

    Fields:
        title:    New title (unchanged if empty string).
        content:  New paste body (unchanged if empty string).
        language: New syntax-highlight hint (unchanged if empty string).
        ttl_secs: If > 0, reset the paste expiry to now + ttl_secs seconds
                  (capped at 2592000 = 30 days). If 0, keep current expiry.
    """

    var title: String
    var content: String
    var language: String
    var ttl_secs: Int

    def __init__(out self):
        self.title = ""
        self.content = ""
        self.language = ""
        self.ttl_secs = 0


# ── JSON serialisation helpers ───────────────────────────────────────────────


def _paste_to_json(paste: Paste) raises -> String:
    """Serialise a Paste struct to a JSON string via morph."""
    return write(paste)


def _pastes_to_json_array(pastes: List[Paste]) raises -> String:
    """Serialise a list of Paste structs to a JSON array string."""
    var out = String("[")
    for i in range(len(pastes)):
        if i > 0:
            out += ","
        out += write(pastes[i])
    out += "]"
    return out^


# ── Handlers ──────────────────────────────────────────────────────────────────


def health_handler() raises -> Response:
    """Handle GET /health — liveness probe.

    Returns:
        200 OK with ``{"status":"ok"}``.
    """
    return ok_json('{"status":"ok"}')


def create_paste_handler(
    db: Database, cfg: MobinConfig, body: String
) raises -> Response:
    """Handle POST /paste — create a new paste.

    Body parsing is done by the caller (the per-route Handler struct's
    ``BodyText`` extractor) so this function gets a UTF-8 decoded
    string. Empty / unparseable bodies are 400'd by the caller.

    Args:
        db:   Open database connection.
        cfg:  Server configuration (max_size, ttl_days).
        body: Raw JSON request body, already UTF-8 decoded.

    Returns:
        200 OK with the full paste JSON object plus ``delete_token``,
        or a 4xx error response on validation failure.
    """
    if body.byte_length() == 0:
        return bad_request("request body is required")

    var cr: CreateRequest
    try:
        cr = read[CreateRequest, default_if_missing=True](body)
    except e:
        return bad_request("invalid JSON: " + String(e))

    if cr.content.byte_length() == 0:
        return bad_request("content is required")
    if cr.content.byte_length() > cfg.max_size:
        var resp = Response(
            status=Status.CONTENT_TOO_LARGE,
            reason="Content Too Large",
        )
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        return resp^

    # Reject null bytes — they are legal in JSON (\u0000) but cause silent
    # truncation in downstream C string handling and most text editors.
    var content_bytes = cr.content.as_bytes()
    for i in range(cr.content.byte_length()):
        if content_bytes[i] == 0:
            return bad_request("content must not contain null bytes")

    # Default to server config (in days → seconds); cap at 30 days.
    comptime _MAX_TTL_SECS = 30 * 86400
    var ttl = cr.ttl_secs if cr.ttl_secs > 0 else cfg.ttl_days * 86400
    ttl = min(ttl, _MAX_TTL_SECS)

    var paste = new_paste(cr.title, cr.content, cr.language, ttl)
    # Generate an unguessable delete token — returned once at create time
    # and stored in the DB. Required as X-Delete-Token header to delete.
    var delete_token = String(uuid4())
    db_create(db, paste, delete_token)

    # Append delete_token to the response JSON. It is intentionally omitted
    # from GET/LIST responses so it is only ever visible to the creator.
    var paste_json = _paste_to_json(paste)
    var response_json = (
        String(
            from_utf8_lossy=paste_json[
                byte = : paste_json.byte_length() - 1
            ].as_bytes()
        )
        + ',"delete_token":"'
        + delete_token
        + '"}'
    )
    return ok_json(response_json)


def get_paste_handler(db: Database, paste_id: String) raises -> Response:
    """Handle GET /paste/{id} — retrieve and view a paste.

    Increments the view counter on each successful fetch.

    Args:
        db:       Open database connection.
        paste_id: UUID string of the paste (extracted by the caller from
                  the ``:id`` path capture via ``PathStr["id"]``).

    Returns:
        200 OK with Paste JSON, or 404 Not Found.
    """
    var paste_opt = db_get(db, paste_id)
    if not paste_opt:
        return not_found("paste " + paste_id)
    var paste = paste_opt.take()
    db_inc_views(db, paste_id)
    paste.views += 1
    return ok_json(_paste_to_json(paste))


def delete_paste_handler(
    db: Database, paste_id: String, token: String
) raises -> Response:
    """Handle DELETE /paste/{id} — remove a paste.

    The caller (the per-route Handler struct) extracts the ``X-Delete-
    Token`` header via ``OptionalHeaderStr["X-Delete-Token"]`` and
    passes the value (or empty string when the header is absent) here.

    Args:
        db:       Open database connection.
        paste_id: UUID string of the paste (extracted from the ``:id``
                  path capture).
        token:    Value of the ``X-Delete-Token`` header, or empty
                  string when the header was not sent.

    Returns:
        200 OK on success; 401 missing token, 403 wrong token, 404
        missing paste.
    """
    if token == "":
        var resp = Response(status=Status.UNAUTHORIZED, reason="Unauthorized")
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        return resp^

    var paste_opt = db_get(db, paste_id)
    if not paste_opt:
        return not_found("paste " + paste_id)

    if not db_check_token(db, paste_id, token):
        var resp = Response(status=Status.FORBIDDEN, reason="Forbidden")
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        return resp^

    db_delete(db, paste_id)
    return ok_json('{"deleted":true}')


def update_paste_handler(
    db: Database,
    cfg: MobinConfig,
    paste_id: String,
    token: String,
    body: String,
) raises -> Response:
    """Handle PUT /paste/{id} — update an existing paste.

    All cross-cutting concerns (path capture, header read, body decode)
    are pre-extracted by the caller. This function performs only the
    application-level checks: token presence + match, paste existence,
    body shape, and content limits.

    Args:
        db:       Open database connection.
        cfg:      Server configuration (max_size).
        paste_id: UUID string of the paste (from the ``:id`` capture).
        token:    Value of ``X-Delete-Token`` header (or empty string).
        body:     Raw JSON body, already UTF-8 decoded.

    Returns:
        200 OK with the updated Paste JSON, or a 4xx/5xx error response.
    """
    if token == "":
        var resp = Response(status=Status.UNAUTHORIZED, reason="Unauthorized")
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        return resp^

    var paste_opt = db_get(db, paste_id)
    if not paste_opt:
        return not_found("paste " + paste_id)

    if not db_check_token(db, paste_id, token):
        var resp = Response(status=Status.FORBIDDEN, reason="Forbidden")
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        return resp^

    var current = paste_opt.take()

    if body.byte_length() == 0:
        return bad_request("request body is required")

    var ur: UpdateRequest
    try:
        ur = read[UpdateRequest, default_if_missing=True](body)
    except e:
        return bad_request("invalid JSON: " + String(e))

    var new_title = ur.title if ur.title.byte_length() > 0 else current.title
    var new_content = (
        ur.content if ur.content.byte_length() > 0 else current.content
    )
    var new_language = (
        ur.language if ur.language.byte_length() > 0 else current.language
    )

    if new_content.byte_length() == 0:
        return bad_request("content cannot be empty")
    if new_content.byte_length() > cfg.max_size:
        var resp = Response(
            status=Status.CONTENT_TOO_LARGE,
            reason="Content Too Large",
        )
        resp.headers.set("Content-Type", "text/plain; charset=utf-8")
        return resp^

    var content_bytes = new_content.as_bytes()
    for i in range(new_content.byte_length()):
        if content_bytes[i] == 0:
            return bad_request("content must not contain null bytes")

    comptime _MAX_TTL_SECS = 30 * 86400
    var new_expires_at = current.expires_at
    if ur.ttl_secs > 0:
        new_expires_at = Int(Timestamp.now().unix_secs()) + min(
            ur.ttl_secs, _MAX_TTL_SECS
        )

    db_update(
        db, paste_id, new_title, new_content, new_language, new_expires_at
    )

    var updated_opt = db_get(db, paste_id)
    if not updated_opt:
        return internal_error("failed to retrieve updated paste")
    return ok_json(_paste_to_json(updated_opt.take()))


def list_pastes_handler(
    db: Database,
    limit: Int,
    offset: Int,
    before_ts: Int,
    search: String,
) raises -> Response:
    """Handle GET /pastes — paginated list of recent non-expired pastes.

    All query parameters are pre-parsed by the caller's typed extractors
    (``OptionalQueryInt`` / ``OptionalQueryStr``); a present-but-
    unparseable ``limit=abc`` is a 400 from the router, never an Int(0)
    silently swallowed here.

    Args:
        db:        Open database connection.
        limit:     Max results (capped at 100 inside ``db_list``).
        offset:    Offset-based pagination offset.  Ignored when
                   ``before_ts > 0`` (keyset path).
        before_ts: Keyset cursor — return only pastes older than this
                   Unix timestamp.  ``0`` selects the offset path.
        search:    Substring search filter applied to title and content.
                   Empty string disables filtering.

    Returns:
        200 OK with ``{"pastes":[...],"count":<n>}`` and optionally
        ``"next_before":<unix_ts>`` for keyset pagination continuation.
    """
    var pastes = db_list(db, limit, offset, before_ts, search)
    var arr = _pastes_to_json_array(pastes)
    var n = len(pastes)
    var body = '{"pastes":' + arr + ',"count":' + String(n)

    if before_ts > 0 and n == min(limit, 100):
        body += ',"next_before":' + String(pastes[n - 1].created_at)

    body += "}"
    return ok_json(body)


def stats_handler(db: Database) raises -> Response:
    """Handle GET /stats — aggregate statistics.

    Args:
        db: Open database connection.

    Returns:
        200 OK with ``{"total":<n>,"today":<n>,"total_views":<n>}``.
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
    return ok_json(body)
