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

# nginx/nginx.conf is bind-mounted into the container as a single FILE, which
# Docker pins by inode. `git reset --hard` below replaces the file (new inode),
# so the running container keeps the OLD file until it is recreated — a plain
# `nginx -s reload` would reload stale config. Hash it before/after the reset
# so step 4 can detect a change and force-recreate only when needed.
NGINX_HASH_BEFORE=$(sha256sum nginx/nginx.conf 2>/dev/null | awk '{print $1}' || echo none)

# ── 1. Pull latest code ───────────────────────────────────────────────────────
echo "==> [deploy] Pulling latest code from origin/main"
git fetch origin main
git reset --hard origin/main
git submodule update --init --recursive

NGINX_HASH_AFTER=$(sha256sum nginx/nginx.conf 2>/dev/null | awk '{print $1}' || echo none)

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

# docker-compose.prod.yml resolves images as `${IMAGE_TAG:-latest}`. Without this,
# any bare `docker compose ...` run later (e.g. manually on the VPS) without
# IMAGE_TAG set in the shell falls back to `:latest`, which on the registry is
# OLDER than what we just deployed — silently downgrading the app. Persist the
# tag into the .env file that Compose auto-reads for interpolation so it stays
# pinned even for commands run outside this script.
ENV_FILE="${APP_DIR}/.env"
if grep -q '^IMAGE_TAG=' "$ENV_FILE" 2>/dev/null; then
  sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" "$ENV_FILE"
else
  printf '\nIMAGE_TAG=%s\n' "${IMAGE_TAG}" >> "$ENV_FILE"
fi
echo "✓ Pinned IMAGE_TAG=${IMAGE_TAG} in ${ENV_FILE}"

# ── 4. Reload Nginx ───────────────────────────────────────────────────────────
if [ "$NGINX_HASH_BEFORE" != "$NGINX_HASH_AFTER" ]; then
  # Config changed this deploy — the running container still has the OLD file
  # pinned by inode, so a reload alone would reload stale config. Validate the
  # NEW file in a throwaway container first (so a bad config can't take nginx
  # down), then force-recreate to pick up the new inode.
  echo "==> [deploy] nginx.conf changed — validating and recreating Nginx container..."
  docker run --rm \
    -v "${APP_DIR}/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v /etc/letsencrypt:/etc/letsencrypt:ro \
    nginx:1.27-alpine nginx -t
  IMAGE_TAG="$IMAGE_TAG" $COMPOSE up -d --force-recreate --no-deps nginx
  echo "✓ Nginx recreated with new config"
else
  # Config unchanged — reload (not restart) so in-flight SSL connections are
  # not dropped. This also flushes Nginx's DNS cache so it re-resolves the new
  # `backend` container IP after Docker replaced the container above.
  echo "==> [deploy] Reloading Nginx..."
  $COMPOSE exec -T nginx nginx -t   # validate config first
  $COMPOSE exec -T nginx nginx -s reload
  echo "✓ Nginx reloaded"
fi

# ── 5. Remove dangling images to reclaim disk ─────────────────────────────────
echo "==> [deploy] Pruning dangling images"
docker image prune -f

echo ""
echo "✓ Deploy complete — zero downtime (tag: ${IMAGE_TAG})"
echo ""
$COMPOSE ps
