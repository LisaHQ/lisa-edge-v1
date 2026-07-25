#!/usr/bin/env bash
set -euo pipefail

# Internal Matter/OTBR Thread credential check-and-sync path. This is NOT a
# root CLI command: interactive workflows (setup, service add, restore with
# --start-services, otbr network create, otbr dataset restore) run it after
# their service refresh so the operator is asked exactly when a sync is
# actually needed. The explicit manual command stays:
#   sudo ./lisa-edge matter thread sync
#
# Synchronization direction is ONLY ever:
#   OTBR active dataset -> Matter Server reserved default Thread credential
#
# Prompt policy (automated paths must never hang):
#   - prompting requires stdin AND stdout to be terminals
#   - the internal deployment engine exports LISA_THREAD_SYNC_NO_PROMPT=1,
#     which suppresses the prompt even on a terminal
#   - LISA_THREAD_SYNC_ASSUME_YES=1 records consent a caller already
#     obtained interactively; the sync then runs without another prompt
#
# Only identity fields returned by the Matter API (Thread network name and
# extended PAN ID) are compared or printed. The raw dataset, Network Key and
# PSKc are never printed, logged, or passed through process arguments.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: services/matter-server/thread-sync-if-needed.sh [--check-only]

Internal helper: check whether the Matter server's reserved default Thread
credential matches OTBR's active dataset, and offer to copy the dataset when
an interactive operator is present.

Options:
  --check-only  Report the relationship state without prompting or mutating.
                Exit 0 (match or not applicable), 3 (sync needed),
                4 (cannot be verified).
  -h, --help    Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f .env ]; then
  echo "[LISA] Thread sync check skipped: .env is missing (run 'sudo ./lisa-edge setup' first)."
  [ "$CHECK_ONLY" -eq 1 ] && exit 4
  exit 0
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/matter-server/lib/ws.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"

# Classify the current OTBR <-> Matter default-credential relationship.
# Sets THREAD_SYNC_STATE to one of:
#   not-selected        Matter or OTBR is not in the service selection
#   matter-not-running  Matter is selected but lisa-matter is not running
#   otbr-not-running    OTBR is selected but lisa-otbr is not running
#   otbr-no-dataset     OTBR runs but has no readable active dataset
#   default-missing     the reserved default credential is not configured
#   drift               the default credential identity differs from OTBR
#   match               the default credential already matches OTBR
#   unverifiable        a dependency or API is unavailable
# and, when known, THREAD_SYNC_OTBR_NAME / THREAD_SYNC_OTBR_XPAN /
# THREAD_SYNC_DEFAULT_NAME / THREAD_SYNC_DEFAULT_XPAN (identity fields only).
check_thread_sync_state() {
  THREAD_SYNC_STATE=""
  THREAD_SYNC_OTBR_NAME=""
  THREAD_SYNC_OTBR_XPAN=""
  THREAD_SYNC_DEFAULT_NAME=""
  THREAD_SYNC_DEFAULT_XPAN=""

  if ! lisa_has_service matter || ! lisa_has_service otbr; then
    THREAD_SYNC_STATE=not-selected
    return 0
  fi
  if ! matter_ws_container_running; then
    THREAD_SYNC_STATE=matter-not-running
    return 0
  fi
  if ! otbr_container_is_running; then
    THREAD_SYNC_STATE=otbr-not-running
    return 0
  fi

  local otbr_hex
  otbr_hex="$(thread_otbr_active_dataset_hex_live)" || otbr_hex=""
  if [ -z "$otbr_hex" ]; then
    THREAD_SYNC_STATE=otbr-no-dataset
    return 0
  fi
  THREAD_SYNC_OTBR_NAME="$(thread_dataset_network_name "$otbr_hex")"
  THREAD_SYNC_OTBR_XPAN="$(thread_dataset_ext_pan_id "$otbr_hex")"

  local output rc=0
  output="$(matter_ws_run credentials)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    THREAD_SYNC_STATE=unverifiable
    return 0
  fi

  # The reserved default credential is the ONLY entry that decides
  # commissioning readiness; named (legacy) entries are never consulted.
  if ! matter_ws_default_configured "$output"; then
    THREAD_SYNC_STATE=default-missing
    return 0
  fi
  THREAD_SYNC_DEFAULT_NAME="$(matter_ws_field "$output" default.network_name)"
  THREAD_SYNC_DEFAULT_XPAN="$(matter_ws_field "$output" default.ext_pan_id)"

  if [ "$THREAD_SYNC_DEFAULT_NAME" = "$THREAD_SYNC_OTBR_NAME" ] &&
     [ "${THREAD_SYNC_DEFAULT_XPAN^^}" = "${THREAD_SYNC_OTBR_XPAN^^}" ]; then
    THREAD_SYNC_STATE=match
  else
    THREAD_SYNC_STATE=drift
  fi
}

