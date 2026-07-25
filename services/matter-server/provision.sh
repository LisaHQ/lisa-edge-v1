#!/usr/bin/env bash

# True when the lisa-matter container is currently running on this host.
matter_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  grep -qx lisa-matter <<<"$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
}

# Detect existing Matter data backups and stage the operator's choice as a
# one-shot pending marker consumed by data/init-or-restore.sh on deploy.
configure_matter_data_source() {
  local search_root="" selection="" answer choice item index
  local backups=() default_choice matter_running=0
  local pending_data pending_reset

  # shellcheck disable=SC1091
  . "$EDGE_REPO/services/matter-server/data/lib.sh"
  pending_data="$MATTER_DATA_BACKUP_DIR/$MATTER_PENDING_DATA_FILE_NAME"
  pending_reset="$MATTER_DATA_BACKUP_DIR/$MATTER_PENDING_RESET_FILE_NAME"
  matter_container_running && matter_running=1

  echo
  echo "--- Matter data detection ---"
  if [ -d "$MATTER_DATA_BACKUP_DIR" ]; then
    ask_choice search_root "Path to scan for Matter data backups" \
      "$MATTER_DATA_BACKUP_DIR" "$MATTER_DATA_BACKUP_DIR"
  else
    info "Default Matter data backup directory does not exist yet: $MATTER_DATA_BACKUP_DIR"
    ask_value search_root "Custom path to scan for Matter data backups (directory or .tar.gz file, Enter to skip)" ""
  fi

  if [ -z "$search_root" ]; then
    info "Skipping Matter data detection."
  elif [ -f "$search_root" ]; then
    selection="$search_root"
  elif [ -d "$search_root" ]; then
    mapfile -t backups < <(matter_list_data_backup_files "$search_root")
    if [ "${#backups[@]}" -gt 0 ]; then
      echo "Detected Matter data backups (newest first):"
      index=1
      for item in "${backups[@]}"; do
        printf '  %d) %s\n' "$index" "$item"
        index=$((index + 1))
      done
      echo "  r) Reset the Matter fabric instead (re-commission every device)"
      echo "  s) Skip (keep the current data behavior)"
      # Default to the safe choice when a Matter server is already running.
      default_choice=1
      [ "$matter_running" -eq 1 ] && default_choice=s
      while :; do
        read -r -p "Select a backup to restore, r, or s [$default_choice]: " choice
        choice="${choice:-$default_choice}"
        case "$choice" in
          r|R) selection="reset"; break ;;
          s|S) selection=""; break ;;
          *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#backups[@]}" ]; then
              selection="${backups[$((choice - 1))]}"
              break
            fi
            echo "Invalid selection. Try again." >&2
            ;;
        esac
      done
    else
      warn "No Matter data backup (*.tar.gz) was found under $search_root."
      ask_yes_no answer "Reset the Matter fabric on the next deployment" "no"
      [ "$answer" = "yes" ] && selection="reset"
    fi
  else
    warn "Matter data backup path does not exist: $search_root. Skipping detection."
  fi

  if [ -z "$selection" ]; then
    if [ "${DRY_RUN:-0}" -eq 0 ] &&
      { [ -e "$pending_data" ] || [ -e "$pending_reset" ]; }; then
      rm -f -- "$pending_data" "$pending_reset"
      info "Cleared a previously staged Matter data selection."
    fi
    return 0
  fi

  if [ "$selection" != "reset" ] && ! matter_data_archive_is_valid "$selection"; then
    die "Selected Matter data archive is not a readable tar.gz with safe relative members: $selection"
  fi

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    info "Dry run: Matter data selection is not staged."
    return 0
  fi

  mkdir -p "$MATTER_DATA_BACKUP_DIR"
  chmod 0700 "$MATTER_DATA_BACKUP_DIR"
  if [ "$selection" = "reset" ]; then
    rm -f -- "$pending_data"
    : > "$pending_reset"
    chmod 0600 "$pending_reset"
    info "Staged: the Matter fabric will be RESET on the next deploy."
    warn "Resetting the fabric requires re-commissioning every Matter device."
  else
    rm -f -- "$pending_reset"
    if [ ! "$selection" -ef "$pending_data" ]; then
      install -m 0600 -- "$selection" "$pending_data"
    fi
    info "Staged Matter data for restore on the next deploy: $selection"
  fi
  info "Deploy backs up the currently active fabric data before applying the change."
  info "To cancel before deploying, delete $pending_data and $pending_reset."
}

