# mobin

[![CI](https://github.com/ehsanmok/mobin/actions/workflows/ci.yml/badge.svg)](https://github.com/ehsanmok/mobin/actions/workflows/ci.yml)
[![Deploy](https://github.com/ehsanmok/mobin/actions/workflows/deploy.yml/badge.svg?event=workflow_run)](https://github.com/ehsanmok/mobin/actions/workflows/deploy.yml)

A pastebin service built entirely in [Mojo](https://docs.modular.com/mojo/) (`==1.0.0b1`). Zero Python in the hot path: the HTTP server, WebSocket server, database layer, JSON serialisation, and routing are all Mojo code.

**Live demo: [mobin.fly.dev](https://mobin.fly.dev/)**

- **Backend**: Mojo on the [flare](https://github.com/ehsanmok/flare) v0.7 stack — `flare.Router` with `:id` path captures, `Cors` / `Logger` / `RequestId` / `CatchPanic` middleware chain, typed extractors (`PathStr`, `OptionalQueryInt`, `OptionalHeaderStr`, `BodyText`), shared-state `App[AppState]`, multi-worker `HttpServer.serve(handler, num_workers=default_worker_count())` (HTTP) + single-worker `WsServer.serve(handler, num_workers=1)` (WS) under a `fork()` split. Persistence via [sqlite](https://github.com/ehsanmok/sqlite) WAL + per-request connections; JSON via [morph](https://github.com/ehsanmok/morph) + [json](https://github.com/ehsanmok/json); IDs via [uuid](https://github.com/ehsanmok/uuid); time via [tempo](https://github.com/ehsanmok/tempo); env via [envo](https://github.com/ehsanmok/envo); pretty-print via [pprint](https://github.com/ehsanmok/pprint).
- **Frontend**: Vanilla JS + nginx, live feed via WebSocket, auto-removal of expired pastes
- **Infra**: Docker Compose, single root `pixi.toml` (monorepo), GitHub Actions -> [Fly.io](https://fly.io) CD

## Architecture

```mermaid
graph TD
    subgraph Browser
        UI[HTML / JS frontend]
    end

    subgraph "Docker / Fly.io"
        direction TB
        NGINX[nginx :3000\nfrontend]

        subgraph Mojo backend process
            FORK[fork]
            HTTP[HttpServer :8080\nREST API]
            WS[WsServer :8081\nWebSocket feed]
        end

        SQLITE[(SQLite WAL\n/data/mobin.db)]
    end

    UI -->|HTTP GET /| NGINX
    UI -->|REST API calls| HTTP
    UI -->|ws://...:8081/feed| WS

    FORK -->|parent| HTTP
    FORK -->|child| WS

    HTTP -->|per-request connection| SQLITE
    WS -->|per-connection connection| SQLITE
```

## Quick start

```bash
pixi install          # resolves Mojo deps + builds flare's libflare_tls.so / libflare_zlib.so
pixi run run-dev      # start backend on :8080 (HTTP) and :8081 (WS)
```

`pixi install` runs `scripts/build_flare_ffi.sh` on activation; that compiles the FFI bridges flare v0.7 needs (`libflare_tls.so` for the WebSocket SHA-1 + reactor read/write hot path, `libflare_zlib.so` for HTTP gzip) into `.pixi/envs/default/lib/` so the backend can dlopen them. Idempotent; only rebuilds when the upstream source is newer than the installed copy.

Open `http://localhost:8080`. The backend serves the embedded frontend directly. The HTTP parent picks `num_workers` from `default_worker_count()` automatically; override with `MOBIN_HTTP_WORKERS=N` for benchmarking.

Or with Docker Compose:

```bash
docker compose up --build
# Frontend: http://localhost:3000
# Backend:  http://localhost:8080
```

## Documentation

| Guide | What it covers |
|-------|---------------|
| [Architecture](docs/architecture.md) | Process model, database design, URL routing, stats table |
| [API Reference](docs/api.md) | REST endpoints, WebSocket feed, TTL options, curl examples |
| [Development](docs/development.md) | Repo layout, pixi commands, environment variables, integration tests |
| [Package Management](docs/package-management.md) | Why Pixi, dependency pinning, dependency graph |
| [Deployment](docs/deployment.md) | Fly.io, VPS + Docker Compose, Caddy TLS, Litestream backup |
| [Performance](docs/performance.md) | Local and live benchmarks |
| [Security](docs/security.md) | Security checklist and resilience |
| [Mojo DX](docs/mojo-dx.md) | Language friction points and what's been resolved |
