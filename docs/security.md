# Security

| Area | Status | Notes |
|------|--------|-------|
| Unicode support | Handled | Multi-byte UTF-8 (CJK, emoji, Arabic) roundtrips correctly |
| Input validation | Handled | Empty body, malformed JSON, wrong field types -> `400` |
| Oversized payloads | Handled | >64 KB (configurable via `MAX_SIZE` env var) -> `413 Content Too Large` |
| Null bytes | Handled | `\x00` in content -> `400 Bad Request` |
| SQL injection | Handled | All queries use parameterised SQLite statements |
| XSS | Handled | Frontend uses `textContent` / `esc()`, no `innerHTML` on user data |
| Path traversal | Handled | No filesystem access based on user input |
| Delete auth | Handled | One-time `delete_token` per paste; `401`/`403` without it |
| CORS | Handled | `Access-Control-Allow-Origin: *` on all responses |
| Rate limiting | Handled | Via Caddy (see [deployment](deployment.md#tls--rate-limiting-via-caddy)) |
| HTTPS / TLS | Handled | Via Caddy (self-hosted) or Fly.io (managed) |

## Resilience

| Feature | How |
|---------|-----|
| Container auto-restart | `restart: always` in prod compose; Fly.io auto-restarts on health-check failure |
| HTTP / WS isolation | `fork()` gives HTTP and WS separate OS processes; a WS crash cannot kill the HTTP server |
| WS self-restart | WS child retries up to 10x with exponential back-off (2 s -> 16 s cap) before giving up |
| Crash-safe DB | SQLite WAL + `synchronous=NORMAL` survives unclean shutdown without corruption |
| Liveness probe | `GET /health` -> `{"status":"ok"}` used by Docker healthcheck and Fly.io |
| AOT compilation | Dockerfile compiles to a standalone binary; JIT fallback if AOT fails |
