# mobin frontend

Vanilla JS single-page application served by nginx.

## Features

- **Create paste** — title, content, language selector, TTL picker
- **View paste** — syntax display, view count, expiry, share URL
- **Live feed** — WebSocket push from backend; falls back to 3s polling
- **Stats panel** — total/today/views, auto-refreshed every 30s
- **Copy to clipboard** — paste content and share URL
- **SPA routing** — `/paste/{id}` deep links work on reload

## Running standalone

```bash
docker build -t mobin-frontend .
docker run -p 80:80 mobin-frontend
```

Open `http://localhost` — the page connects to `localhost:8080` (backend API)
and `ws://localhost:8081` (WebSocket feed). Make sure the backend is running.

## Configuration

The frontend uses `window.location.hostname` to determine API and WS URLs,
so it works on any host without code changes:

```javascript
const API = window.location.protocol + '//' + HOST + ':8080';
const WS  = 'ws://' + HOST + ':8081/feed';
```

For production behind a reverse proxy, update these to use `/api/` paths
and configure nginx proxy_pass accordingly.
