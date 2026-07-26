#!/usr/bin/env bash
set -euo pipefail

# Runs from deploy BEFORE `docker compose up`, while the Matter fabric store
# is plain files on disk. Applies one-shot wizard selections, protects the
# store before a container image change (matterjs-server migrates
# python-matter-server storage in place, one-way), and restores the latest
# backup into an empty store. A container this script stops stays stopped:
# the compose up that follows starts it again.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$EDGE_REPO"

set -a
source ./.env
set +a

DATA_ROOT="${DATA_ROOT:-/srv/lisa-edge}"
MATTER_DATA_DIR="$DATA_ROOT/docker/volumes/matter-server"
BACKUP_DIR="${MATTER_DATA_BACKUP_DIR:-$DATA_ROOT/backups/matter}"
LATEST="${MATTER_DATA_LATEST:-$BACKUP_DIR/latest.matter-data.tar.gz}"

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/matter-server/data/lib.sh"
lisa_validate_persistent_path MATTER_DATA_DIR "$MATTER_DATA_DIR"
lisa_validate_persistent_path MATTER_DATA_BACKUP_DIR "$BACKUP_DIR"
PENDING_DATA="$BACKUP_DIR/$MATTER_PENDING_DATA_FILE_NAME"
PENDING_RESET="$BACKUP_DIR/$MATTER_PENDING_RESET_FILE_NAME"

mkdir -p "$MATTER_DATA_DIR"
matter_data_set_store_ownership "$MATTER_DATA_DIR"

matter_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  grep -qx lisa-matter <<<"$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
}

stop_matter_if_running() {
  if matter_container_running; then
    echo "Stopping lisa-matter (deploy starts it again)..."
    docker stop lisa-matter >/dev/null
  fi
}

# Consistent snapshot of the current store into BACKUP_DIR. The caller must
# have stopped the container first. Updates the latest symlink.
snapshot_data() {
  local suffix="$1"
  local out
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  out="$BACKUP_DIR/matter-data-$(date -u +%Y%m%dT%H%M%SZ)-$suffix.tar.gz"
  tar -C "$MATTER_DATA_DIR" -czf "$out" .
  chmod 0600 "$out"
  matter_data_write_archive_sidecars "$out" "$suffix"
  ln -sfn "$(basename "$out")" "$BACKUP_DIR/latest.matter-data.tar.gz"
  echo "Matter fabric data backed up to: $out"
}

wipe_data() {
  find "$MATTER_DATA_DIR" -mindepth 1 -delete
}

extract_archive() {
  local archive_file="$1"
  if ! matter_data_archive_is_valid "$archive_file"; then
    echo "ERROR: Matter data archive is not a readable tar.gz with safe relative members: $archive_file" >&2
    exit 1
  fi
  if ! matter_data_archive_checksum_ok "$archive_file"; then
    echo "ERROR: Refusing to restore an archive that fails its checksum." >&2
    exit 1
  fi
  tar -C "$MATTER_DATA_DIR" -xzf "$archive_file"
  # Extraction as root preserves archive ownership (pre-switch archives carry
  # root-owned files); hand the store back to the server user afterwards.
  matter_data_set_store_ownership "$MATTER_DATA_DIR"
}

# One-shot change staged by the provisioning wizard. Applied exactly once:
# the marker is removed only after the change fully succeeds, so an
# interrupted deploy safely retries.
if [ -f "$PENDING_DATA" ] || [ -f "$PENDING_RESET" ]; then
  stop_matter_if_running
  if matter_data_dir_has_state "$MATTER_DATA_DIR"; then
    echo "Provisioning staged a Matter data change. Backing up the current fabric data first."
    snapshot_data pre-staged-change
  fi
  if [ -f "$PENDING_DATA" ]; then
    echo "Applying the Matter data backup selected during provisioning."
    wipe_data
    extract_archive "$PENDING_DATA"
  else
    echo "Resetting the Matter fabric as selected during provisioning."
    wipe_data
    # Drop the latest pointer, or auto-restore would resurrect the old fabric
    # into the emptied store on the next deploy. The archives themselves stay.
    rm -f -- "$BACKUP_DIR/latest.matter-data.tar.gz"
    echo "A new fabric is created when the server starts; re-commission Matter devices."
  fi
  rm -f -- "$PENDING_DATA" "$PENDING_RESET"
  exit 0
fi

if matter_data_dir_has_state "$MATTER_DATA_DIR"; then
  # Protect the store before the container image changes underneath it. The
  # python-matter-server -> matterjs-server storage migration is one-way, so
  # this snapshot is the only way back to the pre-migration format.
  CONFIGURED_IMAGE="${MATTER_SERVER_IMAGE:-ghcr.io/matter-js/matterjs-server:1.3.0}"
  RUNNING_IMAGE=""
  if command -v docker >/dev/null 2>&1; then
    RUNNING_IMAGE="$(docker inspect -f '{{.Config.Image}}' lisa-matter 2>/dev/null || true)"
  fi
  if [ -z "$RUNNING_IMAGE" ]; then
    echo "Matter data present without a lisa-matter container. Backing it up before deploy."
    snapshot_data pre-deploy
  elif [ "$RUNNING_IMAGE" != "$CONFIGURED_IMAGE" ]; then
    echo "Matter container image changes ($RUNNING_IMAGE -> $CONFIGURED_IMAGE)."
    echo "Backing up the fabric data before the new image touches it."
    stop_matter_if_running
    snapshot_data pre-image-change
  else
    echo "Matter fabric data present and image unchanged; scheduled backups cover it."
  fi
  exit 0
fi

if [ "${MATTER_AUTO_RESTORE_DATA:-1}" = "1" ] && [ -f "$LATEST" ]; then
  echo "No Matter fabric data found. Restoring latest backup."
  extract_archive "$LATEST"
  echo "Matter fabric data restored from: $LATEST"
  exit 0
fi

echo "No Matter fabric data and no backup found. A fresh fabric is created on first start."
