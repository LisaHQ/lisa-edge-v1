#!/usr/bin/env bash

UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$UI_DIR/../../../lib/paths.sh"

info() { printf '[LISA] %s\n' "$*"; }
warn() { printf '[LISA] WARNING: %s\n' "$*" >&2; }
die() { printf '[LISA] ERROR: %s\n' "$*" >&2; exit 1; }

ask_value() {
  local variable="$1"
  local label="$2"
  local default_value="${3:-}"
  local value

  while :; do
    if [ -n "$default_value" ]; then
      read -r -p "$label [$default_value]: " value
      value="${value:-$default_value}"
    else
      read -r -p "$label: " value
    fi
    case "$value" in
      *"'"*) echo "Values must not contain single quotes ('). Try again." >&2; continue ;;
    esac
    break
  done
  printf -v "$variable" '%s' "$value"
}

ask_choice() {
  local variable="$1"
  local label="$2"
  local default_value="$3"
  shift 3
  local options=("$@")
  local option value index

  echo "$label:"
  index=1
  for option in "${options[@]}"; do
    printf '  %d) %s\n' "$index" "$option"
    index=$((index + 1))
  done
  while :; do
    read -r -p "Select a number or enter a custom value [$default_value]: " value
    value="${value:-$default_value}"
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le "${#options[@]}" ]; then
      value="${options[$((value - 1))]}"
    fi
    case "$value" in
      *"'"*) echo "Values must not contain single quotes ('). Try again." >&2; continue ;;
    esac
    break
  done
  printf -v "$variable" '%s' "$value"
}

# Strict numbered menu for a bounded enumeration: only a listed number (or
# Enter for the default) is accepted; free-form values are rejected and
# re-prompted. The selected option TEXT lands in the variable and the
# selected 1-based number in ASK_MENU_INDEX. On end-of-input without an
# acceptable answer the wizard fails with guidance instead of hanging.
ask_menu() {
  local variable="$1"
  local label="$2"
  local default_index="$3"
  shift 3
  local options=("$@")
  local option index value rc

  echo "$label:"
  index=1
  for option in "${options[@]}"; do
    printf '  %d) %s\n' "$index" "$option"
    index=$((index + 1))
  done
  while :; do
    rc=0
    read -r -p "Select a number [$default_index]: " value || rc=1
    value="${value:-$default_index}"
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le "${#options[@]}" ]; then
      ASK_MENU_INDEX="$value"
      printf -v "$variable" '%s' "${options[$((value - 1))]}"
      return 0
    fi
    [ "$rc" -eq 1 ] && die "A numbered selection between 1 and ${#options[@]} is required for: $label"
    echo "Select a number between 1 and ${#options[@]}." >&2
  done
}

ask_secret() {
  local variable="$1"
  local label="$2"
  local current_value="${3:-}"
  local value

  while :; do
    if [ -n "$current_value" ]; then
      read -r -s -p "$label [press Enter to keep current value]: " value
      echo
      value="${value:-$current_value}"
    else
      read -r -s -p "$label [leave empty to auto-generate/skip]: " value
      echo
    fi
    case "$value" in
      *"'"*) echo "Values must not contain single quotes ('). Try again." >&2; continue ;;
    esac
    break
  done
  printf -v "$variable" '%s' "$value"
}

# Render a yes/no prompt as "Question? [y/N] " (or "[Y/n] " for a yes
# default) with no trailing colon; colons are reserved for prompts that
# request a value, path, selection, or free-form input. Pure so tests can
# verify the format.
format_yes_no_prompt() {
  local label="$1"
  local default_value="${2:-no}"
  local hint="[y/N]"
  case "$label" in
    *\?) ;;
    *) label="$label?" ;;
  esac
  [ "$default_value" = "yes" ] && hint="[Y/n]"
  printf '%s %s ' "$label" "$hint"
}

ask_yes_no() {
  local variable="$1"
  local label="$2"
  local default_value="${3:-no}"
  local input

  while true; do
    read -r -p "$(format_yes_no_prompt "$label" "$default_value")" input
    input="${input:-$default_value}"
    case "${input,,}" in
      y|yes) printf -v "$variable" '%s' "yes"; return 0 ;;
      n|no) printf -v "$variable" '%s' "no"; return 0 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

require_absolute_path() {
  local label="$1"
  local value="$2"
  case "$value" in
    /*) ;;
    *) die "$label must be an absolute path: $value" ;;
  esac
  [ "$value" != "/" ] || die "$label cannot be /."
}

require_persistent_data_path() {
  local label="$1"
  local value="$2"
  lisa_validate_persistent_path "$label" "$value" || die "Unsafe persistent-data path."
}

require_port() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be numeric."
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$label must be between 1 and 65535."
}

require_bind_address() {
  local label="$1"
  local value="$2"
  local octet
  local octets=()

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "$label must be an IPv4 bind address."
  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    [ "$octet" -le 255 ] || die "$label contains an invalid IPv4 octet."
  done
}

generate_hex_secret() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}
