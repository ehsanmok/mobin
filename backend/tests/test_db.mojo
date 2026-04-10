"""Unit tests for mobin.db — all database CRUD functions.

Uses an in-memory SQLite database for isolation and speed.
No network or server processes required.
"""

from std.testing import assert_equal, assert_true, assert_false
from sqlite import Database
from mobin.db import (
    init_db,
    db_create,
    db_get,
    db_inc_views,
    db_delete,
    db_update,
    db_purge_expired,
    db_list,
    db_list_since,
    db_stats,
)
from mobin.models import Paste
from tempo import Timestamp


def _now() -> Int:
    return Int(Timestamp.now().unix_secs())


def _make_paste(
    id: String, title: String, content: String, offset_secs: Int = 0
) -> Paste:
    """Helper: create a Paste with timestamps relative to now."""
    var now = _now() + offset_secs
    return Paste(
        id=id,
        title=title,
        content=content,
        language="python",
        created_at=now,
        expires_at=now + 86400,  # expires in 1 day
        views=0,
    )


def _open_db() raises -> Database:
    """Open an initialised in-memory database."""
    var db = Database(":memory:")
    init_db(db)
    return db^


def test_init_db() raises:
    """Checks that init_db creates the pastes table without error."""
    var db = _open_db()
    # Verify table exists by inserting and querying
    db.execute("INSERT INTO pastes (id, title, content, language, created_at, expires_at, views) VALUES ('x', '', 'c', 'plain', 1, 9999999999, 0)")
    var stmt = db.prepare("SELECT COUNT(*) FROM pastes")
    var row = stmt.step()
    assert_true(row.__bool__())
    assert_equal(row.value().int_val(0), 1)


def test_db_create_and_get() raises:
    """Checks that db_create inserts a paste and db_get retrieves it by ID."""
    var db = _open_db()
    var p = _make_paste("id-1", "Hello", "print('hi')")
    db_create(db, p)

    var got = db_get(db, "id-1")
    assert_true(got.__bool__())
    var paste = got.value()
    assert_equal(paste.id, "id-1")
    assert_equal(paste.title, "Hello")
    assert_equal(paste.content, "print('hi')")
    assert_equal(paste.language, "python")
    assert_equal(paste.views, 0)


def test_db_get_missing() raises:
    """Checks that db_get returns None for a non-existent ID."""
    var db = _open_db()
    var got = db_get(db, "missing")
    assert_false(got.__bool__())


def test_db_get_expired() raises:
    """Checks that db_get returns None for an expired paste."""
    var db = _open_db()
    var now = _now()
    # Insert with expires_at in the past
    var p = Paste(
        id="expired",
        title="Old",
        content="x",
        language="plain",
        created_at=now - 7200,
        expires_at=now - 3600,  # expired 1 hour ago
        views=0,
    )
    db_create(db, p)
    var got = db_get(db, "expired")
    assert_false(got.__bool__())


def test_db_inc_views() raises:
    """Checks that db_inc_views increments the view counter atomically."""
    var db = _open_db()
    var p = _make_paste("v-1", "Title", "x")
    db_create(db, p)

    db_inc_views(db, "v-1")
    db_inc_views(db, "v-1")
    db_inc_views(db, "v-1")

    var got = db_get(db, "v-1")
    assert_true(got.__bool__())
    assert_equal(got.value().views, 3)


def test_db_delete() raises:
    """Checks that db_delete removes a paste; subsequent db_get returns None."""
    var db = _open_db()
    var p = _make_paste("del-1", "Delete me", "content")
    db_create(db, p)

    db_delete(db, "del-1")
    var got = db_get(db, "del-1")
    assert_false(got.__bool__())


def test_db_list_empty() raises:
    """Checks that db_list returns an empty list when no pastes exist."""
    var db = _open_db()
    var result = db_list(db)
    assert_equal(len(result), 0)


def test_db_list_order() raises:
    """Checks that db_list returns pastes ordered newest-first."""
    var db = _open_db()
    # Insert 3 pastes with increasing created_at
    for i in range(3):
        var p = _make_paste("p-" + String(i), "T" + String(i), "c", i * 10)
        db_create(db, p)

    var result = db_list(db)
    assert_equal(len(result), 3)
    # Newest first
    assert_equal(result[0].id, "p-2")
    assert_equal(result[1].id, "p-1")
    assert_equal(result[2].id, "p-0")


def test_db_list_limit() raises:
    """Checks that db_list respects the limit parameter."""
    var db = _open_db()
    for i in range(5):
        var p = _make_paste("lim-" + String(i), "T", "c", i)
        db_create(db, p)

    var result = db_list(db, limit=2)
    assert_equal(len(result), 2)


def test_db_list_offset() raises:
    """Checks that db_list respects the offset parameter for pagination."""
    var db = _open_db()
    for i in range(4):
        var p = _make_paste("off-" + String(i), "T", "c", i)
        db_create(db, p)

    var page2 = db_list(db, limit=2, offset=2)
    assert_equal(len(page2), 2)
    # Page 2 should be the two oldest (offset=2 skips newest 2)
    assert_equal(page2[0].id, "off-1")
    assert_equal(page2[1].id, "off-0")


def test_db_list_since() raises:
    """Checks that db_list_since returns only pastes created after since_secs."""
    var db = _open_db()
    var base = _now()
    var p_old = Paste(
        id="old",
        title="Old",
        content="x",
        language="plain",
        created_at=base - 100,
        expires_at=base + 86400,
        views=0,
    )
    var p_new = Paste(
        id="new",
        title="New",
        content="y",
        language="plain",
        created_at=base,
        expires_at=base + 86400,
        views=0,
    )
    db_create(db, p_old)
    db_create(db, p_new)

    var result = db_list_since(db, base - 50)
    assert_equal(len(result), 1)
    assert_equal(result[0].id, "new")


