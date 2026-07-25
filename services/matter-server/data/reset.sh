#!/usr/bin/env bash
set -euo pipefail

# Reset the Matter fabric (operator entry point: lisa-edge matter reset).
# Removes the Matter fabric credentials and all commissioned-device state:
# EVERY Matter device must be re-commissioned afterwards. The current data
# is backed up first when readable. Never part of normal deploy or update;
# this is an explicit, confirmed development/recovery action.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF2'
Usage: lisa-edge matter reset

Back up and then WIPE the Matter fabric data. A fresh, empty fabric is
created when the server starts again; every Matter device (and every stored
Thread credential entry) is gone and test devices must be re-commissioned.
Requires typing RESET to confirm.

Options:
  -h, --help  Show this help.
EOF2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f .env ]; then
  echo "ERROR: missing .env; run 'sudo ./lisa-edge setup' first." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a

DATA_ROOT="${DATA_ROOT:-/srv/lisa-edge}"
MATTER_DATA_DIR="$DATA_ROOT/docker/volumes/matter-server"
BACKUP_DIR="${MATTER_DATA_BACKUP_DIR:-$DATA_ROOT/backups/matter}"

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/matter-server/data/lib.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/matter-server/lib/ws.sh"
lisa_validate_persistent_path MATTER_DATA_DIR "$MATTER_DATA_DIR"
lisa_validate_persistent_path MATTER_DATA_BACKUP_DIR "$BACKUP_DIR"

echo "This wipes the Matter fabric data under $MATTER_DATA_DIR."
echo "A fresh fabric is created on the next start and EVERY Matter device"
echo "must be re-commissioned. Stored Thread credential entries are removed"
echo "as part of the wipe. The current data is backed up first when readable."
read -r -p "Type RESET to continue: " answer
if [ "$answer" != "RESET" ]; then
  echo "Aborted. No changes were made."
  exit 1
fi

WAS_RUNNING=0
if matter_ws_container_running; then
  WAS_RUNNING=1
fi
restart_matter() {
  if [ "${WAS_RUNNING:-0}" -eq 1 ]; then
    docker start lisa-matter >/dev/null 2>&1 || \
      echo "WARNING: Could not restart lisa-matter; start it with: docker start lisa-matter" >&2
  fi
}
if [ "$WAS_RUNNING" -eq 1 ]; then
  echo "Stopping lisa-matter..."
  trap restart_matter EXIT
  docker stop lisa-matter >/dev/null
fi

if matter_data_dir_has_state "$MATTER_DATA_DIR"; then
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  SAFETY_OUT="$BACKUP_DIR/matter-data-$(date -u +%Y%m%dT%H%M%SZ)-pre-reset.tar.gz"
  tar -C "$MATTER_DATA_DIR" -czf "$SAFETY_OUT" .
  chmod 0600 "$SAFETY_OUT"
  matter_data_write_archive_sidecars "$SAFETY_OUT" pre-reset
  echo "Current fabric data preserved as: $SAFETY_OUT"
fi

# Recreate the expected empty store with safe ownership and permissions.
mkdir -p "$MATTER_DATA_DIR"
find "$MATTER_DATA_DIR" -mindepth 1 -delete
chmod 0750 "$MATTER_DATA_DIR"
# Self-heal ownership so the fresh fabric can be written by the server user
# even when the store was created by an older (root-owned) deployment.
matter_data_set_store_ownership "$MATTER_DATA_DIR"
# Drop the latest pointer, or auto-restore would resurrect the old fabric
# into the emptied store on the next deploy. The archives themselves stay.
rm -f -- "$BACKUP_DIR/latest.matter-data.tar.gz"

if [ "$WAS_RUNNING" -eq 1 ]; then
  echo "Restarting lisa-matter..."
  restart_matter
  WAS_RUNNING=0
  trap - EXIT

  echo "Verifying that the server starts with an empty fabric..."
  VERIFIED=0
  for _ in $(seq 1 30); do
    RC=0
    WS_OUTPUT="$(MATTER_WS_CONNECT_TIMEOUT_MS=4000 MATTER_WS_RESPONSE_TIMEOUT_MS=6000 \
      matter_ws_run status 2>/dev/null)" || RC=$?
    if [ "$RC" -eq 0 ]; then
      NODE_COUNT="$(matter_ws_field "$WS_OUTPUT" node_count)"
      CRED_COUNT="$(matter_ws_field "$WS_OUTPUT" thread_credential_count)"
      echo "Server is up: commissioned nodes=${NODE_COUNT:-0}, stored Thread credentials=${CRED_COUNT:-0}."
      if [ "${NODE_COUNT:-0}" = "0" ] && [ "${CRED_COUNT:-0}" = "0" ]; then
        VERIFIED=1
      fi
      break
    fi
    sleep 2
  done
  if [ "$VERIFIED" -ne 1 ]; then
    echo "WARNING: could not verify an empty fabric over the WebSocket API." >&2
    echo "Inspect next: sudo ./lisa-edge matter status; docker logs --tail 30 lisa-matter" >&2
  fi
else
  echo "lisa-matter was not running; a fresh fabric is created on the next deploy."
fi

echo
echo "Matter fabric data reset. Re-commission your Matter devices, then store"
echo "the Thread credentials again with: sudo ./lisa-edge matter thread sync"
echo "To roll back instead, restore the pre-reset archive:"
echo "  services/matter-server/data/restore.sh $BACKUP_DIR/<pre-reset archive>"
