#!/usr/bin/env bash
set -euo pipefail

# Service catalog listing (operator entry point: lisa-edge service list).
# Works without root and without a running Docker daemon.
#
# STATUS semantics ("installed" means selected/configured as a LISA Edge
# service in LISA_COMPOSE_SERVICES - image presence alone never counts):
#   not-installed  the service is not selected in LISA_COMPOSE_SERVICES
#   installed      selected, but no container currently exists
#   running        the container is running and not unhealthy
#   stopped        the container exists but is stopped/exited/created/paused
#   error          the container is dead, restarting, or reports unhealthy
#   unknown        the runtime state cannot be determined (Docker or the
#                  configuration is unreadable from this account)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/registry.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"

ENV_FILE="$EDGE_REPO/.env"

# Selection state: 'none' (not configured yet), 'known', or 'unreadable'
# (an .env exists but this account cannot read or parse it).
SELECTION_STATE=none
if [ -e "$ENV_FILE" ]; then
  if [ -r "$ENV_FILE" ] && (set -euo pipefail; set -a; . "$ENV_FILE"; set +a) >/dev/null 2>&1; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    SELECTION_STATE=known
  else
    SELECTION_STATE=unreadable
  fi
fi

# Docker reachability decides between real runtime states and 'unknown'.
DOCKER_OK=0
if command -v docker >/dev/null 2>&1 && docker ps -q >/dev/null 2>&1; then
  DOCKER_OK=1
fi

service_is_selected() {
  [ "$SELECTION_STATE" = "known" ] || return 1
  lisa_has_service "$1"
}

service_status() {
  local service="$1" container state health

  if [ "$SELECTION_STATE" = "unreadable" ]; then
    printf 'unknown\n'
    return 0
  fi
  if ! service_is_selected "$service"; then
    printf 'not-installed\n'
    return 0
  fi
  if [ "$DOCKER_OK" -ne 1 ]; then
    printf 'unknown\n'
    return 0
  fi

  container="$(lisa_service_container_name "$service")"
  state="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
    "$container" 2>/dev/null)" || {
    printf 'installed\n'
    return 0
  }
  health="${state#*|}"
  state="${state%%|*}"

  case "$state" in
    running)
      if [ "$health" = "unhealthy" ]; then
        printf 'error\n'
      else
        printf 'running\n'
      fi
      ;;
    exited|created|paused|removing) printf 'stopped\n' ;;
    dead|restarting) printf 'error\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

printf '%-16s %-14s %-16s %s\n' 'SERVICE' 'STATUS' 'DEPENDENCIES' 'PURPOSE'
for service in $LISA_ALL_SERVICES; do
  dependencies="$(lisa_service_dependencies "$service")"
  printf '%-16s %-14s %-16s %s\n' \
    "$service" "$(service_status "$service")" "${dependencies:--}" \
    "$(lisa_service_description "$service")"
done

if [ "$SELECTION_STATE" = "unreadable" ]; then
  echo
  echo "NOTE: $ENV_FILE exists but is not readable from this account;" >&2
  echo "runtime states are reported as unknown (try again with sudo)." >&2
elif [ "$SELECTION_STATE" = "known" ] && [ "$DOCKER_OK" -ne 1 ]; then
  echo
  echo "NOTE: Docker is not reachable from this account; selected services" >&2
  echo "are reported as unknown (try again with sudo, or start Docker)." >&2
fi

cat <<'EOF'

Status: not-installed (not selected), installed (selected, no container),
running, stopped, error (dead/restarting/unhealthy), unknown (Docker or
configuration unreadable). "Installed" means selected in
LISA_COMPOSE_SERVICES, never mere image presence.

Aliases accepted by the command interface:
  home-assistant -> ha
  matter-server -> matter
  tailscale -> vpn-tailscale
EOF
