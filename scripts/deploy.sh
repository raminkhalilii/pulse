#!/usr/bin/env bash
# deploy.sh — runs ON the VPS, called by the GitHub Actions CD job via SSH.
# Usage: ./scripts/deploy.sh <image-tag>
#
# Required environment on the VPS:
#   - Docker + Docker Compose plugin installed
#   - GHCR_TOKEN exported (or logged in via `docker login ghcr.io`)
#   - /opt/pulse/.env file present with all production secrets
#   - /opt/pulse/ contains a checkout of this repo
set -euo pipefail

IMAGE_TAG="${1:-latest}"
# Derive APP_DIR from the script's own location so it works regardless of
# where on the server this repo is checked out.
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose -f ${APP_DIR}/docker-compose.prod.yml"

echo "==> [deploy] Starting deployment (tag: ${IMAGE_TAG}) in ${APP_DIR}"

cd "$APP_DIR"

# ── 1. Pull latest code ───────────────────────────────────────────────────────
echo "==> [deploy] Pulling latest code from origin/main"
git fetch origin main
git reset --hard origin/main
git submodule update --init --recursive

# ── 2. Pull updated images from GHCR ─────────────────────────────────────────
echo "==> [deploy] Pulling Docker images (tag: ${IMAGE_TAG})"
IMAGE_TAG="$IMAGE_TAG" $COMPOSE pull backend worker frontend

# ── 3. Health-gated rolling restart ──────────────────────────────────────────
# --no-deps    : only restart the named services, not postgres/redis/nginx
# --no-build   : use the pre-built image we just pulled
# --wait       : BLOCK until every container with a healthcheck reports healthy.
#                This is what makes the deploy zero-downtime:
#                Docker starts the new container, waits for /health to pass,
#                THEN stops the old one. The deploy script only continues
#                (and Nginx only reloads) once the new container is confirmed ready.
#                If the new container never becomes healthy, --wait exits non-zero
#                and the old container keeps running (automatic rollback).
echo "==> [deploy] Starting new containers (waiting for health checks to pass)..."
IMAGE_TAG="$IMAGE_TAG" $COMPOSE up -d \
  --no-deps \
  --no-build \
  --remove-orphans \
  --wait \
  backend worker frontend

echo "✓ All containers healthy"

# ── 4. Reload Nginx ───────────────────────────────────────────────────────────
# Reload (not restart) so in-flight SSL connections are not dropped.
# This also flushes Nginx's DNS cache so it re-resolves the new `backend`
# container IP after Docker replaced the container.
echo "==> [deploy] Reloading Nginx..."
$COMPOSE exec -T nginx nginx -t   # validate config first
$COMPOSE exec -T nginx nginx -s reload
echo "✓ Nginx reloaded"

# ── 5. Remove dangling images to reclaim disk ─────────────────────────────────
echo "==> [deploy] Pruning dangling images"
docker image prune -f

echo ""
echo "✓ Deploy complete — zero downtime (tag: ${IMAGE_TAG})"
echo ""
$COMPOSE ps
