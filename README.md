# mobin

A pastebin service built entirely in [Mojo](https://docs.modular.com/mojo/). Zero Python in the hot path — the HTTP server, WebSocket server, database layer, JSON serialisation, and routing are all Mojo code.

- **Backend**: Mojo (`flare` HTTP + WS, `sqlite`, `morph` JSON, `uuid`, `tempo`)
- **Frontend**: Vanilla JS + nginx — syntax highlighting, live feed via WebSocket
- **Infra**: Docker Compose, `pixi` dependency management

---

## Architecture

```mermaid
graph TD
    subgraph Browser
        UI[HTML / JS frontend]
    end

    subgraph Docker / local
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
    UI -->|ws://…:8081/feed| WS

    FORK -->|parent| HTTP
    FORK -->|child| WS

    HTTP -->|per-request connection| SQLITE
    WS -->|per-connection connection| SQLITE
```

### Process model

`main()` calls `fork()` **once** before binding either port:

| Process | Role | Port |
|---------|------|------|
| Parent | `HttpServer` — handles all REST requests | `$PORT` (default 8080) |
| Child  | `WsServer` — pushes new pastes to subscribers | `$WS_PORT` (default 8081) |

`fork()` is used instead of `parallelize` because `parallelize`'s `TaskGroup` calls `abort()` on any unhandled exception — a routine WebSocket disconnection would kill both servers. Separate OS processes give full fault isolation: an EPIPE in the WS child does not affect the HTTP parent.

### Database

Both processes open **independent** SQLite connections. WAL mode allows one writer and many concurrent readers without blocking.

```
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
```

Each HTTP request and each WS connection gets its own `Database` handle that is closed when the handler returns (RAII).

### Mojo package layout

```
backend/
├── main.mojo               ← entry point (fork, bind, serve)
├── mobin/
│   ├── __init__.mojo       ← public re-exports
│   ├── models.mojo         ← Paste, PasteStats, ServerConfig structs
│   ├── db.mojo             ← SQLite helpers (init_db, db_create, …)
│   ├── handlers.mojo       ← per-route handler functions
│   ├── router.mojo         ← URL dispatch (method × path → handler)
│   ├── feed.mojo           ← WebSocket live-feed loop
│   └── static.mojo         ← embedded frontend HTML
└── tests/
    ├── test_models.mojo
    ├── test_db.mojo
    └── test_router.mojo
```

---

## Quick start — local

```bash
cd backend
pixi install          # resolve + install all Mojo dependencies
pixi run build        # compile main.mojo → ./mobin-backend
./mobin-backend       # start on :8080 (HTTP) and :8081 (WS)
```

Open `http://localhost:8080`.

Environment variables (all optional):

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP server port |
| `WS_PORT` | `8081` | WebSocket server port |
| `DB_PATH` | `data/mobin.db` | SQLite database file path |
| `FLARE_LIB` | *(auto)* | Explicit path to `libflare_tls.so` / `.dylib` |

---

## Quick start — Docker Compose

```bash
docker compose up --build
```

| URL | Service |
|-----|---------|
| `http://localhost:3000` | Frontend (nginx) |
| `http://localhost:8080` | Backend REST API (direct) |
| `http://localhost:8081` | WebSocket feed (direct) |
| `http://localhost:8089` | Locust load-test UI |

---

## Backend commands (`cd backend`)

| Command | What it does |
|---------|-------------|
| `pixi install` | Install all Mojo library dependencies into `.pixi/envs/default/` |
| `pixi run build` | Compile `main.mojo` to a standalone `mobin-backend` binary |
| `pixi run run` | Build then immediately start the backend |
| `pixi run run-dev` | Run with `mojo run` (no compile step, faster iteration) |
| `pixi run tests` | Run all three unit-test suites (`test_models`, `test_db`, `test_router`) |
| `pixi run test-models` | Unit tests for `Paste` / `PasteStats` / `ServerConfig` / `new_paste()` |
| `pixi run test-db` | Unit tests for all SQLite helpers (`init_db`, CRUD, stats, expiry) |
| `pixi run test-router` | Unit tests for URL routing, CORS preflight, 404 handling |
| `pixi run format` | Auto-format `mobin/`, `main.mojo`, and `tests/` with `mojo format` |

---

## Integration tests (`cd integtest`)

The integration suite starts a **real backend subprocess** with a temporary SQLite database, waits for `/health` to respond, runs all tests, then terminates the backend and its forked child.

| Command | What it does |
|---------|-------------|
| `pixi install` | Install Python test dependencies (`pytest`, `httpx`, `websockets`, `locust`) |
| `pixi run test` | Run HTTP + WebSocket integration tests against a freshly started backend |
| `pixi run test-all` | Same as above but includes any additional test files |
| `pixi run load-test` | Headless Locust: 50 users, 5/s ramp, 60 s, against `http://localhost:8080` |
| `pixi run load-ui` | Locust with web UI on `:8089` — set users and run time interactively |

Set `MOBIN_URL=http://my-server:8080` to run the test suite against an already-running instance instead of spawning a local backend.

---

## REST API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/paste` | Create a new paste |
| `GET` | `/paste/{id}` | Fetch paste by UUID (increments view count) |
| `DELETE` | `/paste/{id}` | Delete paste by UUID |
| `GET` | `/pastes` | List pastes (`?limit=20&offset=0`) |
| `GET` | `/stats` | Global stats (`total`, `today`, `total_views`) |
| `GET` | `/health` | Liveness probe — returns `{"status":"ok"}` |
| `GET` | `/` | Serve frontend HTML |
| `OPTIONS` | `*` | CORS preflight — returns 204 with `Access-Control-Allow-*` headers |

All responses include `Access-Control-Allow-Origin: *`.

### Create paste

```bash
curl -X POST http://localhost:8080/paste \
  -H 'Content-Type: application/json' \
  -d '{
    "title":    "hello world",
    "content":  "print(\"hello\")",
    "language": "python",
    "ttl_days": 7
  }'
```

Response:

```json
{
  "id":         "550e8400-e29b-41d4-a716-446655440000",
  "title":      "hello world",
  "content":    "print(\"hello\")",
  "language":   "python",
  "created_at": 1712620800,
  "expires_at": 1713225600,
  "views":      0
}
```

### WebSocket live feed

```
ws://localhost:8081/feed
```

On connection the server begins polling the database every 500 ms. Each new paste is pushed as a JSON object (same schema as the REST response). A `PING` frame is sent after each poll to detect stale connections — the server silently drops disconnected clients and accepts the next one.

```bash
# Quick test with websocat
websocat ws://localhost:8081/feed
```

---

## Performance

Observed under 50-user Locust load test (5 users/s ramp, 60 s):

| Metric | Observed |
|--------|----------|
| Create paste (POST /paste) | ~350 RPS, p95 ≈ 130 ms |
| Get paste (GET /paste/:id) | ~600 RPS, p95 ≈ 80 ms |
| List pastes (GET /pastes) | ~500 RPS, p95 ≈ 90 ms |
| Idle memory | ~15 MB |
| Error rate | 0% |

SQLite WAL mode handles concurrent reads well at these concurrency levels. Write throughput becomes the limiting factor under sustained write-heavy load.

---

## Known limitations & security notes

| Area | Status | Notes |
|------|--------|-------|
| **Unicode support** | ✅ Fixed | Multi-byte UTF-8 (CJK, emoji, Arabic, etc.) roundtrips correctly via `morph` v0.1.0+ |
| **Input validation** | ✅ Fixed | Empty body, malformed JSON, wrong field types → `400 Bad Request` |
| **Oversized payloads** | ✅ Handled | > 2 MB → `413 Content Too Large` |
| **SQL injection** | ✅ Safe | All queries use parameterised SQLite statements |
| **XSS** | ✅ Safe | Frontend uses `textContent` / `esc()` helper — no `innerHTML` on user data |
| **Path traversal** | ✅ Safe | No filesystem access based on user input |
| **CORS** | ✅ Present | `Access-Control-Allow-Origin: *` on all responses |
| **Authentication / authorisation** | ✅ Delete token | `POST /paste` returns a one-time `delete_token`; `DELETE /paste/:id` requires `X-Delete-Token` header — returns `401` if missing, `403` if wrong |
| **Rate limiting** | ✅ Via Caddy | `Caddyfile` ships with commented `rate_limit` block (requires caddy-ratelimit plugin); uncomment after `xcaddy build --with github.com/mholt/caddy-ratelimit` |
| **Null bytes in content** | ✅ Rejected | Content containing `\x00` bytes returns `400 Bad Request` |
| **HTTPS / TLS** | ✅ Via Caddy | `docker-compose.prod.yml` includes a Caddy service that auto-provisions Let's Encrypt certs; edit `Caddyfile` to set your domain |

---

## Resilience

### Level 0 — baseline (already in place)

| Feature | How |
|---------|-----|
| Container auto-restart | `restart: always` in prod compose; Fly.io restarts on health-check failure |
| HTTP server isolation | `fork()` separates HTTP and WS into distinct OS processes — a WS crash cannot kill the HTTP server |
| WS self-restart | WS child retries up to 10 times with exponential back-off (2 s → 16 s cap) before giving up |
| Crash-safe DB | SQLite WAL + `synchronous=NORMAL` — survives unclean shutdown without corruption |
| Liveness probe | `GET /health` → `{"status":"ok"}` used by Docker healthcheck and Fly.io |

### Level 1 — continuous backup with Litestream (optional, ~5 min setup)

Litestream streams every SQLite WAL commit to object storage in real time (≤1 s lag). On restart it restores the latest snapshot automatically. Worst-case data loss: ~1 second of writes.

**Cloudflare R2** is recommended (10 GB free storage, zero egress fees):

1. Create a bucket `mobin-backup` in your [R2 dashboard](https://dash.cloudflare.com/?to=/:account/r2).
2. Generate an R2 API token with *Object Read & Write* on that bucket.
3. Set secrets — **never commit these**:

```bash
# Fly.io
fly secrets set \
  LITESTREAM_REPLICA_URL="s3://mobin-backup/mobin.db?endpoint=https://<account-id>.r2.cloudflarestorage.com" \
  LITESTREAM_ACCESS_KEY_ID="<r2-access-key>" \
  LITESTREAM_SECRET_ACCESS_KEY="<r2-secret>"
fly deploy   # picks up new secrets + restores DB on first boot if volume is empty

# Docker Compose (docker-compose.prod.yml)
# Uncomment the LITESTREAM_* lines in the environment section and fill in values.
docker compose -f docker-compose.prod.yml up -d
```

**Restore** from replica (e.g. after volume loss):

```bash
# Fly.io — delete the old volume and create a fresh one; on next deploy
# entrypoint.sh will restore automatically from the replica.
fly volumes delete <vol-id>
fly volumes create mobin_data --size 1 --region ord
fly deploy

# Docker Compose — delete the volume and restart; entrypoint.sh restores.
docker compose -f docker-compose.prod.yml down -v
docker compose -f docker-compose.prod.yml up -d
```

---

## Deployment

### Fly.io

```bash
# First time
fly launch --no-deploy --copy-config   # reads fly.toml, creates app
fly volumes create mobin_data --size 1 --region ord
fly deploy

# Updates
fly deploy

# Useful commands
fly logs          # tail live logs
fly status        # health check status
fly ssh console   # shell into the VM
fly scale memory 1024   # bump RAM if OOM on startup (default 512 MB)
```

If Litestream is configured (via `fly secrets set`), `entrypoint.sh` restores
the latest DB snapshot before the first request is served.

### Docker Compose (VPS / bare metal)

```bash
# On the server (e.g. Hetzner CX11 ~2 €/month)
docker compose -f docker-compose.prod.yml up -d

# View logs
docker compose -f docker-compose.prod.yml logs -f backend

# Update to latest image
docker compose -f docker-compose.prod.yml pull && \
docker compose -f docker-compose.prod.yml up -d
```
