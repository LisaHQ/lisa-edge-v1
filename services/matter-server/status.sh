#!/usr/bin/env bash
set -euo pipefail

# Focused Matter Server status (operator entry point: lisa-edge matter
# status). Read-only, quick, and secret-safe.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge matter status

Show the Matter Server runtime state: container, WebSocket schema, network
exposure, fabric label, Bluetooth, stored Thread credential summary and its
relationship to OTBR, and backup coverage. Secrets are never shown.

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

field() { printf '%-26s%s\n' "$1" "$2"; }

if [ ! -f .env ]; then
  field "Status:" "NOT CONFIGURED"
  echo "Missing .env. Run: sudo ./lisa-edge configure"
  exit 0
fi
set -a
# shellcheck disable=SC1091
source ./.env
set +a
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/thread-dataset.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/matter-server/lib/ws.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/otbr/dataset/lib.sh"

if ! lisa_has_service matter; then
  field "Status:" "NOT CONFIGURED"
  echo "Matter is not in LISA_COMPOSE_SERVICES. Run: sudo ./lisa-edge configure"
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

CONTAINER_STATE="$(docker inspect -f '{{.State.Status}}' lisa-matter 2>/dev/null || echo absent)"
CONTAINER_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' lisa-matter 2>/dev/null || true)"
field "Container state:" "$CONTAINER_STATE"
field "Container health:" "${CONTAINER_HEALTH:-none}"
field "Image:" "${MATTER_SERVER_IMAGE:-ghcr.io/matter-js/matterjs-server:1.3.0}"
field "Listen address:" "${MATTER_LISTEN_ADDRESS:-127.0.0.1}"
field "Primary interface:" "${MATTER_PRIMARY_INTERFACE:-auto-detect}"
BLE_ADAPTER="$(lisa_matter_ble_adapter)"
field "Bluetooth adapter:" "$BLE_ADAPTER"

if [ "$CONTAINER_STATE" != "running" ]; then
  field "Status:" "STOPPED"
  echo "Start it with: sudo ./lisa-edge deploy"
  exit 0
fi
case "$CONTAINER_HEALTH" in
  unhealthy) demote FAILED ;;
  starting) demote STARTING ;;
esac

RC=0
WS_OUTPUT="$(MATTER_WS_CONNECT_TIMEOUT_MS=5000 MATTER_WS_RESPONSE_TIMEOUT_MS=8000 \
  matter_ws_run status)" || RC=$?
if [ "$RC" -ne 0 ]; then
  field "WebSocket API:" "UNREACHABLE (client exit $RC)"
  demote FAILED
