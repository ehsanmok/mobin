"""mobin backend entry point.

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
from flare.http import HttpServer, Request, Response
from flare.ws import WsServer, WsConnection
from flare.net import SocketAddr

from mobin import (
    ServerConfig,
    init_db,
    router,
    feed_handler,
)


# ── Per-request handlers ──────────────────────────────────────────────────────


def _http_handler(req: Request) raises -> Response:
    """Handle one HTTP request.

    Opens a fresh SQLite connection per request using ``DB_PATH`` from the
    process environment.

    Args:
        req: Incoming HTTP request.

    Returns:
        HTTP response.
    """
    var db_path = getenv("DB_PATH", "data/mobin.db")
    var db = Database(db_path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    var cfg = ServerConfig()
    cfg.db_path = db_path
    return router(req, db, cfg)


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
        var dir_part = String(unsafe_from_utf8=db_path.as_bytes()[:slash_pos])
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
        # ── Child: WebSocket server ───────────────────────────────────────────
        try:
            var ws_srv = WsServer.bind(SocketAddr.unspecified(UInt16(ws_port)))
            print("WS   server ready on :" + String(ws_port))
            ws_srv.serve(_ws_handler)
        except e:
            print("[ws] fatal: " + String(e))
        return  # child exits normally

    if pid < 0:
        raise Error("fork() failed (rc=" + String(pid) + ")")

    # ── Parent: HTTP server ───────────────────────────────────────────────────
    try:
        var srv = HttpServer.bind(SocketAddr.unspecified(UInt16(port)))
        print("HTTP server ready on :" + String(port))
        srv.serve(_http_handler)
    except e:
        print("[http] fatal: " + String(e))

    # HTTP server exited — send SIGTERM to the WS child.
    _ = external_call["kill", Int32](Int32(pid), Int32(15))
