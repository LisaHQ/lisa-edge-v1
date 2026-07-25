#!/usr/bin/env bash
set -euo pipefail

# LISA Edge readiness checks (operator entry point: lisa-edge health).
#
# Outcome model:
#   HEALTHY   every required check passed
#   DEGRADED  the stack works, but something needs operator attention
#             (BLE unavailable, missing/drifted Matter Thread credential,
#             missing backup coverage). New Thread commissioning may fail.
#   FAILED    a required service or dependency is broken
#
# Exit codes (stable):
#   0  HEALTHY (also DEGRADED without --strict, so the systemd runtime unit
#      never tears down an otherwise functioning Matter network over a
#      commissioning-only degradation)
#   1  FAILED
#   2  usage error
#   3  DEGRADED (only with --strict)

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF2'
Usage: lisa-edge health [--strict]

Run readiness checks for the selected services and report an overall
HEALTHY, DEGRADED, or FAILED result.

Options:
  --strict    Exit nonzero (3) when the result is DEGRADED. Without it,
              DEGRADED exits 0 so the systemd runtime keeps running.
  -h, --help  Show this help.

Exit codes: 0 HEALTHY (or DEGRADED without --strict), 1 FAILED,
2 usage error, 3 DEGRADED (--strict).
EOF2
}

STRICT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ ! -f .env ]; then
  echo "Missing .env. Run 'sudo ./lisa-edge configure' (or setup) first." >&2
  echo "[LISA] Overall status: FAILED"
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
lisa_build_compose_files "$EDGE_REPO"
FILES=("${LISA_COMPOSE_FILES[@]}")

FAILURES=()
DEGRADATIONS=()
note_failed() { FAILURES+=("$1"); echo "[LISA] FAILED: $1" >&2; }
note_degraded() { DEGRADATIONS+=("$1"); echo "[LISA] DEGRADED: $1" >&2; }

# Internal wait tuning (also used by the test suite to keep runs fast).
HEALTH_ATTEMPTS="${LISA_HEALTH_WAIT_ATTEMPTS:-30}"
HEALTH_DELAY="${LISA_HEALTH_WAIT_DELAY_SECONDS:-2}"

check_tcp() {
  local host="$1"
  local port="$2"
  timeout 3 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

wait_for_tcp() {
  local label="$1"
  local host="$2"
  local port="$3"

  for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
    if check_tcp "$host" "$port"; then
      echo "[LISA] $label is accepting connections on $host:$port."
      return 0
    fi
    sleep "$HEALTH_DELAY"
  done

  note_failed "$label did not become ready on $host:$port."
  return 1
}

healthcheck_host() {
  local bind_address="$1"
  if [ "${HEALTHCHECK_BIND_ADDR:-auto}" != "auto" ]; then
    printf '%s\n' "$HEALTHCHECK_BIND_ADDR"
  elif [ "$bind_address" = "0.0.0.0" ]; then
    printf '127.0.0.1\n'
  else
    printf '%s\n' "$bind_address"
  fi
}

wait_for_container() {
  local name="$1"
  local state health
  for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)"
    if [ "$state" = "running" ] && { [ -z "$health" ] || [ "$health" = "healthy" ]; }; then
      echo "[LISA] Container ready: $name${health:+ ($health)}"
      return 0
    fi
    if [ "$state" = "exited" ] || [ "$state" = "dead" ] || [ "$health" = "unhealthy" ]; then
      docker logs --tail 50 "$name" >&2 2>/dev/null || true
      note_failed "container $name failed readiness (state=${state:-missing}, health=${health:-none})"
      return 1
    fi
    sleep "$HEALTH_DELAY"
  done
  note_failed "container readiness timed out: $name"
  return 1
}

check_tailscale() {
  if docker exec lisa-tailscale tailscale status --peers=false >/dev/null 2>&1; then
    echo "[LISA] Tailscale is authenticated and responding."
  elif [ -z "${TS_AUTHKEY:-}" ]; then
    # No auth key was configured: interactive login is expected, so an
    # unauthenticated tailscale must not fail readiness (or the systemd
    # deploy unit) on an otherwise healthy node.
    echo "[LISA] WARNING: Tailscale is running but not authenticated." >&2
    echo "[LISA] Authenticate with: docker exec lisa-tailscale tailscale up" >&2
  else
    note_failed "Tailscale is not authenticated or ready; check TS_AUTHKEY."
  fi
}

