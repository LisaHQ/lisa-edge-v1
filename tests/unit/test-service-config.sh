#!/usr/bin/env bash
set -euo pipefail

# Service-specific configuration validation and Matter compose-slice
# selection: Thread network name limits, listen address, primary interface,
# Bluetooth adapter, fabric label, credential ID, and the conditional
# BLE/primary-interface compose files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
. "$REPO_ROOT/lib/service-config.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/compose.sh"

fail() {
  echo "SERVICE CONFIG TEST ERROR: $*" >&2
  exit 1
}

expect_ok() { "$@" 2>/dev/null || fail "expected valid: $*"; }
expect_bad() {
  if "$@" 2>/dev/null; then
    fail "expected rejection: $*"
  fi
}

# --- Thread network name ---
expect_ok lisa_validate_thread_network_name "LISA-HOME-01"
expect_ok lisa_validate_thread_network_name "ABCDEFGHIJKLMNOP"       # 16 bytes
expect_bad lisa_validate_thread_network_name ""
expect_bad lisa_validate_thread_network_name "ABCDEFGHIJKLMNOPQ"     # 17 bytes
expect_bad lisa_validate_thread_network_name "ééééééééa"             # 17 bytes UTF-8
expect_bad lisa_validate_thread_network_name "HAS SPACE"
expect_bad lisa_validate_thread_network_name "$(printf 'a\tb')"

# --- listen address ---
expect_ok lisa_validate_matter_listen_address "127.0.0.1"
expect_ok lisa_validate_matter_listen_address "192.168.10.2"
expect_ok lisa_validate_matter_listen_address "0.0.0.0"
expect_bad lisa_validate_matter_listen_address ""
expect_bad lisa_validate_matter_listen_address "localhost"
expect_bad lisa_validate_matter_listen_address "999.1.1.1"
expect_bad lisa_validate_matter_listen_address "fd00::1"

# --- primary interface ---
expect_ok lisa_validate_matter_primary_interface ""
expect_ok lisa_validate_matter_primary_interface "enp1s0"
expect_bad lisa_validate_matter_primary_interface "bad iface"
expect_bad lisa_validate_matter_primary_interface "waytoolonginterfacename"

# --- bluetooth adapter ---
expect_ok lisa_validate_matter_bluetooth_adapter "0"
expect_ok lisa_validate_matter_bluetooth_adapter "12"
expect_ok lisa_validate_matter_bluetooth_adapter "none"
expect_bad lisa_validate_matter_bluetooth_adapter "hci0"
expect_bad lisa_validate_matter_bluetooth_adapter "-1"

# --- fabric label ---
expect_ok lisa_validate_matter_fabric_label "LISA Home"
expect_bad lisa_validate_matter_fabric_label ""
expect_bad lisa_validate_matter_fabric_label "$(printf 'x%.0s' $(seq 1 33))"
expect_bad lisa_validate_matter_fabric_label "$(printf 'a\nb')"

# --- credential id (explicit `matter thread remove --id` values only) ---
expect_ok lisa_validate_matter_thread_credential_id "lisa-home-01"
expect_ok lisa_validate_matter_thread_credential_id "default"
expect_bad lisa_validate_matter_thread_credential_id ""
expect_bad lisa_validate_matter_thread_credential_id "Has-Upper"
expect_bad lisa_validate_matter_thread_credential_id "-leading-dash"
expect_bad lisa_validate_matter_thread_credential_id "spaces here"
expect_bad lisa_validate_matter_thread_credential_id "$(printf 'x%.0s' $(seq 1 65))"

# --- aggregate validators ---
(
  MATTER_LISTEN_ADDRESS=127.0.0.1 MATTER_PRIMARY_INTERFACE="" \
  MATTER_BLUETOOTH_ADAPTER=0 MATTER_FABRIC_LABEL="LISA Home" \
  lisa_validate_matter_config
) || fail "aggregate matter validation must pass with defaults"
# The legacy MATTER_THREAD_CREDENTIAL_ID variable is ignored: even a value
# that would never validate must not break configuration validation.
(
  MATTER_LISTEN_ADDRESS=127.0.0.1 MATTER_PRIMARY_INTERFACE="" \
  MATTER_BLUETOOTH_ADAPTER=0 MATTER_FABRIC_LABEL="LISA Home" \
  MATTER_THREAD_CREDENTIAL_ID="INVALID VALUE" \
  lisa_validate_matter_config
) || fail "a legacy MATTER_THREAD_CREDENTIAL_ID must be ignored, not fatal"
if (MATTER_LISTEN_ADDRESS=nonsense lisa_validate_matter_config) 2>/dev/null; then
  fail "aggregate matter validation must fail on a bad listen address"
fi
(THREAD_NETWORK_NAME=LISA-HOME-01 lisa_validate_otbr_config) ||
  fail "aggregate otbr validation must pass"

# --- BLE adapter resolution ---
[ "$(MATTER_BLUETOOTH_ADAPTER= lisa_matter_ble_adapter)" = "none" ] ||
  fail "empty adapter must resolve to none"
[ "$(MATTER_BLUETOOTH_ADAPTER=none lisa_matter_ble_adapter)" = "none" ] ||
  fail "'none' must resolve to none"
[ "$(unset MATTER_BLUETOOTH_ADAPTER; lisa_matter_ble_adapter)" = "0" ] ||
  fail "unset adapter must default to 0"

# --- compose slice selection ---
compose_files() {
  lisa_build_compose_files "$REPO_ROOT" >/dev/null
  printf '%s\n' "${LISA_COMPOSE_FILES[@]}"
}

LISA_COMPOSE_SERVICES="matter"
unset MATTER_BLUETOOTH_ADAPTER MATTER_PRIMARY_INTERFACE || true
files="$(compose_files)"
grep -q 'compose.ble.yml' <<<"$files" || fail "default selection must include the BLE slice"
if grep -q 'compose.primary-interface.yml' <<<"$files"; then
  fail "primary-interface slice must be absent when the variable is empty"
fi

MATTER_BLUETOOTH_ADAPTER=none
files="$(compose_files)"
if grep -q 'compose.ble.yml' <<<"$files"; then
  fail "BLE slice must be absent when MATTER_BLUETOOTH_ADAPTER=none"
fi

MATTER_BLUETOOTH_ADAPTER=0
MATTER_PRIMARY_INTERFACE=enp1s0
files="$(compose_files)"
grep -q 'compose.ble.yml' <<<"$files" || fail "BLE slice must be present for adapter 0"
grep -q 'compose.primary-interface.yml' <<<"$files" ||
  fail "primary-interface slice must be present when the variable is set"

echo "Service configuration tests passed."
