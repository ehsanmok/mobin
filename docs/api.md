# REST API

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

Every response also carries an `X-Request-Id` header for log correlation. If the client supplies `X-Request-Id` on the request it is echoed back unchanged; otherwise the server generates one.

## Stats

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

## TTL options

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

## Create a paste

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

## Delete a paste

```bash
curl -X DELETE http://localhost:8080/paste/550e8400-e29b-41d4-a716-446655440000 \
  -H 'X-Delete-Token: a3f1c2d4-...'
```

| Missing / wrong token | Response |
|-----------------------|----------|
| Header absent | `401 Unauthorized` |
| Token incorrect | `403 Forbidden` |
| Token correct | `200 {"deleted":true}` |

## WebSocket live feed

Connect to `ws://localhost:8081/feed`. Each new paste is pushed as a JSON object (same schema as the GET response, without `delete_token`). The server sends a PING every 500 ms to detect stale connections.

```bash
# Quick test with websocat (brew install websocat)
websocat ws://localhost:8081/feed
```

In production: `wss://mobin.fly.dev:8081/feed` (TLS terminated by Fly.io).
