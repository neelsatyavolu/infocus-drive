#!/usr/bin/env bash
# Rebuild InFocus Drive containers on the NAS after a tar deploy.
# Usage: bash scripts/deploy-rebuild.sh [cache-bust-tag]
# Follows docs/DEPLOY.md §3. Reads connection details from the environment:
#   NAS_SSH_HOST     SSH hostname (e.g. ssh.example.com behind Cloudflare Access)
#   NAS_SSH_USER     NAS account with sudo
#   NAS_DEPLOY_PATH  compose project dir on the NAS (e.g. /volume1/docker/infocus-drive)
#   SSHPASS          that account's password (export it from your secret manager)
set -euo pipefail

TAG="${1:-}"
: "${NAS_SSH_HOST:?set NAS_SSH_HOST}" "${NAS_SSH_USER:?set NAS_SSH_USER}"
: "${NAS_DEPLOY_PATH:?set NAS_DEPLOY_PATH}" "${SSHPASS:?export SSHPASS}"
export SSHPASS
test "${#SSHPASS}" -ge 8 || { echo "SSHPASS looks wrong"; exit 1; }
B64="$(printf '%s' "$SSHPASS" | base64 | tr -d '\n')"

SSH_OPTS=(-o PubkeyAuthentication=no -o PreferredAuthentications=password
          -o "ProxyCommand=cloudflared access ssh --hostname %h"
          -o ConnectTimeout=60 -o ServerAliveInterval=15
          -o ServerAliveCountMax=20 -o NumberOfPasswordPrompts=1)

run_rebuild() {
  sshpass -e ssh "${SSH_OPTS[@]}" "$NAS_SSH_USER@$NAS_SSH_HOST" "bash -s" <<REMOTE
set -euo pipefail
echo "host=\$(hostname)"
if [ -n "$TAG" ]; then grep -o 'v=$TAG' $NAS_DEPLOY_PATH/app/static/index.html | head -3; fi
test -f $NAS_DEPLOY_PATH/.env && echo env_present || { echo MISSING_ENV; exit 9; }
echo '$B64' | base64 -d | sudo -S docker compose -f $NAS_DEPLOY_PATH/docker-compose.yml up -d --build 2>&1 | tail -5
echo '$B64' | base64 -d | sudo -S docker exec infocus-drive sh -c \
  'ls /app/thumbs.py /app/static/quick.js; which ffmpeg; python -c "import PIL; print(\"PIL\", PIL.__version__)"'
echo REMOTE_OK
REMOTE
}

for i in 1 2 3 4 5 6 7 8; do
  echo "=== attempt $i ==="
  if run_rebuild; then echo SUCCESS; exit 0; fi
  sleep $((i * 10))
done
echo "rebuild failed after retries" >&2
exit 1
