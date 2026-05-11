# mobin

[![CI](https://github.com/ehsanmok/mobin/actions/workflows/ci.yml/badge.svg)](https://github.com/ehsanmok/mobin/actions/workflows/ci.yml)
[![Deploy](https://github.com/ehsanmok/mobin/actions/workflows/deploy.yml/badge.svg?event=workflow_run)](https://github.com/ehsanmok/mobin/actions/workflows/deploy.yml)

A pastebin service built entirely in [Mojo](https://docs.modular.com/mojo/). Zero Python in the hot path: the HTTP server, WebSocket server, database layer, JSON serialisation, and routing are all Mojo code.

**Live demo: [mobin.fly.dev](https://mobin.fly.dev/)**

- **Backend**: Mojo ([flare](https://github.com/ehsanmok/flare) HTTP + WS, [sqlite](https://github.com/ehsanmok/sqlite), [json](https://github.com/ehsanmok/json), [morph](https://github.com/ehsanmok/morph) serde, [uuid](https://github.com/ehsanmok/uuid), [tempo](https://github.com/ehsanmok/tempo), [envo](https://github.com/ehsanmok/envo), [pprint](https://github.com/ehsanmok/pprint))
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
pixi install          # resolve + install all Mojo dependencies
pixi run run-dev      # start backend on :8080 (HTTP) and :8081 (WS)
```

Open `http://localhost:8080`. The backend serves the embedded frontend directly.

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
