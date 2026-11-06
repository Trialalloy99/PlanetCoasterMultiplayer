#!/usr/bin/env bash
# Deployt den PC2MP-Server auf den VPS (systemd-Dienst "pc2mp", Port 7790/tcp).
# Usage: server/deploy/deploy.sh [user@host] [ssh-key]
set -euo pipefail
HOST="${1:-root@147.79.101.210}"
KEY="${2:-$HOME/.ssh/pc2mp_vps}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH=(ssh -i "$KEY" -o BatchMode=yes "$HOST")

"${SSH[@]}" 'id pc2mp >/dev/null 2>&1 || useradd --system --home /opt/pc2mp --shell /usr/sbin/nologin pc2mp; mkdir -p /opt/pc2mp/data; chown -R pc2mp:pc2mp /opt/pc2mp'
scp -i "$KEY" -o BatchMode=yes "$DIR/pc2mp_server.py" "$HOST:/opt/pc2mp/pc2mp_server.py"
scp -i "$KEY" -o BatchMode=yes "$DIR/deploy/pc2mp.service" "$HOST:/etc/systemd/system/pc2mp.service"
"${SSH[@]}" 'chown pc2mp:pc2mp /opt/pc2mp/pc2mp_server.py; systemctl daemon-reload; systemctl enable --now pc2mp; systemctl restart pc2mp; ufw status | grep -q "^7790/tcp" || ufw allow 7790/tcp comment "PC2MP Multiplayer"; sleep 1; systemctl --no-pager --lines=5 status pc2mp'
