#!/usr/bin/env bash
set -euo pipefail

# Internal full-stack deployment engine. NOT a root CLI command.
#
# Responsibility: validate the current configuration, prepare service data,
# create/update/start all selected services, and verify stack health.
#
# Callers: setup (fresh/restore/refresh/repair), lisa-edge update, service
# add/remove, live restore with --start-services, reset workflows, and the
# systemd runtime unit (which invokes this script directly). It is safe to
# rerun, fully non-interactive, and never prompts. It does not run host
# bootstrap phases, does not update Git, does not change the service
# selection, and never erases service data.
#
# Options (internal controls for trusted callers and troubleshooting):
#   --pull     refresh the selected images (update uses this)
#   --offline  require all selected images to exist locally
# Without a flag the configured LISA_PULL_POLICY applies.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

# Anything started through the engine (including automatic OTBR dataset
# restore/network creation) must never prompt for a Matter Thread credential
# sync; interactive workflows check and prompt AFTER the engine completes.
export LISA_THREAD_SYNC_NO_PROMPT=1

PULL_POLICY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pull) PULL_POLICY=always ;;
    --offline) PULL_POLICY=never ;;
    -h|--help)
      echo "Usage: $0 [--pull|--offline]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ ! -f .env ]; then
  echo "Missing .env; run 'sudo ./lisa-edge setup' first." >&2
  exit 1
fi
chmod 0600 .env

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"
lisa_validate_persistent_path DATA_ROOT "${DATA_ROOT:-/srv/lisa-edge}"

PULL_POLICY="${PULL_POLICY:-${LISA_PULL_POLICY:-missing}}"
case "$PULL_POLICY" in
  always|missing|never) ;;
  *) echo "LISA_PULL_POLICY must be always, missing, or never." >&2; exit 1 ;;
esac
export LISA_EFFECTIVE_PULL_POLICY="$PULL_POLICY"

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/images.sh"
lisa_build_compose_files "$EDGE_REPO"
lisa_validate_selected_images

# Validate service-specific mandatory configuration before any container
# is touched; deploying with invalid Matter/Thread settings would come up
# in a broken or unsafe state.
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/service-config.sh"
if lisa_has_service matter; then
  lisa_validate_matter_config || exit 1
  if [ "${MATTER_LISTEN_ADDRESS:-127.0.0.1}" = "0.0.0.0" ]; then
    echo "[LISA] WARNING: MATTER_LISTEN_ADDRESS=0.0.0.0 exposes the unauthenticated" >&2
    echo "[LISA] Matter WebSocket API on every interface. Restrict it to a trusted" >&2
    echo "[LISA] address and firewall TCP ${MATTER_SERVER_PORT:-5580}." >&2
  fi
fi
if lisa_has_service otbr; then
  lisa_validate_otbr_config || exit 1
fi
echo "[LISA] Selected container images:"
lisa_print_selected_images
FILES=("${LISA_COMPOSE_FILES[@]}")
UP_ARGS=(-d --remove-orphans)

# Zero selected services is a valid deployment: 'compose up' would fail on a
# project without services, so reconcile the intentionally empty deployment
# by removing only this project's obsolete containers ('compose down
# --remove-orphans' touches nothing outside the LISA Edge Compose project;
# images, bind-mounted service data, and backups are preserved). The run
# still finishes with the canonical health check.
if [ -z "$(lisa_selected_services)" ]; then
  echo "[LISA] No services selected; reconciling the intentionally empty deployment."
  docker compose --env-file .env "${FILES[@]}" down --remove-orphans
  "$EDGE_REPO/ops/deploy/healthcheck.sh"
  exit 0
fi

if [ "$PULL_POLICY" = "always" ]; then
  echo "[LISA] Pulling selected service images..."
  docker compose --env-file .env "${FILES[@]}" pull
elif [ "$PULL_POLICY" = "never" ]; then
  UP_ARGS+=(--pull never)
fi

if lisa_has_service mqtt; then
  "$EDGE_REPO/services/mqtt/prepare.sh"
  docker compose --env-file .env "${FILES[@]}" up "${UP_ARGS[@]}" --force-recreate mosquitto
fi

# Matter fabric-data protection runs BEFORE compose up, while the store is
# plain files: it applies staged wizard selections, backs the store up ahead
# of a container image change, and restores the latest backup into an empty
# store. Compose up then starts the (possibly stopped) container.
if lisa_has_service matter; then
  "$EDGE_REPO/services/matter-server/data/init-or-restore.sh"
fi

docker compose --env-file .env "${FILES[@]}" up "${UP_ARGS[@]}"

if lisa_has_service otbr; then
  "$EDGE_REPO/services/otbr/dataset/init-or-restore.sh"
fi

"$EDGE_REPO/ops/deploy/healthcheck.sh"
