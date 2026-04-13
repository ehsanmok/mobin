# Performance

## Local (Docker Compose, Mac M-series)

Observed under 50-user Locust load test (5 users/s ramp, 60 s):

| Metric | Observed |
|--------|----------|
| Create paste (POST /paste) | ~350 RPS, p95 ~ 130 ms |
| Get paste (GET /paste/:id) | ~600 RPS, p95 ~ 80 ms |
| List pastes (GET /pastes) | ~500 RPS, p95 ~ 90 ms |
| Idle memory | ~15 MB |
| Error rate | 0% |

## Live endpoint (mobin.fly.dev, shared-cpu-1x 256 MB)

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
