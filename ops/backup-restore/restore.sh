#!/usr/bin/env bash
set -euo pipefail

START_SERVICES=0
ALLOW_MISSING_CHECKSUM=0
ARCHIVE=""
PYTHON_BIN="${PYTHON_BIN:-python3}"
RESTORE_TARGET_ROOT="${LISA_RESTORE_TARGET_ROOT:-/}"
TARGET_ROOT_FROM_CLI=0

usage() {
  cat >&2 <<EOF
Usage: sudo $0 [options] /path/to/lisa-edge-backup.tar.gz

Options:
  --start-services            Start the restored services (internal
                              deployment engine + health check) after
                              restoring to the live root
  --no-start-services         Restore only (default)
  --target-root PATH          Restore into an exact mount below /mnt
                              (never starts services)
  --allow-missing-checksum    Allow a trusted legacy archive without sidecar
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-start-services) START_SERVICES=0 ;;
    --start-services) START_SERVICES=1 ;;
    --target-root)
      [ "$#" -ge 2 ] || { echo "--target-root requires a path." >&2; usage; exit 1; }
      RESTORE_TARGET_ROOT="$2"
      TARGET_ROOT_FROM_CLI=1
      shift
      ;;
    --allow-missing-checksum) ALLOW_MISSING_CHECKSUM=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      [ -z "$ARCHIVE" ] || { echo "Only one backup archive may be specified." >&2; exit 1; }
      ARCHIVE="$1"
      ;;
  esac
  shift
done

[ -n "$ARCHIVE" ] || { usage; exit 1; }

if [ "$(id -u)" -ne 0 ] && { [ "$RESTORE_TARGET_ROOT" = "/" ] || [ "$TARGET_ROOT_FROM_CLI" -eq 1 ]; }; then
  echo "Run as root: sudo $0 /path/to/backup.tar.gz" >&2
  exit 1
fi

ARCHIVE="$(readlink -f "$ARCHIVE")"
[ -f "$ARCHIVE" ] || { echo "Backup archive not found: $ARCHIVE" >&2; exit 1; }

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

# shellcheck disable=SC1091
. "$EDGE_REPO/ops/backup-restore/lib/backup.sh"
# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"

command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
  echo "$PYTHON_BIN is required for safe backup validation." >&2
  exit 1
}

