#!/usr/bin/env bash
# WoowTech Headscale VPN — Podman one-shot deployment
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HS_PORT=28080
HP_PORT=23000

# ---------------------------------------------------------------
echo "==> [1/7] Load .env (SERVER_URL)"
[ -f .env ] || cp .env.example .env
# shellcheck disable=SC1091
source .env
SERVER_URL="${SERVER_URL:-http://localhost:${HS_PORT}}"
echo "    SERVER_URL = ${SERVER_URL}"

# Patch server_url into headscale config
sed -i "s|^server_url:.*|server_url: ${SERVER_URL}|" config/headscale/config.yaml

# ---------------------------------------------------------------
echo "==> [2/7] Generate Headplane cookie secret (32 chars)"
if [ ! -f config/headplane/cookie-secret ]; then
  openssl rand -hex 16 | tr -d '\n' > config/headplane/cookie-secret
  echo "    created config/headplane/cookie-secret"
else
  echo "    already exists — keeping"
fi
# Placeholder api-key so the ro bind mount is complete on first start
[ -f config/headplane/api-key ] || printf 'placeholder' > config/headplane/api-key

# ---------------------------------------------------------------
echo "==> [3/7] Start Headscale"
podman-compose up -d headscale

echo "    waiting for /health ..."
for i in $(seq 1 24); do
  if curl -sf "http://localhost:${HS_PORT}/health" >/dev/null 2>&1; then break; fi
  sleep 5
done
curl -sf "http://localhost:${HS_PORT}/health" || { echo "FATAL: headscale not healthy"; podman logs --tail 20 headscale; exit 1; }
echo ""

# ---------------------------------------------------------------
echo "==> [4/7] Create default user (idempotent)"
podman exec headscale headscale users create default 2>/dev/null || echo "    user exists — ok"

# ---------------------------------------------------------------
echo "==> [5/7] Create Headplane API key"
API_KEY=$(podman exec headscale headscale apikeys create --expiration 90d | tail -1 | tr -d '[:space:]')
printf '%s' "$API_KEY" > config/headplane/api-key
echo "    api key written to config/headplane/api-key"

# ---------------------------------------------------------------
echo "==> [6/7] Start Headplane"
podman-compose up -d headplane
sleep 5
HP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HP_PORT}/admin" || true)
# 302 = redirect to login — healthy
if [ "$HP_CODE" != "302" ] && [ "$HP_CODE" != "200" ]; then
  # config was mounted before api-key existed → restart once
  podman restart headplane >/dev/null; sleep 5
  HP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${HP_PORT}/admin" || true)
fi
echo "    /admin -> HTTP ${HP_CODE}"

# ---------------------------------------------------------------
echo "==> [7/7] Create a reusable test PreAuthKey (72h)"
PREKEY=$(podman exec headscale headscale preauthkeys create --user 1 --reusable --expiration 72h | tail -1 | tr -d '[:space:]')

cat <<EOF

=============================================================
 ✅ Headscale + Headplane are up (rootless Podman)
=============================================================
 Headscale control plane : http://localhost:${HS_PORT}   (health: /health)
 Headplane admin UI      : http://localhost:${HP_PORT}/admin
 Headplane login API key : ${API_KEY}

 Connect a device:
   tailscale up --login-server=${SERVER_URL} --authkey=${PREKEY}

 Expose externally (ngrok example — verified to pass the
 Tailscale noise protocol, unlike Cloudflare Tunnel):
   ngrok http ${HS_PORT}
   # then set SERVER_URL in .env to the https URL and re-run ./deploy.sh
=============================================================
EOF
