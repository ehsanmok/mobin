"""HTTP request routing for mobin pastebin, built on ``flare.Router``.

Routes are declared via ``r.get / r.post / r.put / r.delete`` with ``:id``
path parameters. Each per-route handler is a small ``Handler`` struct that
owns a snapshot of the application state (DB path + ``MobinConfig``) and
opens its own SQLite connection per request from that path. SQLite's WAL
mode + per-connection locking makes this safe across concurrent workers
in a future commit (``num_workers=N``).

The hand-rolled ``if path == ...`` chain and the bespoke ``_parse_path_query``
helper from the v0.1-shape router are gone — path parameter extraction
goes through ``req.param("id")`` and the query string is read directly via
``req.query_param(name)`` inside ``list_pastes_handler``.

CORS preflight (``OPTIONS *``) is currently handled by ``MobinHandler``,
a thin wrapper around ``Router`` that intercepts the ``OPTIONS`` method.
``MobinHandler`` is transitional: commit 6 deletes it and replaces the
preflight with a proper ``flare.Cors`` middleware in front of the router.
"""

from flare.prelude import *
from flare.http import Handler
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


# ── Application-scoped state ─────────────────────────────────────────────────


@fieldwise_init
struct AppState(Copyable, Defaultable, ImplicitlyCopyable, Movable):
    """Application-scoped state shared by every request.

    Kept minimal in this commit: a DB path + a ``MobinConfig`` snapshot.
    Per-request handlers each open their own SQLite connection from
    ``db_path`` (cheap with WAL mode; multi-worker safe). Commit 8 wraps
    this struct in ``flare.http.App[AppState]`` so the v0.7 ``State[T]``
    extractor wires it through automatically.
    """

    var db_path: String
    var cfg: MobinConfig

    def __init__(out self):
        """Build defaults (data/mobin.db + default ``MobinConfig``)."""
        self.db_path = "data/mobin.db"
        self.cfg = MobinConfig()


