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

All configuration is read from environment variables at startup:

| Env var | Default | Description |
|---------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address for HTTP and WS servers |
| `PORT` | `8080` | HTTP server port |
| `WS_PORT` | `8081` | WebSocket server port |
| `DB_PATH` | `data/mobin.db` | Path to SQLite database file |
| `MAX_SIZE` | `65536` | Maximum paste size in bytes (64 KB) |
| `TTL_DAYS` | `30` | Default paste time-to-live in days |
