"""Mobin backend entry point.

Reads configuration from environment variables and launches two servers in
separate OS processes via ``fork()``:

  * Parent process — HTTP server  (PORT env var, default 8080)
  * Child process  — WebSocket server (WS_PORT env var, default 8081)

``fork()`` gives full process isolation: a crash or panic in the WS child
cannot kill the HTTP parent, and vice-versa.  This is why we do NOT use
``parallelize``—its ``TaskGroup`` calls ``abort()`` on any exception that
escapes a task, which would kill both servers on the first WS disconnection.

``std.os.process.Process.run()`` is NOT used here because it does not inherit
the parent's environment when invoking ``posix_spawnp`` (stdlib bug: ``envp``
is not passed, so every ``getenv()`` call in the child returns the default).
``fork()`` is correct: the child inherits the full environment via the OS
copy-on-write mechanism.

The database schema is created once BEFORE the fork so both processes
inherit the same on-disk state.  Each handler then opens its own SQLite
connection per-request/per-connection.

Usage:
    pixi run build
    ./mobin-backend                     # built-in defaults
    DB_PATH=/tmp/my.db PORT=9000 ./mobin-backend
"""

from std.ffi import external_call
from std.os import getenv, makedirs
from sqlite import Database
from flare.http import HttpServer
from flare.runtime import default_worker_count
from flare.ws import WsServer, WsConnection
from flare.net import SocketAddr

from mobin import (
    AppState,
    MobinConfig,
    init_db,
    db_purge_expired,
    build_router,
    feed_handler,
)


# ── Per-request handlers ──────────────────────────────────────────────────────


