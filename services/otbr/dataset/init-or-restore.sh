#!/usr/bin/env bash
set -euo pipefail

# Runs from deploy AFTER `docker compose up`. Decides what to do with OTBR's
# Thread operational dataset: apply a one-shot change staged by the
# provisioning wizard, back up an already-active dataset, auto-restore the
# latest backup into an empty OTBR, or (only when explicitly allowed) create
# a brand-new network. All mutations delegate to restore.sh and
# network-create.sh so the safety behavior (backup-before-replace, read-back
# verification, Matter sync) exists in exactly one place.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$EDGE_REPO"

set -a
source ./.env
set +a

LATEST="${OTBR_DATASET_LATEST:-/srv/lisa-edge/backups/otbr/latest.dataset.hex}"

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"
BACKUP_DIR="${OTBR_DATASET_BACKUP_DIR:-/srv/lisa-edge/backups/otbr}"
# Test seam (mirrors the repository's LISA_EDGE_TESTING contract): a backup
# directory below /tmp is accepted only in testing mode; real hosts always
# validate the persistent path.
SKIP_PATH_VALIDATION=0
if [ "${LISA_EDGE_TESTING:-0}" = "1" ]; then
  case "$BACKUP_DIR" in /tmp/*) SKIP_PATH_VALIDATION=1 ;; esac
fi
if [ "$SKIP_PATH_VALIDATION" -ne 1 ]; then
  lisa_validate_persistent_path OTBR_DATASET_BACKUP_DIR "$BACKUP_DIR"
fi
PENDING_DATASET="$BACKUP_DIR/$OTBR_PENDING_DATASET_FILE_NAME"
PENDING_NEW_NETWORK="$BACKUP_DIR/$OTBR_PENDING_NEW_NETWORK_FILE_NAME"

# Attempt counts and delays are env-overridable ONLY for tests; the
# defaults are the production behavior.
WAIT_ATTEMPTS="${OTBR_DATASET_WAIT_ATTEMPTS:-60}"
WAIT_DELAY="${OTBR_DATASET_WAIT_DELAY:-2}"

echo "Waiting for OTBR container..."
CONTAINER_RUNNING=0
for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
  if otbr_container_is_running; then
    CONTAINER_RUNNING=1
    break
  fi
  sleep "$WAIT_DELAY"
done
if [ "$CONTAINER_RUNNING" -ne 1 ]; then
  echo "ERROR: lisa-otbr container is not running." >&2
  echo "Inspect next: docker ps -a --filter name=lisa-otbr; docker logs --tail 50 lisa-otbr" >&2
  exit 1
fi

# The container can be Running while otbr-agent is still starting or is
# crash-looping (for example when the RCP radio cannot be opened). ot-ctl
# reports "connect session failed" until the agent socket exists, so gate all
# dataset decisions on agent readiness instead of container state.
echo "Waiting for otbr-agent to accept commands..."
if ! otbr_wait_for_agent "$WAIT_ATTEMPTS" "$WAIT_DELAY"; then
  {
    echo "ERROR: otbr-agent did not become ready; ot-ctl cannot connect to its socket."
    echo "The lisa-otbr container is running but the OpenThread agent has not started."
    echo "Inspect next:"
    echo "  docker logs --tail 50 lisa-otbr"
    echo "  ls -l ${THREAD_RADIO_DEVICE:-/dev/serial/by-id/}"
    echo "Common causes:"
    echo "  - THREAD_RADIO_DEVICE does not point at the attached RCP radio"
    echo "  - the radio was unplugged or re-enumerated under a new device path"
    echo "  - THREAD_RADIO_URL uses the wrong UART baud rate for this radio"
    echo "  - OTBR_BACKBONE_IF does not match an active host interface"
  } >&2
  exit 1
fi

DATASET_STATUS=""
RC=0
otbr_classify_active_dataset_retry "${OTBR_DATASET_CLASSIFY_ATTEMPTS:-30}" "$WAIT_DELAY" || RC=$?
case "$RC" in
  0) DATASET_STATUS=present ;;
  1) DATASET_STATUS=absent ;;
  *)
    {
      echo "ERROR: Could not determine the active Thread dataset state."
      echo "otbr-agent answered readiness checks but dataset reads kept failing."
      echo "Refusing to restore or create a network on an ambiguous state."
      echo "Inspect next:"
      echo "  docker logs --tail 50 lisa-otbr"
      echo "  docker exec lisa-otbr ot-ctl state"
      echo "  docker exec lisa-otbr ot-ctl dataset active -x"
      echo "Rerun deploy once ot-ctl answers consistently."
    } >&2
    exit 1
    ;;
esac

# One-shot dataset change staged by the provisioning wizard. Applied exactly
# once: the marker is removed only after the change fully succeeds, so an
# interrupted deploy safely retries. The wizard already collected the
# operator's explicit consent, so the replacement is pre-authorized here.
if [ -f "$PENDING_DATASET" ] || [ -f "$PENDING_NEW_NETWORK" ]; then
  if [ -f "$PENDING_DATASET" ]; then
    echo "Applying the Thread dataset selected during provisioning."
    OTBR_DATASET_RESTORE_ASSUME_YES=1 \
      "$EDGE_REPO/services/otbr/dataset/restore.sh" "$PENDING_DATASET"
    # Snapshot the now-active dataset so latest.dataset.hex reflects it.
    "$EDGE_REPO/services/otbr/dataset/backup.sh" --label post-restore
  else
    echo "Creating the new Thread network selected during provisioning."
    OTBR_NETWORK_CREATE_ASSUME_YES=1 \
      "$EDGE_REPO/services/otbr/network-create.sh"
  fi
  rm -f -- "$PENDING_DATASET" "$PENDING_NEW_NETWORK"
  exit 0
fi

if [ "$DATASET_STATUS" = "present" ]; then
  echo "OTBR already has an active dataset. Backing it up."
  "$EDGE_REPO/services/otbr/dataset/backup.sh"
  exit 0
fi

# Empty dataset, no pending one-shot action: apply the persistent recovery
# policy. A new network is only ever created automatically when NO latest
# backup exists; a backup with restoration disabled fails closed instead of
# silently replacing the Thread network it belongs to.
LATEST_EXISTS=0
[ -f "$LATEST" ] && LATEST_EXISTS=1
ACTION="$(otbr_empty_dataset_action \
  "${OTBR_AUTO_RESTORE_DATASET:-1}" "${OTBR_AUTO_CREATE_NETWORK:-0}" "$LATEST_EXISTS")"
case "$ACTION" in
  restore-latest)
    echo "No active dataset found. Restoring latest dataset."
    OTBR_DATASET_RESTORE_ASSUME_YES=1 \
      "$EDGE_REPO/services/otbr/dataset/restore.sh" "$LATEST"
    exit 0
    ;;
  create-network)
    echo "No active dataset and no latest backup exist. Creating a new Thread network (allowed by policy)."
    OTBR_NETWORK_CREATE_ASSUME_YES=1 \
      "$EDGE_REPO/services/otbr/network-create.sh"
    exit 0
    ;;
  fail-backup-restore-disabled)
    {
      echo "ERROR: No active dataset, but a latest Thread dataset backup exists:"
      echo "  $LATEST"
      echo "Automatic restoration is disabled (OTBR_AUTO_RESTORE_DATASET=0), and a"
      echo "replacement Thread network is NEVER created while a backup exists:"
      echo "it would orphan every device paired to the backed-up network."
      echo "Choose one:"
      echo "  - restore the backup:  sudo ./lisa-edge otbr dataset restore '$LATEST'"
      echo "  - enable restoration:  sudo ./lisa-edge setup  (Future OTBR recovery policy)"
      echo "  - replace the network deliberately:  sudo ./lisa-edge otbr network create"
    } >&2
    exit 1
    ;;
  fail-no-backup|*)
    {
      echo "ERROR: No active dataset and no latest backup found."
      echo "The configured recovery policy does not allow creating a network automatically."
      echo "Choose one:"
      echo "  - create one explicitly:  sudo ./lisa-edge otbr network create"
      echo "  - restore a specific backup:  sudo ./lisa-edge otbr dataset restore <file>"
      echo "  - change the policy:  sudo ./lisa-edge setup  (Future OTBR recovery policy)"
    } >&2
    exit 1
    ;;
esac
