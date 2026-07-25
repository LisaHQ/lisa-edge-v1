#!/usr/bin/env bash
set -euo pipefail

# Show OTBR's active Thread operational dataset (operator entry point:
# lisa-edge otbr dataset show). The default output is a decoded, REDACTED
# summary: the complete dataset contains the Thread network key and PSKc and
# is only printed with an explicit --show-secret.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"

usage() {
  cat <<'EOF'
Usage: lisa-edge otbr dataset show [--show-secret]

Print a decoded summary of OTBR's active Thread operational dataset.
Secrets (network key, PSKc) are redacted by default.

Options:
  --show-secret   Print the complete dataset hex (contains the Thread
                  network key and PSKc). Treat the output as a secret.
  -h, --help      Show this help.
EOF
}

SHOW_SECRET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --show-secret) SHOW_SECRET=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

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

if [ "$SHOW_SECRET" -eq 1 ]; then
  {
    echo "WARNING: the following line is the COMPLETE Thread operational dataset."
    echo "WARNING: it contains the Thread network key and PSKc. Do not paste it"
    echo "WARNING: into logs, tickets, or chat. Anyone holding it can join and"
    echo "WARNING: control the Thread network."
  } >&2
  printf '%s\n' "$DATASET_HEX"
  exit 0
fi

thread_dataset_summary "$DATASET_HEX"
