#!/usr/bin/env bash
set -euo pipefail

# Focused Matter-over-Thread diagnostics (operator entry point:
# lisa-edge doctor matter-thread). Read-only and secret-safe: never prints
# the Thread dataset, network key, PSKc, or Matter fabric credentials, and
# every failed check comes with an actionable next step.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge doctor matter-thread

Run read-only Matter-over-Thread diagnostics: OTBR, RCP, Thread attachment,
IPv6 forwarding, mDNS, Matter server WebSocket, Thread credentials, BLE,
and backup coverage. Secrets are never printed.

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

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS  %s\n' "$1"; }
warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf 'WARN  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '      Next: %s\n' "$2"; fi
}
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '      Next: %s\n' "$2"; fi
}

echo "=== LISA Edge doctor: matter-thread ==="

if [ ! -f .env ]; then
  fail "configuration missing (.env)" "run: sudo ./lisa-edge configure"
  exit 1
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
. "$EDGE_REPO/services/otbr/dataset/lib.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/services/matter-server/lib/ws.sh"

# --- service selection --------------------------------------------------
OTBR_SELECTED=0
MATTER_SELECTED=0
lisa_has_service otbr && OTBR_SELECTED=1
lisa_has_service matter && MATTER_SELECTED=1
if [ "$OTBR_SELECTED" -eq 1 ] && [ "$MATTER_SELECTED" -eq 1 ]; then
  pass "services selected: otbr + matter"
else
  warn "matter-over-thread needs both services selected (otbr=$OTBR_SELECTED matter=$MATTER_SELECTED)" \
    "run: sudo ./lisa-edge configure and select both, then deploy"
fi

# --- docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  pass "docker is available"
else
  fail "docker is not available or the daemon is not running" \
    "systemctl status docker; sudo ./lisa-edge bootstrap"
  exit 1
fi

container_state() {
  docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || echo absent
}

