"""Core data models for mobin pastebin.

Defines Paste, PasteStats, and ServerConfig structs along with
the new_paste() factory function.
"""

from uuid import uuid4
from tempo import Timestamp


@fieldwise_init
struct Paste(Defaultable, Movable, ImplicitlyCopyable):
    """A single paste entry stored in SQLite.

    Fields:
        id:         UUID v4 identifier (primary key).
        title:      Human-readable title (may be empty).
        content:    Raw paste content (code or text).
        language:   Syntax-highlight hint, e.g. "python", "plain".
        created_at: Unix seconds of creation time.
        expires_at: Unix seconds of expiry time.
        views:      Number of times this paste has been viewed.
    """

    var id: String
    var title: String
    var content: String
    var language: String
    var created_at: Int
    var expires_at: Int
    var views: Int

    def __init__(out self):
        self.id = ""
        self.title = ""
        self.content = ""
        self.language = "plain"
        self.created_at = 0
        self.expires_at = 0
        self.views = 0


@fieldwise_init
struct PasteStats(Defaultable, Movable):
    """Aggregate statistics for the pastebin service.

    Fields:
        total:       Total non-expired pastes.
        today:       Pastes created in the last 24 hours.
        total_views: Cumulative view count across all pastes.
    """

    var total: Int
    var today: Int
    var total_views: Int

    def __init__(out self):
        self.total = 0
        self.today = 0
        self.total_views = 0


@fieldwise_init
struct ServerConfig(Defaultable, Movable):
    """Runtime configuration for the mobin backend.

    Loaded via envo from config.toml, env vars, and CLI flags.
    Precedence (highest to lowest): CLI > env vars > config.toml.

    Fields:
        host:     Bind address for HTTP and WS servers.
        port:     HTTP server port.
        ws_port:  WebSocket server port.
        db_path:  Path to SQLite database file.
        max_size: Maximum paste size in bytes.
        ttl_days: Default paste time-to-live in days.
    """

    var host: String
    var port: Int
    var ws_port: Int
    var db_path: String
    var max_size: Int
    var ttl_days: Int

    def __init__(out self):
        """Initialise from environment variables with hard-coded fallbacks.

        Reads PORT, WS_PORT, DB_PATH, MAX_SIZE, TTL_DAYS, HOST from the
        environment. Any env var that is absent or non-numeric silently falls
        back to the default so that ServerConfig() satisfies Defaultable.
        """
        from std.os import getenv
        self.host    = getenv("HOST",    "0.0.0.0")
        self.db_path = getenv("DB_PATH", "data/mobin.db")
        try:
            self.port     = Int(getenv("PORT",     "8080"))
        except:
            self.port     = 8080
        try:
            self.ws_port  = Int(getenv("WS_PORT",  "8081"))
        except:
            self.ws_port  = 8081
        try:
            self.max_size = Int(getenv("MAX_SIZE", "65536"))
        except:
            self.max_size = 65536
        try:
            self.ttl_days = Int(getenv("TTL_DAYS", "30"))
        except:
            self.ttl_days = 30


def new_paste(
    title: String,
    content: String,
    language: String,
    ttl_secs: Int,
) raises -> Paste:
    """Create a new Paste with a generated UUID and computed timestamps.

    Args:
        title:    Human-readable title for the paste.
        content:  Paste body (code or text).
        language: Syntax highlight language hint.
        ttl_secs: Seconds until the paste expires (e.g. 3600 = 1 hour).

    Returns:
        A fully initialized Paste ready for insertion into the database.

    Raises:
        Error: If UUID generation fails.
    """
    var now = Int(Timestamp.now().unix_secs())
    return Paste(
        id=String(uuid4()),
        title=title,
        content=content,
        language=language,
        created_at=now,
        expires_at=now + ttl_secs,
        views=0,
    )
