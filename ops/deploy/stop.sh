#!/usr/bin/env bash
set -euo pipefail

# Internal full-stack stop implementation. NOT a root CLI command: the
# systemd runtime unit invokes this script directly on ExecStop. Operators
# stop services with 'lisa-edge service stop'. Non-destructive for data:
# service data, configuration, images, and backups are preserved (compose
# down removes the stack's containers/networks but never its bind-mounted
# data).

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

if [ ! -f .env ]; then
  exit 0
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/compose.sh"
lisa_build_compose_files "$EDGE_REPO"
FILES=("${LISA_COMPOSE_FILES[@]}")

docker compose --env-file .env "${FILES[@]}" down --remove-orphans
