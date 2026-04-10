# ── Single stage: pixi env + mojo run ────────────────────────────────────────
# We don't attempt to link a standalone binary because the conda cross-compiler
# sysroot used by the Mojo toolchain has a different glibc baseline than the
# Docker host. Running `pixi run mojo run main.mojo` avoids the linker entirely
# and uses the JIT path, which works correctly on any glibc ≥ 2.17.
FROM ghcr.io/prefix-dev/pixi:0.66.0

# git + ca-certificates are required for pixi to clone git-sourced Mojo
# dependencies over HTTPS (flare, sqlite, uuid, etc. are source packages).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        wget \
        curl \
        libsqlite3-dev \
        libssl-dev \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# Allow git to operate in any directory (needed when running as root in Docker).
RUN git config --global --add safe.directory '*'

WORKDIR /app

# Copy dependency manifests first for better layer caching.
# pixi.lock pins every dependency to a specific commit/version.
COPY pixi.toml pixi.lock* ./

# Install all dependencies (Mojo compiler + all git-sourced Mojo libraries).
RUN pixi install

# Copy source code
COPY . .

# Data volume mount point for SQLite WAL database
RUN mkdir -p data
VOLUME ["/app/data"]

EXPOSE 8080 8081

# Run the backend directly with the Mojo interpreter; avoids the
# cross-compiler linker issue while keeping the image self-contained.
ENTRYPOINT ["pixi", "run", "mojo", "run", "-I", ".", "main.mojo"]