# True when this host runs systemd (timer coverage checks only make sense there).
has_systemd() {
  case "${LISA_HEALTH_ASSUME_SYSTEMD:-auto}" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

check_backup_timer() {
  local unit="$1" label="$2"
  has_systemd || return 0
  if [ "$(systemctl is-active "$unit" 2>/dev/null || true)" != "active" ]; then
    note_degraded "$label backup timer ($unit) is not active."
  fi
}

check_otbr() {
  # shellcheck disable=SC1091
  . "$EDGE_REPO/services/otbr/dataset/lib.sh"

  # RCP communication: the agent must answer, and the co-processor must
  # report a version. An agent that answers state queries is talking to the
  # RCP over spinel; use `rcp version` when the build supports it.
  local state rcp_version
  state="$(otbr_thread_state)"
  if [ -z "$state" ]; then
    note_failed "OTBR (otbr-agent) does not answer ot-ctl; RCP or agent is down."
    return
  fi
  rcp_version="$(timeout 5 docker exec lisa-otbr ot-ctl rcp version 2>/dev/null | head -n 1 | tr -d '\r' || true)"
  case "$rcp_version" in
    ""|*Error*|*InvalidCommand*) : ;; # older CLI builds; agent liveness already proven
    *) echo "[LISA] OTBR RCP: $rcp_version" ;;
  esac

  # Attachment.
  local attached=0
  for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
    state="$(otbr_thread_state)"
    case "$state" in
      leader|router|child) attached=1; break ;;
    esac
    sleep "$HEALTH_DELAY"
  done
  if [ "$attached" -eq 1 ]; then
    echo "[LISA] OTBR is attached with Thread state: $state"
  else
    note_failed "OTBR did not attach to a Thread network (last state: ${state:-unknown})."
    return
  fi

  # Dataset must be readable and unambiguous.
  local rc=0
  otbr_classify_active_dataset_retry 10 2 || rc=$?
  if [ "$rc" -ne 0 ]; then
    note_failed "OTBR dataset state is ambiguous or absent while attached."
    return
  fi
  OTBR_HEALTH_DATASET_HEX="$OTBR_ACTIVE_DATASET_HEX"

  check_backup_timer lisa-otbr-dataset-backup.timer "OTBR dataset"
}

check_matter() {
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/thread-dataset.sh"
  # shellcheck disable=SC1091
  . "$EDGE_REPO/services/matter-server/lib/ws.sh"

  local output rc=0
  output="$(MATTER_WS_CONNECT_TIMEOUT_MS=8000 MATTER_WS_RESPONSE_TIMEOUT_MS=10000 \
    matter_ws_run credentials)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      "$MATTER_WS_EXIT_SCHEMA")
        note_failed "Matter server WebSocket schema is older than $MATTER_WS_MIN_SCHEMA (check MATTER_SERVER_IMAGE)." ;;
      *)
        note_failed "Matter server WebSocket API is unreachable (client exit $rc)." ;;
    esac
    return
  fi
  echo "[LISA] Matter server WebSocket responds (schema $(matter_ws_field "$output" server.schema_version))."

  # BLE: degraded, not failed - network-only Matter control still works.
  if [ "$(lisa_matter_ble_adapter)" != "none" ]; then
    local ble
    ble="$(matter_ws_field "$output" server.bluetooth_enabled)"
    if [ "$ble" != "true" ]; then
      note_degraded "Bluetooth commissioning is unavailable (adapter hci$(lisa_matter_ble_adapter)); network-based Matter control still works."
    fi
  fi

  # The Matter server's RESERVED DEFAULT Thread credential must be
  # configured (thread_credentials_set=true plus a non-empty summary) and
  # match OTBR's identity fields. Named credentials are never consulted: a
  # named entry must not make commissioning look ready while the default is
  # missing or drifted.
  if lisa_has_service otbr; then
    local default_name default_xpan
    default_name="$(matter_ws_field "$output" default.network_name)"
    default_xpan="$(matter_ws_field "$output" default.ext_pan_id)"
    if ! matter_ws_default_configured "$output"; then
      note_degraded "the Matter server's default Thread credential is not configured; new Thread commissioning is expected to fail (run: sudo ./lisa-edge matter thread sync)."
    elif [ -n "${OTBR_HEALTH_DATASET_HEX:-}" ]; then
      local otbr_name otbr_xpan
      otbr_name="$(thread_dataset_network_name "$OTBR_HEALTH_DATASET_HEX")"
      otbr_xpan="$(thread_dataset_ext_pan_id "$OTBR_HEALTH_DATASET_HEX")"
      if [ "$default_name" = "$otbr_name" ] && [ "${default_xpan^^}" = "${otbr_xpan^^}" ]; then
        echo "[LISA] Thread network identity fields match between OTBR and the Matter server's default credential (no detectable drift)."
      else
        note_degraded "OTBR and Matter Thread identity fields differ (OTBR: ${otbr_name:-?}/${otbr_xpan:-?}, matter default: ${default_name:-?}/${default_xpan:-?}); new Thread commissioning is expected to fail (run: sudo ./lisa-edge matter thread sync)."
      fi
    fi
  fi

  check_backup_timer lisa-matter-data-backup.timer "Matter data"
}

echo "[LISA] Checking containers..."
docker compose --env-file .env "${FILES[@]}" ps

if lisa_has_service mqtt; then
  wait_for_container lisa-mqtt || true
fi

if lisa_has_service uptime-kuma; then
  wait_for_container lisa-uptime || true
fi

for service in $(lisa_selected_services); do
  case "$service" in
    ha) wait_for_container lisa-ha || true ;;
    matter) wait_for_container lisa-matter || true ;;
    otbr) wait_for_container lisa-otbr || true ;;
    zigbee2mqtt) wait_for_container lisa-zigbee2mqtt || true ;;
    node-red) wait_for_container lisa-node-red || true ;;
    vpn-tailscale) wait_for_container lisa-tailscale || true ;;
  esac
