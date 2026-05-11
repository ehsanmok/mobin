"""HTTP routing + middleware stack for mobin pastebin.

The handler chain wired up by ``build_router(state)``::

    CatchPanic
      └── RequestId
            └── Logger
                  └── Cors
                        └── MobinHandler   # Defaultable shim around Router
                              └── Router   # method + path → per-route Handler

- ``CatchPanic`` turns any raise from the handler chain into a sanitised
  500 response so a single bad request can never tear the server down.
- ``RequestId`` echoes the inbound ``X-Request-Id`` (or generates one
  derived from ``perf_counter_ns``) on the outbound response.
- ``Logger`` prints ``method url status latency`` per request to stdout.
- ``Cors`` runs the spec'd CORS dance: allowed-origin check, preflight
  short-circuit (``OPTIONS`` + ``Access-Control-Request-Method``), and
  outbound ``Access-Control-*`` header attachment.
- ``MobinHandler`` is a tiny ``Defaultable``-conforming wrapper around
  ``Router`` (the framework's ``Router`` is constructible with no args
  but does not declare ``Defaultable``; the middleware ``Inner`` trait
  bound requires it). It carries no logic of its own.
- ``Router`` does method + path dispatch to the per-route handlers.

Each per-route handler is a small ``Handler``-conforming struct that
captures the slice of ``AppState`` it needs and opens its own SQLite
connection per request. Path params are read via ``req.param("id")``;
query parameters are read inside ``list_pastes_handler`` via
``req.query_param``. Both reads are zero-allocation on the empty case.
"""

from flare.prelude import *
from flare.http import (
    CatchPanic,
    Cors,
    CorsConfig,
    Handler,
    Logger,
    RequestId,
)
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


# ── Router shim — Defaultable wrapper around flare.Router ────────────────────


@fieldwise_init
struct MobinHandler(Copyable, Defaultable, Handler, Movable):
    """Tiny ``Defaultable``-conforming wrapper around ``Router``.

    The four middleware structs (``Cors``, ``Logger``, ``RequestId``,
    ``CatchPanic``) all parameterise their inner handler as
    ``Inner: Handler & Copyable & Defaultable``. Plain ``flare.Router``
    is constructible with no args but does not declare ``Defaultable``,
    so wrapping it directly fails the trait bound. ``MobinHandler``
    bridges the gap: it carries no logic of its own (its ``serve``
    forwards straight to the inner router) and exists purely so the
    middleware stack composes.
    """

    var inner: Router

    def __init__(out self):
        """Default-construct the inner router with no routes registered.

        Required by the ``Defaultable`` trait; the production code path
        always uses the ``@fieldwise_init`` constructor with a fully
        populated router. The default-constructed shape is only there
        to satisfy the trait bound on the middleware ``Inner`` slot.
        """
        self.inner = Router()

    def serve(self, req: Request) raises -> Response:
        return self.inner.serve(req)


# ── Public middleware-wrapped handler type ───────────────────────────────────
#
# The full type spelling out the middleware chain. ``alias`` lets callers
# (``main.mojo``, the unit tests) declare a single concrete return /
# variable type rather than chasing the nested generic spelling.

comptime MobinApp = CatchPanic[RequestId[Logger[Cors[MobinHandler]]]]


# ── CORS configuration ──────────────────────────────────────────────────────


def _cors_config() -> CorsConfig:
    """Return the CORS policy for the mobin API.

    Wildcard origin (the API is intentionally public) + the four mutating
    HTTP methods plus ``OPTIONS``. ``X-Delete-Token`` is whitelisted as a
    custom request header so the frontend can send the per-paste delete
    token without hitting the standard-header allowlist. Credentials are
    off (``allow_credentials=False``) so the wildcard-origin shortcut
    in ``Cors`` is honoured.
    """
    var cfg = CorsConfig()
    cfg.allowed_origins.append("*")
    cfg.allowed_methods = List[String]()
    cfg.allowed_methods.append("GET")
    cfg.allowed_methods.append("POST")
    cfg.allowed_methods.append("PUT")
    cfg.allowed_methods.append("DELETE")
    cfg.allowed_methods.append("OPTIONS")
    cfg.allowed_headers.append("Content-Type")
    cfg.allowed_headers.append("X-Delete-Token")
    cfg.max_age_seconds = 600
    cfg.allow_credentials = False
    return cfg^


# ── Router factory + middleware stack ────────────────────────────────────────


def build_router(state: AppState) raises -> MobinApp:
    """Build the mobin handler chain (middleware + router + per-route handlers).

    Routes registered:

    - ``GET    /``                    → embedded SPA shell
    - ``GET    /index.html``          → embedded SPA shell
    - ``GET    /health``              → liveness probe
    - ``GET    /stats``               → aggregate statistics
    - ``GET    /pastes``              → paginated paste list
    - ``POST   /paste``               → create a new paste
    - ``GET    /paste/:id``           → retrieve one paste (or SPA shell)
    - ``PUT    /paste/:id``           → update one paste (token required)
    - ``DELETE /paste/:id``           → delete one paste (token required)

    ``OPTIONS *`` preflight is handled by the ``Cors`` middleware in
    front of the router; the router itself does not register any
    ``OPTIONS`` routes.

    Args:
        state: The DB-path + config snapshot all per-route handlers share.

    Returns:
        A ``MobinApp`` (``CatchPanic[RequestId[Logger[Cors[MobinHandler]]]]``)
        ready to hand to ``HttpServer.serve``.
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
    var router_handler = MobinHandler(inner=r^)
    var cors = Cors(inner=router_handler^, config=_cors_config())
    var logger = Logger(inner=cors^, prefix="[mobin]")
    var with_id = RequestId(inner=logger^)
    return CatchPanic(
        inner=with_id^, body='{"error":"internal server error"}'
    )
