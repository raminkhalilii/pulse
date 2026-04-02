# Pulse — Uptime Monitoring

Pulse is a self-hosted uptime monitoring platform. It periodically checks your websites and endpoints, records response latency and availability, and delivers real-time status updates to your dashboard over WebSockets.

---

## Features

- **Configurable check intervals** — 1 min, 5 min, or 30 min per monitor
- **Real-time dashboard** — live UP/DOWN status pushed via Socket.IO
- **Historical data** — per-heartbeat logs and hourly uptime summaries
- **Secure by default** — DNS validation blocks monitoring of private/internal IPs
- **JWT authentication** — access + refresh token flow
- **Fully containerized** — one `docker compose up` for dev, one pull-and-run for prod

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Next.js 16, React 19, Tailwind CSS 4 |
| Backend | NestJS 11, TypeScript |
| Worker | NestJS + BullMQ (separate process) |
| Database | PostgreSQL 17 (Prisma ORM) |
| Cache / Queue | Redis 7 (ioredis + BullMQ) |
| Real-time | Socket.IO 4 over WebSockets |
| Gateway | Nginx (SSL, rate limiting, reverse proxy) |
| Registry | GitHub Container Registry (GHCR) |
| CI/CD | GitHub Actions |

---

## Repository Structure

```
pulse/
├── backend-pulse/          # NestJS API + BullMQ worker
├── frontend-pulse/         # Next.js dashboard
├── nginx/
│   └── nginx.conf          # Reverse proxy, SSL, rate limiting
├── scripts/
│   └── deploy.sh           # Server-side deploy script (called by CI)
├── docker-compose.yml      # Local development stack
├── docker-compose.prod.yml # Production stack (pull-only, no build)
└── .github/workflows/
    └── ci.yml              # Lint → Test → Build → Deploy pipeline
```

---

## Local Development

```bash
git clone --recurse-submodules https://github.com/raminkhalilii/pulse.git
cd pulse
docker compose up
```

| Service | URL |
|---|---|
| Frontend | http://localhost:3001 |
| Backend API | http://localhost:3000/api |
| Swagger docs | http://localhost:3000/docs |

---

## Production Deployment Guide

### Architecture Overview

```
Internet
   │
   ▼
Nginx :443 (SSL termination, rate limiting)
   ├── /api/*       → backend:3000  (NestJS REST API)
   ├── /socket.io/* → backend:3000  (WebSocket upgrade)
   └── /*           → frontend:3000 (Next.js)

Internal Docker network (pulse_net) only:
   backend / worker → postgres:5432
   backend / worker → redis:6379
```

All internal services (Postgres, Redis) have **no public port bindings**. Nginx is the sole public ingress.

---

### Environment Variables

Create `/opt/pulse/.env` on the server before first deploy. Docker Compose reads this file automatically.

```dotenv
# Database
POSTGRES_USER=pulse_user
POSTGRES_PASSWORD=change_me_strong_password
POSTGRES_DB=pulse

# Redis (password required — used by backend, worker, and redis-server itself)
REDIS_PASSWORD=change_me_redis_password

# JWT secrets — generate with: openssl rand -hex 64
ACCESS_TOKEN_SECRET=
JWT_REFRESH_SECRET=

# Deployment
GITHUB_REPOSITORY=raminkhalilii/pulse
DOMAIN=pulsee.website
IMAGE_TAG=latest
```

> `DATABASE_URL` is intentionally absent — `docker-compose.prod.yml` assembles it from the individual Postgres variables at runtime.

---

### CI/CD Pipeline (Standard Flow)

Every push to `main` runs the full pipeline:

```
push to main
    │
    ├── 1. Lint       (ESLint, max 50 warnings)
    ├── 2. Test       (Jest unit tests)
    ├── 3. Build      (Docker images → ghcr.io)
    └── 4. Deploy     (SSH → /opt/pulse/scripts/deploy.sh <sha>)
```

The deploy script on the server pulls the new images and runs `docker compose up -d`.

**Required GitHub Secrets:**

| Secret | Description |
|---|---|
| `VPS_HOST` | Server IP or hostname |
| `VPS_USER` | SSH user (e.g. `ec2-user`) |
| `VPS_SSH_KEY` | PEM-encoded private key |
| `DOMAIN` | Your domain (e.g. `pulsee.website`) |

---

### Manual Deploy / Custom Image Tag

Use this workflow to test a fix without waiting for CI — build locally, push to GHCR, pull on the server.

**1. Build and push from your local machine:**

```bash
docker build -t ghcr.io/raminkhalilii/pulse/backend:test ./backend-pulse
docker push ghcr.io/raminkhalilii/pulse/backend:test
```

**2. Pull and deploy on the production server:**

> Do not skip the `pull` step. Running `up` without pulling will use the cached image.

```bash
# Pull the specific tag
IMAGE_TAG=test docker compose -f docker-compose.prod.yml pull backend worker

# Recreate containers with the new image
IMAGE_TAG=test docker compose -f docker-compose.prod.yml up -d backend worker
```

---

### Useful Server Commands

Run these from `/opt/pulse` (or wherever `docker-compose.prod.yml` lives).

**Check stack status:**
```bash
docker compose -f docker-compose.prod.yml ps
```

**Follow logs in real time:**
```bash
docker compose -f docker-compose.prod.yml logs backend --tail=50 -f
docker compose -f docker-compose.prod.yml logs worker  --tail=50 -f
docker compose -f docker-compose.prod.yml logs nginx   --tail=50 -f
```

**Restart a single service** (e.g. after editing `nginx.conf`):
```bash
docker compose -f docker-compose.prod.yml restart nginx
```

**Force-recreate a container** (picks up config file changes that `restart` won't):
```bash
docker compose -f docker-compose.prod.yml up -d --force-recreate nginx
```

**Prune dangling images** (free up disk after deploys):
```bash
docker image prune -f
```

---

### SSL / TLS

Certificates are issued by Let's Encrypt and mounted read-only into the Nginx container:

```yaml
volumes:
  - /etc/letsencrypt:/etc/letsencrypt:ro
  - /var/www/certbot:/var/www/certbot:ro
```

Renew with Certbot on the host:
```bash
sudo certbot renew --webroot -w /var/www/certbot
docker compose -f docker-compose.prod.yml restart nginx
```

---

## API Reference

Swagger UI is available at `/docs` when the backend is running.

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/auth` | Register a new user |
| `POST` | `/api/auth/login` | Login, returns access + refresh tokens |
| `GET` | `/api/monitors` | List all monitors for the authenticated user |
| `POST` | `/api/monitors` | Create a new monitor |
| `DELETE` | `/api/monitors/:id` | Delete a monitor |

WebSocket namespace: `/socket.io` — emits `heartbeat` events with live check results.

---

## License

MIT
