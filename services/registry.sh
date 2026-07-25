#!/usr/bin/env bash

# Canonical catalog for deployable LISA Edge services. Keep selection keys
# stable because they are stored in .env and in backup archives.
# These globals look unused to IDE/shellcheck within this file, but every
# consumer (lib/compose.sh, services/list.sh, the provisioning wizard, tests)
# sources this file and reads them. Do not delete.
# shellcheck disable=SC2034
LISA_DEFAULT_SERVICES="mqtt uptime-kuma"
# shellcheck disable=SC2034
LISA_ALL_SERVICES="mqtt uptime-kuma ha matter otbr zigbee2mqtt node-red vpn-tailscale"

lisa_normalize_service_id() {
  case "$1" in
    tailscale) printf '%s\n' vpn-tailscale ;;
    home-assistant|homeassistant) printf '%s\n' ha ;;
    matter-server) printf '%s\n' matter ;;
    *) printf '%s\n' "$1" ;;
  esac
}

lisa_service_directory() {
  case "$1" in
    mqtt) printf '%s\n' mqtt ;;
    uptime-kuma) printf '%s\n' uptime-kuma ;;
    ha) printf '%s\n' home-assistant ;;
    matter) printf '%s\n' matter-server ;;
    otbr) printf '%s\n' otbr ;;
    zigbee2mqtt) printf '%s\n' zigbee2mqtt ;;
    node-red) printf '%s\n' node-red ;;
    vpn-tailscale) printf '%s\n' tailscale ;;
    *) return 1 ;;
  esac
}

lisa_service_name() {
  case "$1" in
    mqtt) printf '%s\n' 'MQTT (Mosquitto)' ;;
    uptime-kuma) printf '%s\n' 'Uptime Kuma' ;;
    ha) printf '%s\n' 'Home Assistant' ;;
    matter) printf '%s\n' 'Matter Server' ;;
    otbr) printf '%s\n' 'OpenThread Border Router' ;;
    zigbee2mqtt) printf '%s\n' 'Zigbee2MQTT' ;;
    node-red) printf '%s\n' 'Node-RED' ;;
    vpn-tailscale) printf '%s\n' 'Tailscale VPN' ;;
    *) return 1 ;;
  esac
}

lisa_service_description() {
  case "$1" in
    mqtt) printf '%s\n' 'Local event and messaging backbone' ;;
    uptime-kuma) printf '%s\n' 'Lightweight service monitoring' ;;
    ha) printf '%s\n' 'Optional compact-host home automation controller' ;;
    matter) printf '%s\n' 'Optional local Matter controller server' ;;
    otbr) printf '%s\n' 'Thread border router for Matter-over-Thread' ;;
    zigbee2mqtt) printf '%s\n' 'Optional Zigbee-to-MQTT bridge' ;;
    node-red) printf '%s\n' 'Optional compact-host automation flows' ;;
    vpn-tailscale) printf '%s\n' 'Private remote administration' ;;
    *) return 1 ;;
  esac
}

lisa_service_dependencies() {
  case "$1" in
    zigbee2mqtt) printf '%s\n' mqtt ;;
    *) printf '\n' ;;
  esac
}

lisa_service_configure_function() {
  case "$1" in
    mqtt) printf '%s\n' configure_mqtt ;;
    uptime-kuma) printf '%s\n' configure_uptime_kuma ;;
    ha) printf '%s\n' configure_ha ;;
    matter) printf '%s\n' configure_matter ;;
    otbr) printf '%s\n' configure_otbr ;;
    zigbee2mqtt) printf '%s\n' configure_zigbee2mqtt ;;
    node-red) printf '%s\n' configure_node_red ;;
    vpn-tailscale) printf '%s\n' configure_vpn_tailscale ;;
    *) return 1 ;;
  esac
}