else
  field "WebSocket schema:" "$(matter_ws_field "$WS_OUTPUT" server.schema_version)"
  SDK_VERSION="$(matter_ws_field "$WS_OUTPUT" server.sdk_version)"
  field "Matter SDK (matter.js):" "${SDK_VERSION:-unknown}"
  FABRIC_LABEL="$(matter_ws_field "$WS_OUTPUT" fabric_label)"
  field "Fabric label:" "${FABRIC_LABEL:-${MATTER_FABRIC_LABEL:-LISA Home}} (configured: ${MATTER_FABRIC_LABEL:-LISA Home})"
  BLE_ENABLED="$(matter_ws_field "$WS_OUTPUT" server.bluetooth_enabled)"
  field "Bluetooth available:" "${BLE_ENABLED:-unknown}"
  if [ "$BLE_ADAPTER" != "none" ] && [ "$BLE_ENABLED" != "true" ]; then
    demote DEGRADED
  fi
  NODE_COUNT="$(matter_ws_field "$WS_OUTPUT" node_count)"
  field "Commissioned nodes:" "${NODE_COUNT:-unknown}"

  # The commissioning credential is the Matter server's reserved default
  # entry; named entries never make commissioning ready.
  DEFAULT_CONFIGURED=0
  matter_ws_default_configured "$WS_OUTPUT" && DEFAULT_CONFIGURED=1
  DEFAULT_NAME="$(matter_ws_field "$WS_OUTPUT" default.network_name)"
  DEFAULT_XPAN="$(matter_ws_field "$WS_OUTPUT" default.ext_pan_id)"
  if [ "$DEFAULT_CONFIGURED" -eq 1 ]; then
    field "Default Thread credential:" "configured -> ${DEFAULT_NAME:-?} (extended PAN ID ${DEFAULT_XPAN:-?})"
  else
    field "Default Thread credential:" "NOT CONFIGURED"
    if lisa_has_service otbr; then
      demote DEGRADED
      echo "  New Thread commissioning is expected to fail; run: sudo ./lisa-edge matter thread sync"
    fi
  fi
  NAMED_COUNT=0
  LEGACY_NOTE=""
  while IFS=$'\t' read -r id name xpan; do
    [ "$id" = "default" ] && continue
    NAMED_COUNT=$((NAMED_COUNT + 1))
    if [ "$DEFAULT_CONFIGURED" -eq 1 ] &&
       [ "$name" = "$DEFAULT_NAME" ] && [ "${xpan^^}" = "${DEFAULT_XPAN^^}" ]; then
      LEGACY_NOTE=" (includes legacy duplicate '$id')"
    fi
  done < <(matter_ws_thread_entries "$WS_OUTPUT")
  if [ "$NAMED_COUNT" -gt 0 ]; then
    field "Named credentials:" "$NAMED_COUNT stored, not used for commissioning$LEGACY_NOTE"
  fi

  if lisa_has_service otbr && [ "$DEFAULT_CONFIGURED" -eq 1 ]; then
    if otbr_container_is_running; then
      OTBR_HEX="$(thread_otbr_active_dataset_hex_live)"
      if [ -n "$OTBR_HEX" ]; then
        OTBR_NAME="$(thread_dataset_network_name "$OTBR_HEX")"
        OTBR_XPAN="$(thread_dataset_ext_pan_id "$OTBR_HEX")"
        if [ "$DEFAULT_NAME" = "$OTBR_NAME" ] && [ "${DEFAULT_XPAN^^}" = "${OTBR_XPAN^^}" ]; then
          field "OTBR relationship:" "identity fields match (no detectable drift)"
        else
          field "OTBR relationship:" "DRIFT (OTBR: ${OTBR_NAME:-?}/${OTBR_XPAN:-?})"
          demote DEGRADED
        fi
      else
        field "OTBR relationship:" "unknown (OTBR dataset not readable)"
      fi
    else
      field "OTBR relationship:" "unknown (lisa-otbr not running)"
    fi
  fi
fi

BACKUP_DIR="${MATTER_DATA_BACKUP_DIR:-${DATA_ROOT:-/srv/lisa-edge}/backups/matter}"
LATEST="${MATTER_DATA_LATEST:-$BACKUP_DIR/latest.matter-data.tar.gz}"
if [ -L "$LATEST" ] || [ -f "$LATEST" ]; then
  LATEST_TARGET="$(readlink -f -- "$LATEST" 2>/dev/null || printf '%s' "$LATEST")"
  LATEST_TIME="$(date -u -r "$LATEST_TARGET" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  field "Latest Matter backup:" "$(basename "$LATEST_TARGET") ($LATEST_TIME)"
else
  field "Latest Matter backup:" "none"
  demote DEGRADED
fi

if command -v systemctl >/dev/null 2>&1; then
  TIMER_STATE="$(systemctl is-active lisa-matter-data-backup.timer 2>/dev/null || true)"
  field "Matter backup timer:" "${TIMER_STATE:-unknown}"
  [ "$TIMER_STATE" = "active" ] || demote DEGRADED
else
  field "Matter backup timer:" "no systemd"
fi

field "Status:" "$OVERALL"
