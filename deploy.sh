#!/usr/bin/env bash
# Re-deploy the Weeber backend to the production VPS.
# Usage: ./deploy.sh
#
# Requires sshpass + the VPS password in $WEEBER_VPS_PASSWORD env var.
# Pushes server/ to /opt/weeber/server/, runs npm install, restarts the service.
# Never overwrites the production .env (and .env never makes it into rsync).

set -euo pipefail

VPS_HOST=root@45.196.196.154

if [ -z "${WEEBER_VPS_PASSWORD:-}" ]; then
  echo "Set WEEBER_VPS_PASSWORD before running this script."
  exit 1
fi

cd "$(dirname "$0")"

echo "Pushing server/ to $VPS_HOST:/opt/weeber/server/"
SSHPASS="$WEEBER_VPS_PASSWORD" sshpass -e rsync -az --delete \
  --exclude node_modules \
  --exclude data \
  --exclude '.env' \
  --exclude '*.log' \
  -e "ssh -o StrictHostKeyChecking=accept-new" \
  ./server/ "$VPS_HOST:/opt/weeber/server/"

echo "Running remote install + restart"
SSHPASS="$WEEBER_VPS_PASSWORD" sshpass -e ssh "$VPS_HOST" 'bash -s' <<'REMOTE'
set -e
cd /opt/weeber/server
/opt/node22/bin/npm install --omit=dev --silent 2>&1 | tail -3
systemctl restart weeber-api
sleep 1
systemctl is-active weeber-api
curl -s http://localhost:3030/healthz
echo ""
REMOTE

echo "Done."
