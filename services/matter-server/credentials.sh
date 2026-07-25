#!/usr/bin/env bash
set -euo pipefail

# List the Thread credentials stored on the Matter server (operator entry
# point: lisa-edge matter credentials list). Shows non-secret summaries
# only: the WebSocket API never returns network keys or PSKc values.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge matter credentials list

Show the Thread credential entries stored on the Matter server. The
RESERVED DEFAULT credential is LISA Edge's managed commissioning
credential; named entries are an upstream advanced capability (legacy
duplicates are marked). Secrets are never shown.

Options:
  -h, --help  Show this help.
EOF
}

ACTION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    list)
      [ -z "$ACTION" ] || { echo "ERROR: unexpected argument: $1" >&2; exit 2; }
      ACTION=list
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [ "$ACTION" != "list" ]; then
  echo "ERROR: matter credentials requires the 'list' subcommand." >&2
  usage >&2
  exit 2
fi

if [ ! -f .env ]; then
  echo "ERROR: missing .env; run 'sudo ./lisa-edge setup' first." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a

# shellcheck disable=SC1091
. "$EDGE_REPO/services/matter-server/lib/ws.sh"

if ! matter_ws_container_running; then
  echo "ERROR: lisa-matter container is not running." >&2
  echo "Start it with: sudo ./lisa-edge service start matter" >&2
  exit 1
fi

RC=0
OUTPUT="$(matter_ws_run credentials)" || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "ERROR: could not read credentials from the Matter server (exit $RC)." >&2
  echo "Inspect next: sudo ./lisa-edge matter status; docker logs --tail 30 lisa-matter" >&2
  exit 1
fi

# Reserved default credential: the managed commissioning credential. The
# always-present empty default summary counts as configured only when the
# server also reports thread_credentials_set=true.
DEFAULT_CONFIGURED=0
matter_ws_default_configured "$OUTPUT" && DEFAULT_CONFIGURED=1
DEFAULT_NAME="$(matter_ws_field "$OUTPUT" default.network_name)"
DEFAULT_XPAN="$(matter_ws_field "$OUTPUT" default.ext_pan_id)"

if [ "$DEFAULT_CONFIGURED" -eq 1 ]; then
  echo "Reserved default credential (used for commissioning):"
  echo "  configured -> network ${DEFAULT_NAME:-?} (extended PAN ID ${DEFAULT_XPAN:-?})"
else
  echo "Reserved default credential (used for commissioning):"
  if matter_ws_default_present "$OUTPUT"; then
    echo "  NOT CONFIGURED (empty summary or thread_credentials_set=false)"
  else
    echo "  NOT CONFIGURED (no entry stored)"
  fi
  echo "  New Thread commissioning is expected to fail; store OTBR's dataset with:"
  echo "  sudo ./lisa-edge matter thread sync"
fi

# Named entries: upstream advanced capability, never used by LISA Edge for
# commissioning. Entries matching the configured default are legacy
# duplicates (safe to remove after the default has been verified).
NAMED_ROWS=""
while IFS=$'\t' read -r id name xpan; do
  [ "$id" = "$MATTER_WS_DEFAULT_ID" ] && continue
  note="not used for commissioning"
  if [ "$DEFAULT_CONFIGURED" -eq 1 ] &&
     [ "$name" = "$DEFAULT_NAME" ] && [ "${xpan^^}" = "${DEFAULT_XPAN^^}" ]; then
    note="legacy duplicate of the default; remove with: matter thread remove --id $id"
  fi
  NAMED_ROWS+="$(printf '%-24s %-18s %-18s %s' "$id" "${name:--}" "${xpan:--}" "$note")"$'\n'
done < <(matter_ws_thread_entries "$OUTPUT")

echo
if [ -n "$NAMED_ROWS" ]; then
  echo "Named credentials (advanced upstream capability):"
  printf '%-24s %-18s %-18s %s\n' "ID" "NETWORK NAME" "EXTENDED PAN ID" "NOTE"
  printf '%s' "$NAMED_ROWS"
else
  echo "No named Thread credentials are stored."
fi
