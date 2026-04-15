# Development

## Quick start: local

All commands are run from the **repo root** (where `pixi.toml` lives):

```bash
pixi install          # resolve + install all Mojo dependencies
pixi run run-dev      # start backend on :8080 (HTTP) and :8081 (WS)
```

Open `http://localhost:8080`. The backend serves the embedded frontend directly.

To run the full nginx-fronted UI simultaneously:

```bash
pixi run serve-frontend   # static frontend on :3001 (in a second terminal)
```

## Quick start: Docker Compose

```bash
docker compose up --build
```

| URL | Service |
|-----|---------|
| `http://localhost:3000` | Frontend (nginx) |
| `http://localhost:8080` | Backend REST API (direct) |
| `http://localhost:8081` | WebSocket feed (direct) |
| `http://localhost:8089` | Locust load-test UI |

> **Mac ARM64 (M-series):** The repo includes a `docker-compose.override.yml` that
> builds natively for `linux/arm64`, avoiding slow QEMU emulation. Docker Compose
> merges it automatically, no extra flags needed.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address for HTTP and WS servers |
| `PORT` | `8080` | HTTP server port |
| `WS_PORT` | `8081` | WebSocket server port |
| `DB_PATH` | `data/mobin.db` | SQLite database file path |
| `MAX_SIZE` | `65536` | Max paste size in bytes (64 KB) |
| `TTL_DAYS` | `30` | Default paste time-to-live in days |

## Commands

| Command | What it does |
|---------|-------------|
| `pixi install` | Install all Mojo library dependencies into `.pixi/envs/default/` |
| `pixi run serve` | Start the backend (used by Docker / Fly.io entrypoint) |
| `pixi run run-dev` | Run with `mojo run` (no compile step, fastest iteration) |
| `pixi run build` | Compile `backend/main.mojo` to a standalone `mobin-backend` binary |
| `pixi run run` | Build then immediately start the backend binary |
| `pixi run serve-frontend` | Serve `frontend/src/` on `:3001` via Python HTTP (dev only) |
| `pixi run tests` | Run all three unit-test suites (`test_models`, `test_db`, `test_router`) |
| `pixi run test-models` | Unit tests for `Paste` / `PasteStats` / `ServerConfig` / `new_paste()` |
| `pixi run test-db` | Unit tests for all SQLite helpers (`init_db`, CRUD, stats, expiry) |
| `pixi run test-router` | Unit tests for URL routing, CORS preflight, 404 handling |
| `pixi run format` | Auto-format `mobin/`, `main.mojo`, and `tests/` with `mojo format` |

## Repo layout

```
mobin/
├── pixi.toml                  <- root manifest (all Mojo deps + tasks)
├── pixi.lock                  <- pinned dependency graph
├── Dockerfile                 <- production image (AOT compile with JIT fallback)
├── fly.toml                   <- Fly.io app config (256 MB shared-cpu-1x)
├── docker-compose.yml         <- local dev stack (backend + frontend + locust)
├── docker-compose.override.yml<- ARM64 Mac override (no QEMU emulation)
├── docker-compose.prod.yml    <- production stack with Caddy TLS
├── Caddyfile                  <- Caddy reverse proxy + optional rate limiting
├── .github/workflows/
│   ├── ci.yml                 <- unit tests on push (ubuntu + macOS)
│   └── deploy.yml             <- CI passes -> fly deploy (GitHub Actions)
├── backend/
│   ├── main.mojo              <- entry point (fork, bind, serve)
│   ├── entrypoint.sh          <- Docker entrypoint (AOT/JIT, optional Litestream)
│   ├── litestream.yml         <- Litestream replica config
│   ├── mobin/
│   │   ├── __init__.mojo      <- public re-exports
│   │   ├── models.mojo        <- Paste, PasteStats, ServerConfig structs
│   │   ├── db.mojo            <- SQLite helpers (CRUD, stats table, expiry purge)
│   │   ├── handlers.mojo      <- per-route handler functions
│   │   ├── router.mojo        <- URL dispatch (method x path -> handler)
│   │   ├── feed.mojo          <- WebSocket live-feed loop + periodic expiry sweep
│   │   └── static.mojo        <- embedded frontend HTML (served by backend directly)
│   └── tests/
│       ├── test_models.mojo
│       ├── test_db.mojo
│       └── test_router.mojo
├── frontend/
│   └── src/
│       └── index.html         <- full-featured frontend (served by nginx in dev)
├── integtest/
│   ├── pixi.toml              <- test dependencies (pytest, httpx, websockets, locust)
│   ├── Dockerfile             <- locust container image
│   ├── test_api.py            <- 32 API + WebSocket integration tests
│   ├── test_frontend.py       <- 6 frontend container smoke tests
│   ├── test_health.py         <- 7 health/CORS tests
│   ├── locustfile.py          <- Locust load test scenarios
│   └── conftest.py            <- shared fixtures (base URL, backend lifecycle)
└── docs/                      <- you are here
```

## Integration tests

The integration suite runs **45 tests** against the live Docker Compose stack (from `integtest/`):

| Command | What it does |
|---------|-------------|
| `pixi install` | Install Python test dependencies (`pytest`, `httpx`, `websockets`, `locust`) |
| `pixi run test` | Run HTTP + WebSocket integration tests against a running backend |
| `pixi run test-all` | Run all tests including frontend container smoke tests |
| `pixi run load-test` | Headless Locust: 50 users, 5/s ramp, 60 s, against `http://localhost:8080` |
| `pixi run load-ui` | Locust with web UI on `:8089`; set users and run time interactively |

| File | Tests | Coverage |
|------|-------|---------|
| `test_api.py` | 32 | CRUD, pagination, search, stats, WebSocket live feed |
| `test_frontend.py` | 6 | nginx serves HTML, SPA routing, API reachability, CORS |
| `test_health.py` | 7 | Health probe, stats types, CORS headers, OPTIONS preflight |

Set `MOBIN_URL=http://my-server:8080` to run against an already-running instance.
