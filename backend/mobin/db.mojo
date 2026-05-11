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


def _today_int() -> Int:
    """Return today's date as an integer YYYYMMDD in UTC."""
    var ts = _now()
    var days = ts // 86400
    # Convert days since epoch to YYYYMMDD.
    # 算法 from https://howardhinnant.github.io/date_algorithms.html
    var z = days + 719468
    var era = z // 146097 if z >= 0 else (z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return Int(y) * 10000 + Int(m) * 100 + Int(d)


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

    Idempotent — safe to call on every startup. Automatically migrates
    existing databases by adding new columns if they are missing.

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
        "  views INTEGER NOT NULL DEFAULT 0,"
        "  delete_token TEXT NOT NULL DEFAULT ''"
        ")"
    )
    db.execute(
        "CREATE INDEX IF NOT EXISTS idx_pastes_created ON pastes(created_at)"
    )
    db.execute(
        "CREATE INDEX IF NOT EXISTS idx_pastes_expires ON pastes(expires_at)"
    )
    # Migration: add delete_token column to databases created before this
    # column existed. SQLite errors if the column already exists, so we
    # swallow that error and treat it as a no-op.
    try:
        db.execute(
            "ALTER TABLE pastes ADD COLUMN delete_token TEXT NOT NULL"
            " DEFAULT ''"
        )
    except:
        pass  # column already present — nothing to do

    # Cumulative stats table -- counters only go up, never decrease on
    # paste expiry or purge.  today_pastes resets when today_date rolls
    # over to a new day (UTC).
    db.execute(
        "CREATE TABLE IF NOT EXISTS stats ("
        "  id INTEGER PRIMARY KEY CHECK (id = 1),"
        "  total_pastes INTEGER NOT NULL DEFAULT 0,"
        "  total_views  INTEGER NOT NULL DEFAULT 0,"
        "  today_pastes INTEGER NOT NULL DEFAULT 0,"
        "  today_date   INTEGER NOT NULL DEFAULT 0"
        ")"
    )
    # Migration: add today_pastes/today_date columns for older schemas.
    # Must run BEFORE the INSERT so all columns exist.
    try:
        db.execute(
            "ALTER TABLE stats ADD COLUMN today_pastes INTEGER NOT NULL"
            " DEFAULT 0"
        )
    except:
        pass
    try:
        db.execute(
            "ALTER TABLE stats ADD COLUMN today_date INTEGER NOT NULL DEFAULT 0"
        )
    except:
        pass
    db.execute(
        "INSERT OR IGNORE INTO stats (id, total_pastes, total_views,"
        " today_pastes, today_date) VALUES (1, 0, 0, 0, 0)"
    )
    # Backfill: if the stats row has 0 totals but pastes already exist
    # (upgrade from older schema), seed the counters from current data.
    var cur_date = _today_int()
    var backfill_stmt = db.prepare(
        "UPDATE stats SET"
        "  total_pastes = (SELECT COUNT(*) FROM pastes),"
        "  total_views  = (SELECT COALESCE(SUM(views), 0) FROM pastes),"
        "  today_pastes = (SELECT COUNT(*) FROM pastes WHERE created_at > ?),"
        "  today_date   = ?"
        " WHERE total_pastes = 0"
        "   AND (SELECT COUNT(*) FROM pastes) > 0"
    )
    var yesterday = _now() - 86400
    backfill_stmt.bind_int(1, yesterday)
    backfill_stmt.bind_int(2, cur_date)
    _ = backfill_stmt.step()


