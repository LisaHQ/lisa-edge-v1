#!/usr/bin/env bash
set -euo pipefail

# LISA Edge update (operator entry point: lisa-edge update [clean]).
#
# Meaning: update the repository, refresh selected container images, run
# the internal deployment engine, and verify health. Untracked files (.env,
# runtime data, secrets) are always preserved. This workflow is fully
# non-interactive: it never prompts for a Matter/OTBR Thread credential
# sync; when credentials are missing or drifted, the engine's health check
# reports DEGRADED and prints the manual remediation command
# (sudo ./lisa-edge matter thread sync) while the services keep running.
#
# To apply the current local configuration WITHOUT obtaining updates, use
# the setup menu's "Refresh services" action instead (sudo ./lisa-edge
# setup); it runs the engine without Git update or intentional image
# refresh.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

CLEAN_MODE=0
case "${1:-}" in
  "") ;;
  clean)
    CLEAN_MODE=1
    ;;
  *)
    echo "Usage: lisa-edge update [clean]" >&2
    echo "  clean  Discard local changes to tracked files and reset to the remote branch." >&2
    exit 2
    ;;
esac

if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  if [ "$CLEAN_MODE" -eq 1 ]; then
    UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [ -z "$UPSTREAM" ]; then
      echo "ERROR: the current branch has no upstream; cannot run 'update clean'." >&2
      exit 1
    fi
    echo "[LISA] Discarding local changes to tracked files and syncing with $UPSTREAM..."
    echo "[LISA] Untracked files (.env, runtime data, secrets) are preserved."
    git fetch
    git reset --hard "$UPSTREAM"
  else
    git pull --ff-only
  fi
fi

"$EDGE_REPO/ops/deploy/deploy.sh" --pull