lisa_service_image_variable() {
  case "$1" in
    mqtt) printf '%s\n' MQTT_IMAGE ;;
    uptime-kuma) printf '%s\n' UPTIME_KUMA_IMAGE ;;
    ha) printf '%s\n' HOME_ASSISTANT_IMAGE ;;
    matter) printf '%s\n' MATTER_SERVER_IMAGE ;;
    otbr) printf '%s\n' OTBR_IMAGE ;;
    zigbee2mqtt) printf '%s\n' ZIGBEE2MQTT_IMAGE ;;
    node-red) printf '%s\n' NODE_RED_IMAGE ;;
    vpn-tailscale) printf '%s\n' TAILSCALE_IMAGE ;;
    *) return 1 ;;
  esac
}

lisa_service_is_default() {
  case " $LISA_DEFAULT_SERVICES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Lifecycle metadata (consumed by services/lifecycle.sh). Keep these tables
# in sync with the Compose files and provisioning wizards; the structure
# tests verify directory and Compose coverage.
# ---------------------------------------------------------------------------

# Compose top-level service name (docker compose up/stop/rm target).
lisa_service_compose_name() {
  case "$1" in
    mqtt) printf '%s\n' mosquitto ;;
    uptime-kuma) printf '%s\n' uptime-kuma ;;
    ha) printf '%s\n' homeassistant ;;
    matter) printf '%s\n' matter-server ;;
    otbr) printf '%s\n' otbr ;;
    zigbee2mqtt) printf '%s\n' zigbee2mqtt ;;
    node-red) printf '%s\n' node-red ;;
    vpn-tailscale) printf '%s\n' tailscale ;;
    *) return 1 ;;
  esac
}

# Fixed container_name from the service Compose file.
lisa_service_container_name() {
  case "$1" in
    mqtt) printf '%s\n' lisa-mqtt ;;
    uptime-kuma) printf '%s\n' lisa-uptime ;;
    ha) printf '%s\n' lisa-ha ;;
    matter) printf '%s\n' lisa-matter ;;
    otbr) printf '%s\n' lisa-otbr ;;
    zigbee2mqtt) printf '%s\n' lisa-zigbee2mqtt ;;
    node-red) printf '%s\n' lisa-node-red ;;
    vpn-tailscale) printf '%s\n' lisa-tailscale ;;
    *) return 1 ;;
  esac
}

# Selected services that depend on $1 (reverse dependency lookup).
lisa_service_dependents() {
  local candidate dependency
  for candidate in $LISA_ALL_SERVICES; do
    [ "$candidate" = "$1" ] && continue
    for dependency in $(lisa_service_dependencies "$candidate"); do
      [ "$dependency" = "$1" ] && printf '%s\n' "$candidate"
    done
  done
}

# Runtime data/state/secret paths owned EXCLUSIVELY by the service, relative
# to DATA_ROOT, one per line. These are the paths 'service remove' deletes.
lisa_service_data_paths() {
  case "$1" in
    mqtt) printf '%s\n' docker/volumes/mosquitto ;;
    uptime-kuma) printf '%s\n' docker/volumes/uptime-kuma ;;
    ha) printf '%s\n' docker/volumes/homeassistant ;;
    matter) printf '%s\n' docker/volumes/matter-server ;;
    otbr) printf '%s\n' docker/volumes/otbr ;;
    zigbee2mqtt) printf '%s\n' docker/volumes/zigbee2mqtt ;;
    node-red) printf '%s\n' docker/volumes/node-red ;;
    vpn-tailscale) printf '%s\n' docker/volumes/tailscale ;;
    *) return 1 ;;
  esac
}

# Directory holding backups dedicated EXCLUSIVELY to the service (empty when
# the service has no dedicated backups). Shared full-stack archives under
# BACKUP_DEST are never service-owned.
lisa_service_backup_dir() {
  case "$1" in
    matter) printf '%s\n' "${MATTER_DATA_BACKUP_DIR:-${DATA_ROOT:-/srv/lisa-edge}/backups/matter}" ;;
    otbr) printf '%s\n' "${OTBR_DATASET_BACKUP_DIR:-${DATA_ROOT:-/srv/lisa-edge}/backups/otbr}" ;;
    *) printf '\n' ;;
  esac
}

