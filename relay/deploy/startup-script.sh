#!/usr/bin/env bash
# GCE startup-script — runs as root on every boot. SSH-free deploy: pulls the
# relay binary from GCS (via the VM service-account token, no gsutil needed),
# installs it as a systemd service, and starts it. Idempotent — re-running on
# reboot just refreshes the binary.
set -euo pipefail

# Set these to your own GCS bucket + object before provisioning your VM.
BUCKET="${RELAY_BUCKET:-your-relay-bucket}"
BIN=claudeometer-relay-linux-amd64

mkdir -p /opt/claudeometer-relay /var/lib/claudeometer-relay

# Fetch the binary from GCS using the instance service-account access token.
TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
# Download to a temp file then atomically rename into place. A plain `curl -o`
# over the running binary fails with ETXTBSY (curl exit 23) on reboot, because
# systemd has already restarted the old binary; rename swaps the inode safely.
curl -sf -H "Authorization: Bearer ${TOKEN}" \
  -o /opt/claudeometer-relay/claudeometer-relay.new \
  "https://storage.googleapis.com/storage/v1/b/${BUCKET}/o/${BIN}?alt=media"
chmod +x /opt/claudeometer-relay/claudeometer-relay.new
mv -f /opt/claudeometer-relay/claudeometer-relay.new /opt/claudeometer-relay/claudeometer-relay

id claudeometer &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin claudeometer
chown -R claudeometer:claudeometer /opt/claudeometer-relay /var/lib/claudeometer-relay

cat > /etc/systemd/system/claudeometer-relay.service <<'UNIT'
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

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable claudeometer-relay
systemctl restart claudeometer-relay