@always_inline
def _open_db(db_path: String) raises -> Database:
    """Open a fresh SQLite connection at ``db_path`` with WAL pragmas.

    The pragmas mirror ``main.mojo``'s startup setup so every per-request
    connection sees the same on-disk semantics (write-ahead log + relaxed
    fsync). Per-request open is intentional — SQLite connections are
    cheap, and per-connection locks let multiple flare workers process
    requests in parallel without sharing connection state.
    """
    var db = Database(db_path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    return db^


# ── Per-route Handler structs ────────────────────────────────────────────────
#
# Each route is wired through a tiny ``Handler``-conforming struct that
# captures the slice of ``AppState`` it actually needs. This is the
# transitional shape between the v0.1 closure-capture pattern (kept the
# router function-typed) and the v0.7 typed-extractor pattern
# (``Extracted[H]`` + per-field extractors, landing in commit 7).


@fieldwise_init
struct _IndexHandler(Copyable, Handler, Movable):
    """``GET /`` and ``GET /index.html`` — serve the embedded SPA shell."""

    def serve(self, req: Request) raises -> Response:
        return serve_index()


@fieldwise_init
struct _HealthHandler(Copyable, Handler, Movable):
    """``GET /health`` — liveness probe, no DB hit."""

    def serve(self, req: Request) raises -> Response:
        return health_handler(req)


@fieldwise_init
struct _StatsHandler(Copyable, Handler, Movable):
    """``GET /stats`` — aggregate statistics."""

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        var db = _open_db(self.db_path)
        return stats_handler(req, db)


@fieldwise_init
struct _ListPastesHandler(Copyable, Handler, Movable):
    """``GET /pastes`` — paginated list, reads its own query string."""

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        var db = _open_db(self.db_path)
        return list_pastes_handler(req, db)


@fieldwise_init
struct _CreatePasteHandler(Copyable, Handler, Movable):
    """``POST /paste`` — create a new paste."""

    var db_path: String
    var cfg: MobinConfig

    def serve(self, req: Request) raises -> Response:
        var db = _open_db(self.db_path)
        return create_paste_handler(req, db, self.cfg)


@fieldwise_init
struct _GetPasteHandler(Copyable, Handler, Movable):
    """``GET /paste/:id`` — fetch a paste, or serve the SPA on browser nav.

    A browser navigating directly to ``/paste/<id>`` sends
    ``Accept: text/html``; in that case we hand back the embedded
    frontend so the SPA can render the paste client-side. Programmatic
    JSON requests (``Accept: application/json``, or any non-HTML accept)
    fall through to the JSON handler.
    """

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        var accept = req.headers.get("Accept")
        if accept.find("text/html") >= 0:
            return serve_index()
        var db = _open_db(self.db_path)
        var paste_id = req.param("id")
        return get_paste_handler(req, db, paste_id)


@fieldwise_init
struct _UpdatePasteHandler(Copyable, Handler, Movable):
    """``PUT /paste/:id`` — update an existing paste (auth required)."""

    var db_path: String
    var cfg: MobinConfig

    def serve(self, req: Request) raises -> Response:
        var db = _open_db(self.db_path)
        var paste_id = req.param("id")
        return update_paste_handler(req, db, self.cfg, paste_id)


@fieldwise_init
struct _DeletePasteHandler(Copyable, Handler, Movable):
    """``DELETE /paste/:id`` — remove a paste (auth required)."""

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        var db = _open_db(self.db_path)
        var paste_id = req.param("id")
        return delete_paste_handler(req, db, paste_id)


# ── CORS preflight wrapper (transitional) ────────────────────────────────────
#
# Replaced wholesale by ``flare.Cors`` middleware in commit 6. Until then
# we wrap the Router in a thin Handler that intercepts ``OPTIONS`` and
# emits the preflight response the frontend expects (Allow-Origin: *,
# the four mutating methods + OPTIONS, and the two custom headers we use).


@fieldwise_init
struct MobinHandler(Copyable, Handler, Movable):
    """``Handler`` wrapper that adds CORS preflight on top of a ``Router``.

    Implements the ``Handler`` trait so the ``HttpServer.serve`` entry
    point + the ``Router``-as-Handler pattern compose cleanly: the
    server calls into ``self.serve``, we short-circuit ``OPTIONS``,
    and everything else delegates to the inner ``Router``. Commit 6
    replaces this struct with a ``Cors(router, CorsConfig(...))``
    middleware pipeline.
    """

    var inner: Router

    def serve(self, req: Request) raises -> Response:
        if req.method == Method.OPTIONS:
            return _cors_preflight()
        return self.inner.serve(req)


def _cors_preflight() raises -> Response:
    """Build the canonical CORS preflight response (204 + Allow-* headers)."""
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


# ── Router factory ───────────────────────────────────────────────────────────


def build_router(state: AppState) raises -> MobinHandler:
    """Build the mobin HTTP router with v0.7 ``Router`` + path params.

    Routes:

    - ``GET    /``                    → embedded SPA shell
    - ``GET    /index.html``          → embedded SPA shell
    - ``GET    /health``              → liveness probe
    - ``GET    /stats``               → aggregate statistics
    - ``GET    /pastes``              → paginated paste list
    - ``POST   /paste``               → create a new paste
    - ``GET    /paste/:id``           → retrieve one paste (or SPA shell)
    - ``PUT    /paste/:id``           → update one paste (token required)
    - ``DELETE /paste/:id``           → delete one paste (token required)
    - ``OPTIONS *``                   → CORS preflight (via ``MobinHandler``)

    Args:
        state: The DB-path + config snapshot all per-route handlers share.

    Returns:
        A ``MobinHandler`` that wraps an inner ``Router`` and adds CORS
        preflight handling. The wrapper is itself a ``Handler``, so it
        slots straight into ``HttpServer.serve(handler)``.
    """
    var r = Router()
    r.get("/", _IndexHandler())
    r.get("/index.html", _IndexHandler())
    r.get("/health", _HealthHandler())
    r.get("/stats", _StatsHandler(db_path=state.db_path))
    r.get("/pastes", _ListPastesHandler(db_path=state.db_path))
    r.post(
        "/paste",
        _CreatePasteHandler(db_path=state.db_path, cfg=state.cfg),
    )
    r.get("/paste/:id", _GetPasteHandler(db_path=state.db_path))
    r.put(
        "/paste/:id",
        _UpdatePasteHandler(db_path=state.db_path, cfg=state.cfg),
    )
    r.delete("/paste/:id", _DeletePasteHandler(db_path=state.db_path))
    return MobinHandler(inner=r^)
