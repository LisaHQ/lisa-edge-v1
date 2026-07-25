#!/usr/bin/env bash
set -euo pipefail

# Create a brand-new Thread network on OTBR (operator entry point:
# lisa-edge otbr network create). This is a NETWORK REPLACEMENT operation:
# when an active dataset exists it is backed up and then replaced, and every
# device paired to the old network must be re-commissioned. There is no
# cosmetic rename of an established Thread network.
#
# Deploy-time automation (dataset/init-or-restore.sh) pre-authorizes the
# replacement with OTBR_NETWORK_CREATE_ASSUME_YES=1 after the provisioning
# wizard staged it; that variable is internal, not an operator interface.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge otbr network create

Create a completely new Thread network named THREAD_NETWORK_NAME (.env).
When a Thread network is already active it is backed up first, then
REPLACED: existing Thread devices are disconnected and every test device
must be re-commissioned. A typed confirmation is required in that case.

Options:
  -h, --help  Show this help.
EOF
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

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"

NETWORK_NAME="${THREAD_NETWORK_NAME:-}"
if ! thread_network_name_is_valid "$NETWORK_NAME"; then
  echo "ERROR: THREAD_NETWORK_NAME in .env is not a valid Thread network name." >&2
  echo "Set it (max 16 bytes, no control characters or whitespace), then rerun." >&2
  exit 1
fi

ot() {
  docker exec lisa-otbr ot-ctl "$@"
}

# 1. Confirm OTBR and otbr-agent readiness.
if ! otbr_container_is_running; then
  echo "ERROR: lisa-otbr container is not running." >&2
  echo "Start it with: sudo ./lisa-edge service start otbr" >&2
  exit 1
fi
echo "Waiting for otbr-agent to accept commands..."
if ! otbr_wait_for_agent "${OTBR_AGENT_WAIT_ATTEMPTS:-60}" "${OTBR_WAIT_DELAY_SECONDS:-2}"; then
  echo "ERROR: otbr-agent did not become ready; ot-ctl cannot connect." >&2
  echo "Inspect next: docker logs --tail 50 lisa-otbr; ls -l ${THREAD_RADIO_DEVICE:-/dev/serial/by-id/}" >&2
  exit 1
fi

# 2. Detect whether an active dataset already exists (never trust one read).
RC=0
otbr_classify_active_dataset_retry "${OTBR_DATASET_CLASSIFY_ATTEMPTS:-15}" "${OTBR_WAIT_DELAY_SECONDS:-2}" || RC=$?
if [ "$RC" -eq 2 ]; then
  echo "ERROR: Could not determine the active dataset state." >&2
  echo "Refusing to create a network over an ambiguous state." >&2
  echo "Inspect next: docker exec lisa-otbr ot-ctl dataset active -x" >&2
  exit 1
fi

if [ "$RC" -eq 0 ]; then
  # 3. Warn, 4. back up, and require explicit confirmation before replacing.
  echo "WARNING: OTBR already has an ACTIVE Thread network:"
  thread_dataset_summary "$OTBR_ACTIVE_DATASET_HEX" | sed 's/^/  /'
  echo
  echo "Creating '$NETWORK_NAME' REPLACES this network. Devices paired to it"
  echo "will be disconnected and must be re-commissioned onto the new network."
  if [ "${OTBR_NETWORK_CREATE_ASSUME_YES:-0}" != "1" ]; then
    read -r -p "Type CREATE to continue: " answer
    if [ "$answer" != "CREATE" ]; then
      echo "Aborted. No changes were made."
      exit 1
    fi
  fi
  echo "Backing up the currently active dataset first..."
  "$EDGE_REPO/services/otbr/dataset/backup.sh" --label pre-network-create
fi

# 5-8. Initialize a new operational dataset, apply the network name, set a
# fresh random PSKc AFTER the name (a passphrase-derived PSKc depends on the
# name and extended PAN ID, so the name must be final first), then commit.
echo "Creating Thread network '$NETWORK_NAME'..."
ot dataset init new >/dev/null
ot dataset networkname "$NETWORK_NAME" >/dev/null
PSKC="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
ot dataset pskc "$PSKC" >/dev/null
unset PSKC
ot dataset commit active >/dev/null

# 9-11. Bring the interface up, start Thread, wait for attachment.
ot ifconfig up >/dev/null
ot thread start >/dev/null
echo "Waiting for the node to attach (become leader of the new network)..."
if ! otbr_wait_for_attach "${OTBR_ATTACH_WAIT_ATTEMPTS:-60}" "${OTBR_WAIT_DELAY_SECONDS:-2}"; then
  echo "ERROR: OTBR did not attach after creating the network (state: $(otbr_thread_state))." >&2
  echo "Inspect next: docker logs --tail 50 lisa-otbr; docker exec lisa-otbr ot-ctl state" >&2
  exit 1
fi

# 12-13. Read the committed dataset back and verify its identity fields.
RC=0
otbr_classify_active_dataset_retry "${OTBR_DATASET_CLASSIFY_ATTEMPTS:-15}" "${OTBR_WAIT_DELAY_SECONDS:-2}" || RC=$?
if [ "$RC" -ne 0 ]; then
  echo "ERROR: Created a new Thread network but could not read it back." >&2
  echo "Inspect next: docker exec lisa-otbr ot-ctl dataset active -x" >&2
  echo "Then store it manually: sudo ./lisa-edge otbr dataset backup" >&2
  exit 1
fi
CREATED_NAME="$(thread_dataset_network_name "$OTBR_ACTIVE_DATASET_HEX")"
CREATED_XPAN="$(thread_dataset_ext_pan_id "$OTBR_ACTIVE_DATASET_HEX")"
CREATED_PAN="$(thread_dataset_pan_id "$OTBR_ACTIVE_DATASET_HEX")"
if [ "$CREATED_NAME" != "$NETWORK_NAME" ]; then
  echo "ERROR: Read-back verification failed: expected network name '$NETWORK_NAME', got '${CREATED_NAME:-none}'." >&2
  exit 1
fi
if [ -z "$CREATED_XPAN" ] || [ -z "$CREATED_PAN" ]; then
  echo "ERROR: Read-back verification failed: the committed dataset is missing identity fields." >&2
  exit 1
fi

# 14. Back up the new dataset.
"$EDGE_REPO/services/otbr/dataset/backup.sh" --label network-create

echo
echo "New Thread network is active:"
thread_dataset_summary "$OTBR_ACTIVE_DATASET_HEX" | sed 's/^/  /'

# 15. Check the Matter relationship through the shared check-and-sync path.
# The new network always differs from the old default credential, so an
# interactive operator is asked (default Yes); an internal-engine automatic
# creation never prompts and leaves the health model to report the drift.
if lisa_has_service matter; then
  echo
  "$EDGE_REPO/services/matter-server/thread-sync-if-needed.sh" || true
fi

# 16. Recommissioning notice.
echo
echo "NOTE: this is a new Thread network. Every Thread device that was paired"
echo "to a previous network must be factory-reset and re-commissioned."
