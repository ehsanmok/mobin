# Deployment

## Option A: Fly.io (recommended)

[Fly.io](https://fly.io) runs Docker containers close to your users. It handles TLS, health checks, and rolling deploys.

**Current production config:**

| Resource | Value | Monthly cost |
|----------|-------|-------------|
| VM | `shared-cpu-1x`, 256 MB | ~$0 (free tier) |
| Volume | 1 GB persistent | $0 (free tier) |
| Dedicated IPv4 | For WebSocket on :8081 | $2/month |
| **Total** | | **~$2/month** |

The Dockerfile performs AOT compilation. The resulting 546 MB image contains a standalone binary that starts in <2 seconds and runs comfortably in 256 MB.

### Prerequisites

```bash
# macOS
brew install flyctl

# Linux
curl -L https://fly.io/install.sh | sh

# Authenticate (add a credit card to unlock free tier, no charge for small apps)
fly auth login
```

### First deploy

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

### Continuous deployment (push-to-main)

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

### Useful commands

```bash
fly logs                  # tail live logs
fly status                # health check status and VM state
fly ssh console           # shell inside the running container
fly deploy                # push a new version (rolling deploy)
fly volumes list          # list persistent volumes
fly secrets list          # list configured secrets (values hidden)
```

## Option B: VPS with Docker Compose (Hetzner, DigitalOcean, etc.)

A Hetzner CX22 (~4 EUR/month) or DigitalOcean Droplet ($6/month) is more than enough.

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

### TLS + rate limiting via Caddy

[Caddy](https://caddyserver.com) handles HTTPS automatically: no certbot, no manual certificate renewal.

```
Internet -> Caddy :443 (TLS termination) -> backend :8080 (HTTP)
                                         -> backend :8081 (WebSocket)
```

Caddy obtains a free [Let's Encrypt](https://letsencrypt.org) certificate for your domain the first time it receives a request. It renews automatically.

**Setup:**

1. Create an `A` record pointing your domain to your server's IP.
2. Set your domain: `export CADDY_DOMAIN=mobin.yourdomain.com`
3. Start: `docker compose -f docker-compose.prod.yml up -d`

### Continuous DB backup with Litestream

[Litestream](https://litestream.io) streams every SQLite WAL commit to object storage in real time (<=1 s lag). [Cloudflare R2](https://www.cloudflare.com/developer-platform/r2/) is recommended: 10 GB free storage, zero egress fees.

**Step 1: create an R2 bucket**

1. Sign up / log in at [dash.cloudflare.com](https://dash.cloudflare.com).
2. Go to **R2 Object Storage** -> **Create bucket** -> name it `mobin-backup`.
3. Go to **Manage R2 API Tokens** -> **Create API Token** -> grant *Object Read & Write* on the `mobin-backup` bucket.
4. Copy the **Access Key ID** and **Secret Access Key**.
5. Copy your **Account ID** from the R2 overview page.

**Step 2: set the secrets**

```bash
# Fly.io
fly secrets set \
  LITESTREAM_REPLICA_URL="s3://mobin-backup/mobin.db?endpoint=https://<account-id>.r2.cloudflarestorage.com" \
  LITESTREAM_ACCESS_KEY_ID="<your-access-key-id>" \
  LITESTREAM_SECRET_ACCESS_KEY="<your-secret-access-key>"

# Docker Compose: uncomment + fill the LITESTREAM_* vars in docker-compose.prod.yml
```

**Step 3: deploy** -- `entrypoint.sh` detects `LITESTREAM_REPLICA_URL` automatically. If the DB is absent it restores from R2; if present it begins replicating.

## Which deployment to pick?

| | Fly.io | VPS + Docker Compose |
|-|--------|---------------------|
| **Cost** | ~$2/month (IPv4 only) | ~4 EUR/month |
| **TLS** | Automatic (Fly handles it) | Automatic (Caddy handles it) |
| **Setup time** | ~15 min | ~20 min |
| **CD on push** | Built-in (GitHub Actions) | Manual `docker compose up` |
| **Persistent storage** | Fly volumes (1 GB free) | Server disk |
| **Litestream backup** | `fly secrets set` + auto-deploy | Uncomment env vars in compose |
| **SSH access** | `fly ssh console` | `ssh root@ip` |
| **Best for** | Getting something live quickly | Full control, cost predictability |
