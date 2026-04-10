#!/bin/sh
# mobin entrypoint: optionally wraps the backend with Litestream replication.
#
# If LITESTREAM_REPLICA_URL is set, Litestream restores the latest DB snapshot
# from the replica before starting, then replicates every WAL commit going
# forward.  If the env var is absent, the backend runs with no replication.
#
# Restore behaviour:
#   - If the DB file already exists (e.g. mounted volume has data), Litestream
#     skips the restore and just begins replicating from the current WAL.
#   - If the DB file is absent, Litestream downloads the latest snapshot and
#     applies any trailing WAL segments before handing off to the app.
set -e

DB_PATH="${DB_PATH:-/app/data/mobin.db}"
DB_DIR="$(dirname "$DB_PATH")"
mkdir -p "$DB_DIR"

if [ -n "$LITESTREAM_REPLICA_URL" ]; then
    echo "[litestream] replication → $LITESTREAM_REPLICA_URL"

    # Restore only if the database does not already exist on the volume.
    if [ ! -f "$DB_PATH" ]; then
        echo "[litestream] no local DB found — attempting restore..."
        litestream restore -config /app/litestream.yml -if-replica-exists "$DB_PATH" \
            && echo "[litestream] restore complete" \
            || echo "[litestream] no replica snapshot yet — starting fresh"
    else
        echo "[litestream] existing DB found at $DB_PATH — skipping restore"
    fi

    echo "[litestream] starting continuous replication..."
    exec litestream replicate \
        -config /app/litestream.yml \
        -- pixi run mojo run -I . main.mojo
else
    echo "[mobin] Litestream disabled (set LITESTREAM_REPLICA_URL to enable)"
    exec pixi run mojo run -I . main.mojo
fi
