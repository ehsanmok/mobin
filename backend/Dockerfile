# ── Single stage: pixi env + mojo run ────────────────────────────────────────
# We don't attempt to link a standalone binary because the conda cross-compiler
# sysroot used by the Mojo toolchain has a different glibc baseline than the
# Docker host. Running `pixi run mojo run main.mojo` avoids the linker entirely
# and uses the JIT path, which works correctly on any glibc ≥ 2.17.
FROM ghcr.io/prefix-dev/pixi:0.66.0

# git + ca-certificates are required for pixi to clone git-sourced Mojo
# dependencies over HTTPS (flare, sqlite, uuid, etc. are source packages).
# tar is needed to extract the Litestream binary.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        wget \
        curl \
        tar \
        libsqlite3-dev \
        libssl-dev \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# ── Litestream (continuous SQLite replication) ────────────────────────────────
# Installed unconditionally; activated at runtime only when
# LITESTREAM_REPLICA_URL is set (see entrypoint.sh).
# TARGETARCH is injected automatically by Docker BuildKit: amd64 | arm64.
ARG LITESTREAM_VERSION=0.3.13
ARG TARGETARCH
RUN set -ex; \
    ARCH="${TARGETARCH:-amd64}"; \
    curl -fsSL \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream; \
    litestream version

# Allow git to operate in any directory (needed when running as root in Docker).
RUN git config --global --add safe.directory '*'

WORKDIR /app

# Copy dependency manifests first for better layer caching.
# pixi.lock pins every dependency to a specific commit/version.
COPY pixi.toml pixi.lock* ./

# Install all dependencies (Mojo compiler + all git-sourced Mojo libraries).
RUN pixi install

# Copy source code and configs
COPY . .

# Ensure the entrypoint script is executable (git may strip the bit).
RUN chmod +x entrypoint.sh

# Data volume mount point for SQLite WAL database
RUN mkdir -p data
VOLUME ["/app/data"]

EXPOSE 8080 8081

# entrypoint.sh conditionally wraps the app with Litestream when
# LITESTREAM_REPLICA_URL is set; otherwise runs the app directly.
ENTRYPOINT ["/app/entrypoint.sh"]
