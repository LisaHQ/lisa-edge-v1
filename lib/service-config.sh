#!/usr/bin/env bash

# Validation for service-specific mandatory configuration. Sourced by
# ops/deploy/deploy.sh before any container is started, and by unit tests.
# Every function is pure (no docker, no filesystem writes); errors go to
# stderr and the calling deploy aborts. Keep this file free of side effects.

LISA_SERVICE_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LISA_SERVICE_CONFIG_LIB_DIR/thread-dataset.sh"

# IPv4 dotted-quad check (mirrors install/provisioning/lib/ui.sh semantics
# without die()); used for listen-address validation.
lisa_config_is_ipv4() {
  local value="$1" octet octets=()
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    [ "$octet" -le 255 ] || return 1
  done
  return 0
}

# THREAD_NETWORK_NAME: required when OTBR is selected. OpenThread limits the
# name to 16 BYTES; the shared validator distinguishes bytes from characters.
# Whitespace is additionally rejected because ot-ctl tokenizes arguments on
# spaces and a name that cannot be applied reliably must not be configured.
lisa_validate_thread_network_name() {
  local name="${1-}"
  thread_network_name_is_valid "$name" || return 1
  case "$name" in
    *[[:space:]]*)
      echo "THREAD_NETWORK_NAME must not contain whitespace (ot-ctl argument limits)." >&2
      return 1
      ;;
  esac
  return 0
}

# MATTER_LISTEN_ADDRESS: the unauthenticated WebSocket bind address. Must be
# an explicit IPv4 address. 0.0.0.0 is accepted only when the operator set
# it deliberately; the wizard and docs warn about it, and deploy prints a
# warning (handled by the caller).
lisa_validate_matter_listen_address() {
  local value="${1-}"
  if [ -z "$value" ]; then
    echo "MATTER_LISTEN_ADDRESS must not be empty (use 127.0.0.1 for local-only)." >&2
    return 1
  fi
  if ! lisa_config_is_ipv4 "$value"; then
    echo "MATTER_LISTEN_ADDRESS must be an IPv4 address, got: $value" >&2
    return 1
  fi
  return 0
}

# MATTER_PRIMARY_INTERFACE: empty (upstream auto-detect) or a plausible
# Linux interface name.
lisa_validate_matter_primary_interface() {
  local value="${1-}"
  [ -z "$value" ] && return 0
  if ! [[ "$value" =~ ^[A-Za-z0-9._-]{1,15}$ ]]; then
    echo "MATTER_PRIMARY_INTERFACE is not a valid interface name: $value" >&2
    return 1
  fi
  return 0
}

# MATTER_BLUETOOTH_ADAPTER: "none" (disable BLE) or an hci adapter number.
lisa_validate_matter_bluetooth_adapter() {
  local value="${1-}"
  case "$value" in
    none|"") return 0 ;;
  esac
  if ! [[ "$value" =~ ^[0-9]{1,2}$ ]]; then
    echo "MATTER_BLUETOOTH_ADAPTER must be an hci adapter number (e.g. 0) or 'none', got: $value" >&2
    return 1
  fi
  return 0
}

# MATTER_FABRIC_LABEL: shown on devices as the fabric's human label. The
# Matter specification caps fabric labels at 32 bytes.
lisa_validate_matter_fabric_label() {
  local value="${1-}"
  local byte_length
  if [ -z "$value" ]; then
    echo "MATTER_FABRIC_LABEL must not be empty." >&2
    return 1
  fi
  byte_length="$(printf '%s' "$value" | LC_ALL=C wc -c)"
  if [ "$byte_length" -gt 32 ]; then
    echo "MATTER_FABRIC_LABEL exceeds 32 bytes: $value" >&2
    return 1
  fi
  if [ "$(printf '%s' "$value" | LC_ALL=C tr -d '[:cntrl:]' | LC_ALL=C wc -c)" -ne "$byte_length" ]; then
    echo "MATTER_FABRIC_LABEL must not contain control characters." >&2
    return 1
  fi
  return 0
}

# Thread credential entry ID passed explicitly to `matter thread remove
# --id` (named legacy entries, or 'default' for the reserved default slot).
# NOT part of the configuration model: the managed commissioning credential
# is always the Matter server's reserved default entry, and the legacy
# MATTER_THREAD_CREDENTIAL_ID .env variable is ignored. Keep the value
# filesystem/JSON friendly: lowercase letters, digits, dot, dash,
# underscore; must start alphanumeric; max 64 chars.
lisa_validate_matter_thread_credential_id() {
  local value="${1-}"
  if [ -z "$value" ]; then
    echo "The credential ID must not be empty." >&2
    return 1
  fi
  if ! [[ "$value" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
    echo "The credential ID must match [a-z0-9][a-z0-9._-]{0,63}, got: $value" >&2
    return 1
  fi
  return 0
}

# Validate everything the matter service needs before deploy.
lisa_validate_matter_config() {
  local failed=0
  lisa_validate_matter_listen_address "${MATTER_LISTEN_ADDRESS:-127.0.0.1}" || failed=1
  lisa_validate_matter_primary_interface "${MATTER_PRIMARY_INTERFACE:-}" || failed=1
  lisa_validate_matter_bluetooth_adapter "${MATTER_BLUETOOTH_ADAPTER:-0}" || failed=1
  lisa_validate_matter_fabric_label "${MATTER_FABRIC_LABEL:-LISA Home}" || failed=1
  # MATTER_THREAD_CREDENTIAL_ID is intentionally NOT validated: it is a
  # legacy variable, ignored everywhere. Existing .env files that still
  # carry it must not break deploy/configure/update/health.
  return "$failed"
}

# Validate everything the otbr service needs before deploy.
lisa_validate_otbr_config() {
  local failed=0
  lisa_validate_thread_network_name "${THREAD_NETWORK_NAME:-LISA-HOME-01}" || failed=1
  return "$failed"
}
