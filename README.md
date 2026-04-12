# mobin

A pastebin service built entirely in [Mojo](https://docs.modular.com/mojo/). Zero Python in the hot path: the HTTP server, WebSocket server, database layer, JSON serialisation, and routing are all Mojo code.

**Live demo: [mobin.fly.dev](https://mobin.fly.dev/)**

- **Backend**: Mojo (`flare` HTTP + WS, `sqlite`, `morph` JSON, `uuid`, `tempo`)
- **Frontend**: Vanilla JS + nginx with syntax highlighting, live feed via WebSocket, auto-removal of expired pastes
- **Infra**: Docker Compose, single root `pixi.toml` (monorepo), GitHub Actions -> Fly.io CD

---

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

### Production URL routing (Fly.io)

In production (HTTPS), the frontend detects the protocol and adjusts:

- **API** -> same origin (`https://mobin.fly.dev/...`). Fly.io's `[http_service]` routes port 443 to internal port 8080
- **WebSocket** -> `wss://mobin.fly.dev:8081/feed`. Fly.io's `[[services]]` terminates TLS on port 8081 via a dedicated IPv4
- **Fallback** -> if WS is unreachable, the frontend polls `GET /pastes` every 3 seconds

In local dev, explicit ports are used: `:8080` for API, `:8081` for WS.

### Process model

`main()` calls `fork()` **once** before binding either port:

| Process | Role | Port |
|---------|------|------|
| Parent | `HttpServer`: handles all REST requests | `$PORT` (default 8080) |
| Child  | `WsServer`: pushes new pastes to subscribers | `$WS_PORT` (default 8081) |

`fork()` is used instead of `parallelize` because `parallelize`'s `TaskGroup` calls `abort()` on any unhandled exception, so a routine WebSocket disconnection would kill both servers. Separate OS processes give full fault isolation: an EPIPE in the WS child does not affect the HTTP parent. The WS child also self-restarts up to 10 times with exponential back-off before giving up.

### Database

Both processes open **independent** SQLite connections. WAL mode allows one writer and many concurrent readers without blocking.

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
```

Each HTTP request and each WS connection gets its own `Database` handle that is closed when the handler returns (RAII).

#### Stats table

Stats use a dedicated `stats` table with monotonically-increasing counters:

| Counter | Incremented when | Never decreases |
|---------|-----------------|----------------|
| `total_pastes` | A paste is created | Even after paste expires or is purged |
| `total_views` | A paste is viewed | Even after paste expires or is purged |

The `today` counter resets to 0 at midnight UTC and counts up from there. All counters are stored in the `stats` table and survive paste expiry and purge. A backfill migration seeds counters from existing data when upgrading from an older schema.

### Repo layout

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
│   └── deploy.yml             <- push-to-main -> fly deploy (GitHub Actions)
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
└── integtest/
    ├── pixi.toml              <- test dependencies (pytest, httpx, websockets, locust)
    ├── Dockerfile             <- locust container image
    ├── .dockerignore          <- excludes host .pixi/ from Docker context
    ├── test_api.py            <- 32 API + WebSocket integration tests
    ├── test_frontend.py       <- 6 frontend container smoke tests
    ├── test_health.py         <- 7 health/CORS tests
    ├── locustfile.py          <- Locust load test scenarios
    └── conftest.py            <- shared fixtures (base URL, backend lifecycle)
```

---

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

Environment variables (all optional):

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP server port |
| `WS_PORT` | `8081` | WebSocket server port |
| `DB_PATH` | `data/mobin.db` | SQLite database file path |
| `MAX_SIZE` | `65536` | Max paste size in bytes |
| `TTL_SECS` | `2592000` | Server-side default paste expiry in seconds (30 days) |

---

## Quick start: Docker Compose (dev)

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

---

## Commands (all from repo root)

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

---

## Integration tests (`cd integtest`)

The integration suite runs **45 tests** against the live Docker Compose stack:

| Command | What it does |
|---------|-------------|
| `pixi install` | Install Python test dependencies (`pytest`, `httpx`, `websockets`, `locust`) |
| `pixi run test` | Run HTTP + WebSocket integration tests against a running backend |
| `pixi run test-all` | Run all tests including frontend container smoke tests |
| `pixi run load-test` | Headless Locust: 50 users, 5/s ramp, 60 s, against `http://localhost:8080` |
| `pixi run load-ui` | Locust with web UI on `:8089`; set users and run time interactively |

Test breakdown:

| File | Tests | Coverage |
|------|-------|---------|
| `test_api.py` | 32 | CRUD, pagination, search, stats, WebSocket live feed |
| `test_frontend.py` | 6 | nginx serves HTML, SPA routing, API reachability, CORS |
| `test_health.py` | 7 | Health probe, stats types, CORS headers, OPTIONS preflight |

Set `MOBIN_URL=http://my-server:8080` to run the test suite against an already-running instance instead of spawning a local backend.

---

## REST API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/paste` | Create a new paste |
| `GET` | `/paste/{id}` | Fetch paste by UUID (increments view count) |
| `PUT` | `/paste/{id}` | Update paste (requires `X-Delete-Token` header) |
| `DELETE` | `/paste/{id}` | Delete paste (requires `X-Delete-Token` header) |
| `GET` | `/pastes` | List pastes (`?limit=20&offset=0`, `?q=term`, `?before=ts`) |
| `GET` | `/stats` | Global stats: `total` (all-time), `today` (24h), `total_views` (cumulative) |
| `GET` | `/health` | Liveness probe, returns `{"status":"ok"}` |
| `GET` | `/` | Serve frontend HTML |
| `OPTIONS` | `*` | CORS preflight, returns 204 with `Access-Control-Allow-*` headers |

All responses include `Access-Control-Allow-Origin: *`.

### Stats

The `/stats` endpoint returns cumulative counters that **never decrease**:

```json
{
  "total": 42,
  "today": 5,
  "total_views": 128
}
```

| Field | Meaning |
|-------|---------|
| `total` | All-time pastes created (survives expiry and purge) |
| `today` | Pastes created today (UTC). Resets to 0 at midnight, never decreases within a day |
| `total_views` | Cumulative view count across all pastes (survives expiry and purge) |

### TTL options

Paste lifetime is specified in **seconds** via `ttl_secs`. The UI exposes these presets:

| UI label | `ttl_secs` |
|----------|-----------|
| 1 minute | `60` |
| 5 minutes | `300` |
| **1 hour (default)** | **`3600`** |
| 12 hours | `43200` |
| 1 day | `86400` |
| 4 days | `345600` |
| 7 days | `604800` |
| 30 days (max) | `2592000` |

Any value above `2592000` (30 days) is clamped server-side. Expired pastes are removed from the live feed in real time and purged from the database every 60 seconds.

### Create a paste

```bash
curl -X POST http://localhost:8080/paste \
  -H 'Content-Type: application/json' \
  -d '{
    "title":    "hello world",
    "content":  "print(\"hello\")",
    "language": "python",
    "ttl_secs": 3600
  }'
```

Response (save `delete_token`, it is only returned once):

```json
{
  "id":           "550e8400-e29b-41d4-a716-446655440000",
  "title":        "hello world",
  "content":      "print(\"hello\")",
  "language":     "python",
  "created_at":   1712620800,
  "expires_at":   1713225600,
  "views":        0,
  "delete_token": "a3f1c2d4-..."
}
```

### Delete a paste

```bash
curl -X DELETE http://localhost:8080/paste/550e8400-e29b-41d4-a716-446655440000 \
  -H 'X-Delete-Token: a3f1c2d4-...'
```

| Missing / wrong token | Response |
|-----------------------|----------|
| Header absent | `401 Unauthorized` |
| Token incorrect | `403 Forbidden` |
| Token correct | `200 {"deleted":true}` |

### WebSocket live feed

Connect to `ws://localhost:8081/feed`. Each new paste is pushed as a JSON object (same schema as the GET response, without `delete_token`). The server sends a PING every 500 ms to detect stale connections.

```bash
# Quick test with websocat (brew install websocat)
websocat ws://localhost:8081/feed
```

In production: `wss://mobin.fly.dev:8081/feed` (TLS terminated by Fly.io).

---

## Performance

### Local (Docker Compose, Mac M-series)

Observed under 50-user Locust load test (5 users/s ramp, 60 s):

| Metric | Observed |
|--------|----------|
| Create paste (POST /paste) | ~350 RPS, p95 ~ 130 ms |
| Get paste (GET /paste/:id) | ~600 RPS, p95 ~ 80 ms |
| List pastes (GET /pastes) | ~500 RPS, p95 ~ 90 ms |
| Idle memory | ~15 MB |
| Error rate | 0% |

### Live endpoint (mobin.fly.dev, shared-cpu-1x 256 MB)

Sequential load test, 50 requests per endpoint, warm machine:

| Endpoint | avg | p50 | p95 | min |
|----------|-----|-----|-----|-----|
| POST /paste (create) | 236 ms | 236 ms | 289 ms | 193 ms |
| GET /paste/:id (read) | 250 ms | 233 ms | 260 ms | 195 ms |
| GET /pastes (list) | 234 ms | 232 ms | 262 ms | 197 ms |
| GET /stats | 229 ms | 233 ms | 263 ms | 186 ms |
| GET /health | 305 ms | 242 ms | 559 ms | 184 ms |

The ~200 ms floor is network round-trip from the test client. Server-side processing is <5 ms. 0 errors across 250 requests. Cold-start adds ~1-2 s on the first request when the Fly.io machine wakes from sleep.

SQLite WAL mode handles concurrent reads well at these concurrency levels. Write throughput becomes the limiting factor under sustained write-heavy load.

---

## Known limitations and future improvements

### Service / feature gaps

Items marked ✅ have been implemented. Remaining items are open improvements.

| Area | Status | Notes |
|------|--------|-------|
| **Paste editing** | ✅ Done | `PUT /paste/{id}` with `X-Delete-Token`; partial updates; optional `ttl_secs` to reset expiry |
| **Expiry enforcement** | ✅ Done | Background sweep every 60 s; startup purge cleans rows that expired while the service was down |
| **Keyset pagination** | ✅ Done | `GET /pastes?before=<unix_ts>` for cursor-stable pages; classic `offset=N` still supported |
| **Paste search** | ✅ Done | `GET /pastes?q=<term>` filters by case-insensitive substring match (SQLite LIKE) |
| **Monotonic stats** | ✅ Done | Stats never decrease on paste expiry; dedicated `stats` table with cumulative counters |
| **Production deploy** | ✅ Done | AOT-compiled binary on Fly.io (256 MB, shared-cpu-1x) with dedicated IPv4 for WS |
| **Authentication** | Not planned | Pastes are intentionally public; delete token is the only ownership proof |
| **WS child death** | Open | After 10 retries the live feed goes silent; a `/ws/health` probe could alert the user |
| **Single-region SQLite** | Open | One writer; horizontal scaling requires Turso/libSQL or Postgres |
| **Rate limiting** | Partial | Caddy rate-limits by IP; no per-paste-creator quotas |
| **Full-text search** | Open | Current LIKE search is `O(n)` per query; SQLite FTS5 would be faster at scale |

### Mojo DX friction (things the language/libs should fix)

These are not bugs (the service is correct), but each required a workaround that
Python would express in one line. They are useful upstream bug reports / feature
requests for the Mojo ecosystem.

#### 1. `String` byte-range slicing requires `unsafe`

**Today:** every substring by byte index uses the `unsafe_from_utf8=` escape hatch:

```mojo
# router.mojo: strip the "/paste/" prefix
var paste_id = String(unsafe_from_utf8=path.as_bytes()[_PREFIX.byte_length():])

# handlers.mojo: parse a query-string value
val_str = String(unsafe_from_utf8=query.as_bytes()[start:end])
```

**Fix needed in stdlib:** `String.__getitem__(Slice) -> String` that trusts the
caller's byte slice. No `unsafe` name should be required for standard slicing.

---

#### 2. `Request.body` is `List[UInt8]`, not `String`

**Today:** every HTTP handler must manually copy the byte list and null-terminate
before JSON parsing:

```mojo
var raw = List[UInt8](capacity=len(req.body) + 1)
for b in req.body:
    raw.append(b)
raw.append(0)
var body = String(unsafe_from_utf8=raw)
```

**Fix needed in `flare`:** `Request.text() -> String` (UTF-8 decode of the body).

---

#### 3. No way to add ad-hoc fields to `morph.write()` output

`morph.write(paste)` reflects the struct and serialises all fields. The `delete_token`
field must not appear in `GET` responses but must appear once in the `POST` response.
The handler surgically removes the closing `}` and appends the field manually.

**Fix needed in `morph`:** `write_with(obj, extra: Dict[String, String])` or a
`@skip_serialise` field attribute.

---

#### 4. `fork()`, `sleep()`, `kill()` need raw `external_call`

```mojo
var pid = Int(external_call["fork", Int32]())
_ = external_call["sleep", Int32](Int32(backoff))
_ = external_call["kill", Int32](Int32(pid), Int32(15))
```

**Fix needed in `std.os.process`:** `fork() -> Int`, `sleep(seconds: Int)`, and
`kill(pid: Int, sig: Int)`. Basic POSIX wrappers.

---

#### 5. C-FFI `String -> Int` pointer casting and keepalive boilerplate

In `sqlite/ffi.mojo`, every string passed to a C function requires a manual copy,
pointer cast, and an explicit `_ = v^` keepalive to prevent premature deallocation.

**Fix needed in stdlib:** A `String.with_c_ptr { |ptr, len| ... }` scoped helper
that guarantees the buffer is alive for the duration of the closure.

---

### Summary table: `unsafe` usage and where it should go away

| Location | `unsafe` pattern | Root cause | Fix target |
|----------|-----------------|-----------|-----------|
| `router.mojo` | `String(unsafe_from_utf8=path.as_bytes()[n:])` | No `String` slice | `stdlib` |
| `handlers.mojo` | byte-copy loop + `unsafe_from_utf8=` for body | `Request.body` is `List[UInt8]` | `flare` |
| `handlers.mojo` | JSON surgery to inject `delete_token` | `morph` can't add extra fields | `morph` |
| `handlers.mojo` | `String(unsafe_from_utf8=query.as_bytes()[s:e])` | No `String` slice | `stdlib` |
| `morph/value.mojo` | `String(unsafe_from_utf8=data[i:i+n])` (x6) | No `String` slice | `stdlib` |
| `sqlite/ffi.mojo` | `Int(v.unsafe_ptr())` + `_ = v^` (x4) | No scoped C-string helper | `stdlib` |
| `main.mojo` | `external_call["fork"]` / `sleep` / `kill` | Missing POSIX wrappers | `stdlib` |

---

## Security

| Area | Status | Notes |
|------|--------|-------|
| Unicode support | ✅ | Multi-byte UTF-8 (CJK, emoji, Arabic) roundtrips correctly |
| Input validation | ✅ | Empty body, malformed JSON, wrong field types -> `400` |
| Oversized payloads | ✅ | >2 MB -> `413 Content Too Large` |
| Null bytes | ✅ | `\x00` in content -> `400 Bad Request` |
| SQL injection | ✅ | All queries use parameterised SQLite statements |
| XSS | ✅ | Frontend uses `textContent` / `esc()`, no `innerHTML` on user data |
| Path traversal | ✅ | No filesystem access based on user input |
| Delete auth | ✅ | One-time `delete_token` per paste; `401`/`403` without it |
| CORS | ✅ | `Access-Control-Allow-Origin: *` on all responses |
| Rate limiting | ✅ | Via Caddy (see [TLS + rate limiting](#tls--rate-limiting-via-caddy)) |
| HTTPS / TLS | ✅ | Via Caddy (self-hosted) or Fly.io (managed) |

---

## Resilience

### What's already in place

| Feature | How |
|---------|-----|
| Container auto-restart | `restart: always` in prod compose; Fly.io auto-restarts on health-check failure |
| HTTP / WS isolation | `fork()` gives HTTP and WS separate OS processes; a WS crash cannot kill the HTTP server |
| WS self-restart | WS child retries up to 10x with exponential back-off (2 s -> 16 s cap) before giving up |
| Crash-safe DB | SQLite WAL + `synchronous=NORMAL` survives unclean shutdown without corruption |
| Liveness probe | `GET /health` -> `{"status":"ok"}` used by Docker healthcheck and Fly.io |
| AOT compilation | Dockerfile compiles to a standalone binary; JIT fallback if AOT fails |

### Continuous DB backup with Litestream (optional)

[Litestream](https://litestream.io) streams every SQLite WAL commit to object storage in real time (<=1 s lag). If the volume is ever lost, it restores the latest snapshot automatically on the next startup. Worst-case data loss: ~1 second of writes.

[Cloudflare R2](https://www.cloudflare.com/developer-platform/r2/) is the recommended backend: 10 GB free storage, zero egress fees.

**Step 1: create an R2 bucket**

1. Sign up / log in at [dash.cloudflare.com](https://dash.cloudflare.com).
2. Go to **R2 Object Storage** -> **Create bucket** -> name it `mobin-backup`.
3. Go to **Manage R2 API Tokens** -> **Create API Token** -> grant *Object Read & Write* on the `mobin-backup` bucket.
4. Copy the **Access Key ID** and **Secret Access Key** (you'll need them in the next step).
5. Copy your **Account ID** from the R2 overview page (a 32-char hex string).

**Step 2: set the secrets**

Never commit credentials. Set them via your deployment tool:

```bash
# Fly.io (see Deployment section)
fly secrets set \
  LITESTREAM_REPLICA_URL="s3://mobin-backup/mobin.db?endpoint=https://<account-id>.r2.cloudflarestorage.com" \
  LITESTREAM_ACCESS_KEY_ID="<your-access-key-id>" \
  LITESTREAM_SECRET_ACCESS_KEY="<your-secret-access-key>"

# Docker Compose: open docker-compose.prod.yml and uncomment + fill in the
# three LITESTREAM_* environment variables under the backend service.
```

**Step 3: deploy**

The `entrypoint.sh` script detects `LITESTREAM_REPLICA_URL` automatically:
- If the DB file is **absent** on the volume (first boot or after volume loss) it downloads the latest snapshot from R2 before starting the server.
- If the DB file **exists** it skips the restore and begins replicating immediately.

---

## TLS + rate limiting via Caddy

[Caddy](https://caddyserver.com) is a modern web server that handles HTTPS automatically: no certbot, no manual certificate renewal. The `Caddyfile` and a Caddy service are already included in `docker-compose.prod.yml`.

### How Caddy fits in

```
Internet -> Caddy :443 (TLS termination) -> backend :8080 (HTTP)
                                         -> backend :8081 (WebSocket)
```

Caddy obtains a free [Let's Encrypt](https://letsencrypt.org) certificate for your domain the first time it receives a request. It renews it automatically before expiry. You do nothing.

### Setup (5 minutes)

**Step 1: point a domain at your server**

Create an `A` record in your DNS provider pointing your domain (e.g. `mobin.yourdomain.com`) to your server's IP address.

**Step 2: set your domain**

```bash
export CADDY_DOMAIN=mobin.yourdomain.com
```

**Step 3: start the stack**

```bash
docker compose -f docker-compose.prod.yml up -d
```

---

## Deployment

### Option A: Fly.io (recommended)

[Fly.io](https://fly.io) runs Docker containers close to your users. It handles TLS, health checks, and rolling deploys.

**Current production config:**

| Resource | Value | Monthly cost |
|----------|-------|-------------|
| VM | `shared-cpu-1x`, 256 MB | ~$0 (free tier) |
| Volume | 1 GB persistent | $0 (free tier) |
| Dedicated IPv4 | For WebSocket on :8081 | $2/month |
| **Total** | | **~$2/month** |

The Dockerfile performs AOT compilation. The resulting 546 MB image contains a standalone binary that starts in <2 seconds and runs comfortably in 256 MB.

**Prerequisites**

```bash
# macOS
brew install flyctl

# Linux
curl -L https://fly.io/install.sh | sh

# Authenticate (add a credit card to unlock free tier, no charge for small apps)
fly auth login
```

**First deploy**

```bash
cd /path/to/mobin

# 1. Create the app
fly launch --no-deploy --copy-config

# 2. Create a persistent volume for SQLite (1 GB, free tier)
fly volumes create mobin_data --size 1 --region ord

# 3. Allocate a dedicated IPv4 for WebSocket on port 8081
fly ips allocate-v4

# 4. (Optional) add Litestream backup secrets
fly secrets set \
  LITESTREAM_REPLICA_URL="s3://mobin-backup/mobin.db?endpoint=https://<account-id>.r2.cloudflarestorage.com" \
  LITESTREAM_ACCESS_KEY_ID="<key>" \
  LITESTREAM_SECRET_ACCESS_KEY="<secret>"

# 5. Deploy
fly deploy
# First deploy: ~3-5 min (downloads Mojo toolchain + installs deps)
# Subsequent deploys: ~2-3 min (Docker layer cache)

# 6. Open in browser
fly open
```

**Continuous deployment (push-to-main)**

```yaml
# .github/workflows/deploy.yml (already committed)
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

Get the token: `fly tokens create deploy -x 999999h`

**Useful day-to-day commands**

```bash
fly logs                  # tail live logs
fly status                # health check status and VM state
fly ssh console           # shell inside the running container
fly deploy                # push a new version (rolling deploy)
fly volumes list          # list persistent volumes
fly secrets list          # list configured secrets (values hidden)
```

### Option B: VPS with Docker Compose (Hetzner, DigitalOcean, etc.)

A Hetzner CX22 (~4 €/month) or DigitalOcean Droplet ($6/month) is more than enough.

```bash
ssh root@<your-server-ip>
curl -fsSL https://get.docker.com | sh
git clone https://github.com/your-user/mobin.git
cd mobin

# Set your domain for TLS
export CADDY_DOMAIN=mobin.yourdomain.com

# Start the stack
docker compose -f docker-compose.prod.yml up -d
```

---

## Summary: which deployment to pick?

| | Fly.io | VPS + Docker Compose |
|-|--------|---------------------|
| **Cost** | ~$2/month (IPv4 only) | ~4 €/month |
| **TLS** | Automatic (Fly handles it) | Automatic (Caddy handles it) |
| **Setup time** | ~15 min | ~20 min |
| **CD on push** | ✅ Built-in (GitHub Actions) | Manual `docker compose up` |
| **Persistent storage** | Fly volumes (1 GB free) | Server disk |
| **Litestream backup** | `fly secrets set` + auto-deploy | Uncomment env vars in compose |
| **SSH access** | `fly ssh console` | `ssh root@ip` |
| **Best for** | Getting something live quickly | Full control, cost predictability |
