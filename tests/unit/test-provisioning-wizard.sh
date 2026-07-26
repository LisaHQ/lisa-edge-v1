#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WIZARD="$REPO_ROOT/install/provisioning/lisa-first-boot.sh"

# Remote tag discovery stays off in tests; the image menus render their
# offline fallback (current/template/cataloged choices).
export LISA_IMAGE_QUERY_DISABLE=1

output="$({
  printf '\n\n\n\n\n\n\n\n\n\n6\n'
  for _ in $(seq 1 14); do echo; done
} | bash "$WIZARD" --mode config-only --dry-run 2>&1)"

grep -qi 'Added mqtt because zigbee2mqtt depends on it' <<<"$output"
grep -q 'services: mqtt zigbee2mqtt' <<<"$output"
# Every selected service gets the shared image menu, even offline.
grep -q -- '--- MQTT (Mosquitto) container image ---' <<<"$output" || {
  echo "The MQTT image menu must be shown for a selected service." >&2
  exit 1
}
grep -q -- '--- Zigbee2MQTT container image ---' <<<"$output" || {
  echo "The Zigbee2MQTT image menu must be shown for a selected service." >&2
  exit 1
}

# --- zero-service selection: explicit 'none' is a valid choice ---------------
output="$(printf '\n\n\n\n\n\n\n\n\n\nnone\n' |
  bash "$WIZARD" --mode config-only --dry-run 2>&1)"
grep -q 'none) Select no service' <<<"$output" || {
  echo "The service menu must offer an explicit 'none' option." >&2
  exit 1
}
grep -q 'Selected services: (none)' <<<"$output" || {
  echo "Selecting 'none' must be accepted and reported as (none)." >&2
  exit 1
}
grep -q 'services: (none)' <<<"$output" || {
  echo "The review output must print (none) instead of a blank service list." >&2
  exit 1
}
grep -q '(none - no services selected)' <<<"$output" || {
  echo "The image review must handle an empty selection." >&2
  exit 1
}
grep -q "Bootstrap or repair this host" <<<"$output" || {
  echo "The config-only guidance must point host-level changes at Bootstrap/repair." >&2
  exit 1
}
grep -q "Host-level settings" <<<"$output" || {
  echo "The config-only guidance must state that Refresh services does not apply host-level settings." >&2
  exit 1
}
if grep -q 'Refresh services, or Bootstrap' <<<"$output"; then
  echo "The old ambiguous config-only guidance must be gone." >&2
  exit 1
fi

# --- pressing Enter preserves an explicitly empty current selection ----------
# (.env.template ships LISA_COMPOSE_SERVICES="" - explicitly empty.)
output="$(printf '\n\n\n\n\n\n\n\n\n\n\n' |
  bash "$WIZARD" --mode config-only --dry-run 2>&1)"
grep -q 'Current/default selection: (none)' <<<"$output" || {
  echo "An empty current selection must be shown as (none)." >&2
  exit 1
}
grep -q 'services: (none)' <<<"$output" || {
  echo "Pressing Enter must preserve the empty selection, not restore defaults." >&2
  exit 1
}

if conflict_output="$({
  printf '\n\n\n\n\n\n\n\n\n\n1 7\n'
  for _ in $(seq 1 7); do echo; done
  echo 1883
} | bash "$WIZARD" --mode config-only --dry-run 2>&1)"; then
  echo "Expected a selected-service port conflict to fail." >&2
  exit 1
fi
grep -q 'Port conflict' <<<"$conflict_output"

# shellcheck disable=SC1091
. "$REPO_ROOT/install/provisioning/lib/ui.sh"
if (require_bind_address TEST_BIND_ADDR 999.1.1.1) >/dev/null 2>&1; then
  echo "Expected an invalid bind address to fail." >&2
  exit 1
fi
if (require_persistent_data_path DATA_ROOT /etc/lisa-edge) >/dev/null 2>&1; then
  echo "Expected a protected persistent-data path to fail." >&2
  exit 1
