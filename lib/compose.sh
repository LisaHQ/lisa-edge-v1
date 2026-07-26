#!/usr/bin/env bash

LISA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISA_REPO_ROOT="$(cd "$LISA_LIB_DIR/.." && pwd)"
. "$LISA_REPO_ROOT/services/registry.sh"

lisa_selected_services() {
  # ${VAR-default} (not ${VAR:-default}): only a completely UNSET selection
  # falls back to the registry defaults. An explicitly EMPTY selection means
  # "this host intentionally runs zero services" and must stay empty.
  local selected="${LISA_COMPOSE_SERVICES-$LISA_DEFAULT_SERVICES}"
  local service normalized result=""
  if [ "$selected" = "all" ]; then
    selected="$LISA_ALL_SERVICES"
  fi
  for service in $selected; do
    normalized="$(lisa_normalize_service_id "$service")"
    case " $result " in
      *" $normalized "*) ;;
      *) result="${result:+$result }$normalized" ;;
    esac
  done
  printf '%s\n' "$result"
}

lisa_has_service() {
  local wanted="$1"
  local service
  for service in $(lisa_selected_services); do
    [ "$service" = "$wanted" ] && return 0
  done
  return 1
}

lisa_validate_services() {
  local selected
  local service
  local dependency
  selected="$(lisa_selected_services)"

  # An empty selection is valid: the host is configured and provisioned but
  # intentionally runs no application service.
  for service in $selected; do
    case " $LISA_ALL_SERVICES " in
      *" $service "*) ;;
      *)
        echo "Unknown LISA_COMPOSE_SERVICES entry: $service" >&2
        echo "Allowed: $LISA_ALL_SERVICES" >&2
        return 1
        ;;
    esac
  done

  for service in $selected; do
    for dependency in $(lisa_service_dependencies "$service"); do
      if ! lisa_has_service "$dependency"; then
        echo "$service requires $dependency. Add $dependency to LISA_COMPOSE_SERVICES." >&2
        return 1
      fi
    done
  done
}

lisa_build_compose_files() {
  local repo_root="$1"
  local service
  local service_file
  local added=""

  lisa_validate_services
  # Built for callers: deploy/stop/update/healthcheck/backup source this file
  # and expand "${LISA_COMPOSE_FILES[@]}" — unused-looking only at file scope.
  # shellcheck disable=SC2034
  LISA_COMPOSE_FILES=(-f "$repo_root/ops/deploy/compose.yml")
  for service in $(lisa_selected_services); do
    case " $added " in *" $service "*) continue ;; esac
    service_file="$repo_root/services/$(lisa_service_directory "$service")/compose.yml"
    [ -f "$service_file" ] || {
      echo "Missing Compose service file: $service_file" >&2
      return 1
    }
    LISA_COMPOSE_FILES+=(-f "$service_file")
    if [ "$service" = "matter" ]; then
      # BLE needs root + HCI capabilities; commissioning-over-network-only
      # deployments (MATTER_BLUETOOTH_ADAPTER=none) run without both.
      if [ "$(lisa_matter_ble_adapter)" != "none" ]; then
        LISA_COMPOSE_FILES+=(-f "$repo_root/services/$(lisa_service_directory "$service")/compose.ble.yml")
      fi
      # PRIMARY_INTERFACE must be absent (not empty) for upstream
      # auto-detection, so it lives in its own conditional slice.
      if [ -n "${MATTER_PRIMARY_INTERFACE:-}" ]; then
        LISA_COMPOSE_FILES+=(-f "$repo_root/services/$(lisa_service_directory "$service")/compose.primary-interface.yml")
      fi
    fi
    added="${added:+$added }$service"
  done
}

# Effective Matter Bluetooth adapter selection: an hci adapter number, or
# the literal "none" to disable BLE commissioning support entirely.
lisa_matter_ble_adapter() {
  # Unset defaults to adapter 0; an explicitly EMPTY value means "none"
  # (${VAR-default} keeps the empty string, unlike ${VAR:-default}).
  local adapter="${MATTER_BLUETOOTH_ADAPTER-0}"
  [ -n "$adapter" ] || adapter=none
  printf '%s\n' "$adapter"
}
