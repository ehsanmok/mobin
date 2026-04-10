"""SQLite database layer for mobin pastebin.

All functions open a WAL-mode connection for concurrent reader/writer access.
The HTTP server uses a single read-write connection; the WS feed server uses a
separate read-only connection — both point to the same SQLite file.

WAL mode allows multiple concurrent readers and one writer without blocking.
"""

from sqlite import Database, Statement
from tempo import Timestamp
from .models import Paste, PasteStats


def _now() -> Int:
    """Return current Unix timestamp in seconds."""
    return Int(Timestamp.now().unix_secs())


def _row_to_paste(stmt: Statement) raises -> Optional[Paste]:
    """Step a statement and convert the next row to a Paste.

    Args:
        stmt: A prepared SELECT statement positioned before a row.

    Returns:
        An Optional[Paste] — Some if a row was available, None otherwise.
    """
    var row_opt = stmt.step()
    if not row_opt:
        return None
    var row = row_opt.take()
    return Paste(
        id=row.text_val(0),
        title=row.text_val(1),
        content=row.text_val(2),
        language=row.text_val(3),
        created_at=row.int_val(4),
        expires_at=row.int_val(5),
        views=row.int_val(6),
    )


def init_db(db: Database) raises:
    """Create the pastes table and enable WAL journal mode.

    Idempotent — safe to call on every startup.

    Args:
        db: Open SQLite database connection to initialize.

    Raises:
        Error: If DDL execution fails.
    """
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA foreign_keys=ON")
    db.execute(
        "CREATE TABLE IF NOT EXISTS pastes ("
        "  id TEXT PRIMARY KEY,"
        "  title TEXT NOT NULL DEFAULT '',"
        "  content TEXT NOT NULL,"
        "  language TEXT NOT NULL DEFAULT 'plain',"
        "  created_at INTEGER NOT NULL,"
        "  expires_at INTEGER NOT NULL,"
        "  views INTEGER NOT NULL DEFAULT 0"
        ")"
    )
    db.execute(
        "CREATE INDEX IF NOT EXISTS idx_pastes_created ON pastes(created_at)"
    )
    db.execute(
        "CREATE INDEX IF NOT EXISTS idx_pastes_expires ON pastes(expires_at)"
    )


def db_create(db: Database, paste: Paste) raises:
    """Insert a new Paste into the database.

    Args:
        db:    Open SQLite database connection.
        paste: The Paste to insert (id must be unique).

    Raises:
        Error: On UNIQUE constraint violation or other SQLite error.
    """
    var stmt = db.prepare(
        "INSERT INTO pastes (id, title, content, language, created_at,"
        " expires_at, views) VALUES (?, ?, ?, ?, ?, ?, ?)"
    )
    stmt.bind_text(1, paste.id)
    stmt.bind_text(2, paste.title)
    stmt.bind_text(3, paste.content)
    stmt.bind_text(4, paste.language)
    stmt.bind_int(5, paste.created_at)
    stmt.bind_int(6, paste.expires_at)
    stmt.bind_int(7, paste.views)
    _ = stmt.step()


def db_get(db: Database, paste_id: String) raises -> Optional[Paste]:
    """Retrieve a non-expired paste by ID.

    Args:
        db:       Open SQLite database connection.
        paste_id: UUID string of the paste to fetch.

    Returns:
        Some(Paste) if found and not expired, None otherwise.

    Raises:
        Error: On SQLite error.
    """
    var now = _now()
    var stmt = db.prepare(
        "SELECT id, title, content, language, created_at, expires_at, views"
        " FROM pastes WHERE id = ? AND expires_at > ?"
    )
    stmt.bind_text(1, paste_id)
    stmt.bind_int(2, now)
    return _row_to_paste(stmt)


def db_inc_views(db: Database, paste_id: String) raises:
    """Atomically increment the view counter for a paste.

    Args:
        db:       Open SQLite database connection.
        paste_id: UUID string of the paste to update.

    Raises:
        Error: On SQLite error.
    """
    var stmt = db.prepare(
        "UPDATE pastes SET views = views + 1 WHERE id = ?"
    )
    stmt.bind_text(1, paste_id)
    _ = stmt.step()


