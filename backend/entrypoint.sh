#!/bin/sh
# mobin entrypoint: optionally wraps the backend with Litestream replication.
#
# Supports two run modes (detected via /app/backend/.build_mode):
#   aot  — pre-compiled binary, exec /app/backend/mobin-backend directly
#   jit  — source mode, exec via `mojo run main.mojo` (slower start, same result)
#
# If LITESTREAM_REPLICA_URL is set, Litestream restores the latest DB snapshot
# before starting and replicates every WAL commit going forward.
set -e

DB_PATH="${DB_PATH:-/app/data/mobin.db}"
DB_DIR="$(dirname "$DB_PATH")"
mkdir -p "$DB_DIR"

LITESTREAM_CONFIG="$(dirname "$0")/litestream.yml"
BUILD_MODE_FILE="/app/backend/.build_mode"
BUILD_MODE="$(cat "$BUILD_MODE_FILE" 2>/dev/null || echo "aot")"

if [ "$BUILD_MODE" = "aot" ] && [ -f "/app/backend/mobin-backend" ]; then
    echo "[mobin] mode=aot — running pre-compiled binary"
    CMD="/app/backend/mobin-backend"
else
    echo "[mobin] mode=jit — JIT-compiling main.mojo (first start will be slow)"
    # pixi shell-hook already activated via ENTRYPOINT wrapper
    CMD="mojo run /app/backend/main.mojo"
fi

if [ -n "$LITESTREAM_REPLICA_URL" ]; then
    echo "[litestream] replication → $LITESTREAM_REPLICA_URL"

    if [ ! -f "$DB_PATH" ]; then
        echo "[litestream] no local DB found — attempting restore..."
        litestream restore -config "$LITESTREAM_CONFIG" -if-replica-exists "$DB_PATH" \
            && echo "[litestream] restore complete" \
            || echo "[litestream] no replica snapshot yet — starting fresh"
    else
        echo "[litestream] existing DB found at $DB_PATH — skipping restore"
    fi

    echo "[litestream] starting continuous replication..."
    # shellcheck disable=SC2086
    exec litestream replicate -config "$LITESTREAM_CONFIG" -- $CMD
else
    echo "[mobin] Litestream disabled (set LITESTREAM_REPLICA_URL to enable)"
    # shellcheck disable=SC2086
    exec $CMD
fi