print_remediation() {
  echo "[LISA] Services stay running. Sync manually when ready with:"
  echo "[LISA]   sudo ./lisa-edge matter thread sync"
}

run_sync() {
  echo "[LISA] Copying OTBR's active Thread dataset to the Matter server's default credential..."
  if "$EDGE_REPO/services/matter-server/thread.sh" sync --from-otbr; then
    return 0
  fi
  echo "[LISA] WARNING: the Thread credential sync failed." >&2
  print_remediation >&2
  return 1
}

# Interactive prompt wrapper around the classification. Returns:
#   0  match, nothing applicable, or a successful sync
#   1  a sync was attempted and failed
#   3  a sync is needed but was not performed (no consent / declined)
prompt_thread_sync_if_needed() {
  check_thread_sync_state

  case "$THREAD_SYNC_STATE" in
    not-selected)
      return 0
      ;;
    matter-not-running|otbr-not-running)
      echo "[LISA] Thread credential check skipped: ${THREAD_SYNC_STATE%-not-running} is selected but not running."
      echo "[LISA] The relationship is checked again when both services run in an interactive workflow."
      print_remediation
      return 0
      ;;
    otbr-no-dataset)
      echo "[LISA] OTBR has no readable active Thread dataset yet, so the Matter server's"
      echo "[LISA] default credential cannot be synchronized now. Once OTBR has an active"
      echo "[LISA] network, run:"
      echo "[LISA]   sudo ./lisa-edge matter thread sync"
      return 0
      ;;
    unverifiable)
      echo "[LISA] WARNING: the Matter server API is unavailable; the Thread credential" >&2
      echo "[LISA] relationship cannot be verified right now." >&2
      echo "[LISA] Inspect next: sudo ./lisa-edge matter thread status" >&2
      return 0
      ;;
    match)
      echo "[LISA] Matter server's default Thread credential already matches OTBR's active"
      echo "[LISA] network '${THREAD_SYNC_OTBR_NAME:-?}' (extended PAN ID ${THREAD_SYNC_OTBR_XPAN:-?}). No sync needed."
      return 0
      ;;
    default-missing)
      echo "[LISA] The Matter server's reserved default Thread credential is NOT configured."
      echo "[LISA] OTBR's active network: '${THREAD_SYNC_OTBR_NAME:-?}' (extended PAN ID ${THREAD_SYNC_OTBR_XPAN:-?})."
      echo "[LISA] New Thread commissioning fails until the credential is set."
      ;;
    drift)
      echo "[LISA] The Matter server's default Thread credential differs from OTBR's active network:"
      echo "[LISA]   OTBR:   '${THREAD_SYNC_OTBR_NAME:-?}' (extended PAN ID ${THREAD_SYNC_OTBR_XPAN:-?})"
      echo "[LISA]   Matter: '${THREAD_SYNC_DEFAULT_NAME:-?}' (extended PAN ID ${THREAD_SYNC_DEFAULT_XPAN:-?})"
      echo "[LISA] New Thread commissioning is expected to fail until they match."
      ;;
  esac

  # default-missing or drift: a sync is needed.
  if [ "${LISA_THREAD_SYNC_ASSUME_YES:-0}" = "1" ]; then
    run_sync
    return $?
  fi
  if [ "${LISA_THREAD_SYNC_NO_PROMPT:-0}" = "1" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    print_remediation
    return 3
  fi

  local answer
  while :; do
    read -r -p "Copy OTBR's active Thread dataset to Matter Server's default credential? [Y/n] " answer
    case "${answer,,}" in
      ""|y|yes)
        run_sync
        return $?
        ;;
      n|no)
        echo "[LISA] Skipped by operator request."
        print_remediation
        return 3
        ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  check_thread_sync_state
  echo "thread-sync-state=$THREAD_SYNC_STATE"
  case "$THREAD_SYNC_STATE" in
    match|not-selected) exit 0 ;;
    default-missing|drift) exit 3 ;;
    *) exit 4 ;;
  esac
fi

prompt_thread_sync_if_needed
exit $?