fi

# --- yes/no prompt format: "Question? [y/N]" with no trailing colon ---
prompt="$(format_yes_no_prompt "Enable feature" no)"
[ "$prompt" = "Enable feature? [y/N] " ] || {
  echo "Yes/no prompts must render 'Question? [y/N] ' (got: '$prompt')." >&2
  exit 1
}
prompt="$(format_yes_no_prompt "Apply now" yes)"
[ "$prompt" = "Apply now? [Y/n] " ] || {
  echo "Yes/no prompts with a yes default must render '? [Y/n] ' (got: '$prompt')." >&2
  exit 1
}
# A label already ending in '?' must not get a second question mark.
prompt="$(format_yes_no_prompt "Ready?" no)"
[ "$prompt" = "Ready? [y/N] " ] || {
  echo "Yes/no prompts must not duplicate the question mark (got: '$prompt')." >&2
  exit 1
}
case "$prompt" in
  *:*) echo "Yes/no prompts must not contain a colon." >&2; exit 1 ;;
esac
# ask_yes_no still accepts the default on empty input with the new prompt.
YESNO=""
ask_yes_no YESNO "Enable feature" no <<< ""
[ "$YESNO" = "no" ] || { echo "ask_yes_no must keep the default on empty input." >&2; exit 1; }
ask_yes_no YESNO "Enable feature" yes <<< ""
[ "$YESNO" = "yes" ] || { echo "ask_yes_no must keep a yes default on empty input." >&2; exit 1; }

# --- ask_choice behavior ---
CHOICE=""
ask_choice CHOICE "Menu default" "beta" alpha beta >/dev/null <<< ""
[ "$CHOICE" = "beta" ] || { echo "ask_choice empty input must keep the default." >&2; exit 1; }
ask_choice CHOICE "Menu numeric" "alpha" alpha beta >/dev/null <<< "2"
[ "$CHOICE" = "beta" ] || { echo "ask_choice numeric input must select the option." >&2; exit 1; }
ask_choice CHOICE "Menu custom" "alpha" alpha beta >/dev/null <<< "gamma"
[ "$CHOICE" = "gamma" ] || { echo "ask_choice must accept a custom value." >&2; exit 1; }

# --- shared image selection through the OTBR service (release tags mocked,
# --- no network; full provider coverage lives in test-image-resolver.sh and
# --- test-image-advisories.sh) ---
# shellcheck disable=SC1091
. "$REPO_ROOT/services/registry.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/images.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/services/otbr/provision.sh"
unset LISA_IMAGE_QUERY_DISABLE

lisa_image_query_release_tags() {
  printf 'v2026.07.1\nv2026.06.0\nv2026.05.2\n'
}
OTBR_IMAGE="openthread/border-router:latest"
menu_output="$(lisa_configure_service_image otbr <<< "" 2>&1)"
grep -q '2) openthread/border-router:v2026.06.0' <<<"$menu_output" || {
  echo "OTBR image menu must list the available releases." >&2
  exit 1
}
OTBR_IMAGE="openthread/border-router:latest"
lisa_configure_service_image otbr <<< "" >/dev/null 2>&1
[ "$OTBR_IMAGE" = "openthread/border-router:v2026.07.1" ] || {
  echo "With a floating current image, the newest release must be the default, got: $OTBR_IMAGE" >&2
  exit 1
}
OTBR_IMAGE="openthread/border-router:latest"
lisa_configure_service_image otbr <<< "3" >/dev/null 2>&1
[ "$OTBR_IMAGE" = "openthread/border-router:v2026.05.2" ] || {
  echo "OTBR image menu must honor a numbered selection, got: $OTBR_IMAGE" >&2
  exit 1
}
# A pinned release stays the default, and the release menu is STILL shown.
OTBR_IMAGE="openthread/border-router:v2026.04.0"
menu_output="$(lisa_configure_service_image otbr <<< "" 2>&1)"
grep -q '1) openthread/border-router:v2026.07.1' <<<"$menu_output" || {
  echo "A tagged current image must not suppress the release menu." >&2
  exit 1
}
grep -qE '[0-9]+\) openthread/border-router:v2026.04.0 \[current\]' <<<"$menu_output" || {
  echo "The tagged current image must be listed and marked [current]." >&2
  exit 1
}
OTBR_IMAGE="openthread/border-router:v2026.04.0"
lisa_configure_service_image otbr <<< "" >/dev/null 2>&1
[ "$OTBR_IMAGE" = "openthread/border-router:v2026.04.0" ] || {
  echo "A pinned OTBR release must remain the default, got: $OTBR_IMAGE" >&2
  exit 1
}