# Print available Bluetooth adapter numbers (hciN -> N), one per line.
matter_detect_bluetooth_adapters() {
  local adapter
  for adapter in /sys/class/bluetooth/hci*; do
    [ -e "$adapter" ] || continue
    basename "$adapter" | sed 's/^hci//'
  done
}

# Print administratively-up host interfaces usable as the Matter primary
# interface, excluding loopback and container/VPN/Thread virtual interfaces.
matter_detect_active_interfaces() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 |
    grep -Ev '^(lo|docker.*|br-.*|veth.*|wpan.*|tailscale.*|tun.*|tap.*|virbr.*)$' || true
}

# Selectable label for disabling BLE in the adapter menu.
MATTER_BLE_DISABLE_LABEL="none (disable BLE commissioning)"

# Normalize an adapter menu selection or free-form answer to the stored
# MATTER_BLUETOOTH_ADAPTER value: "hci0" -> "0", the disable label (or any
# 'none...' answer, or an empty answer) -> "none", numbers pass through.
matter_normalize_bluetooth_choice() {
  local choice="${1-}"
  case "$choice" in
    ""|none*) printf 'none\n' ;;
    hci*) printf '%s\n' "${choice#hci}" ;;
    *) printf '%s\n' "$choice" ;;
  esac
}

configure_matter_bluetooth() {
  local adapters=() adapter options=() default_option choice current
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/service-config.sh"
  mapfile -t adapters < <(matter_detect_bluetooth_adapters)
  current="${MATTER_BLUETOOTH_ADAPTER:-0}"
  if [ "${#adapters[@]}" -gt 0 ]; then
    for adapter in "${adapters[@]}"; do
      options+=("hci$adapter")
    done
    options+=("$MATTER_BLE_DISABLE_LABEL")
    default_option="hci${adapters[0]}"
    for adapter in "${adapters[@]}"; do
      [ "$adapter" = "$current" ] && default_option="hci$adapter"
    done
    [ "$current" = "none" ] && default_option="$MATTER_BLE_DISABLE_LABEL"
    ask_choice choice "Detected Bluetooth adapters for BLE commissioning" \
      "$default_option" "${options[@]}"
  else
    warn "No Bluetooth adapter found under /sys/class/bluetooth/."
    warn "BLE commissioning will be unavailable; Matter-over-Thread devices can still be commissioned via another BLE-capable controller."
    ask_value choice \
      "Bluetooth adapter (hciN or number, or 'none' to disable BLE)" \
      "none"
  fi
  MATTER_BLUETOOTH_ADAPTER="$(matter_normalize_bluetooth_choice "$choice")"
  lisa_validate_matter_bluetooth_adapter "$MATTER_BLUETOOTH_ADAPTER" ||
    die "Invalid MATTER_BLUETOOTH_ADAPTER."
  if [ "$MATTER_BLUETOOTH_ADAPTER" != "none" ] &&
    [ ! -d "/sys/class/bluetooth/hci$MATTER_BLUETOOTH_ADAPTER" ]; then
    warn "hci$MATTER_BLUETOOTH_ADAPTER does not exist yet; BLE will report degraded until it is present."
  fi
}

# Selectable label for keeping the upstream mDNS interface auto-detection.
MATTER_IF_AUTO_LABEL="auto-detect (recommended)"

