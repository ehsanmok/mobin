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
captures the slice of ``AppState`` it needs and uses flare v0.7's typed
extractors (``PathStr``, ``OptionalQueryInt``, ``OptionalQueryStr``,
``OptionalHeaderStr``, ``BodyText``) to pull request data into typed
locals before delegating to the application-level handler functions in
``handlers.mojo``. Parse failures (e.g. ``?limit=abc``) raise out of
``.extract(req)`` and are caught at the wrapper boundary, turning them
into ``400 Bad Request`` instead of leaking a 500.
"""

from flare.prelude import *
from flare.http import (
    App,
    BodyText,
    CatchPanic,
    Cors,
    CorsConfig,
    Handler,
    Logger,
    OptionalHeaderStr,
    OptionalQueryInt,
    OptionalQueryStr,
    PathStr,
    RequestId,
    State,
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


# ── Per-route Handler structs (typed-extractor edge) ─────────────────────────
#
# Each route is wired through a tiny ``Handler``-conforming struct that
# captures the slice of ``AppState`` it actually needs and uses flare's
# typed extractors as value-constructors (``Extractor.extract(req)``)
# inside ``serve``. The wrapper is the boundary at which "request bytes"
# stop and "typed application values" start: extractor errors are
# caught here and mapped to 400 so the application-level handler in
# ``handlers.mojo`` sees only validated typed inputs.
#
# Why not ``Extracted[H]``? ``Extracted[H]`` reflects on ``H``'s field
# list and treats every field as an ``Extractor``, which means ``H``
# can't carry state-capture fields (``db_path``, ``cfg``). Until the
# v0.7 ``State[S]`` extractor lands (commit 8 wires up
# ``App[AppState]``; ``State[S]`` injection itself is on the flare
# roadmap), the value-constructor pattern is the right level of
# integration: it keeps the per-route struct's state private while
# still routing every request datum through a typed extractor.


# ── Optional-query-int helper ────────────────────────────────────────────────
#
# ``OptionalQueryInt[name]`` returns ``Optional[Int]``: ``None`` when
# the parameter is absent, ``Some(value)`` when present and parseable.
# A *present-but-bad* value (``?limit=abc``) raises out of
# ``.extract``; the wrapper's ``try/except`` catches it and returns
# 400. This helper folds the ``if x.value: x.value.value() else
# default`` pattern into a single line so the per-route ``serve``
# bodies stay readable.


@always_inline
def _opt_int[name: StaticString](req: Request, default_val: Int) raises -> Int:
    """Read optional query param ``name`` as ``Int``, defaulting to ``default_val``.
    """
    var x = OptionalQueryInt[name].extract(req)
    return x.value.value() if x.value else default_val


@always_inline
def _opt_str[
    name: StaticString
](req: Request, default_val: String) raises -> String:
    """Read optional query param ``name`` as ``String``, defaulting to ``default_val``.
    """
    var x = OptionalQueryStr[name].extract(req)
    return x.value.value() if x.value else default_val


@always_inline
def _opt_header_str[
    name: StaticString
](req: Request, default_val: String) raises -> String:
    """Read optional header ``name`` as ``String``, defaulting to ``default_val``.
    """
    var x = OptionalHeaderStr[name].extract(req)
    return x.value.value() if x.value else default_val


@fieldwise_init
struct _IndexHandler(Copyable, Handler, Movable):
    """``GET /`` and ``GET /index.html`` — serve the embedded SPA shell."""

    def serve(self, req: Request) raises -> Response:
        return serve_index()


@fieldwise_init
struct _HealthHandler(Copyable, Handler, Movable):
    """``GET /health`` — liveness probe, no DB hit."""

    def serve(self, req: Request) raises -> Response:
        return health_handler()


@fieldwise_init
struct _StatsHandler(Copyable, Handler, Movable):
    """``GET /stats`` — aggregate statistics."""

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        var db = _open_db(self.db_path)
        return stats_handler(db)


@fieldwise_init
struct _ListPastesHandler(Copyable, Handler, Movable):
    """``GET /pastes`` — paginated list with typed query extractors.

    The four query parameters are pulled through
    ``OptionalQueryInt`` / ``OptionalQueryStr`` so a malformed
    ``?limit=abc`` returns a clean 400 instead of falling through to a
    silent default (which is what the pre-v0.7 ``_parse_int`` shim used
    to do).
    """

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        try:
            var limit = _opt_int["limit"](req, 20)
            var offset = _opt_int["offset"](req, 0)
            var before_ts = _opt_int["before"](req, 0)
            var search = _opt_str["q"](req, String(""))
            var db = _open_db(self.db_path)
            return list_pastes_handler(db, limit, offset, before_ts, search)
        except e:
            return bad_request(String(e))


@fieldwise_init
struct _CreatePasteHandler(Copyable, Handler, Movable):
    """``POST /paste`` — create a new paste from a JSON body."""

    var db_path: String
    var cfg: MobinConfig

    def serve(self, req: Request) raises -> Response:
        try:
            var body = BodyText.extract(req).value
            var db = _open_db(self.db_path)
            return create_paste_handler(db, self.cfg, body)
        except e:
            return bad_request(String(e))


@fieldwise_init
struct _GetPasteHandler(Copyable, Handler, Movable):
    """``GET /paste/:id`` — fetch a paste, or serve the SPA on browser nav.

    A browser navigating directly to ``/paste/<id>`` sends
    ``Accept: text/html``; in that case we hand back the embedded
    frontend so the SPA can render the paste client-side. Programmatic
    JSON requests (``Accept: application/json``, or any non-HTML accept)
    fall through to the JSON handler.

    Both reads — the ``:id`` path capture and the ``Accept`` header —
    go through typed extractors (``PathStr`` / ``OptionalHeaderStr``).
    """

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        try:
            var accept = _opt_header_str["Accept"](req, String(""))
            if accept.find("text/html") >= 0:
                return serve_index()
            var paste_id = PathStr["id"].extract(req).value
            var db = _open_db(self.db_path)
            return get_paste_handler(db, paste_id)
        except e:
            return bad_request(String(e))


@fieldwise_init
struct _UpdatePasteHandler(Copyable, Handler, Movable):
    """``PUT /paste/:id`` — update an existing paste (auth required)."""

    var db_path: String
    var cfg: MobinConfig

    def serve(self, req: Request) raises -> Response:
        try:
            var paste_id = PathStr["id"].extract(req).value
            var token = _opt_header_str["X-Delete-Token"](req, String(""))
            var body = BodyText.extract(req).value
            var db = _open_db(self.db_path)
            return update_paste_handler(
                db, self.cfg, paste_id, token, body
            )
        except e:
            return bad_request(String(e))


@fieldwise_init
struct _DeletePasteHandler(Copyable, Handler, Movable):
    """``DELETE /paste/:id`` — remove a paste (auth required)."""

    var db_path: String

    def serve(self, req: Request) raises -> Response:
        try:
            var paste_id = PathStr["id"].extract(req).value
            var token = _opt_header_str["X-Delete-Token"](req, String(""))
            var db = _open_db(self.db_path)
            return delete_paste_handler(db, paste_id, token)
        except e:
            return bad_request(String(e))


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
# Two ``comptime`` aliases spell the public types so ``main.mojo`` and
# the unit tests don't have to chase the nested-generic spelling:
#
# * ``MobinApp`` — the bare middleware stack
#   (``CatchPanic > RequestId > Logger > Cors > MobinHandler``).
#   Returned by ``build_router`` and used by the unit tests, which
#   want a concrete handler with no app-state plumbing on top.
#
# * ``MobinService`` — ``App[AppState, MobinApp]``, the production
#   shape: the same middleware chain with an ``AppState`` snapshot
#   bolted on so a future ``State[AppState]`` extractor (or any
#   middleware that calls ``app.state_view()``) can pull
#   request-independent state without a global. Returned by
#   ``build_app``; this is what ``main.mojo`` hands to
#   ``HttpServer.serve``.

comptime MobinApp = CatchPanic[RequestId[Logger[Cors[MobinHandler]]]]
comptime MobinService = App[AppState, MobinApp]


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
    """Build the mobin middleware chain + router + per-route handlers.

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

    Returns the *bare* middleware-wrapped chain — no ``App[AppState]``
    wrapper. That makes it the right thing to dispatch through in
    unit tests (``backend/tests/test_router.mojo``), which want to
    drive ``serve`` without wiring the typed-state plumbing.
    Production code goes through ``build_app`` instead, which wraps
    this in ``App[AppState, MobinApp]``.

    Args:
        state: The DB-path + config snapshot all per-route handlers share.

    Returns:
        A ``MobinApp`` (``CatchPanic[RequestId[Logger[Cors[MobinHandler]]]]``)
        ready to hand to ``HttpServer.serve`` (or to wrap in ``App``).
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


def build_app(state: AppState) raises -> MobinService:
    """Build the production handler tree: ``App[AppState] > MobinApp``.

    This is the v0.7-shaped entry point for ``HttpServer.serve``. The
    ``App`` wrapper carries the ``AppState`` snapshot alongside the
    middleware chain; the per-route handlers still capture their own
    slice of state at registration time, so request-time state lookup
    is a struct field read, not a hash lookup. The wrapper is
    primarily a hook for the future v0.7 ``State[AppState]`` extractor
    + any middleware that wants to call ``app.state_view()`` (the
    pattern in ``flare/examples/intermediate/state.mojo``).

    The returned ``App`` keeps an owned copy of ``state`` and the
    full middleware-wrapped router; the caller transfers ownership of
    both into the ``HttpServer`` via the standard ``serve(app^)``.

    Args:
        state: The shared DB-path + ``MobinConfig`` snapshot.

    Returns:
        A ``MobinService`` (``App[AppState, MobinApp]``) ready for
        ``HttpServer.serve``.
    """
    var router = build_router(state)
    return App(state=state, handler=router^)