# Dedicated systemd timer for the service (empty when none exists).
lisa_service_timer() {
  case "$1" in
    matter) printf '%s\n' lisa-matter-data-backup.timer ;;
    otbr) printf '%s\n' lisa-otbr-dataset-backup.timer ;;
    *) printf '\n' ;;
  esac
}

# Preparation hook run BEFORE the service container starts (repo-relative
# script path; empty when none is needed).
lisa_service_pre_start_hook() {
  case "$1" in
    mqtt) printf '%s\n' services/mqtt/prepare.sh ;;
    matter) printf '%s\n' services/matter-server/data/init-or-restore.sh ;;
    *) printf '\n' ;;
  esac
}

# Initialization hook run AFTER the service container starts (repo-relative
# script path; empty when none is needed).
lisa_service_post_start_hook() {
  case "$1" in
    otbr) printf '%s\n' services/otbr/dataset/init-or-restore.sh ;;
    *) printf '\n' ;;
  esac
}

# Backup hook run BEFORE 'service remove' deletes the service's active data
# (repo-relative script path, called with --label pre-remove; empty when the
# service has no dedicated backup tooling).
lisa_service_pre_remove_backup_hook() {
  case "$1" in
    matter) printf '%s\n' services/matter-server/data/backup.sh ;;
    otbr) printf '%s\n' services/otbr/dataset/backup.sh ;;
    *) printf '\n' ;;
  esac
}

# .env keys owned by the service's provisioning wizard. 'service add'
# persists exactly these after running the service wizard, so the rest of
# the configuration is never rewritten.
lisa_service_env_vars() {
  case "$1" in
    mqtt) printf '%s\n' "MQTT_USERNAME MQTT_PASSWORD MQTT_BIND_ADDR MQTT_PORT MQTT_WS_PORT MQTT_IMAGE" ;;
    uptime-kuma) printf '%s\n' "UPTIME_KUMA_BIND_ADDR UPTIME_KUMA_PORT UPTIME_KUMA_IMAGE" ;;
    ha) printf '%s\n' "HOME_ASSISTANT_PORT HOME_ASSISTANT_IMAGE" ;;
    matter) printf '%s\n' "MATTER_SERVER_PORT MATTER_LISTEN_ADDRESS MATTER_PRIMARY_INTERFACE MATTER_BLUETOOTH_ADAPTER MATTER_FABRIC_LABEL MATTER_LOG_LEVEL MATTER_DATA_BACKUP_DIR MATTER_DATA_LATEST MATTER_DATA_RETENTION_DAYS MATTER_AUTO_RESTORE_DATA MATTER_SERVER_IMAGE" ;;
    otbr) printf '%s\n' "THREAD_NETWORK_NAME THREAD_RADIO_DEVICE THREAD_RADIO_URL OTBR_BACKBONE_IF OTBR_THREAD_IF OTBR_LOG_LEVEL OTBR_DATASET_BACKUP_DIR OTBR_DATASET_LATEST OTBR_DATASET_RETENTION_DAYS OTBR_AUTO_RESTORE_DATASET OTBR_AUTO_CREATE_NETWORK LISA_ENABLE_THREAD_HOST_PREP OTBR_IMAGE" ;;
    zigbee2mqtt) printf '%s\n' "ZIGBEE_DONGLE ZIGBEE2MQTT_BIND_ADDR ZIGBEE2MQTT_PORT ZIGBEE2MQTT_IMAGE" ;;
    node-red) printf '%s\n' "NODE_RED_BIND_ADDR NODE_RED_PORT NODE_RED_IMAGE" ;;
    vpn-tailscale) printf '%s\n' "TS_AUTHKEY TS_EXTRA_ARGS TS_USERSPACE TAILSCALE_IMAGE" ;;
    *) return 1 ;;
  esac
}

# True when adding the service requires the OTBR/Thread host preparation
# phase (Avahi, IPv6 forwarding sysctl).
lisa_service_needs_thread_host_prep() {
  case "$1" in
    otbr) return 0 ;;
    *) return 1 ;;
  esac
}
