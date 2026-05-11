#!/bin/bash
# Build + install the flare FFI bridges into ``$CONDA_PREFIX/lib/`` so
# the mobin backend can dlopen them at runtime regardless of which env
# (backend's own ``.pixi``, integtest's ``.pixi``, or a bare shell) the
# binary is launched from.
#
# Why mobin needs its own activation hook
# =======================================
#
# flare v0.7 ships its FFI helpers as source-built shared libraries
# (``libflare_tls.so``, ``libflare_zlib.so``, ``libflare_fs.so``,
# optionally ``libflare_brotli.so``). The upstream ``flare/pixi.toml``
# wires ``flare/tls/ffi/build.sh`` and ``flare/http/ffi/build.sh`` into
# its own ``[activation].scripts`` so the .so files are present
# whenever someone develops *inside* the flare repo.
#
# When mobin pulls flare via ``pixi-build`` (git source), only the
# ``.mojopkg`` lands in ``$CONDA_PREFIX/lib/mojo/``. The FFI sources
# end up under ``backend/.pixi/build/work/flare-*/work/`` and the
# upstream build scripts there compile the .so files into a
# ``build/`` sibling directory — but never propagate them anywhere
# the runtime helpers can find them. Without this hook the backend
# aborts at startup with ``symbol not found: flare_read`` (the
# reactor's hot-path wrapper around ``read(2)``/``write(2)`` exposed
# by ``libflare_tls.so``).
#
# This script:
#   1. Locates the most recent flare build-work tree.
#   2. Sources the upstream ``build.sh`` scripts (they handle their
#      own idempotency check + actual compilation).
#   3. Copies the freshly-built ``.so`` files into ``$CONDA_PREFIX/lib/``
#      so ``flare.net.socket._find_flare_lib`` (which falls back to
#      ``$CONDA_PREFIX/lib/libflare_tls.so`` when ``FLARE_LIB`` is not
#      set) resolves them.
#
# NOTE: When used as a pixi activation script, use ``return`` not
# ``exit`` so the sourcing shell is not terminated. A missing flare
# cache during early ``pixi install`` is normal and silently skipped —
# the next activation picks it up once the cache is populated.

set -u

if [ -z "${CONDA_PREFIX:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="$REPO_ROOT/.pixi/build/work"

if [ ! -d "$WORK_ROOT" ]; then
    return 0 2>/dev/null || exit 0
fi

# Pick the most recent flare build-work tree (``ls -td`` orders by
# mtime). pixi-build occasionally keeps stale caches alongside the
# active one; the newest mtime is always the one matching the
# currently-resolved flare commit.
FLARE_WORK="$(ls -td "$WORK_ROOT"/flare-*-*/work 2>/dev/null | head -1)"
if [ -z "$FLARE_WORK" ] || [ ! -d "$FLARE_WORK/flare" ]; then
    return 0 2>/dev/null || exit 0
fi

mkdir -p "$CONDA_PREFIX/lib"

# Source upstream build scripts (they compile into ``$FLARE_WORK/build/``
# and short-circuit when up to date).
TLS_BUILD="$FLARE_WORK/flare/tls/ffi/build.sh"
HTTP_BUILD="$FLARE_WORK/flare/http/ffi/build.sh"

if [ -f "$TLS_BUILD" ]; then
    # shellcheck disable=SC1090
    . "$TLS_BUILD" || true
fi

if [ -f "$HTTP_BUILD" ]; then
    # shellcheck disable=SC1090
    . "$HTTP_BUILD" || true
fi

# ── Install all freshly-built .so files into $CONDA_PREFIX/lib ──────────────
# The upstream main-branch build scripts only export ``FLARE_LIB`` /
# ``FLARE_ZLIB_LIB`` and (on Linux) prepend ``LD_PRELOAD``; they don't
# install anywhere. Setting env vars only helps the activation shell
# itself — child processes spawned by integtest fixtures (which set
# their own ``CONDA_PREFIX``) won't inherit them. So we copy the .so
# files into ``$CONDA_PREFIX/lib/`` where the runtime fallback path
# in ``flare.net.socket._find_flare_lib`` resolves them.
FLARE_BUILD_DIR="$FLARE_WORK/build"
if [ -d "$FLARE_BUILD_DIR" ]; then
    for so in "$FLARE_BUILD_DIR"/libflare_*.so; do
        [ -f "$so" ] || continue
        dest="$CONDA_PREFIX/lib/$(basename "$so")"
        # Only copy when the build artifact is newer than the installed
        # copy (or the installed copy is missing). Cheap mtime check.
        if [ ! -f "$dest" ] || [ "$so" -nt "$dest" ]; then
            cp "$so" "$dest"
        fi
    done
fi

return 0 2>/dev/null || exit 0