def db_delete(db: Database, paste_id: String) raises:
    """Delete a paste by ID.

    Args:
        db:       Open SQLite database connection.
        paste_id: UUID string of the paste to delete.

    Raises:
        Error: On SQLite error.
    """
    var stmt = db.prepare("DELETE FROM pastes WHERE id = ?")
    stmt.bind_text(1, paste_id)
    _ = stmt.step()


def db_list(
    db: Database, limit: Int = 20, offset: Int = 0
) raises -> List[Paste]:
    """Return a paginated list of non-expired pastes, newest first.

    Args:
        db:     Open SQLite database connection.
        limit:  Maximum number of results (default 20, capped at 100).
        offset: Number of rows to skip for pagination.

    Returns:
        List of Paste objects ordered by creation time descending.

    Raises:
        Error: On SQLite error.
    """
    var safe_limit = min(limit, 100)
    var now = _now()
    var stmt = db.prepare(
        "SELECT id, title, content, language, created_at, expires_at, views"
        " FROM pastes WHERE expires_at > ?"
        " ORDER BY created_at DESC LIMIT ? OFFSET ?"
    )
    stmt.bind_int(1, now)
    stmt.bind_int(2, safe_limit)
    stmt.bind_int(3, offset)

    var results = List[Paste]()
    while True:
        var row_opt = stmt.step()
        if not row_opt:
            break
        var row = row_opt.take()
        results.append(
            Paste(
                id=row.text_val(0),
                title=row.text_val(1),
                content=row.text_val(2),
                language=row.text_val(3),
                created_at=row.int_val(4),
                expires_at=row.int_val(5),
                views=row.int_val(6),
            )
        )
    return results^


def db_list_since(db: Database, since_secs: Int) raises -> List[Paste]:
    """Return non-expired pastes created after since_secs, oldest first.

    Used by the WebSocket feed to push new pastes to connected clients.

    Args:
        db:         Open SQLite database connection (read-only usage).
        since_secs: Unix timestamp — return pastes created after this.

    Returns:
        List of Paste objects ordered by creation time ascending, max 50.

    Raises:
        Error: On SQLite error.
    """
    var now = _now()
    var stmt = db.prepare(
        "SELECT id, title, content, language, created_at, expires_at, views"
        " FROM pastes WHERE created_at > ? AND expires_at > ?"
        " ORDER BY created_at ASC LIMIT 50"
    )
    stmt.bind_int(1, since_secs)
    stmt.bind_int(2, now)

    var results = List[Paste]()
    while True:
        var row_opt = stmt.step()
        if not row_opt:
            break
        var row = row_opt.take()
        results.append(
            Paste(
                id=row.text_val(0),
                title=row.text_val(1),
                content=row.text_val(2),
                language=row.text_val(3),
                created_at=row.int_val(4),
                expires_at=row.int_val(5),
                views=row.int_val(6),
            )
        )
    return results^


def db_stats(db: Database) raises -> PasteStats:
    """Return aggregate statistics for all non-expired pastes.

    Args:
        db: Open SQLite database connection.

    Returns:
        PasteStats with total, today (last 24h), and total_views.

    Raises:
        Error: On SQLite error.
    """
    var now = _now()
    var yesterday = now - 86400
    var stmt = db.prepare(
        "SELECT COUNT(*) as total,"
        " COALESCE(SUM(CASE WHEN created_at > ? THEN 1 ELSE 0 END), 0) as today,"
        " COALESCE(SUM(views), 0) as total_views"
        " FROM pastes WHERE expires_at > ?"
    )
    stmt.bind_int(1, yesterday)
    stmt.bind_int(2, now)

    var row_opt = stmt.step()
    if not row_opt:
        return PasteStats()
    var row = row_opt.take()
    return PasteStats(
        total=row.int_val(0),
        today=row.int_val(1),
        total_views=row.int_val(2),
    )
