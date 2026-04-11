# ── Stage 1: build ────────────────────────────────────────────────────────────
# Force linux/amd64 — Mojo nightly ships amd64 binaries; Fly.io is amd64 too.
FROM --platform=linux/amd64 ghcr.io/prefix-dev/pixi:0.66.0 AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git ca-certificates build-essential \
        libsqlite3-dev libssl-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN git config --global --add safe.directory '*'

WORKDIR /app

COPY pixi.toml pixi.lock* ./
RUN pixi install

# ── Redirect conda cross-linker to system ld ──────────────────────────────────
# conda GCC ships its own cross-linker (x86_64-conda-linux-gnu-ld) which uses
# a minimal sysroot that only has GLIBC stubs up to ~2.17.  Mojo runtime libs
# need GLIBC_2.29–2.34 versioned symbols.  Replacing the conda ld with a thin
# wrapper that calls the system ld (which knows about the real installed glibc)
# fixes the link-time "undefined reference to …@GLIBC_2.34" errors.
RUN set -e; \
    echo "=== Locating conda cross-linker ==="; \
    # Search for the ld binary (may be regular file or symlink) in multiple locations
    CONDA_LD=$(find /app/.pixi/envs/default/libexec /app/.pixi/envs/default/bin \
                   \( -type f -o -type l \) -name "ld" -o \
                   -name "x86_64-conda-linux-gnu-ld" 2>/dev/null | head -1); \
    echo "  found: $CONDA_LD"; \
    if [ -n "$CONDA_LD" ] && [ -x /usr/bin/ld ]; then \
        echo "=== Replacing $CONDA_LD with system ld wrapper ==="; \
        mv "$CONDA_LD" "${CONDA_LD}.orig"; \
        # Add system library paths so the linker can resolve GLIBC_2.34+ versioned symbols
        printf '#!/bin/sh\nexec /usr/bin/ld -L/lib/x86_64-linux-gnu -L/usr/lib/x86_64-linux-gnu "$@"\n' > "$CONDA_LD"; \
        chmod +x "$CONDA_LD"; \
        echo "=== Done ==="; \
    else \
        echo "=== No replacement done (ld path: '$CONDA_LD') ==="; \
    fi

# ── Fix MLIR bytecode incompatibility ─────────────────────────────────────────
# flare.mojopkg and json.mojopkg are shipped as pre-compiled conda artifacts
# (pixi-build). Their MLIR bytecode may not match the runtime Mojo compiler
# even when version strings are identical (nightly builds can change internal
# MLIR format without bumping the semver).
#
# Root-cause analysis (from `conda-meta/*.json`):
#   flare.mojopkg  ← flare conda package   → recompile from source
#   json.mojopkg   ← json conda package    → recompile from source
#   buffer.mojopkg ← mojo-compiler package → already compatible, leave alone
#   morph/, sqlite/, envo/, uuid/, tempo/, pprint/ → source dirs, no issue
#
# Solution: use `mojo package` with the runtime compiler on the exact commits
# pinned in pixi.lock to produce compatible bytecode.
RUN set -e; \
    PKGDIR=/app/.pixi/envs/default/lib/mojo; \
    \
    echo "=== Recompiling json.mojopkg (compile first; flare imports it) ==="; \
    git clone --depth 1 --no-tags https://github.com/ehsanmok/json.git /tmp/json-src; \
    git -C /tmp/json-src fetch --depth 1 origin 8f1b68db27e1ce82e5891ee74f4cf39eb6bae875; \
    git -C /tmp/json-src checkout FETCH_HEAD; \
    pixi run -- mojo package /tmp/json-src/json -o $PKGDIR/json.mojopkg && echo "    json OK"; \
    \
    echo "=== Recompiling flare.mojopkg ==="; \
    git clone --depth 1 --no-tags https://github.com/ehsanmok/flare.git /tmp/flare-src; \
    git -C /tmp/flare-src fetch --depth 1 origin 5e7965dc87e62d20099744b479b1a0cd10896ad0; \
    git -C /tmp/flare-src checkout FETCH_HEAD; \
    pixi run -- mojo package /tmp/flare-src/flare -o $PKGDIR/flare.mojopkg && echo "    flare OK"; \
    \
    rm -rf /tmp/json-src /tmp/flare-src

COPY backend/  ./backend/
COPY frontend/ ./frontend/

# ── AOT-compile backend to native binary ──────────────────────────────────────
# AOT compilation requires a native linux/amd64 host (e.g. GitHub Actions).
# On Mac/Docker emulation the conda cross-linker's sysroot may lack GLIBC_2.34
# stubs; in that case we fall back to JIT mode (mojo run at container startup).
RUN if pixi run build; then \
        echo "aot" > /app/backend/.build_mode; \
        echo "=== AOT compilation succeeded ==="; \
    else \
        echo "jit" > /app/backend/.build_mode; \
        echo "=== AOT failed — falling back to JIT mode ==="; \
    fi

# Generate shell activation script for the runtime stage.
RUN pixi shell-hook --shell bash > /shell-hook.sh && \
    echo 'exec "$@"' >> /shell-hook.sh

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM --platform=linux/amd64 ubuntu:22.04 AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libsqlite3-0 libssl3 zlib1g ca-certificates curl tar && \
    rm -rf /var/lib/apt/lists/*

ARG LITESTREAM_VERSION=0.3.13
RUN curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C /usr/local/bin litestream && \
    litestream version

WORKDIR /app

# Pixi runtime environment (Mojo runtime libs, Python, shared libs, etc.).
COPY --from=builder /app/.pixi/envs/default   /app/.pixi/envs/default
# Shell-hook activates the environment (sets PATH, LD_LIBRARY_PATH, etc.).
COPY --from=builder /shell-hook.sh            /shell-hook.sh
# Build artefacts + source (AOT binary if present, .build_mode flag, sources for JIT).
COPY --from=builder /app/backend/             ./backend/
# Operational files.
COPY backend/entrypoint.sh  ./backend/entrypoint.sh
COPY backend/litestream.yml ./backend/litestream.yml
COPY frontend/              ./frontend/

RUN chmod +x backend/entrypoint.sh && \
    [ -f backend/mobin-backend ] && chmod +x backend/mobin-backend || true && \
    mkdir -p /data

EXPOSE 8080 8081

ENTRYPOINT ["/bin/bash", "/shell-hook.sh", "/app/backend/entrypoint.sh"]
