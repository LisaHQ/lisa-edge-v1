#!/usr/bin/env bash
set -euo pipefail

# Export OTBR's active Thread operational dataset to a protected file
# (operator entry point: lisa-edge otbr dataset export --output <file>).
# The dataset is written atomically with mode 0600 and never printed.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"

usage() {
  cat <<'EOF'
Usage: lisa-edge otbr dataset export --output <file>

Write OTBR's active Thread operational dataset to <file> (created with mode
0600). The file contains the complete Thread credentials; store it like a
secret and delete it when it is no longer needed.

Options:
  --output <file>  Destination file. Must not already exist.
  -h, --help       Show this help.
EOF
}

OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || { echo "ERROR: --output requires a file path." >&2; exit 2; }
      OUTPUT="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$OUTPUT" ]; then
  echo "ERROR: --output <file> is required." >&2
  usage >&2
  exit 2
fi
if [ -d "$OUTPUT" ]; then
  echo "ERROR: --output must be a file, not a directory: $OUTPUT" >&2
  exit 2
fi
RESOLVED_OUTPUT="$(lisa_validate_secret_output_file "dataset export target" "$OUTPUT")" || exit 2

if ! otbr_container_is_running; then
  echo "ERROR: lisa-otbr container is not running." >&2
  echo "Start it with: sudo ./lisa-edge service start otbr" >&2
  exit 1
fi

DATASET_HEX="$(thread_otbr_active_dataset_hex_live)"
if [ -z "$DATASET_HEX" ]; then
  echo "ERROR: OTBR has no readable active dataset (agent still starting, or no network formed)." >&2
  echo "Inspect next: docker exec lisa-otbr ot-ctl state; docker logs --tail 50 lisa-otbr" >&2
  exit 1
fi

# Atomic, permission-safe write: temp file in the destination directory,
# created 0600 under a restrictive umask, then renamed into place.
DEST_DIR="$(dirname -- "$RESOLVED_OUTPUT")"
TMP_FILE="$(umask 077 && mktemp "$DEST_DIR/.thread-dataset.XXXXXX")"
cleanup() { rm -f -- "$TMP_FILE" 2>/dev/null || true; }
trap cleanup EXIT
printf '%s\n' "$DATASET_HEX" > "$TMP_FILE"
chmod 0600 "$TMP_FILE"
mv -- "$TMP_FILE" "$RESOLVED_OUTPUT"
trap - EXIT

echo "Thread dataset exported to: $RESOLVED_OUTPUT (mode 0600)"
echo "WARNING: this file contains the complete Thread credentials (network key, PSKc)."
echo "Store it like a secret and delete it when no longer needed."