configure_matter_network() {
  local interfaces=() interface answer
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/service-config.sh"
  info "127.0.0.1 keeps the WebSocket API host-local."
  info "For remote access, bind to a trusted host LAN address and firewall the port."
  while :; do
    ask_value MATTER_LISTEN_ADDRESS \
      "Matter WebSocket listen IPv4 address" "${MATTER_LISTEN_ADDRESS:-127.0.0.1}"
    lisa_validate_matter_listen_address "$MATTER_LISTEN_ADDRESS" && break
    echo "Try again." >&2
  done
  if [ "$MATTER_LISTEN_ADDRESS" = "0.0.0.0" ]; then
    warn "0.0.0.0 exposes the unauthenticated WebSocket API on every interface. Firewall TCP ${MATTER_SERVER_PORT:-5580}."
  fi

  mapfile -t interfaces < <(matter_detect_active_interfaces)
  if [ "${#interfaces[@]}" -gt 0 ]; then
    local if_options=("$MATTER_IF_AUTO_LABEL" "${interfaces[@]}")
    local default_if="$MATTER_IF_AUTO_LABEL" interface choice
    for interface in "${interfaces[@]}"; do
      [ "$interface" = "${MATTER_PRIMARY_INTERFACE:-}" ] && default_if="$interface"
    done
    ask_choice choice "Matter mDNS primary interface" "$default_if" "${if_options[@]}"
    if [ "$choice" = "$MATTER_IF_AUTO_LABEL" ]; then
      MATTER_PRIMARY_INTERFACE=""
    else
      MATTER_PRIMARY_INTERFACE="$choice"
    fi
  else
    ask_yes_no answer "Pin Matter mDNS to a specific host interface" "no"
    if [ "$answer" = "yes" ]; then
      ask_value MATTER_PRIMARY_INTERFACE "Primary interface name" "${MATTER_PRIMARY_INTERFACE:-}"
    else
      MATTER_PRIMARY_INTERFACE=""
    fi
  fi
  lisa_validate_matter_primary_interface "$MATTER_PRIMARY_INTERFACE" ||
    die "Invalid MATTER_PRIMARY_INTERFACE."
}

configure_matter_identity() {
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/service-config.sh"
  while :; do
    ask_value MATTER_FABRIC_LABEL \
      "Matter fabric label (stored on devices, max 32 UTF-8 bytes)" \
      "${MATTER_FABRIC_LABEL:-LISA Home}"
    lisa_validate_matter_fabric_label "$MATTER_FABRIC_LABEL" && break
    echo "Try again." >&2
  done
  # The Thread commissioning credential is always stored in the Matter
  # server's reserved default entry; there is no credential ID to configure
  # (the legacy MATTER_THREAD_CREDENTIAL_ID variable is ignored).
}

configure_matter() {
  local answer
  echo
  echo "--- Matter Server wizard ---"
  info "Matter Server (matterjs-server) uses host networking for mDNS commissioning and stores its fabric data under DATA_ROOT."
  info "The WebSocket API has no authentication; restrict TCP ${MATTER_SERVER_PORT:-5580} to trusted controller networks."
  ask_value MATTER_SERVER_PORT "Matter WebSocket/API port" "${MATTER_SERVER_PORT:-5580}"
  require_port MATTER_SERVER_PORT "$MATTER_SERVER_PORT"
  configure_matter_network
  configure_matter_bluetooth
  configure_matter_identity
  ask_value MATTER_DATA_BACKUP_DIR "Matter backup archive directory" "${MATTER_DATA_BACKUP_DIR:-$DATA_ROOT/backups/matter}"
  require_persistent_data_path "MATTER_DATA_BACKUP_DIR" "$MATTER_DATA_BACKUP_DIR"
  # Looks unused here, but lisa-first-boot.sh writes it into .env via env_line().
  # shellcheck disable=SC2034
  MATTER_DATA_LATEST="$MATTER_DATA_BACKUP_DIR/latest.matter-data.tar.gz"
  configure_matter_data_source
  ask_yes_no answer "Automatically restore the latest Matter data backup when the store is empty" "yes"
  # MATTER_AUTO_RESTORE_DATA looks unused here, but lisa-first-boot.sh writes it into .env via env_line().
  # shellcheck disable=SC2034
  [ "$answer" = "yes" ] && MATTER_AUTO_RESTORE_DATA=1 || MATTER_AUTO_RESTORE_DATA=0
}
