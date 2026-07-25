#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_OUTPUT="$EDGE_REPO/.env"
MODE=""
BACKUP_ARCHIVE=""
DRY_RUN=0
RESTORED_FROM_BACKUP=0

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/ops/backup-restore/lib/backup.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/images.sh"
for wizard in "$EDGE_REPO"/services/*/provision.sh; do
  [ -f "$wizard" ] || continue
  # shellcheck disable=SC1090
  . "$wizard"
done

IFS=' ' read -r -a SERVICE_IDS <<< "$LISA_ALL_SERVICES"
ALL_SERVICE_NAMES="${SERVICE_IDS[*]}"

usage() {
  cat <<'EOF'
Usage: sudo ./lisa-edge setup [options]

Interactive setup: configuration, restore, service refresh, host bootstrap,
and host repair.

Options:
  --mode MODE       fresh, restore-usb, restore-path, config-only,
                    refresh, or repair
  --backup PATH     Backup archive or directory for restore-path
  --output PATH     Write environment file to PATH (default: repo .env)
  --dry-run         Run the wizard without writing or applying anything
  -h, --help        Show this help
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --backup) BACKUP_ARCHIVE="${2:-}"; shift 2 ;;
      --output) ENV_OUTPUT="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

load_environment() {
  set -a
  # shellcheck disable=SC1091
  . "$EDGE_REPO/.env.template"
  if [ -f "$EDGE_REPO/.env" ]; then
    [ -r "$EDGE_REPO/.env" ] || die "Cannot read $EDGE_REPO/.env (try again with sudo)."
    # shellcheck disable=SC1091
    . "$EDGE_REPO/.env"
  fi
  set +a
}

choose_mode() {
  local choice
  [ -n "$MODE" ] && return 0

  echo
  echo "Setup actions:"
  echo "  1) Fresh setup"
  echo "  2) Restore from removable storage (USB)"
  echo "  3) Restore from a mounted local/NAS path"
  echo "  4) Edit configuration only (nothing is applied)"
  echo "  5) Refresh services using the current configuration"
  echo "  6) Bootstrap or repair this host using the current configuration"
  read -r -p "Select action [1]: " choice
  case "${choice:-1}" in
    1) MODE=fresh ;;
    2) MODE=restore-usb ;;
    3) MODE=restore-path ;;
    4) MODE=config-only ;;
    5) MODE=refresh ;;
    6) MODE=repair ;;
    *) die "Invalid setup action." ;;
  esac
}

service_description() {
  lisa_service_description "$1"
}

contains_word() {
  local list="$1"
  local wanted="$2"
  case " $list " in *" $wanted "*) return 0 ;; *) return 1 ;; esac
}

select_services() {
  local current="${LISA_COMPOSE_SERVICES:-$LISA_DEFAULT_SERVICES}"
  local input token service dependency selected="" normalized_current=""
  local index=1

  if [ "$current" = "all" ]; then
    current="$ALL_SERVICE_NAMES"
  else
    for token in $current; do
      service="$(lisa_normalize_service_id "$token")"
      contains_word "$ALL_SERVICE_NAMES" "$service" || die "Unknown configured service: $token"
      contains_word "$normalized_current" "$service" ||
        normalized_current="${normalized_current:+$normalized_current }$service"
    done
    current="$normalized_current"
  fi

  echo
  echo "Available services:"
  for service in "${SERVICE_IDS[@]}"; do
    printf '  %d) %-15s %s\n' "$index" "$service" "$(service_description "$service")"
    index=$((index + 1))
  done
  echo "  all) Install all services"
  echo
  echo "Current/default selection: $current"
  read -r -p "Select numbers or names separated by comma/space [keep current]: " input
  input="${input//,/ }"

  if [ -z "$input" ]; then
    selected="$current"
  elif [ "${input,,}" = "all" ]; then
    selected="$ALL_SERVICE_NAMES"
  else
    for token in $input; do
      if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#SERVICE_IDS[@]}" ]; then
        service="${SERVICE_IDS[$((token - 1))]}"
      else
        service="$(lisa_normalize_service_id "$token")"
        contains_word "$ALL_SERVICE_NAMES" "$service" || die "Unknown service selection: $token"
      fi
      contains_word "$selected" "$service" || selected="${selected:+$selected }$service"
    done
  fi

  [ -n "$selected" ] || die "Select at least one service."
  for service in $selected; do
    for dependency in $(lisa_service_dependencies "$service"); do
      if ! contains_word "$selected" "$dependency"; then
        selected="$dependency $selected"
        info "Added $dependency because $service depends on it."
      fi
    done
  done

  LISA_COMPOSE_SERVICES=""
  for service in "${SERVICE_IDS[@]}"; do
    if contains_word "$selected" "$service"; then
      LISA_COMPOSE_SERVICES="${LISA_COMPOSE_SERVICES:+$LISA_COMPOSE_SERVICES }$service"
    fi
  done
  [ -n "$LISA_COMPOSE_SERVICES" ] || die "Select at least one implemented service."
  info "Selected services: $LISA_COMPOSE_SERVICES"
}

configure_global() {
  local answer mount_default expected_source detected_source detected_target pin_default sudo_default
  echo
  echo "--- Host and storage wizard ---"
  ask_value LISA_EDGE_HOSTNAME "Hostname" "${LISA_EDGE_HOSTNAME:-lisa-edge-01}"
  [[ "$LISA_EDGE_HOSTNAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Invalid hostname."
  ask_value TZ "Timezone" "${TZ:-America/Los_Angeles}"
  ask_value DATA_ROOT "Persistent data root" "${DATA_ROOT:-/srv/lisa-edge}"
  require_persistent_data_path "DATA_ROOT" "$DATA_ROOT"
  ask_value BACKUP_DEST "Backup destination (local path or mounted NAS path)" "${BACKUP_DEST:-$DATA_ROOT/backups}"
  require_persistent_data_path "BACKUP_DEST" "$BACKUP_DEST"
  mount_default=no
  case "$BACKUP_DEST" in /mnt/*|/media/*|/run/media/*) mount_default=yes ;; esac
  [ "${BACKUP_REQUIRE_MOUNT:-0}" = "1" ] && mount_default=yes
  ask_yes_no answer "Require BACKUP_DEST to remain on a mounted filesystem" "$mount_default"
  if [ "$answer" = "yes" ]; then
    BACKUP_REQUIRE_MOUNT=1
    expected_source="${BACKUP_EXPECTED_MOUNT_SOURCE:-}"
    if [ -d "$BACKUP_DEST" ] && command -v findmnt >/dev/null 2>&1; then
      detected_target="$(findmnt -rn -T "$BACKUP_DEST" -o TARGET 2>/dev/null || true)"
      detected_source="$(findmnt -rn -T "$BACKUP_DEST" -o SOURCE 2>/dev/null || true)"
      if [ -n "$detected_target" ] && [ "$detected_target" != "/" ]; then
        expected_source="$detected_source"
      fi
    fi
    ask_value BACKUP_EXPECTED_MOUNT_SOURCE "Expected mount source (empty accepts any non-root mount)" "$expected_source"
  else
    BACKUP_REQUIRE_MOUNT=0
    BACKUP_EXPECTED_MOUNT_SOURCE=""
  fi
  ask_value BACKUP_RETENTION_DAYS "Backup retention in days" "${BACKUP_RETENTION_DAYS:-14}"
  [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "Retention must be numeric."
  ask_value HEALTHCHECK_BIND_ADDR "Healthcheck target IP or auto" "${HEALTHCHECK_BIND_ADDR:-auto}"
  [ "$HEALTHCHECK_BIND_ADDR" = "auto" ] || require_bind_address "HEALTHCHECK_BIND_ADDR" "$HEALTHCHECK_BIND_ADDR"
  pin_default=no
  [ "${LISA_REQUIRE_PINNED_IMAGES:-0}" = "1" ] && pin_default=yes
  ask_yes_no answer "Require immutable container image digests" "$pin_default"
  [ "$answer" = "yes" ] && LISA_REQUIRE_PINNED_IMAGES=1 || LISA_REQUIRE_PINNED_IMAGES=0
  ask_value LISA_ADMIN_USER "Administrative account" "${LISA_ADMIN_USER:-lisa}"
  [ "$LISA_ADMIN_USER" != "root" ] || die "LISA_ADMIN_USER cannot be root."
  [[ "$LISA_ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid LISA_ADMIN_USER."
  sudo_default=no
  [ "${LISA_KEEP_PASSWORDLESS_SUDO:-0}" = "1" ] && sudo_default=yes
  ask_yes_no answer "Keep passwordless sudo after bootstrap (not recommended)" "$sudo_default"
  [ "$answer" = "yes" ] && LISA_KEEP_PASSWORDLESS_SUDO=1 || LISA_KEEP_PASSWORDLESS_SUDO=0
}

review_image_references() {
  local confirmed
  echo
  echo "--- Selected container images ---"
  lisa_validate_selected_images || die "Container image policy validation failed."
  lisa_print_selected_images
  if [ "$RESTORED_FROM_BACKUP" -eq 1 ]; then
    ask_yes_no confirmed "Trust and use the container image references restored from backup" "no"
    [ "$confirmed" = "yes" ] || die "Restored image references were not approved. Edit them and rerun provisioning."
  fi
}

run_service_wizards() {
  local service configure_function
  for service in "${SERVICE_IDS[@]}"; do
    contains_word "$LISA_COMPOSE_SERVICES" "$service" || continue
    configure_function="$(lisa_service_configure_function "$service")"
    declare -F "$configure_function" >/dev/null || die "Missing provisioning function for $service: $configure_function"
    "$configure_function"
  done
}

validate_service_endpoints() {
  local addresses=()
  local ports=()
  local labels=()
  local address port label index

  register_endpoint() {
    address="$1"
    port="$2"
    label="$3"
    for index in "${!ports[@]}"; do
      if [ "${ports[$index]}" = "$port" ] && {
        [ "${addresses[$index]}" = "$address" ] ||
        [ "${addresses[$index]}" = "0.0.0.0" ] ||
        [ "$address" = "0.0.0.0" ];
      }; then
        die "Port conflict: $label and ${labels[$index]} both use $address:$port."
      fi
    done
    addresses+=("$address")
    ports+=("$port")
    labels+=("$label")
  }

  if contains_word "$LISA_COMPOSE_SERVICES" mqtt; then
    register_endpoint "$MQTT_BIND_ADDR" "$MQTT_PORT" "MQTT TCP"
    register_endpoint "$MQTT_BIND_ADDR" "$MQTT_WS_PORT" "MQTT WebSocket"
  fi
  if contains_word "$LISA_COMPOSE_SERVICES" uptime-kuma; then
    register_endpoint "$UPTIME_KUMA_BIND_ADDR" "$UPTIME_KUMA_PORT" "Uptime Kuma"
  fi
  if contains_word "$LISA_COMPOSE_SERVICES" zigbee2mqtt; then
    register_endpoint "$ZIGBEE2MQTT_BIND_ADDR" "$ZIGBEE2MQTT_PORT" "Zigbee2MQTT"
  fi
  if contains_word "$LISA_COMPOSE_SERVICES" node-red; then
    register_endpoint "$NODE_RED_BIND_ADDR" "$NODE_RED_PORT" "Node-RED"
  fi
}

choose_archive() {
  local search_root="$1"
  local archives=()
  local item choice index=1

  if [ -f "$search_root" ]; then
    BACKUP_ARCHIVE="$search_root"
    return 0
  fi
  [ -d "$search_root" ] || die "Backup path does not exist: $search_root"

  while IFS= read -r item; do archives+=("$item"); done < <(
    find "$search_root" -maxdepth 4 -type f -name 'lisa-edge-backup-*.tar.gz' | sort -r
  )
  [ "${#archives[@]}" -gt 0 ] || die "No LISA Edge backup archive found under $search_root"

  echo
  echo "Available backups:"
  for item in "${archives[@]}"; do
    printf '  %d) %s\n' "$index" "$item"
    index=$((index + 1))
  done
  read -r -p "Select backup [1]: " choice
  choice="${choice:-1}"
  [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid backup selection."
  [ "$choice" -ge 1 ] && [ "$choice" -le "${#archives[@]}" ] || die "Invalid backup selection."
  BACKUP_ARCHIVE="${archives[$((choice - 1))]}"
}

verify_backup_archive() {
  info "Verifying backup checksum..."
  lisa_verify_backup_checksum "$BACKUP_ARCHIVE"
}

discover_usb_backup() {
  local mount_dir="/mnt/lisa-backup"
  local root

  if [ -e /dev/disk/by-label/LISA_BACKUP ]; then
    mkdir -p "$mount_dir"
    if ! mountpoint -q "$mount_dir"; then
      mount -o ro /dev/disk/by-label/LISA_BACKUP "$mount_dir"
      MOUNTED_BACKUP_DIR="$mount_dir"
      trap 'umount "$MOUNTED_BACKUP_DIR" 2>/dev/null || true' EXIT
    fi
    choose_archive "$mount_dir"
    return 0
  fi

  for root in /media /run/media /mnt; do
    [ -d "$root" ] || continue
    if find "$root" -maxdepth 4 -type f -name 'lisa-edge-backup-*.tar.gz' -print -quit | grep -q .; then
      choose_archive "$root"
      return 0
    fi
  done
  die "No LISA_BACKUP volume or backup archive was found."
}

prepare_restore() {
  local path
  case "$MODE" in
    restore-usb)
      if [ -n "$BACKUP_ARCHIVE" ]; then choose_archive "$BACKUP_ARCHIVE"; else discover_usb_backup; fi
      ;;
    restore-path)
      if [ -z "$BACKUP_ARCHIVE" ]; then
        ask_value path "Mounted NAS directory or backup archive" ""
        BACKUP_ARCHIVE="$path"
      fi
      choose_archive "$BACKUP_ARCHIVE"
      ;;
    *) return 0 ;;
  esac

  info "Selected backup: $BACKUP_ARCHIVE"
  RESTORED_FROM_BACKUP=1
  verify_backup_archive
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run: restore skipped."
  else
    bash "$EDGE_REPO/ops/backup-restore/restore.sh" --no-start-services "$BACKUP_ARCHIVE"
    load_environment
  fi
}

env_line() {
  local key="$1"
  local value="${2:-}"
  case "$value" in
    *$'\n'*|*"'"*) die "$key contains an unsupported newline or single quote." ;;
  esac
  printf "%s='%s'\n" "$key" "$value"
}

write_environment() {
  local temp_file="$ENV_OUTPUT.tmp"
  local backup_file

  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    info "Dry-run configuration summary:"
    echo "  mode: $MODE"
    echo "  hostname: $LISA_EDGE_HOSTNAME"
    echo "  data root: $DATA_ROOT"
    echo "  backup destination: $BACKUP_DEST"
    echo "  backup requires mount: $BACKUP_REQUIRE_MOUNT"
    [ -n "${BACKUP_EXPECTED_MOUNT_SOURCE:-}" ] && echo "  expected mount source: $BACKUP_EXPECTED_MOUNT_SOURCE"
    echo "  services: $LISA_COMPOSE_SERVICES"
    echo "  immutable images required: $LISA_REQUIRE_PINNED_IMAGES"
    echo "  keep passwordless sudo: $LISA_KEEP_PASSWORDLESS_SUDO"
    lisa_print_selected_images
    return 0
  fi

  mkdir -p "$(dirname "$ENV_OUTPUT")"
  if [ -f "$ENV_OUTPUT" ]; then
    backup_file="$ENV_OUTPUT.before-wizard-$(date +%Y%m%d-%H%M%S)"
    cp "$ENV_OUTPUT" "$backup_file"
    chmod 0600 "$backup_file"
  fi

  {
    env_line LISA_EDGE_HOSTNAME "$LISA_EDGE_HOSTNAME"
    env_line TZ "$TZ"
    env_line DATA_ROOT "$DATA_ROOT"
    env_line BACKUP_DEST "$BACKUP_DEST"
    env_line BACKUP_RETENTION_DAYS "$BACKUP_RETENTION_DAYS"
    env_line BACKUP_REQUIRE_MOUNT "$BACKUP_REQUIRE_MOUNT"
    env_line BACKUP_EXPECTED_MOUNT_SOURCE "${BACKUP_EXPECTED_MOUNT_SOURCE:-}"
    env_line COMPOSE_PROJECT_NAME "${COMPOSE_PROJECT_NAME:-lisa-edge}"
    env_line LISA_PULL_POLICY "${LISA_PULL_POLICY:-missing}"
    env_line LISA_REQUIRE_PINNED_IMAGES "$LISA_REQUIRE_PINNED_IMAGES"
    env_line LISA_ENABLE_THREAD_HOST_PREP "${LISA_ENABLE_THREAD_HOST_PREP:-0}"
    env_line LISA_COMPOSE_SERVICES "$LISA_COMPOSE_SERVICES"
    env_line MQTT_IMAGE "${MQTT_IMAGE:-eclipse-mosquitto:2}"
    env_line UPTIME_KUMA_IMAGE "${UPTIME_KUMA_IMAGE:-louislam/uptime-kuma:1}"
    env_line HOME_ASSISTANT_IMAGE "${HOME_ASSISTANT_IMAGE:-ghcr.io/home-assistant/home-assistant:stable}"
    env_line MATTER_SERVER_IMAGE "${MATTER_SERVER_IMAGE:-ghcr.io/matter-js/matterjs-server:stable}"
    env_line OTBR_IMAGE "${OTBR_IMAGE:-openthread/border-router:latest}"
    env_line ZIGBEE2MQTT_IMAGE "${ZIGBEE2MQTT_IMAGE:-koenkk/zigbee2mqtt:latest}"
    env_line NODE_RED_IMAGE "${NODE_RED_IMAGE:-nodered/node-red:latest}"
    env_line TAILSCALE_IMAGE "${TAILSCALE_IMAGE:-tailscale/tailscale:latest}"
    env_line HEALTHCHECK_BIND_ADDR "$HEALTHCHECK_BIND_ADDR"
    env_line MQTT_BIND_ADDR "${MQTT_BIND_ADDR:-127.0.0.1}"
    env_line MQTT_PORT "${MQTT_PORT:-1883}"
    env_line MQTT_WS_PORT "${MQTT_WS_PORT:-9001}"
    env_line MQTT_USERNAME "${MQTT_USERNAME:-lisa}"
    env_line MQTT_PASSWORD "${MQTT_PASSWORD:-}"
    env_line UPTIME_KUMA_BIND_ADDR "${UPTIME_KUMA_BIND_ADDR:-127.0.0.1}"
    env_line UPTIME_KUMA_PORT "${UPTIME_KUMA_PORT:-3001}"
    env_line MATTER_SERVER_PORT "${MATTER_SERVER_PORT:-5580}"
    env_line MATTER_LISTEN_ADDRESS "${MATTER_LISTEN_ADDRESS:-127.0.0.1}"
    env_line MATTER_PRIMARY_INTERFACE "${MATTER_PRIMARY_INTERFACE:-}"
    env_line MATTER_BLUETOOTH_ADAPTER "${MATTER_BLUETOOTH_ADAPTER:-0}"
    env_line MATTER_FABRIC_LABEL "${MATTER_FABRIC_LABEL:-LISA Home}"
    env_line MATTER_LOG_LEVEL "${MATTER_LOG_LEVEL:-info}"
    env_line MATTER_DATA_BACKUP_DIR "${MATTER_DATA_BACKUP_DIR:-$DATA_ROOT/backups/matter}"
    env_line MATTER_DATA_LATEST "${MATTER_DATA_LATEST:-$DATA_ROOT/backups/matter/latest.matter-data.tar.gz}"
    env_line MATTER_DATA_RETENTION_DAYS "${MATTER_DATA_RETENTION_DAYS:-30}"
    env_line MATTER_AUTO_RESTORE_DATA "${MATTER_AUTO_RESTORE_DATA:-1}"
    env_line THREAD_NETWORK_NAME "${THREAD_NETWORK_NAME:-LISA-HOME-01}"
    env_line THREAD_RADIO_DEVICE "${THREAD_RADIO_DEVICE:-/dev/serial/by-id/YOUR_THREAD_RCP_RADIO}"
    env_line THREAD_RADIO_URL "${THREAD_RADIO_URL:-spinel+hdlc+uart:///dev/ttyThreadRCP?uart-baudrate=460800}"
    env_line OTBR_BACKBONE_IF "${OTBR_BACKBONE_IF:-enp1s0}"
    env_line OTBR_THREAD_IF "${OTBR_THREAD_IF:-wpan0}"
    env_line OTBR_LOG_LEVEL "${OTBR_LOG_LEVEL:-5}"
    env_line OTBR_DATASET_BACKUP_DIR "${OTBR_DATASET_BACKUP_DIR:-$DATA_ROOT/backups/otbr}"
    env_line OTBR_DATASET_LATEST "${OTBR_DATASET_LATEST:-$DATA_ROOT/backups/otbr/latest.dataset.hex}"
    env_line OTBR_DATASET_RETENTION_DAYS "${OTBR_DATASET_RETENTION_DAYS:-30}"
    env_line OTBR_AUTO_RESTORE_DATASET "${OTBR_AUTO_RESTORE_DATASET:-1}"
    env_line OTBR_AUTO_CREATE_NETWORK "${OTBR_AUTO_CREATE_NETWORK:-0}"
    env_line ZIGBEE_DONGLE "${ZIGBEE_DONGLE:-/dev/ttyACM0}"
    env_line ZIGBEE2MQTT_BIND_ADDR "${ZIGBEE2MQTT_BIND_ADDR:-127.0.0.1}"
    env_line ZIGBEE2MQTT_PORT "${ZIGBEE2MQTT_PORT:-8080}"
    env_line NODE_RED_BIND_ADDR "${NODE_RED_BIND_ADDR:-127.0.0.1}"
    env_line NODE_RED_PORT "${NODE_RED_PORT:-1880}"
    env_line HOME_ASSISTANT_PORT "${HOME_ASSISTANT_PORT:-8123}"
    env_line TS_AUTHKEY "${TS_AUTHKEY:-}"
    env_line TS_EXTRA_ARGS "${TS_EXTRA_ARGS:-}"
    env_line TS_USERSPACE "${TS_USERSPACE:-false}"
    env_line LISA_ADMIN_USER "$LISA_ADMIN_USER"
    env_line LISA_KEEP_PASSWORDLESS_SUDO "$LISA_KEEP_PASSWORDLESS_SUDO"
  } > "$temp_file"
  chmod 0600 "$temp_file"
  mv "$temp_file" "$ENV_OUTPUT"
  info "Configuration written to $ENV_OUTPUT"
}

# After services were started/refreshed by an interactive workflow, check
# the OTBR <-> Matter default-credential relationship through the shared
# internal check-and-sync path. It prompts (default Yes) only when the
# default credential is missing or differs, and never prompts without a
# terminal.
check_thread_relationship() {
  contains_word "${LISA_COMPOSE_SERVICES:-}" matter || return 0
  contains_word "${LISA_COMPOSE_SERVICES:-}" otbr || return 0
  echo
  "$EDGE_REPO/services/matter-server/thread-sync-if-needed.sh" || true
}

apply_provisioning() {
  local confirmed
  [ "$MODE" != "config-only" ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0

  ask_yes_no confirmed "Bootstrap this host and start the selected services now" "yes"
  [ "$confirmed" = "yes" ] || die "Provisioning cancelled; .env was saved."

  hostnamectl set-hostname "$LISA_EDGE_HOSTNAME" || warn "Could not update the runtime hostname."
  bash "$EDGE_REPO/install/bootstrap/bootstrap.sh"
  install -d -m 0755 /var/lib/lisa-edge
  touch /var/lib/lisa-edge/provisioned
  rm -f /etc/update-motd.d/99-lisa-edge-provision
  systemctl disable lisa-first-boot.service >/dev/null 2>&1 || true
  info "Provisioning completed successfully."
  check_thread_relationship
}

# Setup action 5: apply the current configuration through the internal
# deployment engine. No Git update, no intentional image refresh (the
# configured LISA_PULL_POLICY decides whether missing images are fetched);
# the engine finishes with the canonical health check.
run_refresh() {
  [ -f "$EDGE_REPO/.env" ] ||
    die "No configuration found ($EDGE_REPO/.env). Run a fresh setup first."
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run: service refresh skipped."
    return 0
  fi
  info "Refreshing the selected services with the current configuration..."
  bash "$EDGE_REPO/ops/deploy/deploy.sh"
  info "Service refresh completed."
  check_thread_relationship
}

# Setup action 6: rerun the idempotent host bootstrap (packages, hardening,
# Docker, directories, systemd units) with the existing configuration, then
# start/refresh services through the internal engine and verify health.
run_repair() {
  [ -f "$EDGE_REPO/.env" ] ||
    die "No configuration found ($EDGE_REPO/.env). Run a fresh setup first."
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Dry run: host bootstrap/repair skipped."
    return 0
  fi
  info "Bootstrapping/repairing this host with the current configuration..."
  bash "$EDGE_REPO/install/bootstrap/bootstrap.sh"
  info "Host bootstrap/repair completed."
  check_thread_relationship
}

main() {
  parse_args "$@"
  # LISA_EDGE_TESTING=1 is the shared test seam (mirrors reset-node.sh);
  # real hosts never set it.
  if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -ne 1 ] && [ "${LISA_EDGE_TESTING:-0}" != "1" ]; then
    die "Run as root: sudo $0"
  fi

  echo "============================================================"
  echo " LISA Edge Setup"
  echo "============================================================"

  load_environment
  choose_mode
  case "$MODE" in
    fresh|restore-usb|restore-path|config-only) ;;
    refresh)
      run_refresh
      return 0
      ;;
    repair)
      run_repair
      return 0
      ;;
    *) die "Unsupported mode: $MODE" ;;
  esac
  prepare_restore
  configure_global
  select_services
  run_service_wizards
  validate_service_endpoints
  review_image_references
  write_environment
  apply_provisioning

  if [ "$MODE" = "config-only" ]; then
    info "Configuration saved without being applied. Apply it later through"
    info "'sudo ./lisa-edge setup' (Refresh services, or Bootstrap/repair)."
  fi
}

main "$@"