# --- OTBR ------------------------------------------------------------------
OTBR_DATASET_HEX=""
OTBR_NAME=""
OTBR_XPAN=""
if [ "$OTBR_SELECTED" -eq 1 ]; then
  state="$(container_state lisa-otbr)"
  if [ "${state%%/*}" = "running" ]; then
    pass "lisa-otbr container is running ($state)"
  else
    fail "lisa-otbr container is not running ($state)" \
      "sudo ./lisa-edge deploy; docker logs --tail 50 lisa-otbr"
  fi

  radio="${THREAD_RADIO_DEVICE:-}"
  if [ -n "$radio" ] && [ -e "$radio" ]; then
    pass "RCP device exists: $radio"
    if [ -r "$radio" ] && [ -w "$radio" ]; then
      pass "RCP device is accessible (r/w)"
    else
      warn "RCP device is not readable/writable by this user" \
        "run diagnostics with sudo; check udev permissions on $radio"
    fi
  else
    fail "RCP device is missing: ${radio:-unset}" \
      "ls -l /dev/serial/by-id/; re-run: sudo ./lisa-edge configure"
  fi

  if [ "${state%%/*}" = "running" ]; then
    if timeout 5 docker exec lisa-otbr ot-ctl state >/dev/null 2>&1; then
      pass "otbr-agent answers ot-ctl"
      thread_state="$(otbr_thread_state)"
      case "$thread_state" in
        leader|router|child) pass "Thread attached (role: $thread_state)" ;;
        detached) warn "Thread role is detached" "docker exec lisa-otbr ot-ctl state; wait for attach or check the dataset" ;;
        *) fail "Thread is not running (state: ${thread_state:-unknown})" "docker logs --tail 50 lisa-otbr" ;;
      esac
      rc=0
      otbr_classify_active_dataset_retry 5 1 || rc=$?
      case "$rc" in
        0)
          OTBR_DATASET_HEX="$OTBR_ACTIVE_DATASET_HEX"
          OTBR_NAME="$(thread_dataset_network_name "$OTBR_DATASET_HEX")"
          OTBR_XPAN="$(thread_dataset_ext_pan_id "$OTBR_DATASET_HEX")"
          pass "active dataset present (network: ${OTBR_NAME:-?}, extended PAN ID: ${OTBR_XPAN:-?})"
          ;;
        1) fail "no active Thread dataset" "sudo ./lisa-edge otbr network create (or restore a backup)" ;;
        *) fail "active dataset state is ambiguous" "docker exec lisa-otbr ot-ctl dataset active -x (do NOT deploy until this answers)" ;;
      esac
    else
      fail "otbr-agent does not answer ot-ctl (RCP or agent problem)" \
        "docker logs --tail 50 lisa-otbr; check THREAD_RADIO_DEVICE/THREAD_RADIO_URL"
    fi
  fi

  # IPv6 forwarding and required sysctls (written by bootstrap thread prep).
  for sysctl_key in net.ipv6.conf.all.forwarding net.ipv4.ip_forward; do
    value="$(sysctl -n "$sysctl_key" 2>/dev/null || echo missing)"
    if [ "$value" = "1" ]; then
      pass "sysctl $sysctl_key=1"
    else
      fail "sysctl $sysctl_key=$value (Thread border routing needs 1)" \
        "sudo ./lisa-edge bootstrap (thread host prep) or: sudo sysctl -w $sysctl_key=1"
    fi
  done

  backbone="${OTBR_BACKBONE_IF:-}"
  if [ -n "$backbone" ] && [ -d "/sys/class/net/$backbone" ]; then
    oper="$(cat "/sys/class/net/$backbone/operstate" 2>/dev/null || echo unknown)"
    if [ "$oper" = "up" ]; then
      pass "backbone interface $backbone is up"
    else
      fail "backbone interface $backbone state: $oper" "ip link show $backbone"
    fi
  else
    fail "backbone interface does not exist: ${backbone:-unset}" \
      "ip -o link show; re-run: sudo ./lisa-edge configure"
  fi
fi