# --- Matter wizard menus (detection mocked, no host access) ---
EDGE_REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO_ROOT/services/matter-server/provision.sh"

[ "$(matter_normalize_bluetooth_choice "hci1")" = "1" ] ||
  { echo "hciN choices must normalize to the adapter number." >&2; exit 1; }
[ "$(matter_normalize_bluetooth_choice "$MATTER_BLE_DISABLE_LABEL")" = "none" ] ||
  { echo "The disable label must normalize to 'none'." >&2; exit 1; }
[ "$(matter_normalize_bluetooth_choice "2")" = "2" ] ||
  { echo "Bare adapter numbers must pass through." >&2; exit 1; }

matter_detect_bluetooth_adapters() { printf '0\n1\n'; }
MATTER_BLUETOOTH_ADAPTER=""
bt_output="$(configure_matter_bluetooth <<< "" 2>&1)"
grep -q '1) hci0' <<<"$bt_output" && grep -q '2) hci1' <<<"$bt_output" || {
  echo "Bluetooth menu must number the detected adapters." >&2
  exit 1
}
grep -q '3) none (disable BLE commissioning)' <<<"$bt_output" || {
  echo "Bluetooth menu must offer a numbered 'none' option." >&2
  exit 1
}
configure_matter_bluetooth <<< "" >/dev/null 2>&1
[ "$MATTER_BLUETOOTH_ADAPTER" = "0" ] || {
  echo "Bluetooth menu default must select the first adapter, got: $MATTER_BLUETOOTH_ADAPTER" >&2
  exit 1
}
configure_matter_bluetooth <<< "3" >/dev/null 2>&1
[ "$MATTER_BLUETOOTH_ADAPTER" = "none" ] || {
  echo "Selecting the none option must disable BLE, got: $MATTER_BLUETOOTH_ADAPTER" >&2
  exit 1
}

matter_detect_active_interfaces() { printf 'enp1s0\nwlan0\n'; }
MATTER_LISTEN_ADDRESS="127.0.0.1"
MATTER_PRIMARY_INTERFACE=""
if_output="$(configure_matter_network <<< $'\n\n' 2>&1)"
grep -q '1) auto-detect (recommended)' <<<"$if_output" || {
  echo "Interface menu must offer auto-detect as the first option." >&2
  exit 1
}
grep -q '2) enp1s0' <<<"$if_output" && grep -q '3) wlan0' <<<"$if_output" || {
  echo "Interface menu must list the detected interfaces." >&2
  exit 1
}
configure_matter_network <<< $'\n\n' >/dev/null 2>&1
[ -z "$MATTER_PRIMARY_INTERFACE" ] || {
  echo "Interface menu default must keep auto-detect (empty), got: $MATTER_PRIMARY_INTERFACE" >&2
  exit 1
}
configure_matter_network <<< $'\n2\n' >/dev/null 2>&1
[ "$MATTER_PRIMARY_INTERFACE" = "enp1s0" ] || {
  echo "Interface menu must honor a numbered selection, got: $MATTER_PRIMARY_INTERFACE" >&2
  exit 1
}

echo "Provisioning-wizard tests passed."
