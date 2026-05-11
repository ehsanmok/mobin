"""WebSocket live feed handler for mobin pastebin.

Runs in a separate OS thread (spawned by parallelize) and polls the SQLite
database every 500 ms for new pastes, broadcasting them as JSON to connected
clients. Each WsServer connection is handled sequentially — one client at a
time (WsServer v0.1.0 is single-threaded).

Disconnection detection: a WS PING frame is sent after each sleep. If the
client has disconnected, ``send_frame`` raises ``NetworkError``, which
propagates up through ``_handle_ws_connection`` (which swallows it), allowing
``WsServer.serve`` to accept the next connection immediately.

Usage in main.mojo:
    var ws_srv = WsServer.bind(SocketAddr.unspecified(cfg.ws_port))
    ws_srv.serve(def(conn: WsConnection) capturing: feed_handler(conn, ws_db))
"""

from flare.ws import WsConnection, WsFrame
from flare.utils import usleep
from sqlite import Database
from tempo import Timestamp
from morph.json import write
from .db import db_list_since, db_purge_expired


def feed_handler(conn: WsConnection, db: Database) raises:
    """Push new pastes to a connected WebSocket client every 500 ms.

    Polls the database for pastes created since the last poll and sends each
    one as a JSON string over the WebSocket connection. A WS PING frame is
    sent after each sleep to detect client disconnection: if the peer has
    gone away, ``send_frame`` raises ``NetworkError``, which terminates this
    function and allows ``WsServer.serve`` to accept the next connection.

    Args:
        conn: Established WebSocket connection to a client.
        db:   SQLite connection in WAL mode (open for the connection lifetime).

    Raises:
        NetworkError: When the client disconnects. Propagates to WsServer
                      which swallows it and continues accepting connections.
    """
    # Include pastes from 1 second before connection so the client sees any
    # paste that was created just before it connected.
    var last_seen = Int(Timestamp.now().unix_secs()) - 1

    # Purge expired rows every 60 s (120 × 0.5 s poll intervals).
    # Running in the WS process avoids adding a background thread and keeps
    # the HTTP process free from GC-style pauses.
    comptime PURGE_INTERVAL = 120
    var purge_tick = 0

    while True:
        var new_pastes = db_list_since(db, last_seen)
        for i in range(len(new_pastes)):
            conn.send_text(write(new_pastes[i]))

        if len(new_pastes) > 0:
            # Advance cursor to the most recent paste we sent.
            last_seen = new_pastes[len(new_pastes) - 1].created_at

        # Short poll interval: keeps latency low and lets disconnection
        # detection happen quickly. ``flare.utils.usleep`` is used instead
        # of ``std.time.sleep`` because the latter declares ``nanosleep``
        # with a stdlib signature that conflicts with flare's own
        # ``nanosleep`` declaration in ``flare.runtime._libc_time`` —
        # importing both into the same compilation unit fails to lower
        # to LLVM IR ("existing function with conflicting signature").
        usleep(500_000)

        # PING heartbeat — raises NetworkError if the client disconnected
        # during the sleep, which exits this loop and unblocks the server's
        # accept() call so it can serve the next client.
        conn.send_frame(WsFrame.ping())

        # Periodic cleanup: delete expired rows so the table stays bounded.
        purge_tick += 1
        if purge_tick >= PURGE_INTERVAL:
            purge_tick = 0
            try:
                var n = db_purge_expired(db)
                if n > 0:
                    print("[ws] purged " + String(n) + " expired paste(s)")
            except:
                pass  # non-fatal — will retry next interval