if [ "$RESTORE_TARGET_ROOT" != "/" ]; then
  [ "$START_SERVICES" -eq 0 ] || { echo "A target-root restore cannot start services." >&2; exit 1; }
  if [ "${LISA_EDGE_TESTING:-0}" = "1" ] && [ "$TARGET_ROOT_FROM_CLI" -eq 0 ]; then
    case "$RESTORE_TARGET_ROOT" in /tmp/*) ;; *) echo "Test restore target must be below /tmp." >&2; exit 1 ;; esac
    mkdir -p "$RESTORE_TARGET_ROOT"
    RESTORE_TARGET_ROOT="$(readlink -f "$RESTORE_TARGET_ROOT")"
  else
    case "$RESTORE_TARGET_ROOT" in
      /mnt/*) ;;
      *) echo "--target-root must be below /mnt: $RESTORE_TARGET_ROOT" >&2; exit 1 ;;
    esac
    [ -d "$RESTORE_TARGET_ROOT" ] || { echo "Restore target does not exist: $RESTORE_TARGET_ROOT" >&2; exit 1; }
    RESTORE_TARGET_ROOT="$(readlink -f "$RESTORE_TARGET_ROOT")"
    case "$RESTORE_TARGET_ROOT" in /mnt/*) ;; *) echo "Unsafe resolved target root: $RESTORE_TARGET_ROOT" >&2; exit 1 ;; esac
    command -v findmnt >/dev/null 2>&1 || { echo "findmnt is required for target-root restore." >&2; exit 1; }
    MOUNT_TARGET="$(findmnt -rn -M "$RESTORE_TARGET_ROOT" -o TARGET 2>/dev/null || true)"
    [ "$MOUNT_TARGET" = "$RESTORE_TARGET_ROOT" ] || {
      echo "Restore target must be an exact mounted filesystem: $RESTORE_TARGET_ROOT" >&2
      exit 1
    }
  fi
  [ "$RESTORE_TARGET_ROOT" != "/" ] && [ "$RESTORE_TARGET_ROOT" != "/mnt" ] || {
    echo "Refusing unsafe target root: $RESTORE_TARGET_ROOT" >&2
    exit 1
  }
  case "$ARCHIVE" in
    "$RESTORE_TARGET_ROOT"/*) echo "Backup archive cannot be stored inside the restore target." >&2; exit 1 ;;
  esac
fi

lisa_verify_backup_checksum "$ARCHIVE" "$ALLOW_MISSING_CHECKSUM"

STAGING_ROOT="$(mktemp -d /tmp/lisa-edge-restore.XXXXXX)"
ARCHIVED_ENV="$STAGING_ROOT/validated.env"
EXTRACT_ROOT="$STAGING_ROOT/root"
cleanup() { rm -rf "$STAGING_ROOT"; }
trap cleanup EXIT

REPO_MEMBER="${EDGE_REPO#/}"
VALIDATOR="$EDGE_REPO/ops/backup-restore/lib/validate_backup.py"

MEMBER_LIST="$STAGING_ROOT/members.txt"
tar -tzf "$ARCHIVE" > "$MEMBER_LIST" || {
  echo "Cannot list backup archive: $ARCHIVE" >&2
  exit 1
}
if grep -Fxq '.env' "$MEMBER_LIST"; then
  ARCHIVE_FORMAT=3
  ENV_MEMBER=.env
elif grep -Fxq "$REPO_MEMBER/.env" "$MEMBER_LIST"; then
  ARCHIVE_FORMAT=2
  ENV_MEMBER="$REPO_MEMBER/.env"
else
  echo "Backup archive does not contain a recognized environment member." >&2
  exit 1
fi

echo "[LISA] Detected backup format v$ARCHIVE_FORMAT."

echo "[LISA] Inspecting archive structure and environment..."
"$PYTHON_BIN" "$VALIDATOR" \
  --archive "$ARCHIVE" \
  --env-member "$ENV_MEMBER" \
  --env-output "$ARCHIVED_ENV" \
  --env-template "$EDGE_REPO/.env.template"

RESTORED_DATA_ROOT="$(lisa_read_validated_env_value "$ARCHIVED_ENV" DATA_ROOT /srv/lisa-edge)"
RESTORED_OTBR_DIR="$(lisa_read_validated_env_value \
  "$ARCHIVED_ENV" OTBR_DATASET_BACKUP_DIR "$RESTORED_DATA_ROOT/backups/otbr")"

validate_restore_root() {
  local path="$1"
  lisa_validate_persistent_path "Archived persistent-data path" "$path"
}

for safe_path in "$RESTORED_DATA_ROOT" "$RESTORED_OTBR_DIR"; do
  validate_restore_root "$safe_path"
done

if [ "$ARCHIVE_FORMAT" -eq 3 ]; then
  ALLOW_ARGS=(
    --allow .env
    --allow data
    --allow docker
    --allow state
    --allow secrets
    --allow otbr
  )
else
  # Format v2 stored absolute source paths (without the leading slash).
  ALLOW_ARGS=(
    --allow "$REPO_MEMBER/.env"
    --allow "$REPO_MEMBER/compose"
    --allow "$REPO_MEMBER/config"
    --allow "${RESTORED_DATA_ROOT#/}/data"
    --allow "${RESTORED_DATA_ROOT#/}/docker"
    --allow "${RESTORED_DATA_ROOT#/}/state"
    --allow "${RESTORED_DATA_ROOT#/}/secrets"
    --allow "${RESTORED_OTBR_DIR#/}"
  )
fi

echo "[LISA] Validating restore allowlist and extracting into protected staging..."
"$PYTHON_BIN" "$VALIDATOR" \
  --archive "$ARCHIVE" \
  --env-member "$ENV_MEMBER" \
  --env-output "$ARCHIVED_ENV" \
  --env-template "$EDGE_REPO/.env.template" \
  --extract-root "$EXTRACT_ROOT" \
  "${ALLOW_ARGS[@]}"

# Stop the currently configured stack before replacing persistent data.
if [ "$RESTORE_TARGET_ROOT" = "/" ] && [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/compose.sh"
  lisa_build_compose_files "$EDGE_REPO"
  FILES=("${LISA_COMPOSE_FILES[@]}")
  docker compose --env-file .env "${FILES[@]}" down --remove-orphans || true
fi

# The production repo checkout always lives at /opt/lisa-edge on LISA Edge
# hosts. For a target-root (rescue) restore we must NOT use this script's own
# EDGE_REPO: the running CLI may live on the mounted target itself or in an
# arbitrary rescue checkout, which would misplace the restored .env.
if [ "$RESTORE_TARGET_ROOT" = "/" ]; then
  ENV_RESTORE_TARGET="$EDGE_REPO/.env"
else
  ENV_RESTORE_TARGET="${LISA_RESTORE_REPO_DIR:-/opt/lisa-edge}/.env"
fi

echo "[LISA] Restoring validated files into $RESTORE_TARGET_ROOT"
restore_member() {
  local member="$1"
  local absolute_target="$2"
  local source_path target_path
  source_path="$EXTRACT_ROOT/$member"
  if [ "$RESTORE_TARGET_ROOT" = "/" ]; then
    target_path="$absolute_target"
  else
    target_path="$RESTORE_TARGET_ROOT$absolute_target"
  fi
  [ -e "$source_path" ] || return 0
  if [ -d "$source_path" ]; then
    mkdir -p "$target_path"
    cp -a "$source_path/." "$target_path/"
  else
    mkdir -p "$(dirname "$target_path")"
    cp -a "$source_path" "$target_path"
  fi
}

if [ "$ARCHIVE_FORMAT" -eq 3 ]; then
  restore_member .env "$ENV_RESTORE_TARGET"
  restore_member data "$RESTORED_DATA_ROOT/data"
  restore_member docker "$RESTORED_DATA_ROOT/docker"
  restore_member state "$RESTORED_DATA_ROOT/state"
  restore_member secrets "$RESTORED_DATA_ROOT/secrets"
  restore_member otbr "$RESTORED_OTBR_DIR"
else
  echo "[LISA] Note: legacy v2 repo members compose/ and config/ are validated" >&2
  echo "[LISA] but intentionally not restored (obsolete repository layout)." >&2
  restore_member "$REPO_MEMBER/.env" "$ENV_RESTORE_TARGET"
  restore_member "${RESTORED_DATA_ROOT#/}/data" "$RESTORED_DATA_ROOT/data"
  restore_member "${RESTORED_DATA_ROOT#/}/docker" "$RESTORED_DATA_ROOT/docker"
  restore_member "${RESTORED_DATA_ROOT#/}/state" "$RESTORED_DATA_ROOT/state"
  restore_member "${RESTORED_DATA_ROOT#/}/secrets" "$RESTORED_DATA_ROOT/secrets"
  restore_member "${RESTORED_OTBR_DIR#/}" "$RESTORED_OTBR_DIR"
fi

if [ "$START_SERVICES" -eq 0 ]; then
  echo "[LISA] Restore finished. Services were intentionally NOT started (default)."
  echo "[LISA] Review .env, then start the restored services through an interactive"
  echo "[LISA] workflow: sudo ./lisa-edge setup (Refresh services), or repeat the"
  echo "[LISA] restore with --start-services. The OTBR/Matter Thread credential"
  echo "[LISA] relationship is checked when services are next started that way."
else
  echo "[LISA] Restore finished. Starting the restored services..."
  "$EDGE_REPO/ops/deploy/deploy.sh"
  # Interactive live restore: check the OTBR <-> Matter default-credential
  # relationship through the shared check-and-sync path. It prompts only
  # when a sync is needed and never prompts without a terminal.
  "$EDGE_REPO/services/matter-server/thread-sync-if-needed.sh" || true
fi
