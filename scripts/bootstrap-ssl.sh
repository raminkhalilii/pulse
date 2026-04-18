#!/usr/bin/env bash
# bootstrap-ssl.sh — ONE-TIME script to provision the SSL certificate for
# analytics.pulsee.website before the first full deploy.
#
# PROBLEM: nginx.conf has a server block for analytics.pulsee.website that
# references /etc/letsencrypt/live/analytics.pulsee.website/fullchain.pem.
# If this cert doesn't exist, nginx refuses to start — chicken-and-egg.
#
# SOLUTION this script performs:
#   1. Temporarily swap in a minimal nginx.conf (HTTP only, no analytics HTTPS block)
#   2. Reload nginx — succeeds because no missing cert is referenced
#   3. Run certbot using the webroot already served by nginx
#   4. Restore the real nginx.conf (cert now exists, so it loads fine)
#   5. Reload nginx — now serving analytics.pulsee.website over HTTPS
#
# Usage:
#   CERTBOT_EMAIL=admin@pulsee.website bash scripts/bootstrap-ssl.sh
#
# Run this ONCE on the server, then push your changes to main.
# It is idempotent — safe to re-run if anything fails midway.

set -euo pipefail

CERTBOT_EMAIL="${CERTBOT_EMAIL:?ERROR: Set CERTBOT_EMAIL before running. e.g. CERTBOT_EMAIL=you@example.com bash $0}"

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose -f ${APP_DIR}/docker-compose.prod.yml"
REAL_CONF="${APP_DIR}/nginx/nginx.conf"
TEMP_CONF="/tmp/nginx-bootstrap-$$.conf"
CERT_PATH="/etc/letsencrypt/live/analytics.pulsee.website/fullchain.pem"

# ── Idempotency check ─────────────────────────────────────────────────────────
if [ -f "$CERT_PATH" ]; then
  echo "✓ Certificate already exists at $CERT_PATH — nothing to do."
  exit 0
fi

echo "==> [bootstrap] Starting SSL bootstrap for analytics.pulsee.website"
echo "==> [bootstrap] App dir: $APP_DIR"

# ── Step 1: Write minimal temporary nginx.conf ────────────────────────────────
# This config has analytics.pulsee.website in the HTTP server_name so nginx
# will serve the certbot webroot challenge — but has NO HTTPS analytics block
# so no missing cert causes nginx to fail.
echo "==> [bootstrap] Writing temporary nginx.conf to $TEMP_CONF ..."
cat > "$TEMP_CONF" << 'NGINXEOF'
worker_processes auto;
events { worker_connections 1024; }
http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    upstream backend  { server backend:3000;  keepalive 32; }
    upstream frontend { server frontend:3000; keepalive 32; }

    # HTTP — serves certbot challenge for ALL domains, then redirects
    server {
        listen 80;
        server_name pulsee.website www.pulsee.website analytics.pulsee.website;

        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }
        location / {
            return 301 https://pulsee.website$request_uri;
        }
    }

    # HTTPS — only pulsee.website (analytics HTTPS block intentionally absent)
    server {
        listen 443 ssl;
        http2  on;
        server_name pulsee.website www.pulsee.website;

        ssl_certificate     /etc/letsencrypt/live/pulsee.website/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/pulsee.website/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;

        location /api      { proxy_pass http://backend;  proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header Connection ""; }
        location /health   { proxy_pass http://backend;  proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header Connection ""; access_log off; }
        location /socket.io {
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
        location /         { proxy_pass http://frontend; proxy_http_version 1.1; proxy_set_header Host $host; proxy_set_header Connection ""; }
    }
}
NGINXEOF

# ── Step 2: Swap real conf for temp, reload nginx ─────────────────────────────
echo "==> [bootstrap] Replacing nginx.conf with bootstrap version..."
cp "$REAL_CONF" "${REAL_CONF}.bak"
cp "$TEMP_CONF" "$REAL_CONF"

echo "==> [bootstrap] Reloading nginx with bootstrap config..."
$COMPOSE exec -T nginx nginx -t
$COMPOSE exec -T nginx nginx -s reload
echo "✓ Nginx reloaded (HTTP challenge for analytics is now active)"

# ── Step 3: Get the certificate ───────────────────────────────────────────────
echo "==> [bootstrap] Requesting certificate for analytics.pulsee.website..."

if command -v certbot &>/dev/null; then
  # certbot installed on the host
  certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    -d analytics.pulsee.website \
    --non-interactive \
    --agree-tos \
    -m "$CERTBOT_EMAIL"
else
  # Run certbot via Docker (volumes match what's mounted in nginx)
  docker run --rm \
    -v /etc/letsencrypt:/etc/letsencrypt \
    -v /var/www/certbot:/var/www/certbot \
    certbot/certbot certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    -d analytics.pulsee.website \
    --non-interactive \
    --agree-tos \
    -m "$CERTBOT_EMAIL"
fi

echo "✓ Certificate obtained: $CERT_PATH"

# ── Step 4: Restore real nginx.conf, reload with HTTPS analytics ──────────────
echo "==> [bootstrap] Restoring full nginx.conf (with HTTPS analytics block)..."
cp "${REAL_CONF}.bak" "$REAL_CONF"
rm -f "${REAL_CONF}.bak" "$TEMP_CONF"

echo "==> [bootstrap] Reloading nginx with full config..."
$COMPOSE exec -T nginx nginx -t
$COMPOSE exec -T nginx nginx -s reload
echo "✓ Nginx reloaded — analytics.pulsee.website is now live over HTTPS"

# ── Step 5: Verify ────────────────────────────────────────────────────────────
echo ""
echo "==> [bootstrap] Verifying..."
sleep 2
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://analytics.pulsee.website/ || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo "✓ https://analytics.pulsee.website/ → HTTP $HTTP_CODE"
else
  echo "⚠ https://analytics.pulsee.website/ → HTTP $HTTP_CODE (Matomo container may still be starting)"
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo " Bootstrap complete!"
echo ""
echo " Next steps:"
echo "   1. Push your code to main → CI deploys everything"
echo "   2. Open https://analytics.pulsee.website in your browser"
echo "   3. Complete the Matomo web installer"
echo "      - DB host:     matomo-db"
echo "      - DB name:     matomo  (or \$MATOMO_DB_NAME)"
echo "      - DB user:     matomo  (or \$MATOMO_DB_USER)"
echo "      - DB password: \$MATOMO_DB_PASSWORD (from your .env)"
echo ""
echo " Optional: Set up archiving cron job on the server:"
echo "   echo '5 * * * * root docker compose -f ${APP_DIR}/docker-compose.prod.yml exec -T matomo php /var/www/html/console core:archive --url=https://analytics.pulsee.website > /dev/null 2>&1' | sudo tee /etc/cron.d/matomo-archive"
echo "══════════════════════════════════════════════════════════"
