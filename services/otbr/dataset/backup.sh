#!/usr/bin/env bash
set -euo pipefail

# Back up OTBR's active Thread operational dataset (operator entry point:
# lisa-edge otbr dataset backup [--label <label>]; also run by the
# lisa-otbr-dataset-backup timer and by deploy/restore flows).
#
# Each backup consists of:
#   thread-dataset-<utc-ts>[-label].hex         complete dataset (secret, 0600)
#   thread-dataset-<utc-ts>[-label].hex.sha256  integrity checksum
#   thread-dataset-<utc-ts>[-label].hex.meta    non-secret identity metadata
# plus the latest.dataset.hex symlink pointing at the newest archive.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge otbr dataset backup [--label <label>]

Store OTBR's active Thread operational dataset under
OTBR_DATASET_BACKUP_DIR with a checksum and a non-secret metadata sidecar.

Options:
  --label <label>  Optional label appended to the backup filename
                   (sanitized for filesystem safety).
  -h, --help       Show this help.
EOF
}

LABEL_RAW=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --label)
      [ "$#" -ge 2 ] || { echo "ERROR: --label requires a value." >&2; exit 2; }
      LABEL_RAW="$2"
      shift
      ;;
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

BACKUP_DIR="${OTBR_DATASET_BACKUP_DIR:-/srv/lisa-edge/backups/otbr}"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"
lisa_validate_persistent_path OTBR_DATASET_BACKUP_DIR "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BASE_NAME="thread-dataset-$TS"
# Reserve room for the base name, the '-' separator and the '.hex.sha256'
# extension (the longest sidecar suffix).
LABEL_MAX=$((OTBR_FILENAME_MAX_BYTES - ${#BASE_NAME} - 1 - 11))
LABEL="$(otbr_sanitize_backup_description "$LABEL_RAW" "$LABEL_MAX")"
OUT="$BACKUP_DIR/$BASE_NAME${LABEL:+-$LABEL}.hex"
LATEST="$BACKUP_DIR/latest.dataset.hex"
RETENTION_DAYS="${OTBR_DATASET_RETENTION_DAYS:-30}"

# otbr-agent may briefly drop control sessions right after dataset creation or
# deploy, so a single read can race an agent restart. Retry transient failures,
# but stop immediately when the agent confirms no dataset exists (NotFound).
DATASET=""
for _ in $(seq 1 10); do
  OUTPUT=""
  if OUTPUT="$(docker exec lisa-otbr ot-ctl dataset active -x 2>&1)"; then
    # ot-ctl terminates lines with CRLF; strip \r or the hex line never matches.
    DATASET="$(printf '%s\n' "$OUTPUT" | tr -d '\r' | awk '/^[0-9a-fA-F]+$/ {print $1; exit}')"
    [ -n "$DATASET" ] && break
  fi
  if printf '%s' "$OUTPUT" | grep -qi 'NotFound'; then
    echo "ERROR: OTBR has no active Thread dataset to back up." >&2
    echo "Form or restore a network first (deploy handles both), then rerun this backup." >&2
    exit 1
  fi
  sleep 3
done

if [ -z "$DATASET" ]; then
  {
    echo "ERROR: Could not read active Thread dataset from OTBR."
    echo "Inspect next:"
    echo "  docker exec lisa-otbr ot-ctl state"
    echo "  docker exec lisa-otbr ot-ctl dataset active -x"
    echo "Rerun this backup once ot-ctl answers consistently."
  } >&2
  exit 1
fi

# Stage in the destination directory, then rename: a power loss mid-write
# must never leave a truncated file behind the latest symlink.
TMP_FILE="$(umask 077 && mktemp "$BACKUP_DIR/.thread-dataset.XXXXXX")"
cleanup() { rm -f -- "$TMP_FILE" 2>/dev/null || true; }
trap cleanup EXIT
printf '%s\n' "$DATASET" > "$TMP_FILE"
chmod 0600 "$TMP_FILE"
mv -- "$TMP_FILE" "$OUT"
trap - EXIT

sha256sum "$OUT" | awk -v name="$(basename "$OUT")" '{print $1 "  " name}' > "$OUT.sha256"
chmod 0600 "$OUT.sha256"

# Non-secret identity metadata: enough to pick the right backup later
# without ever opening the secret dataset file.
{
  echo "created_utc=$TS"
  echo "label=$LABEL"
  echo "network_name=$(thread_dataset_network_name "$DATASET")"
  echo "channel=$(thread_dataset_channel "$DATASET")"
  echo "pan_id=$(thread_dataset_pan_id "$DATASET")"
  echo "ext_pan_id=$(thread_dataset_ext_pan_id "$DATASET")"
  echo "mesh_local_prefix=$(thread_dataset_mesh_local_prefix "$DATASET")"
  echo "active_timestamp=$(thread_dataset_active_timestamp "$DATASET")"
} > "$OUT.meta"
chmod 0600 "$OUT.meta"

ln -sfn "$(basename "$OUT")" "$LATEST"

if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && [ "$RETENTION_DAYS" -gt 0 ]; then
  find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name 'thread-dataset-*.hex' -o -name 'thread-dataset-*.hex.sha256' \
       -o -name 'thread-dataset-*.hex.meta' \) \
    -mtime "+$RETENTION_DAYS" -delete
fi

echo "OTBR dataset backed up to: $OUT"