def db_create(db: Database, paste: Paste, delete_token: String = "") raises:
    """Insert a new Paste into the database.

    Args:
        db:           Open SQLite database connection.
        paste:        The Paste to insert (id must be unique).
        delete_token: Unguessable token required to delete this paste.
                      Defaults to "" (no token required) for test
                      convenience; production callers should always supply
                      a UUID-strength token.

    Raises:
        Error: On UNIQUE constraint violation or other SQLite error.
    """
    var stmt = db.prepare(
        "INSERT INTO pastes (id, title, content, language, created_at,"
        " expires_at, views, delete_token) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    )
    stmt.bind_text(1, paste.id)
    stmt.bind_text(2, paste.title)
    stmt.bind_text(3, paste.content)
    stmt.bind_text(4, paste.language)
    stmt.bind_int(5, paste.created_at)
    stmt.bind_int(6, paste.expires_at)
    stmt.bind_int(7, paste.views)
    stmt.bind_text(8, delete_token)
    _ = stmt.step()

    # Increment monotonic counters.  If the calendar day rolled over,
    # reset today_pastes to 1 for the new day.
    var td = _today_int()
    var up = db.prepare(
        "UPDATE stats SET total_pastes = total_pastes + 1,  today_pastes = CASE"
        " WHEN today_date = ? THEN today_pastes + 1 ELSE 1 END,  today_date = ?"
        " WHERE id = 1"
    )
    up.bind_int(1, td)
    up.bind_int(2, td)
    _ = up.step()


def db_check_token(
    db: Database, paste_id: String, token: String
) raises -> Bool:
    """Check whether a delete token matches the stored token for a paste.

    Args:
        db:       Open SQLite database connection.
        paste_id: UUID string of the paste.
        token:    Token to validate against the stored delete_token.

    Returns:
        True if the token matches (or if no token was set — empty string
        matches empty string), False otherwise.

    Raises:
        Error: On SQLite error.
    """
    var stmt = db.prepare(
        "SELECT 1 FROM pastes WHERE id = ? AND delete_token = ?"
    )
    stmt.bind_text(1, paste_id)
    stmt.bind_text(2, token)
    var row_opt = stmt.step()
    return Bool(row_opt)


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
    var stmt = db.prepare("UPDATE pastes SET views = views + 1 WHERE id = ?")
    stmt.bind_text(1, paste_id)
    _ = stmt.step()

    db.execute("UPDATE stats SET total_views = total_views + 1 WHERE id = 1")


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


def db_update(
    db: Database,
    paste_id: String,
    title: String,
    content: String,
    language: String,
    expires_at: Int,
) raises:
    """Update a paste's mutable fields.

    The caller is responsible for verifying the delete token before calling.
    Only updates the paste if it has not yet expired.

    Args:
        db:         Open SQLite database connection.
        paste_id:   UUID string of the paste to update.
        title:      New title (caller merges with current if omitted by user).
        content:    New content body.
        language:   New syntax-highlight language hint.
        expires_at: New expiry Unix timestamp (pass current value to keep).

    Raises:
        Error: On SQLite error.
    """
    var now = _now()
    var stmt = db.prepare(
        "UPDATE pastes SET title = ?, content = ?, language = ?, expires_at = ?"
        " WHERE id = ? AND expires_at > ?"
    )
    stmt.bind_text(1, title)
    stmt.bind_text(2, content)
    stmt.bind_text(3, language)
    stmt.bind_int(4, expires_at)
    stmt.bind_text(5, paste_id)
    stmt.bind_int(6, now)
    _ = stmt.step()


def db_purge_expired(db: Database) raises -> Int:
    """Delete all expired pastes from the database.

    Should be called periodically to prevent unbounded table growth.
    Safe to call concurrently — uses a single atomic DELETE statement.

    Args:
        db: Open SQLite database connection.

    Returns:
        Number of rows deleted.

    Raises:
        Error: On SQLite error.
    """
    var now = _now()
    var stmt = db.prepare("DELETE FROM pastes WHERE expires_at <= ?")
    stmt.bind_int(1, now)
    _ = stmt.step()
    # SELECT changes() returns the count affected by the most recent DML statement.
    var count_stmt = db.prepare("SELECT changes()")
    var row_opt = count_stmt.step()
    if not row_opt:
        return 0
    return row_opt.value().int_val(0)


def db_list(
    db: Database,
    limit: Int = 20,
    offset: Int = 0,
    before_ts: Int = 0,
    search: String = "",
) raises -> List[Paste]:
    """Return a paginated list of non-expired pastes, newest first.

    Supports two pagination modes:
    - Offset-based (default): skip `offset` rows — stable only when no concurrent
      inserts are happening. Use when `before_ts` is 0.
    - Keyset cursor: pass `before_ts` > 0 to return only pastes with
      created_at < before_ts. Stable under concurrent inserts; takes priority
      over `offset` (offset is ignored when before_ts > 0).

    Optionally filters rows by a substring matched (LIKE) against title and content.

    Args:
        db:        Open SQLite database connection.
        limit:     Maximum number of results (default 20, capped at 100).
        offset:    Rows to skip — ignored when before_ts > 0.
        before_ts: Keyset cursor; only return pastes with created_at < this
                   Unix timestamp. Pass 0 (default) to disable.
        search:    Case-insensitive substring filter applied to title and content.
                   Pass "" (default) for no filtering.

    Returns:
        List of Paste objects ordered by creation time descending.

    Raises:
        Error: On SQLite error.
    """
    var safe_limit = min(limit, 100)
    var now = _now()
    var has_before = before_ts > 0
    var has_search = search.byte_length() > 0

    # Build WHERE clause and bind list dynamically to avoid N hard-coded variants.
    var sql = String(
        "SELECT id, title, content, language, created_at, expires_at, views"
        " FROM pastes WHERE expires_at > ?"
    )
    if has_before:
        sql += " AND created_at < ?"
    if has_search:
        sql += " AND (title LIKE ? OR content LIKE ?)"
    sql += " ORDER BY created_at DESC LIMIT ?"
    if not has_before:
        sql += " OFFSET ?"

    var stmt = db.prepare(sql)
    var idx = 1
    stmt.bind_int(idx, now)
    idx += 1
    if has_before:
        stmt.bind_int(idx, before_ts)
        idx += 1
    if has_search:
        var pattern = "%" + search + "%"
        stmt.bind_text(idx, pattern)
        idx += 1
        stmt.bind_text(idx, pattern)
        idx += 1
    stmt.bind_int(idx, safe_limit)
    idx += 1
    if not has_before:
        stmt.bind_int(idx, offset)

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
    """Return cumulative statistics that never decrease on paste expiry.

    All three counters come from the monotonic ``stats`` table.
    ``total`` and ``total_views`` only go up. ``today`` resets to 0
    at the start of each new UTC calendar day and counts up from
    there -- it never decreases within a day, even when pastes expire.

    Args:
        db: Open SQLite database connection.

    Returns:
        PasteStats with total (all-time), today (last 24h), and
        total_views (cumulative).

    Raises:
        Error: On SQLite error.
    """
    # All three counters come from the monotonic stats table.
    # today_pastes resets to 0 only on calendar-day rollover in db_create.
    var td = _today_int()
    var s = db.prepare(
        "SELECT total_pastes, total_views, today_pastes, today_date"
        " FROM stats WHERE id = 1"
    )
    var s_row = s.step()
    var total = 0
    var total_views = 0
    var today = 0
    if s_row:
        var r = s_row.take()
        total = r.int_val(0)
        total_views = r.int_val(1)
        var stored_date = r.int_val(3)
        if stored_date == td:
            today = r.int_val(2)
        # else: different day, today is 0 until the first paste of the day

    return PasteStats(
        total=total,
        today=today,
        total_views=total_views,
    )
