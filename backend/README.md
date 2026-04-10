# mobin backend

100% Mojo HTTP + WebSocket pastebin API.

## Quick start

```bash
pixi install
pixi run build
./mobin-backend
```

API is now live at `http://localhost:8080`.  
WebSocket feed at `ws://localhost:8081/feed`.

## Development run (no binary)

```bash
pixi run run-dev
```

## Tests

```bash
pixi run tests
```

## Configuration

| Source | Priority |
|--------|----------|
| `config.toml` | lowest |
| Environment variables | medium |
| CLI flags | highest |

| Field | Env var | CLI | Default |
|-------|---------|-----|---------|
| `host` | `HOST` | `--host` | `0.0.0.0` |
| `port` | `PORT` | `--port` | `8080` |
| `ws_port` | `WS_PORT` | `--ws-port` | `8081` |
| `db_path` | `DB_PATH` | `--db-path` | `data/mobin.db` |
| `max_size` | `MAX_SIZE` | `--max-size` | `65536` |
| `ttl_days` | `TTL_DAYS` | `--ttl-days` | `30` |