def test_db_stats_empty() raises:
    """Checks that db_stats returns zeros on an empty database."""
    var db = _open_db()
    var s = db_stats(db)
    assert_equal(s.total, 0)
    assert_equal(s.today, 0)
    assert_equal(s.total_views, 0)


def test_db_stats_counts() raises:
    """Checks that db_stats correctly counts total, today, and total_views."""
    var db = _open_db()
    var now = _now()

    # Paste created today
    var p1 = Paste(
        id="s1",
        title="A",
        content="x",
        language="plain",
        created_at=now - 100,
        expires_at=now + 86400,
        views=3,
    )
    # Paste created yesterday
    var p2 = Paste(
        id="s2",
        title="B",
        content="y",
        language="plain",
        created_at=now - 90000,
        expires_at=now + 86400,
        views=7,
    )
    db_create(db, p1)
    db_create(db, p2)

    var s = db_stats(db)
    assert_equal(s.total, 2)
    assert_equal(s.today, 1)   # only p1 (p2 was 25h ago)
    assert_equal(s.total_views, 10)


def test_db_update() raises:
    """Checks that db_update modifies content, title, language, and expiry."""
    var db = _open_db()
    var p = _make_paste("upd-1", "Original", "old content")
    db_create(db, p)

    var new_expires = p.expires_at + 3600
    db_update(db, "upd-1", "Updated Title", "new content", "python", new_expires)

    var got = db_get(db, "upd-1")
    assert_true(got.__bool__())
    var updated = got.value()
    assert_equal(updated.title, "Updated Title")
    assert_equal(updated.content, "new content")
    assert_equal(updated.language, "python")
    assert_equal(updated.expires_at, new_expires)


def test_db_update_expired_noop() raises:
    """Checks that db_update is a no-op when the paste has already expired."""
    var db = _open_db()
    var now = _now()
    var p = Paste(
        id="exp-upd",
        title="Old",
        content="old",
        language="plain",
        created_at=now - 7200,
        expires_at=now - 3600,  # expired 1 hour ago
        views=0,
    )
    db_create(db, p)
    # Update should silently do nothing (WHERE expires_at > now fails)
    db_update(db, "exp-upd", "New", "new", "python", now + 86400)
    var got = db_get(db, "exp-upd")
    # Still not retrievable (expired)
    assert_false(got.__bool__())


def test_db_purge_expired() raises:
    """Checks that db_purge_expired deletes expired rows and returns count."""
    var db = _open_db()
    var now = _now()

    # Insert two expired and one active paste.
    for i in range(2):
        var p = Paste(
            id="expired-" + String(i),
            title="E",
            content="x",
            language="plain",
            created_at=now - 7200,
            expires_at=now - 3600,  # expired
            views=0,
        )
        db_create(db, p)
    var active = _make_paste("active-1", "Active", "y")
    db_create(db, active)

    var deleted = db_purge_expired(db)
    assert_equal(deleted, 2)

    # Active paste should still be retrievable.
    var got = db_get(db, "active-1")
    assert_true(got.__bool__())


def test_db_list_search() raises:
    """Checks that db_list filters by search substring in title and content."""
    var db = _open_db()
    var p1 = _make_paste("s-1", "Python tutorial", "print('hello')", 0)
    var p2 = _make_paste("s-2", "Mojo intro", "var x = 42", 1)
    var p3 = _make_paste("s-3", "Plain text", "no code here", 2)
    db_create(db, p1)
    db_create(db, p2)
    db_create(db, p3)

    # Search in title
    var results = db_list(db, search="Mojo")
    assert_equal(len(results), 1)
    assert_equal(results[0].id, "s-2")

    # Search in content
    var results2 = db_list(db, search="hello")
    assert_equal(len(results2), 1)
    assert_equal(results2[0].id, "s-1")

    # No match
    var results3 = db_list(db, search="notfound")
    assert_equal(len(results3), 0)


def test_db_list_keyset() raises:
    """Checks that before_ts keyset cursor returns only older pastes."""
    var db = _open_db()
    # Insert 3 pastes with strictly increasing created_at (spacing > 1s to avoid ties)
    var base = _now()
    for i in range(3):
        var p = Paste(
            id="ks-" + String(i),
            title="T",
            content="c",
            language="plain",
            created_at=base + i * 10,
            expires_at=base + 86400,
            views=0,
        )
        db_create(db, p)

    # before_ts set to the middle paste's created_at — should only return ks-0
    var cutoff = base + 10  # ks-1's created_at; exclude ks-1 and ks-2
    var result = db_list(db, before_ts=cutoff)
    assert_equal(len(result), 1)
    assert_equal(result[0].id, "ks-0")


def main() raises:
    test_init_db()
    test_db_create_and_get()
    test_db_get_missing()
    test_db_get_expired()
    test_db_inc_views()
    test_db_delete()
    test_db_list_empty()
    test_db_list_order()
    test_db_list_limit()
    test_db_list_offset()
    test_db_list_since()
    test_db_stats_empty()
    test_db_stats_counts()
    test_db_update()
    test_db_update_expired_noop()
    test_db_purge_expired()
    test_db_list_search()
    test_db_list_keyset()
    print("test_db: all tests passed")
