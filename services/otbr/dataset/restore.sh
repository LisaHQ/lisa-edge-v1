#!/usr/bin/env bash
set -euo pipefail

# Restore a Thread operational dataset into OTBR (operator entry point:
# lisa-edge otbr dataset restore <file>). Replacing the active dataset is a
# network replacement: devices paired to the old network lose connectivity,
# so the current dataset is backed up first and an explicit confirmation is
# required. Deploy-time automation (init-or-restore.sh) pre-authorizes the
# operation with OTBR_DATASET_RESTORE_ASSUME_YES=1 after the wizard staged
# it; that variable is internal and not an operator interface.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge otbr dataset restore <file>

Validate <file> and apply it as OTBR's active Thread operational dataset.
When a different dataset is currently active it is backed up first and a
typed confirmation is required, because devices on the current network will
be disconnected. After applying, the committed dataset is read back and
verified. Defaults to OTBR_DATASET_LATEST when <file> is omitted.

Options:
  -h, --help  Show this help.
EOF
}

DATASET_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$DATASET_FILE" ]; then
        echo "ERROR: unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      DATASET_FILE="$1"
      ;;
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

DATASET_FILE="${DATASET_FILE:-${OTBR_DATASET_LATEST:-/srv/lisa-edge/backups/otbr/latest.dataset.hex}}"

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"
lisa_validate_persistent_path OTBR_DATASET_PATH "$(dirname "$DATASET_FILE")"

if [ ! -f "$DATASET_FILE" ]; then
  echo "ERROR: Dataset file not found: $DATASET_FILE" >&2
  exit 1
fi
if ! otbr_dataset_file_is_valid_hex "$DATASET_FILE"; then
  echo "ERROR: Dataset file is not valid hex: $DATASET_FILE" >&2
  exit 1
fi
if ! otbr_dataset_file_checksum_ok "$DATASET_FILE"; then
  echo "ERROR: Refusing to restore a dataset that fails its checksum." >&2
  exit 1
fi

DATASET="$(tr -d '[:space:]' < "$DATASET_FILE")"
if ! thread_dataset_is_valid_hex "$DATASET"; then
  echo "ERROR: Dataset file content is not a valid even-length hex string." >&2
  exit 1
fi
TARGET_XPAN="$(thread_dataset_ext_pan_id "$DATASET")"

if ! otbr_container_is_running; then
  echo "ERROR: lisa-otbr container is not running." >&2
  echo "Start it with: sudo ./lisa-edge service start otbr" >&2
  exit 1
fi
if ! otbr_wait_for_agent "${OTBR_AGENT_WAIT_ATTEMPTS:-30}" "${OTBR_WAIT_DELAY_SECONDS:-2}"; then
  echo "ERROR: otbr-agent did not become ready; ot-ctl cannot connect." >&2
  echo "Inspect next: docker logs --tail 50 lisa-otbr" >&2
  exit 1
fi

RC=0
otbr_classify_active_dataset_retry "${OTBR_DATASET_CLASSIFY_ATTEMPTS:-15}" "${OTBR_WAIT_DELAY_SECONDS:-2}" || RC=$?
if [ "$RC" -eq 2 ]; then
  echo "ERROR: Could not determine the active dataset state; refusing to restore over an ambiguous state." >&2
  echo "Inspect next: docker exec lisa-otbr ot-ctl dataset active -x" >&2
  exit 1
fi

if [ "$RC" -eq 0 ]; then
  CURRENT_XPAN="$(thread_dataset_ext_pan_id "$OTBR_ACTIVE_DATASET_HEX")"
  if [ -n "$TARGET_XPAN" ] && [ "$CURRENT_XPAN" = "$TARGET_XPAN" ]; then
    echo "The selected dataset matches the currently active network (extended PAN ID $TARGET_XPAN)."
  else
    echo "WARNING: OTBR currently has an ACTIVE Thread network."
    echo "Restoring a different dataset REPLACES that network: devices paired to"
    echo "the current network will be disconnected until they are re-joined."
    if [ "${OTBR_DATASET_RESTORE_ASSUME_YES:-0}" != "1" ]; then
      read -r -p "Type RESTORE to continue: " answer
      if [ "$answer" != "RESTORE" ]; then
        echo "Aborted. No changes were made."
        exit 1
      fi
    fi
  fi
  echo "Backing up the currently active dataset first..."
  "$EDGE_REPO/services/otbr/dataset/backup.sh" --label pre-restore
fi

docker exec lisa-otbr ot-ctl thread stop || true
docker exec lisa-otbr ot-ctl ifconfig down || true
docker exec lisa-otbr ot-ctl dataset clear || true
docker exec lisa-otbr ot-ctl dataset set active "$DATASET" >/dev/null
docker exec lisa-otbr ot-ctl ifconfig up >/dev/null
docker exec lisa-otbr ot-ctl thread start >/dev/null

echo "Waiting for OTBR to attach..."
if ! otbr_wait_for_attach "${OTBR_ATTACH_WAIT_ATTEMPTS:-45}" "${OTBR_WAIT_DELAY_SECONDS:-2}"; then
  echo "ERROR: OTBR did not attach after the restore (state: $(otbr_thread_state))." >&2
  echo "Inspect next: docker logs --tail 50 lisa-otbr; docker exec lisa-otbr ot-ctl state" >&2
  exit 1
fi

RC=0
otbr_classify_active_dataset_retry "${OTBR_DATASET_CLASSIFY_ATTEMPTS:-15}" "${OTBR_WAIT_DELAY_SECONDS:-2}" || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "ERROR: Restored dataset could not be read back for verification." >&2
  exit 1
fi
RESTORED_XPAN="$(thread_dataset_ext_pan_id "$OTBR_ACTIVE_DATASET_HEX")"
if [ -n "$TARGET_XPAN" ] && [ "$RESTORED_XPAN" != "$TARGET_XPAN" ]; then
  echo "ERROR: Read-back verification failed: expected extended PAN ID $TARGET_XPAN, got ${RESTORED_XPAN:-none}." >&2
  exit 1
fi

echo "OTBR dataset restored from: $DATASET_FILE"
echo "Active network now:"
thread_dataset_summary "$OTBR_ACTIVE_DATASET_HEX"

# Check the Matter relationship through the shared check-and-sync path: an
# interactive operator is prompted only when the default credential is
# missing or differs; an internal-engine automatic restore never prompts.
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
if lisa_has_service matter; then
  echo
  "$EDGE_REPO/services/matter-server/thread-sync-if-needed.sh" || true
fi