done

if lisa_has_service mqtt; then
  echo "[LISA] Checking MQTT port..."
  wait_for_tcp "MQTT" "$(healthcheck_host "${MQTT_BIND_ADDR:-127.0.0.1}")" "${MQTT_PORT:-1883}" || true
fi

if lisa_has_service uptime-kuma; then
  echo "[LISA] Checking Uptime Kuma port..."
  wait_for_tcp "Uptime Kuma" "$(healthcheck_host "${UPTIME_KUMA_BIND_ADDR:-127.0.0.1}")" "${UPTIME_KUMA_PORT:-3001}" || true
fi

if lisa_has_service ha; then
  wait_for_tcp "Home Assistant" 127.0.0.1 "${HOME_ASSISTANT_PORT:-8123}" || true
fi

if lisa_has_service matter; then
  MATTER_CHECK_HOST=127.0.0.1
  case "${MATTER_LISTEN_ADDRESS:-127.0.0.1}" in
    0.0.0.0|127.0.0.1|"") MATTER_CHECK_HOST=127.0.0.1 ;;
    *) MATTER_CHECK_HOST="${MATTER_LISTEN_ADDRESS}" ;;
  esac
  wait_for_tcp "Matter Server" "$MATTER_CHECK_HOST" "${MATTER_SERVER_PORT:-5580}" || true
fi

if lisa_has_service otbr; then
  check_otbr
fi

if lisa_has_service matter; then
  check_matter
fi

if lisa_has_service zigbee2mqtt; then
  wait_for_tcp "Zigbee2MQTT" "$(healthcheck_host "${ZIGBEE2MQTT_BIND_ADDR:-127.0.0.1}")" "${ZIGBEE2MQTT_PORT:-8080}" || true
fi

if lisa_has_service node-red; then
  wait_for_tcp "Node-RED" "$(healthcheck_host "${NODE_RED_BIND_ADDR:-127.0.0.1}")" "${NODE_RED_PORT:-1880}" || true
fi

if lisa_has_service vpn-tailscale; then
  check_tailscale
fi

# Print the web interfaces of the selected services, preferring the LAN
# address (with the host's mDNS name) and falling back to localhost-only
# with a hint about the bind-address variable that would expose it.
print_web_urls() {
  local lan_ip mdns_host entry label port bind_var
  lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  mdns_host="$(hostname 2>/dev/null || echo lisa-edge).local"

  local entries=()
  if lisa_has_service uptime-kuma; then
    entries+=("Uptime Kuma|${UPTIME_KUMA_PORT:-3001}|UPTIME_KUMA_BIND_ADDR")
  fi
  if lisa_has_service ha; then
    entries+=("Home Assistant|${HOME_ASSISTANT_PORT:-8123}|")
  fi
  if lisa_has_service matter; then
    entries+=("Matter Server|${MATTER_SERVER_PORT:-5580}|")
  fi
  if lisa_has_service otbr; then
    entries+=("OTBR Web|80|")
  fi
  if lisa_has_service zigbee2mqtt; then
    entries+=("Zigbee2MQTT|${ZIGBEE2MQTT_PORT:-8080}|ZIGBEE2MQTT_BIND_ADDR")
  fi
  if lisa_has_service node-red; then
    entries+=("Node-RED|${NODE_RED_PORT:-1880}|NODE_RED_BIND_ADDR")
  fi
  [ "${#entries[@]}" -gt 0 ] || return 0

  echo "[LISA] Web interfaces:"
  for entry in "${entries[@]}"; do
    IFS='|' read -r label port bind_var <<<"$entry"
    if [ -n "$lan_ip" ] && check_tcp "$lan_ip" "$port"; then
      echo "[LISA]   $label: http://$mdns_host:$port  (http://$lan_ip:$port)"
    elif check_tcp 127.0.0.1 "$port"; then
      if [ -n "$bind_var" ]; then
        echo "[LISA]   $label: http://127.0.0.1:$port  (localhost only; set $bind_var=0.0.0.0 in .env and redeploy to expose it on the LAN)"
      else
        echo "[LISA]   $label: http://127.0.0.1:$port  (localhost only)"
      fi
    fi
  done
}
print_web_urls

echo
if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "[LISA] Failed checks:"
  printf '[LISA]   - %s\n' "${FAILURES[@]}"
fi
if [ "${#DEGRADATIONS[@]}" -gt 0 ]; then
  echo "[LISA] Degradations:"
  printf '[LISA]   - %s\n' "${DEGRADATIONS[@]}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "[LISA] Overall status: FAILED"
  exit 1
fi
if [ "${#DEGRADATIONS[@]}" -gt 0 ]; then
  echo "[LISA] Overall status: DEGRADED"
  echo "[LISA] The stack is running, but the items above need attention."
  if [ "$STRICT" -eq 1 ]; then
    exit 3
  fi
  exit 0
fi
echo "[LISA] Overall status: HEALTHY"
