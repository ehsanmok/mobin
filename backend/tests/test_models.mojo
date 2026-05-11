"""Unit tests for mobin.models — Paste, PasteStats, MobinConfig, new_paste.

Uses in-process function calls only; no network or database required.
"""

from std.testing import assert_equal, assert_true, assert_false
from mobin.models import Paste, PasteStats, MobinConfig, new_paste
from tempo import Timestamp


def test_paste_defaults() raises:
    """Paste default init produces sensible zero values."""
    var p = Paste()
    assert_equal(p.id, "")
    assert_equal(p.title, "")
    assert_equal(p.content, "")
    assert_equal(p.language, "plain")
    assert_equal(p.created_at, 0)
    assert_equal(p.expires_at, 0)
    assert_equal(p.views, 0)


def test_paste_fieldwise_init() raises:
    """Paste fieldwise init assigns all fields correctly."""
    var p = Paste(
        id="abc",
        title="Hello",
        content="print(42)",
        language="python",
        created_at=1000,
        expires_at=2000,
        views=5,
    )
    assert_equal(p.id, "abc")
    assert_equal(p.title, "Hello")
    assert_equal(p.content, "print(42)")
    assert_equal(p.language, "python")
    assert_equal(p.created_at, 1000)
    assert_equal(p.expires_at, 2000)
    assert_equal(p.views, 5)


def test_paste_stats_defaults() raises:
    """PasteStats default init produces zeros."""
    var s = PasteStats()
    assert_equal(s.total, 0)
    assert_equal(s.today, 0)
    assert_equal(s.total_views, 0)


def test_mobin_config_defaults() raises:
    """MobinConfig default init uses expected production defaults."""
    var cfg = MobinConfig()
    assert_equal(cfg.host, "0.0.0.0")
    assert_equal(cfg.port, 8080)
    assert_equal(cfg.ws_port, 8081)
    assert_equal(cfg.db_path, "data/mobin.db")
    assert_equal(cfg.max_size, 65536)
    assert_equal(cfg.ttl_days, 30)


def test_new_paste_id_non_empty() raises:
    """Checks that new_paste() generates a non-empty UUID id."""
    var p = new_paste("Test", "content", "python", 3600)
    assert_true(p.id.byte_length() > 0)


def test_new_paste_id_uuid_format() raises:
    """Checks that new_paste() id follows UUID format (length 36, hyphens)."""
    var p = new_paste("Test", "content", "python", 3600)
    assert_equal(p.id.byte_length(), 36)
    assert_true(p.id.find("-") >= 0)


def test_new_paste_fields() raises:
    """Checks that new_paste() copies title, content, and language correctly."""
    var p = new_paste("My Title", "some code", "rust", 3600)
    assert_equal(p.title, "My Title")
    assert_equal(p.content, "some code")
    assert_equal(p.language, "rust")
    assert_equal(p.views, 0)


def test_new_paste_timestamps() raises:
    """Checks that new_paste() sets created_at near now and expires_at ~7 days ahead."""
    var before = Int(Timestamp.now().unix_secs())
    var p = new_paste("T", "c", "plain", 604800)  # 7 days in seconds
    var after = Int(Timestamp.now().unix_secs())

    assert_true(p.created_at >= before)
    assert_true(p.created_at <= after)
    assert_true(p.expires_at > p.created_at)
    # expires_at should be exactly 604800 seconds ahead
    var diff = p.expires_at - p.created_at
    assert_true(diff >= 604799)
    assert_true(diff <= 604801)


def test_new_paste_ttl_one_day() raises:
    """Checks that new_paste() with 86400 s (1 day) sets the correct expiry offset."""
    var p = new_paste("T", "c", "plain", 86400)
    var diff = p.expires_at - p.created_at
    assert_true(diff >= 86399)
    assert_true(diff <= 86401)


def test_new_paste_unique_ids() raises:
    """Checks that successive new_paste() calls produce distinct IDs."""
    var p1 = new_paste("A", "x", "plain", 3600)
    var p2 = new_paste("B", "y", "plain", 3600)
    assert_true(p1.id != p2.id)


def main() raises:
    test_paste_defaults()
    test_paste_fieldwise_init()
    test_paste_stats_defaults()
    test_mobin_config_defaults()
    test_new_paste_id_non_empty()
    test_new_paste_id_uuid_format()
    test_new_paste_fields()
    test_new_paste_timestamps()
    test_new_paste_ttl_one_day()
    test_new_paste_unique_ids()
    print("test_models: all tests passed")