# --- Matter server -----------------------------------------------------------
MATTER_WS_OUTPUT=""
if [ "$MATTER_SELECTED" -eq 1 ]; then
  state="$(container_state lisa-matter)"
  if [ "${state%%/*}" = "running" ]; then
    pass "lisa-matter container is running ($state)"
  else
    fail "lisa-matter container is not running ($state)" \
      "sudo ./lisa-edge deploy; docker logs --tail 50 lisa-matter"
  fi

  matter_host="$(matter_ws_host)"
  matter_port="${MATTER_SERVER_PORT:-5580}"
  if timeout 3 bash -c "</dev/tcp/$matter_host/$matter_port" >/dev/null 2>&1; then
    pass "Matter TCP port $matter_host:$matter_port accepts connections"
  else
    fail "Matter TCP port $matter_host:$matter_port is closed" \
      "docker logs --tail 30 lisa-matter; check MATTER_LISTEN_ADDRESS/MATTER_SERVER_PORT"
  fi

  if [ "${state%%/*}" = "running" ]; then
    rc=0
    MATTER_WS_OUTPUT="$(MATTER_WS_CONNECT_TIMEOUT_MS=5000 MATTER_WS_RESPONSE_TIMEOUT_MS=8000 \
      matter_ws_run status 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      schema="$(matter_ws_field "$MATTER_WS_OUTPUT" server.schema_version)"
      pass "Matter WebSocket API responds (schema $schema)"
      label="$(matter_ws_field "$MATTER_WS_OUTPUT" fabric_label)"
      if [ "$label" = "${MATTER_FABRIC_LABEL:-LISA Home}" ]; then
        pass "fabric label: '$label'"
      else
        warn "fabric label is '${label:-unset}' (configured: '${MATTER_FABRIC_LABEL:-LISA Home}')" \
          "sudo ./lisa-edge deploy applies DEFAULT_FABRIC_LABEL; a fabric created before this setting keeps its old label until reset"
      fi

      # Readiness is decided by the RESERVED DEFAULT credential only; a
      # named credential never makes commissioning ready.
      default_configured=0
      matter_ws_default_configured "$MATTER_WS_OUTPUT" && default_configured=1
      default_name="$(matter_ws_field "$MATTER_WS_OUTPUT" default.network_name)"
      default_xpan="$(matter_ws_field "$MATTER_WS_OUTPUT" default.ext_pan_id)"
      if [ "$default_configured" -eq 1 ]; then
        pass "default Thread credential is configured (network: ${default_name:-?})"
        if [ -n "$OTBR_XPAN" ]; then
          if [ "$default_name" = "$OTBR_NAME" ] && [ "${default_xpan^^}" = "${OTBR_XPAN^^}" ]; then
            pass "OTBR and Matter default-credential identity fields match (no detectable drift)"
          else
            fail "OTBR/Matter Thread identity drift (OTBR: ${OTBR_NAME:-?}/${OTBR_XPAN:-?}, matter default: ${default_name:-?}/${default_xpan:-?})" \
              "sudo ./lisa-edge matter thread sync"
          fi
        fi
      else
        fail "the Matter server's default Thread credential is not configured (thread_credentials_set=false or empty summary)" \
          "sudo ./lisa-edge matter thread sync"
      fi
      while IFS=$'\t' read -r id name xpan; do
        [ "$id" = "default" ] && continue
        if [ "$default_configured" -eq 1 ] &&
           [ "$name" = "$default_name" ] && [ "${xpan^^}" = "${default_xpan^^}" ]; then
          warn "legacy named Thread credential '$id' duplicates the default (not used for commissioning)" \
            "after verifying the default: sudo ./lisa-edge matter thread remove --id $id"
        else
          warn "named Thread credential '$id' is stored (network: ${name:-?}); not used for commissioning" \
            "keep it only if another commissioner needs it; remove with: sudo ./lisa-edge matter thread remove --id $id"
        fi
      done < <(matter_ws_thread_entries "$MATTER_WS_OUTPUT")
    else
      fail "Matter WebSocket API check failed (client exit $rc)" \
        "sudo ./lisa-edge matter status; docker logs --tail 30 lisa-matter"
    fi
  fi

  # Supplemental log-line comparison: the startup log carries channel,
  # PAN ID, and mesh-local prefix, which get_all_credentials does not.
  if [ -n "$OTBR_DATASET_HEX" ] && [ "${state%%/*}" = "running" ]; then
    matter_log_line="$(thread_matter_registered_line_live)"
    if [ -n "$matter_log_line" ]; then
      if drift_details="$(thread_dataset_drift_details "$OTBR_DATASET_HEX" "$matter_log_line")"; then
        pass "supplemental log check: channel/PAN ID/prefix fields match where available"
      else
        warn "supplemental log check found differing fields (may predate the last sync):"           "sudo ./lisa-edge matter thread sync, then restart-free verification via: sudo ./lisa-edge matter thread status"
        printf '      | %s
' "$drift_details"
      fi
    fi
  fi

  # Bluetooth.
  ble_adapter="$(lisa_matter_ble_adapter)"
  if [ "$ble_adapter" = "none" ]; then
    pass "BLE commissioning disabled by configuration (MATTER_BLUETOOTH_ADAPTER=none)"
  else
    if [ -d "/sys/class/bluetooth/hci$ble_adapter" ]; then
      pass "Bluetooth adapter hci$ble_adapter exists on the host"
    else
      fail "Bluetooth adapter hci$ble_adapter does not exist" \
        "ls /sys/class/bluetooth/; set MATTER_BLUETOOTH_ADAPTER to an existing adapter or 'none'"
    fi
    if [ -n "$MATTER_WS_OUTPUT" ]; then
      ble="$(matter_ws_field "$MATTER_WS_OUTPUT" server.bluetooth_enabled)"
      if [ "$ble" = "true" ]; then
        pass "Matter server reports Bluetooth enabled"
      else
        warn "Matter server reports Bluetooth unavailable (network-only commissioning still works)" \
          "sudo btmon during a commissioning attempt; check compose.ble.yml is applied (root + NET_RAW/NET_ADMIN)"
      fi
    fi
  fi
