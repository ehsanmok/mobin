# ── Stage 1: build ────────────────────────────────────────────────────────────
# Force linux/amd64 — Mojo nightly ships amd64 binaries; Fly.io is amd64 too.
FROM ghcr.io/prefix-dev/pixi:0.66.0 AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git ca-certificates build-essential \
        libsqlite3-dev libssl-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN git config --global --add safe.directory '*'

WORKDIR /app

COPY pixi.toml pixi.lock* ./
RUN pixi install

# Note: glibc symbol mismatch handling lives in pixi.toml's [target.linux-*.tasks]
# build commands (`-Xlinker --allow-shlib-undefined`), not as a Dockerfile shim.
# That keeps the Linux link recipe in one place and prevents silent drift if the
# linker flag chain changes.

# Note: there is intentionally no `mojo package` recompile step. Earlier nightly
# Mojo builds could ship MLIR-bytecode-incompatible `.mojopkg` artifacts even
# when their version strings matched the runtime compiler, so a defensive
# rebuild-from-source step lived here. With mojo pinned to the stable
# ``==1.0.0b1`` beta and every dep's ``recipe.yaml`` pinning the same compiler
# version, the artifacts pixi-build produces are bytecode-compatible with the
# runtime compiler by construction. Reintroducing such a step would also
# contradict ``docs/package-management.md`` which documents the workflow as
# pixi-build / rattler-build only, with no ``mojo package`` step.

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
FROM ubuntu:22.04 AS runtime

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
