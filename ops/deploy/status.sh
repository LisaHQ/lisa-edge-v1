#!/usr/bin/env bash
set -euo pipefail

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

if [ ! -f .env ]; then
  echo "LISA Edge is not configured: $EDGE_REPO/.env is missing." >&2
  echo "Run: sudo ./lisa-edge setup" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
lisa_build_compose_files "$EDGE_REPO"

SELECTED_SERVICES="$(lisa_selected_services)"
echo "[LISA] Selected services: ${SELECTED_SERVICES:-(none)}"
docker compose --env-file .env "${LISA_COMPOSE_FILES[@]}" ps

if command -v systemctl >/dev/null 2>&1; then
  RUNTIME_STATE="$(systemctl is-active lisa-edge.service 2>/dev/null || true)"
  BACKUP_TIMER_STATE="$(systemctl is-active lisa-edge-backup.timer 2>/dev/null || true)"
  printf '[LISA] Runtime unit: %s\n' "${RUNTIME_STATE:-unknown}"
  printf '[LISA] Backup timer: %s\n' "${BACKUP_TIMER_STATE:-unknown}"
fi