fi

# --- mDNS / discovery ---------------------------------------------------------
if command -v avahi-daemon >/dev/null 2>&1 || systemctl is-active avahi-daemon >/dev/null 2>&1; then
  if systemctl is-active avahi-daemon >/dev/null 2>&1; then
    pass "avahi-daemon is active"
  else
    warn "avahi-daemon is installed but not active" "sudo systemctl start avahi-daemon"
  fi
else
  warn "avahi-daemon not found (mDNS/service discovery may rely on other responders)" \
    "sudo ./lisa-edge bootstrap installs it with thread host prep"
fi
if command -v avahi-browse >/dev/null 2>&1; then
  if timeout 5 avahi-browse -pt _meshcop._udp 2>/dev/null | grep -q '^='; then
    pass "_meshcop._udp border-router service is discoverable via mDNS"
  else
    warn "_meshcop._udp not discovered within 5s (may be VLAN filtering or OTBR down)" \
      "timeout 10 avahi-browse -rt _meshcop._udp; check IGMP/mDNS across VLANs"
  fi
fi

# --- recent bounded error logs -------------------------------------------------
for name in lisa-otbr lisa-matter; do
  if grep -qx "$name" <<<"$(docker ps --format '{{.Names}}' 2>/dev/null || true)"; then
    errors="$(docker logs --tail 200 "$name" 2>&1 | grep -iE 'error|fatal|fail' | tail -n 5 || true)"
    if [ -n "$errors" ]; then
      warn "recent errors in $name logs (last 5 shown):" "docker logs --tail 200 $name"
      printf '      | %s\n' "$errors" | head -n 6
    else
      pass "no recent errors in $name logs (last 200 lines)"
    fi
  fi
done

# --- backups -----------------------------------------------------------------
if [ "$OTBR_SELECTED" -eq 1 ]; then
  otbr_latest="${OTBR_DATASET_BACKUP_DIR:-${DATA_ROOT:-/srv/lisa-edge}/backups/otbr}/latest.dataset.hex"
  if [ -e "$otbr_latest" ]; then
    pass "latest OTBR dataset backup: $(readlink -f -- "$otbr_latest" 2>/dev/null | xargs -r basename)"
  else
    fail "no OTBR dataset backup exists" "sudo ./lisa-edge otbr dataset backup"
  fi
fi
if [ "$MATTER_SELECTED" -eq 1 ]; then
  matter_latest="${MATTER_DATA_LATEST:-${MATTER_DATA_BACKUP_DIR:-${DATA_ROOT:-/srv/lisa-edge}/backups/matter}/latest.matter-data.tar.gz}"
  if [ -e "$matter_latest" ]; then
    pass "latest Matter data backup: $(readlink -f -- "$matter_latest" 2>/dev/null | xargs -r basename)"
  else
    warn "no Matter data backup exists yet (created automatically once the fabric has state)" \
      "services/matter-server/data/backup.sh --label manual"
  fi
fi
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  for timer in lisa-otbr-dataset-backup.timer lisa-matter-data-backup.timer; do
    if [ "$(systemctl is-active "$timer" 2>/dev/null || true)" = "active" ]; then
      pass "backup timer active: $timer"
    else
      warn "backup timer not active: $timer" "sudo ops/deploy/install-systemd.sh"
    fi
  done
fi

echo
echo "=== doctor matter-thread summary: $PASS_COUNT pass, $WARN_COUNT warn, $FAIL_COUNT fail ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
