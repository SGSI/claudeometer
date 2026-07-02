#!/usr/bin/env bash
# Runs ON the relay VM. Installs the freshly-scp'd binary as a systemd service.
# Expects ~/claudeometer-relay-linux-amd64 to exist (scp'd before running this).
set -euo pipefail

sudo useradd --system --no-create-home --shell /usr/sbin/nologin claudeometer 2>/dev/null || true
sudo mkdir -p /opt/claudeometer-relay /var/lib/claudeometer-relay
sudo mv ~/claudeometer-relay-linux-amd64 /opt/claudeometer-relay/claudeometer-relay
sudo chmod +x /opt/claudeometer-relay/claudeometer-relay
sudo chown -R claudeometer:claudeometer /opt/claudeometer-relay /var/lib/claudeometer-relay

sudo tee /etc/systemd/system/claudeometer-relay.service > /dev/null <<'UNIT'
[Unit]
Description=Claudeometer Teams relay
After=network.target

[Service]
Environment=PORT=8080
Environment=DB_PATH=/var/lib/claudeometer-relay/relay.db
WorkingDirectory=/var/lib/claudeometer-relay
ExecStart=/opt/claudeometer-relay/claudeometer-relay
Restart=always
RestartSec=2
User=claudeometer
Group=claudeometer
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/claudeometer-relay

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now claudeometer-relay
sleep 1
echo "=== active state ==="
sudo systemctl is-active claudeometer-relay
echo "=== local health ==="
curl -s localhost:8080/health
echo
