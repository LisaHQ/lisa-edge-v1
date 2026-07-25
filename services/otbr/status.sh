#!/usr/bin/env bash
set -euo pipefail

# Focused OTBR status (operator entry point: lisa-edge otbr status).
# Read-only, quick, and secret-safe: only decoded identity fields of the
# active dataset are shown, never the dataset itself.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge otbr status

Show the OpenThread Border Router runtime state: container, agent, Thread
role, network identity (no secrets), and dataset backup coverage.

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

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"

field() { printf '%-22s%s\n' "$1" "$2"; }

if [ ! -f .env ]; then
  field "Status:" "NOT CONFIGURED"
  echo "Missing .env. Run: sudo ./lisa-edge setup"
  exit 0
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"

if ! lisa_has_service otbr; then
  field "Status:" "NOT CONFIGURED"
  echo "OTBR is not in LISA_COMPOSE_SERVICES. Add it with: sudo ./lisa-edge service add otbr"
  exit 0
fi

OVERALL="HEALTHY"
demote() {
  case "$1" in
    FAILED) OVERALL="FAILED" ;;
    DEGRADED) [ "$OVERALL" = "FAILED" ] || OVERALL="DEGRADED" ;;
    STOPPED|STARTING) OVERALL="$1" ;;
  esac
}

CONTAINER_STATE="$(docker inspect -f '{{.State.Status}}' lisa-otbr 2>/dev/null || echo absent)"
CONTAINER_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' lisa-otbr 2>/dev/null || true)"
field "Container state:" "$CONTAINER_STATE"
field "Container health:" "${CONTAINER_HEALTH:-none}"

RADIO_DEVICE="${THREAD_RADIO_DEVICE:-}"
if [ -n "$RADIO_DEVICE" ] && [ -e "$RADIO_DEVICE" ]; then
  field "RCP device:" "$RADIO_DEVICE (present)"
else
  field "RCP device:" "${RADIO_DEVICE:-unset} (MISSING)"
  demote FAILED
fi
field "Backbone interface:" "${OTBR_BACKBONE_IF:-unset}"

if [ "$CONTAINER_STATE" != "running" ]; then
  field "Status:" "STOPPED"
  echo "Start it with: sudo ./lisa-edge service start otbr"
  exit 0
fi
case "$CONTAINER_HEALTH" in
  unhealthy) demote FAILED ;;
  starting) demote STARTING ;;
esac

OT_VERSION="$(timeout 5 docker exec lisa-otbr ot-ctl version 2>/dev/null | head -n 1 | tr -d '\r' || true)"
field "OpenThread version:" "${OT_VERSION:-unavailable}"
if [ -z "$OT_VERSION" ]; then
  # Container runs but the agent does not answer: RCP or agent problem.
  demote FAILED
fi

THREAD_STATE="$(timeout 5 docker exec lisa-otbr ot-ctl state 2>/dev/null | head -n 1 | tr -d '\r' || true)"
field "Thread role:" "${THREAD_STATE:-unknown}"
case "$THREAD_STATE" in
  leader|router|child) ;;
  detached) demote DEGRADED ;;
  *) demote FAILED ;;
esac

DATASET_HEX="$(thread_otbr_active_dataset_hex_live)"
if [ -n "$DATASET_HEX" ]; then
  field "Thread network name:" "$(thread_dataset_network_name "$DATASET_HEX")"
  field "Channel:" "$(thread_dataset_channel "$DATASET_HEX")"
  field "PAN ID:" "$(thread_dataset_pan_id "$DATASET_HEX")"
  field "Extended PAN ID:" "$(thread_dataset_ext_pan_id "$DATASET_HEX")"
else
  field "Active dataset:" "none readable"
  demote FAILED
fi

BACKUP_DIR="${OTBR_DATASET_BACKUP_DIR:-${DATA_ROOT:-/srv/lisa-edge}/backups/otbr}"
LATEST="$BACKUP_DIR/latest.dataset.hex"
if [ -L "$LATEST" ] || [ -f "$LATEST" ]; then
  LATEST_TARGET="$(readlink -f -- "$LATEST" 2>/dev/null || printf '%s' "$LATEST")"
  LATEST_TIME="$(date -u -r "$LATEST_TARGET" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  field "Latest dataset backup:" "$(basename "$LATEST_TARGET") ($LATEST_TIME)"
else
  field "Latest dataset backup:" "none"
  demote DEGRADED
fi

if command -v systemctl >/dev/null 2>&1; then
  TIMER_STATE="$(systemctl is-active lisa-otbr-dataset-backup.timer 2>/dev/null || true)"
  field "Dataset backup timer:" "${TIMER_STATE:-unknown}"
  [ "$TIMER_STATE" = "active" ] || demote DEGRADED
else
  field "Dataset backup timer:" "no systemd"
fi

field "Status:" "$OVERALL"
