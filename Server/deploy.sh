#!/bin/bash
# Deploy the server to ubuntu@204.216.106.35:/opt/spotube and wire it into nginx (idempotent).
set -euo pipefail
HOST=${HOST:-ubuntu@204.216.106.35}
cd "$(dirname "$0")"
rsync -az --delete --exclude data --exclude .env --exclude __pycache__ ./ "$HOST:/tmp/spotube-src/"
ssh "$HOST" bash -s <<'REMOTE'
set -euo pipefail
sudo mkdir -p /opt/spotube && sudo chown ubuntu:ubuntu /opt/spotube
rsync -a --delete --exclude data --exclude .env /tmp/spotube-src/ /opt/spotube/
cd /opt/spotube
[ -f .env ] || { echo "SPOTUBE_TOKEN=$(openssl rand -hex 24)" > .env; chmod 600 .env; }
mkdir -p data/cache data/altstore && chmod 755 data data/cache data/altstore
docker compose up -d --build
docker image prune -f --filter label=app=spotube >/dev/null
sudo cp nginx-spotube.conf /etc/nginx/snippets/spotube.conf
V=/etc/nginx/sites-enabled/qerope.me
if ! grep -q "snippets/spotube.conf" "$V"; then
  sudo cp "$V" /etc/nginx/qerope.me.bak-spotube
  sudo sed -i '0,/location \/ { try_files/s//include snippets\/spotube.conf;\n    location \/ { try_files/' "$V"
fi
sudo nginx -t && sudo systemctl reload nginx
for i in $(seq 30); do curl -fs http://127.0.0.1:8770/health && break; sleep 1; done; echo
REMOTE
