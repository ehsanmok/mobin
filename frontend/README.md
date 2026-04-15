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

The frontend auto-detects the environment using the page protocol and requires no code changes across local and production deployments:

```javascript
const HOST      = window.location.hostname;
const IS_PROD   = window.location.protocol === 'https:';
const API       = IS_PROD ? window.location.origin : window.location.protocol + '//' + HOST + ':8080';
const WS_SCHEME = IS_PROD ? 'wss' : 'ws';
const WS        = WS_SCHEME + '://' + HOST + ':8081/feed';
```

- **Local dev**: explicit ports `:8080` (HTTP) and `:8081` (WS)
- **Production (HTTPS)**: API uses same origin (Fly.io routes 443 to 8080 internally), WS uses `wss://` on `:8081` (TLS terminated by Fly.io via dedicated IPv4)
