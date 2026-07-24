#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { echo "[lisa-edge bootstrap] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

log "Starting bootstrap..."
log "Ensuring script permissions..."

chmod +x "$REPO_DIR"/install/bootstrap/*.sh
chmod +x "$REPO_DIR"/install/bootstrap/phases/*.sh
chmod +x "$REPO_DIR"/install/provisioning/*.sh
chmod +x "$REPO_DIR"/lisa-edge
chmod +x "$REPO_DIR"/ops/deploy/*.sh
chmod +x "$REPO_DIR"/ops/backup-restore/*.sh
chmod +x "$REPO_DIR"/ops/diagnostics/*.sh
chmod +x "$REPO_DIR"/services/*.sh
find "$REPO_DIR/services" -type f -name '*.sh' -exec chmod +x {} +
chmod +x "$REPO_DIR"/tools/*.sh
chmod +x "$REPO_DIR"/rescue/scripts/*.sh

cd "$REPO_DIR"

log "Loading environment"
if [ ! -f ".env" ]; then
  cp "$REPO_DIR/.env.template" ".env"

  MQTT_PASSWORD_GENERATED="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  if [ "${#MQTT_PASSWORD_GENERATED}" -ne 48 ]; then
    echo "Could not generate the initial MQTT password." >&2
    exit 1
  fi
  sed -i "s/^MQTT_PASSWORD=.*/MQTT_PASSWORD=$MQTT_PASSWORD_GENERATED/" ".env"
  unset MQTT_PASSWORD_GENERATED
fi
chmod 0600 ".env"
if [ -f ".env" ]; then
  set -a
  source ".env"
  set +a
fi

log "Running bootstrap modules"
for script in "$REPO_DIR"/install/bootstrap/phases/*.sh
do
  [ -f "$script" ] || continue
  log "================================="
  log "Executing $(basename "$script")"
  log "================================="
  bash "$script"
done

# Install runtime and backup units BEFORE deploying: deploy.sh ends with the
# health check, which reports DEGRADED backup-timer coverage when the timers
# are enabled only afterwards. Timers are calendar-based (03:15/03:30), so
# being active during the deploy is the same condition as every routine
# `lisa-edge update` run.
log "Installing systemd runtime and backup units"
"$REPO_DIR/ops/deploy/install-systemd.sh"

log "Deploying services"
"$REPO_DIR/lisa-edge" deploy
bash "$REPO_DIR/install/bootstrap/finalize-admin-access.sh"

log "Marking host as provisioned"
install -d -m 0755 /var/lib/lisa-edge
touch /var/lib/lisa-edge/provisioned
rm -f /etc/update-motd.d/99-lisa-edge-provision
systemctl disable lisa-first-boot.service >/dev/null 2>&1 || true

log "Bootstrap completed successfully"