def _ws_handler(conn: WsConnection) raises:
    """Handle one WebSocket connection.

    Opens a fresh SQLite connection for the lifetime of the connection.

    Args:
        conn: Established WebSocket connection.
    """
    var db_path = getenv("DB_PATH", "data/mobin.db")
    var db = Database(db_path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    feed_handler(conn, db)


# ── Schema initialisation ─────────────────────────────────────────────────────


def _init_schema(db_path: String) raises:
    """Create database tables if they do not yet exist.

    Opens a temporary SQLite connection, applies WAL mode and runs
    ``init_db``, then closes the connection before returning.  Call this
    once in the main process **before** ``fork()`` so both child processes
    inherit the schema on-disk without owning any open connection.

    Args:
        db_path: Path to the SQLite database file.

    Raises:
        Error: If the database cannot be opened or the schema creation fails.
    """
    var db = Database(db_path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    init_db(db)
    # Purge any rows that expired while the service was down, so stale data
    # is never served.  Errors are non-fatal: the service can still run.
    try:
        var purged = db_purge_expired(db)
        if purged > 0:
            print("startup: purged " + String(purged) + " expired paste(s)")
    except:
        pass
    # db goes out of scope → sqlite3_close() called automatically.


# ── Entry point ───────────────────────────────────────────────────────────────


def main() raises:
    """Init the database schema, then start both servers in separate processes.

    Forks the process after schema creation:
    * child  → WebSocket server on WS_PORT
    * parent → HTTP server on PORT

    Both processes read ``DB_PATH`` from the environment and open independent
    SQLite connections, so there is no shared state across the fork.
    """
    var db_path = getenv("DB_PATH", "data/mobin.db")
    var port    = Int(getenv("PORT", "8080"))
    var ws_port = Int(getenv("WS_PORT", "8081"))

    # Ensure the parent directory of the DB file exists.
    var slash_pos = db_path.rfind("/")
    if slash_pos > 0:
        var dir_part = String(from_utf8_lossy=db_path[byte=:slash_pos].as_bytes())
        try:
            makedirs(dir_part, exist_ok=True)
        except:
            pass  # already exists or no permission — sqlite3_open will fail

    # Create schema once before forking so both processes see the tables.
    _init_schema(db_path)

    print("mobin backend starting")
    print("  HTTP  → 0.0.0.0:" + String(port))
    print("  WS    → 0.0.0.0:" + String(ws_port))
    print("  DB    → " + db_path)

    # Fork: child = WS server, parent = HTTP server.
    #
    # We use fork() rather than parallelize() because parallelize() uses
    # Mojo's AsyncRT TaskGroup which calls abort() if any exception escapes
    # a task.  A routine WS disconnection (NetworkError) would therefore kill
    # both servers.  fork() gives full OS-level isolation.
    var pid = Int(external_call["fork", Int32]())

    if pid == 0:
        # ── Child: WebSocket server (with self-restart on failure) ────────────
        # If _ws_handler raises (e.g. EPIPE on client disconnect) flare's
        # serve() loop catches it per-connection and keeps running.  The outer
        # try/except here handles the rare case where bind() or serve() itself
        # throws (e.g. address already in use on restart, OS error).  We retry
        # up to MAX_WS_RESTARTS times with an exponential back-off cap of 16 s.
        comptime MAX_WS_RESTARTS = 10
        var attempts = 0
        while attempts < MAX_WS_RESTARTS:
            try:
                var ws_srv = WsServer.bind(SocketAddr.unspecified(UInt16(ws_port)))
                print("WS server ready on :" + String(ws_port))
                ws_srv.serve(_ws_handler)
                # serve() returned cleanly (shutdown signal) — exit without retry.
                break
            except e:
                attempts += 1
                var backoff = min(1 << attempts, 16)  # 2, 4, 8 … capped at 16 s
                print(
                    "[ws] error (attempt "
                    + String(attempts) + "/" + String(MAX_WS_RESTARTS)
                    + ", retry in " + String(backoff) + "s): "
                    + String(e)
                )
                _ = external_call["sleep", Int32](Int32(backoff))
        if attempts >= MAX_WS_RESTARTS:
            print("[ws] fatal: exceeded max restarts, giving up")
        return  # child exits — Docker / OS will not restart it; HTTP parent continues

    if pid < 0:
        raise Error("fork() failed (rc=" + String(pid) + ")")

    # ── Parent: HTTP server (multi-worker SO_REUSEPORT) ───────────────────────
    #
    # Build the v0.7 ``MobinApp`` middleware-wrapped router once at
    # startup with an immutable ``AppState`` snapshot (db_path +
    # ``MobinConfig``). The router is itself a ``Handler & Copyable``,
    # so it slots straight into the multi-worker
    # ``HttpServer.serve(handler, num_workers=N)`` overload.
    #
    # Multi-worker serve (``num_workers=default_worker_count()``) spins
    # up one pthread reactor per CPU core, each binding its own
    # ``SO_REUSEPORT`` listener on the same address: the kernel hashes
    # new 4-tuples to one of N listeners, giving near-linear scaling on
    # IO-bound HTTP plaintext without contending on a single accept fd.
    # Pinning is on by default on Linux (no-op on macOS). The
    # ``MOBIN_HTTP_WORKERS`` env var lets ops override the auto-detected
    # CPU count for benchmarking or container-CPU-quota scenarios.
    #
    # The per-route handlers inside the middleware chain each open
    # their own SQLite connection from ``state.db_path`` per request
    # (cheap with WAL mode, multi-worker safe — every worker gets its
    # own connection per request, no shared state). ``build_app`` is
    # kept available for the eventual ``App[AppState]`` runtime path
    # but is unused here: ``App`` does not yet declare ``Copyable``,
    # which the multi-worker overload's ``H: Handler & Copyable``
    # bound requires.
    try:
        var cfg = MobinConfig()
        cfg.db_path = db_path
        var state = AppState(db_path=db_path, cfg=cfg)
        var router = build_router(state)
        var workers = Int(
            getenv("MOBIN_HTTP_WORKERS", String(default_worker_count()))
        )
        if workers <= 0:
            workers = 1
        var srv = HttpServer.bind(SocketAddr.unspecified(UInt16(port)))
        print(
            "HTTP server ready on :"
            + String(port)
            + " ("
            + String(workers)
            + " worker(s))"
        )
        srv.serve(router^, num_workers=workers)
    except e:
        print("[http] fatal: " + String(e))

    # HTTP server exited — send SIGTERM to the WS child.
    _ = external_call["kill", Int32](Int32(pid), Int32(15))
