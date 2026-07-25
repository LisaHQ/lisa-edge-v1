#!/usr/bin/env bash
set -euo pipefail

# Canonical LISA Edge reset lifecycle (operator entry point: lisa-edge reset).
#
# Three clearly separated outcomes:
#   reset data          Erase LISA-owned service runtime state, keep the
#                       current .env, then redeploy the selected services.
#   reset provisioning  Remove LISA state and configuration and return the
#                       host to the unprovisioned first-boot state.
#   reset factory       Reinstall the Production OS through the independent
#                       Rescue Layer (guarded handoff; this script never
#                       wipes a disk itself).
#
# Safety model: validate everything before the first mutation, fail closed on
# ambiguity (nested mounts, unresolvable paths, unreachable Docker), require a
# mode-specific confirmation phrase, and never touch Rescue Layer units or
# Docker resources owned by unrelated Compose projects.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

# ---------------------------------------------------------------------------
# Test seams. Real hosts never set LISA_EDGE_TESTING; every override is
# ignored unless LISA_EDGE_TESTING=1 AND the override resolves below /tmp,
# mirroring the restore.sh testing contract.
# ---------------------------------------------------------------------------
TESTING="${LISA_EDGE_TESTING:-0}"

testing_path_or_default() {
  local override="$1"
  local default_value="$2"
  local resolved

  if [ "$TESTING" = "1" ] && [ -n "$override" ]; then
    resolved="$(readlink -m -- "$override")"
    case "$resolved" in
      /tmp/*) printf '%s\n' "$resolved"; return 0 ;;
      *)
        echo "ERROR: testing override must resolve below /tmp: $override" >&2
        exit 1
        ;;
    esac
  fi
  printf '%s\n' "$default_value"
}

SYSTEMD_DIR="$(testing_path_or_default "${LISA_RESET_SYSTEMD_DIR:-}" /etc/systemd/system)"
STATE_DIR="$(testing_path_or_default "${LISA_RESET_STATE_DIR:-}" /var/lib/lisa-edge)"
SBIN_DIR="$(testing_path_or_default "${LISA_RESET_SBIN_DIR:-}" /usr/local/sbin)"
RESCUE_ROOT="$(testing_path_or_default "${LISA_RESET_RESCUE_ROOT:-}" /opt/lisa-rescue)"

# ---------------------------------------------------------------------------
# Production-owned systemd units. Rescue Layer units
# (lisa-rescue-diagnostics.*) are deliberately absent from every list and
# must never be referenced by this script.
# ---------------------------------------------------------------------------
BACKUP_TIMERS=(
  lisa-edge-backup.timer
  lisa-otbr-dataset-backup.timer
  lisa-matter-data-backup.timer
)
BACKUP_SERVICES=(
  lisa-edge-backup.service
  lisa-otbr-dataset-backup.service
  lisa-matter-data-backup.service
)
RUNTIME_SERVICE=lisa-edge.service
FIRST_BOOT_SERVICE=lisa-first-boot.service
PRODUCTION_UNIT_FILES=(
  "$RUNTIME_SERVICE"
  "${BACKUP_SERVICES[@]}"
  "${BACKUP_TIMERS[@]}"
)

MODE=""
DRY_RUN=0
ENV_STATE=missing            # missing | ok | invalid
COMPOSE_READY=0
DATA_ROOT_RESOLVED=""
BACKUP_DEST_RESOLVED=""
BACKUP_DEST_INSIDE=unknown   # yes | no | unknown
PROJECT_NAME=""
SELECTED_SERVICES=""

usage() {
  cat <<'USAGE'
Usage: lisa-edge reset <mode> [--dry-run]

Modes:
  data          Erase service runtime state (containers, project-scoped
                Docker resources, bind-mounted service data, generated
                secrets) and redeploy with the current .env configuration.
                Keeps .env, local backups, host provisioning and timers.
  provisioning  Remove LISA state AND configuration (.env, local backups,
                provision marker, production units) and return the host to
                the unprovisioned first-boot state. Keeps Ubuntu, Docker,
                SSH access and host bootstrap configuration.
  factory       Reinstall the Production OS through the independent Rescue
                Layer. From the Production OS this only prints the safe
                handoff procedure; the disk wipe happens through the
                reviewed production autoinstall workflow, never here.

Options:
  --dry-run     Print the complete reset plan without prompting and without
                changing anything.
  -h, --help    Show this help.

Confirmation phrases (required, exact):
  reset data           RESET DATA
  reset provisioning   RESET LISA
  reset factory        RESET UBUNTU

Anything else aborts without changes.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

info() {
  echo "[LISA] $*"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    data|provisioning|factory)
      [ -z "$MODE" ] || { echo "ERROR: only one reset mode may be given." >&2; exit 2; }
      MODE="$1"
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown reset option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "ERROR: unknown reset mode: $1 (use data, provisioning, or factory)" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$MODE" ]; then
  # No mode: display reset usage only. Never a destructive default.
  usage
  exit 2
fi

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -ne 1 ] && [ "$TESTING" != "1" ]; then
  die "Run as root: sudo lisa-edge reset $MODE"
fi

# ---------------------------------------------------------------------------
# Shared validation (all read-only; nothing below this comment mutates
# anything until the confirmation phrase has been accepted)
# ---------------------------------------------------------------------------

# Validate one persistent root and print its resolved absolute path.
resolve_persistent_root() {
  local label="$1"
  local value="$2"
  local resolved

  [ -n "$value" ] || die "$label is empty; refusing to continue."
  resolved="$(readlink -m -- "$value")" || die "Cannot resolve $label: $value"
  if [ "$TESTING" = "1" ]; then
    case "$resolved" in
      /tmp/*) printf '%s\n' "$resolved"; return 0 ;;
    esac
  fi
  lisa_validate_persistent_path "$label" "$value" || exit 1
  lisa_validate_persistent_path "$label" "$resolved" || exit 1
  printf '%s\n' "$resolved"
}

load_environment() {
  if [ ! -f .env ]; then
    ENV_STATE=missing
    return 0
  fi
  # Prove the file sources cleanly in a strict subshell before trusting it.
  if ! (set -euo pipefail; set -a; . ./.env; set +a) >/dev/null 2>&1; then
    ENV_STATE=invalid
    return 0
  fi
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  ENV_STATE=ok
}

# shellcheck disable=SC1091
. "$EDGE_REPO/lib/paths.sh"

load_environment

case "$MODE" in
  data)
    [ "$ENV_STATE" = "ok" ] ||
      die ".env is $ENV_STATE; 'reset data' redeploys from the current configuration and cannot continue. Fix .env, or use 'reset provisioning' to return to first-boot provisioning."
    ;;
  provisioning|factory)
    if [ "$ENV_STATE" = "invalid" ]; then
      warn ".env cannot be parsed; ignoring it and using canonical defaults (DATA_ROOT=/srv/lisa-edge). No value from the malformed file is used for deletion."
      unset DATA_ROOT BACKUP_DEST COMPOSE_PROJECT_NAME LISA_COMPOSE_SERVICES 2>/dev/null || true
    elif [ "$ENV_STATE" = "missing" ]; then
      info "No .env found; using canonical defaults (DATA_ROOT=/srv/lisa-edge)."
    fi
    ;;
esac

# An explicitly EMPTY value in a loaded .env is ambiguity, not a request
# for the default: refuse instead of guessing a deletion root.
if [ "$ENV_STATE" = "ok" ]; then
  [ "${DATA_ROOT+set}" != "set" ] || [ -n "${DATA_ROOT:-}" ] ||
    die "DATA_ROOT is set but empty in .env; refusing to guess a deletion root."
  [ "${BACKUP_DEST+set}" != "set" ] || [ -n "${BACKUP_DEST:-}" ] ||
    die "BACKUP_DEST is set but empty in .env; refusing to continue."
fi

DATA_ROOT="${DATA_ROOT:-/srv/lisa-edge}"
DATA_ROOT_RESOLVED="$(resolve_persistent_root DATA_ROOT "$DATA_ROOT")"

# Never allow the repository checkout inside the deletion scope (or the
# other way around).
case "$EDGE_REPO/" in
  "$DATA_ROOT_RESOLVED/"*) die "DATA_ROOT ($DATA_ROOT_RESOLVED) contains the repository checkout ($EDGE_REPO); refusing." ;;
esac
case "$DATA_ROOT_RESOLVED/" in
  "$EDGE_REPO/"*) die "DATA_ROOT ($DATA_ROOT_RESOLVED) is inside the repository checkout ($EDGE_REPO); refusing." ;;
esac

BACKUP_DEST="${BACKUP_DEST:-$DATA_ROOT/backups}"
BACKUP_DEST_RESOLVED="$(readlink -m -- "$BACKUP_DEST")" || die "Cannot resolve BACKUP_DEST: $BACKUP_DEST"
case "$BACKUP_DEST_RESOLVED/" in
  "$DATA_ROOT_RESOLVED/"*) BACKUP_DEST_INSIDE=yes ;;
  *) BACKUP_DEST_INSIDE=no ;;
esac

# Compose selection and Compose file list (only meaningful with a valid .env).
if [ "$ENV_STATE" = "ok" ]; then
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/compose.sh"
  if lisa_build_compose_files "$EDGE_REPO"; then
    COMPOSE_READY=1
    SELECTED_SERVICES="$(lisa_selected_services)"
  else
    COMPOSE_READY=0
  fi
  if [ "$MODE" = "data" ] && [ "$COMPOSE_READY" -ne 1 ]; then
    die "The current .env service selection is invalid; 'reset data' would delete data and then fail to redeploy. Fix LISA_COMPOSE_SERVICES first."
  fi
fi

docker_available() {
  command -v docker >/dev/null 2>&1
}

docker_daemon_ready() {
  docker_available && docker ps -q >/dev/null 2>&1
}

# Effective Compose project name: ask docker compose itself when possible
# (COMPOSE_PROJECT_NAME from .env, the top-level "name:" and directory
# fallbacks are not necessarily identical), then fall back safely.
resolve_project_name() {
  local from_config="" from_compose_file=""

  if [ "$COMPOSE_READY" -eq 1 ] && docker_available; then
    from_config="$(docker compose --env-file .env "${LISA_COMPOSE_FILES[@]}" config 2>/dev/null |
      sed -n 's/^name:[[:space:]]*//p' | head -n 1 || true)"
    from_config="${from_config%\"}"
    from_config="${from_config#\"}"
  fi
  if [ -n "$from_config" ]; then
    PROJECT_NAME="$from_config"
    return 0
  fi
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    PROJECT_NAME="$COMPOSE_PROJECT_NAME"
    return 0
  fi
  from_compose_file="$(sed -n 's/^name:[[:space:]]*//p' "$EDGE_REPO/ops/deploy/compose.yml" | head -n 1 || true)"
  PROJECT_NAME="${from_compose_file:-lisa-edge}"
}
resolve_project_name

# ---------------------------------------------------------------------------
# Mount safety: never delete through a nested mount; fail closed when the
# mount table cannot be read.
# ---------------------------------------------------------------------------
mounts_below() {
  local root="$1"
  local table target
  command -v findmnt >/dev/null 2>&1 || return 2
  table="$(findmnt -rn -o TARGET 2>/dev/null)" || return 2
  # A readable mount table always contains at least "/"; an empty result
  # means the table could not really be read, so fail closed.
  [ -n "$table" ] || return 2
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    [ "$target" = "$root" ] && continue
    case "$target/" in
      "$root/"*) printf '%s\n' "$target" ;;
    esac
  done <<< "$table"
  return 0
}

require_no_nested_mounts() {
  local root="$1"
  local found=""
  if ! found="$(mounts_below "$root")"; then
    die "Cannot read the mount table (findmnt unavailable or failing); refusing to delete under $root."
  fi
  if [ -n "$found" ]; then
    echo "ERROR: mounted filesystems exist below $root:" >&2
    printf '  %s\n' "$found" >&2
    echo "Refusing to delete through a mount. Unmount the paths above (or move BACKUP_DEST outside DATA_ROOT) and rerun." >&2
    exit 1
  fi
}

# Delete one subtree that has already been proven to live under the
# validated DATA_ROOT. Symlinks are removed as links and never followed.
delete_tree() {
  local path="$1"

  case "$path" in
    ""|/) die "refusing to delete unsafe path: '$path'" ;;
    "$DATA_ROOT_RESOLVED"|"$DATA_ROOT_RESOLVED"/*) ;;
    *) die "refusing to delete outside the validated DATA_ROOT: $path" ;;
  esac
  [ "$path" != "$DATA_ROOT_RESOLVED" ] || die "refusing to delete DATA_ROOT itself: $path"
  case "$path/" in
    "$EDGE_REPO/"*) die "refusing to delete the repository checkout: $path" ;;
  esac

  if [ -L "$path" ]; then
    rm -f -- "$path"
    return 0
  fi
  [ -e "$path" ] || return 0
  require_no_nested_mounts "$path"
  rm -rf --one-file-system -- "$path"
}

# ---------------------------------------------------------------------------
# systemd helpers (tolerate partially missing units, never touch Rescue units)
# ---------------------------------------------------------------------------
unit_file_installed() {
  [ -f "$SYSTEMD_DIR/$1" ]
}

stop_unit_if_installed() {
  local unit="$1"
  unit_file_installed "$unit" || return 0
  systemctl stop "$unit" || die "could not stop $unit; refusing to delete data while it may still run."
}

disable_and_remove_unit() {
  local unit="$1"
  if unit_file_installed "$unit"; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f -- "$SYSTEMD_DIR/$unit"
  else
    # The unit may still be known to systemd without an installed file.
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  fi
}

install_unit_from_repo() {
  # Same repository-root behavior as ops/deploy/install-systemd.sh.
  local src="$1"
  local dst="$2"
  sed "s|/opt/lisa-edge|$EDGE_REPO|g" "$src" > "$dst"
  chmod 0644 "$dst"
}

# ---------------------------------------------------------------------------
# Docker cleanliness: project-scoped only. Never docker system/volume/network
# prune, never image or build-cache removal, never another project's
# resources.
# ---------------------------------------------------------------------------
PROJECT_FILTER=""

list_project_leftovers() {
  # Prints "kind id" lines for every resource still owned by the project.
  # Fails (fail closed) when any listing cannot be read.
  local containers networks volumes id

  containers="$(docker ps -aq --filter "$PROJECT_FILTER")" ||
    die "cannot list containers for project '$PROJECT_NAME'; refusing to continue."
  networks="$(docker network ls -q --filter "$PROJECT_FILTER")" ||
    die "cannot list networks for project '$PROJECT_NAME'; refusing to continue."
  volumes="$(docker volume ls -q --filter "$PROJECT_FILTER")" ||
    die "cannot list volumes for project '$PROJECT_NAME'; refusing to continue."

  while IFS= read -r id; do
    [ -n "$id" ] && printf 'container %s\n' "$id"
  done <<< "$containers"
  while IFS= read -r id; do
    [ -n "$id" ] && printf 'network %s\n' "$id"
  done <<< "$networks"
  while IFS= read -r id; do
    [ -n "$id" ] && printf 'volume %s\n' "$id"
  done <<< "$volumes"
  return 0
}

docker_project_cleanup() {
  if ! docker_available; then
    warn "docker is not installed; skipping container cleanup (nothing to remove)."
    return 0
  fi
  docker_daemon_ready ||
    die "Docker is installed but not reachable; start Docker and rerun so project cleanup can be verified."

  PROJECT_FILTER="label=com.docker.compose.project=$PROJECT_NAME"

  if [ "$COMPOSE_READY" -eq 1 ]; then
    info "Stopping the Compose stack (project: $PROJECT_NAME)..."
    docker compose --env-file .env "${LISA_COMPOSE_FILES[@]}" down --volumes --remove-orphans ||
      warn "docker compose down reported an error; continuing with label-scoped cleanup."
  else
    info "No usable Compose configuration; using label-scoped cleanup only (project: $PROJECT_NAME)."
  fi

  local leftovers kind id
  leftovers="$(list_project_leftovers)"
  if [ -n "$leftovers" ]; then
    info "Removing remaining resources owned by Compose project '$PROJECT_NAME'..."
    while read -r kind id; do
      [ -n "$id" ] || continue
      case "$kind" in
        container) docker rm -f "$id" >/dev/null || warn "could not remove container $id" ;;
        network) docker network rm "$id" >/dev/null || warn "could not remove network $id" ;;
        volume) docker volume rm "$id" >/dev/null || warn "could not remove volume $id" ;;
      esac
    done <<< "$leftovers"
  fi

  leftovers="$(list_project_leftovers)"
  if [ -n "$leftovers" ]; then
    echo "ERROR: Docker resources owned by project '$PROJECT_NAME' remain after cleanup:" >&2
    printf '  %s\n' "$leftovers" >&2
    die "manual cleanup required; the node is NOT clean."
  fi
  info "Docker is clean for project '$PROJECT_NAME' (images and build cache untouched)."
}

# ---------------------------------------------------------------------------
# Plan output and confirmation
# ---------------------------------------------------------------------------
print_plan() {
  local services_display="${SELECTED_SERVICES:-"(unknown - no usable .env; defaults would apply on the next provisioning)"}"

  echo "==================================================================="
  echo " LISA Edge reset plan"
  echo "==================================================================="
  echo "  Reset mode:              $MODE"
  echo "  Hostname:                $(hostname)"
  echo "  Repository:              $EDGE_REPO"
  echo "  Compose project name:    $PROJECT_NAME"
  echo "  DATA_ROOT:               $DATA_ROOT_RESOLVED"
  if [ "$BACKUP_DEST_INSIDE" = "yes" ]; then
    echo "  BACKUP_DEST:             $BACKUP_DEST_RESOLVED (inside DATA_ROOT)"
  else
    echo "  BACKUP_DEST:             $BACKUP_DEST_RESOLVED (outside DATA_ROOT)"
  fi
  echo "  Selected services:       $services_display"
  echo

  case "$MODE" in
    data)
      cat <<PLAN
  Will DELETE:
    - Compose containers, networks and named/anonymous volumes owned by
      project '$PROJECT_NAME' (orphans included)
    - $DATA_ROOT_RESOLVED/data      (service runtime data, Tailscale state)
    - $DATA_ROOT_RESOLVED/docker    (bind-mounted volumes: Matter fabric,
      OTBR live state, Home Assistant, MQTT data + generated password file,
      Zigbee2MQTT, Node-RED, Uptime Kuma)
    - $DATA_ROOT_RESOLVED/state     (generated service state)
    - $DATA_ROOT_RESOLVED/logs      (runtime logs)
    - $DATA_ROOT_RESOLVED/secrets   (generated service secrets)

  Will PRESERVE:
    - .env and .env.before-wizard-* (configuration, including its secrets)
    - $DATA_ROOT_RESOLVED/backups and any external BACKUP_DEST
    - /var/lib/lisa-edge/provisioned, installed LISA units and enablement
    - repository checkout, Docker Engine, images and build cache
    - Ubuntu packages, SSH access, hostname, network and host bootstrap
    - the Rescue Layer (never touched by this mode)

  systemd:
    - stop before deletion: $RUNTIME_SERVICE, ${BACKUP_TIMERS[*]},
      any running backup service
    - after a SUCCESSFUL redeploy: restart lisa-edge-backup.timer and only
      the OTBR/Matter timers whose services are selected
    - after a FAILED redeploy: all backup timers stay stopped

  Redeploys services:        yes (using the retained .env)
  Reinstalls the Production OS: no

  Note: .env is kept, so configuration secrets stored in .env remain on the
  host. Auto-restore settings in .env (OTBR_AUTO_RESTORE_DATASET,
  MATTER_AUTO_RESTORE_DATA) may repopulate service data from the preserved
  local backups during the redeploy.
PLAN
      ;;
    provisioning)
      cat <<PLAN
  Will DELETE:
    - Compose containers, networks and volumes owned by project
      '$PROJECT_NAME' (orphans included)
    - everything under $DATA_ROOT_RESOLVED (runtime data, generated
      secrets, Matter fabric data, OTBR dataset backups, LOCAL backups)
    - .env, .env.tmp and .env.before-wizard-* in the repository
    - $STATE_DIR/provisioned (the provision marker)
    - installed production unit files: ${PRODUCTION_UNIT_FILES[*]}
    - $SBIN_DIR/lisa-edge (only when it links into this checkout)

  Will PRESERVE:
    - Ubuntu Server, installed packages, Docker Engine, images, build cache
    - the repository checkout, the administrative user, SSH keys and access
    - hostname, network configuration, sudo state
    - host bootstrap configuration (SSH hardening, Thread sysctl, journald
      limits, Chrony, Avahi) - never reversed package by package
    - backups located OUTSIDE DATA_ROOT
    - the Rescue Layer and its units (never touched by this mode)

  systemd:
    - disable, stop and remove: ${PRODUCTION_UNIT_FILES[*]}
    - reinstall and enable: $FIRST_BOOT_SERVICE (first-boot provisioning)
    - daemon-reload and reset-failed for the LISA units

  Redeploys services:        no
  Reinstalls the Production OS: no
PLAN
      ;;
    factory)
      cat <<PLAN
  Will DELETE (through the Rescue Layer reinstall workflow, NOT here):
    - the entire Production OS disk, including DATA_ROOT and any local
      backups stored on the production disk

  Will PRESERVE:
    - the Rescue Layer on its own disk
    - external backups (NAS, removable media, remote storage)

  systemd:
    - production units disappear with the Production filesystem
    - Rescue Layer units remain owned by the Rescue Layer

  Redeploys services:        no
  Reinstalls the Production OS: yes - through the Rescue Layer only

  This command NEVER erases a disk itself. The wipe and reinstall happen
  exclusively through the reviewed production autoinstall workflow, which
  matches the target disk by serial. The reinstalled Production OS comes up
  unprovisioned with lisa-first-boot.service and lisa-edge-provision
  available.
PLAN
      ;;
  esac
  echo "==================================================================="
}

confirm_or_abort() {
  local phrase="$1"
  local answer=""
  echo
  echo "This operation is destructive and cannot be undone by this script."
  printf "Type '%s' to continue (anything else aborts): " "$phrase"
  read -r answer || answer=""
  if [ "$answer" != "$phrase" ]; then
    echo "Aborted. No changes were made."
    exit 1
  fi
}

report_external_backups() {
  if [ "$BACKUP_DEST_INSIDE" = "no" ]; then
    echo "External backups preserved at: $BACKUP_DEST_RESOLVED"
  fi
}

# ---------------------------------------------------------------------------
# Mode: reset data
# ---------------------------------------------------------------------------
DATA_MODE_TARGETS=(data docker state logs secrets)

run_reset_data() {
  local target timer

  # Validate every deletion target against the mount table BEFORE stopping
  # anything, so a doomed reset aborts with the node still running.
  for target in "${DATA_MODE_TARGETS[@]}"; do
    if [ -d "$DATA_ROOT_RESOLVED/$target" ] && [ ! -L "$DATA_ROOT_RESOLVED/$target" ]; then
      require_no_nested_mounts "$DATA_ROOT_RESOLVED/$target"
    fi
  done

  info "Stopping production timers and services before deletion..."
  for timer in "${BACKUP_TIMERS[@]}"; do
    stop_unit_if_installed "$timer"
  done
  for target in "${BACKUP_SERVICES[@]}"; do
    stop_unit_if_installed "$target"
  done
  stop_unit_if_installed "$RUNTIME_SERVICE"

  docker_project_cleanup

  info "Deleting LISA-owned runtime state under $DATA_ROOT_RESOLVED..."
  for target in "${DATA_MODE_TARGETS[@]}"; do
    delete_tree "$DATA_ROOT_RESOLVED/$target"
  done
  info "Preserved: $DATA_ROOT_RESOLVED/backups"
  report_external_backups

  info "Recreating the directory structure..."
  DATA_ROOT="$DATA_ROOT_RESOLVED" bash "$EDGE_REPO/install/bootstrap/phases/30-directories.sh"

  info "Redeploying selected services with the retained .env..."
  if ! bash "$EDGE_REPO/ops/deploy/deploy.sh"; then
    echo >&2
    echo "ERROR: reset data cleanup succeeded but the redeploy FAILED." >&2
    echo "The node is NOT healthy. Backup timers remain STOPPED so they" >&2
    echo "cannot operate on an incomplete deployment." >&2
    echo >&2
    echo "Recover with:" >&2
    echo "  sudo ./lisa-edge setup   (choose 'Refresh services')" >&2
    echo "then restore the backup timers with:" >&2
    echo "  sudo bash $EDGE_REPO/ops/deploy/install-systemd.sh" >&2
    exit 1
  fi

  info "Restoring production timers for the selected services..."
  restore_timers_after_deploy

  echo
  echo "reset data completed: runtime state was recreated and the selected"
  echo "services were redeployed and passed the health check."
  echo "Kept: .env (including its configuration secrets) and local backups."
}

restore_timers_after_deploy() {
  local failed=0

  if unit_file_installed lisa-edge-backup.timer; then
    systemctl enable --now lisa-edge-backup.timer || failed=1
  fi
  if unit_file_installed lisa-otbr-dataset-backup.timer; then
    if service_selected otbr; then
      systemctl enable --now lisa-otbr-dataset-backup.timer || failed=1
    else
      systemctl disable --now lisa-otbr-dataset-backup.timer >/dev/null 2>&1 || true
      info "OTBR dataset backup timer left disabled (OTBR is not selected)."
    fi
  fi
  if unit_file_installed lisa-matter-data-backup.timer; then
    if service_selected matter; then
      systemctl enable --now lisa-matter-data-backup.timer || failed=1
    else
      systemctl disable --now lisa-matter-data-backup.timer >/dev/null 2>&1 || true
      info "Matter data backup timer left disabled (Matter is not selected)."
    fi
  fi

  verify_timer_active() {
    systemctl is-active --quiet "$1" || {
      warn "$1 is not active after restart."
      failed=1
    }
  }
  unit_file_installed lisa-edge-backup.timer && verify_timer_active lisa-edge-backup.timer
  unit_file_installed lisa-otbr-dataset-backup.timer && service_selected otbr &&
    verify_timer_active lisa-otbr-dataset-backup.timer
  unit_file_installed lisa-matter-data-backup.timer && service_selected matter &&
    verify_timer_active lisa-matter-data-backup.timer

  if [ "$failed" -ne 0 ]; then
    echo "ERROR: the redeploy succeeded but at least one backup timer could" >&2
    echo "not be restored. Verify with: systemctl list-timers 'lisa-*'" >&2
    echo "and reinstall timers with: sudo bash $EDGE_REPO/ops/deploy/install-systemd.sh" >&2
    exit 1
  fi
}

service_selected() {
  local wanted="$1" service
  for service in $SELECTED_SERVICES; do
    [ "$service" = "$wanted" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Mode: reset provisioning
# ---------------------------------------------------------------------------
run_reset_provisioning() {
  local unit child target

  # Validate the whole DATA_ROOT against the mount table up front.
  if [ -d "$DATA_ROOT_RESOLVED" ]; then
    require_no_nested_mounts "$DATA_ROOT_RESOLVED"
  fi

  info "Disabling and stopping production runtime and backup units..."
  for unit in "${PRODUCTION_UNIT_FILES[@]}"; do
    disable_and_remove_unit "$unit"
  done

  docker_project_cleanup

  info "Deleting all LISA state under $DATA_ROOT_RESOLVED (including local backups)..."
  if [ -d "$DATA_ROOT_RESOLVED" ] && [ ! -L "$DATA_ROOT_RESOLVED" ]; then
    shopt -s nullglob dotglob
    for child in "$DATA_ROOT_RESOLVED"/*; do
      delete_tree "$child"
    done
    shopt -u nullglob dotglob
  elif [ -L "$DATA_ROOT_RESOLVED" ]; then
    die "DATA_ROOT is a symlink after resolution; refusing to delete through it: $DATA_ROOT_RESOLVED"
  fi

  info "Removing LISA configuration..."
  rm -f -- "$EDGE_REPO/.env" "$EDGE_REPO/.env.tmp"
  for target in "$EDGE_REPO"/.env.before-wizard-*; do
    [ -e "$target" ] && rm -f -- "$target"
  done

  info "Removing the provision marker..."
  install -d -m 0755 "$STATE_DIR"
  rm -f -- "$STATE_DIR/provisioned"

  if [ -L "$SBIN_DIR/lisa-edge" ]; then
    local link_target
    link_target="$(readlink -f -- "$SBIN_DIR/lisa-edge" 2>/dev/null || true)"
    if [ "$link_target" = "$EDGE_REPO/lisa-edge" ]; then
      rm -f -- "$SBIN_DIR/lisa-edge"
      info "Removed $SBIN_DIR/lisa-edge (was linked to this checkout)."
    fi
  fi

  info "Restoring the first-boot provisioning state..."
  install_unit_from_repo \
    "$EDGE_REPO/install/provisioning/systemd/$FIRST_BOOT_SERVICE" \
    "$SYSTEMD_DIR/$FIRST_BOOT_SERVICE"
  systemctl daemon-reload
  systemctl enable "$FIRST_BOOT_SERVICE"
  ln -sfn "$EDGE_REPO/lisa-edge" "$SBIN_DIR/lisa-edge-provision"
  bash "$EDGE_REPO/install/provisioning/notify-first-boot.sh" ||
    warn "could not install the first-boot MOTD notice (cosmetic only)."
  for unit in "${PRODUCTION_UNIT_FILES[@]}" "$FIRST_BOOT_SERVICE"; do
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  done

  echo
  echo "LISA Edge has been reset to the unprovisioned state."
  echo "Run: sudo lisa-edge-provision"
  report_external_backups
}

# ---------------------------------------------------------------------------
# Mode: reset factory
# ---------------------------------------------------------------------------
on_rescue_layer() {
  [ -d "$RESCUE_ROOT/scripts" ] && [ ! -f "$STATE_DIR/provisioned" ]
}

run_reset_factory() {
  if ! on_rescue_layer; then
    # Running on the Production OS: this host cannot safely erase the root
    # filesystem it is running from, and the repository has no verified
    # one-time boot-into-rescue mechanism. Refuse and hand off.
    echo
    echo "Factory reset preflight (running on the Production OS):"
    if [ -f "$STATE_DIR/provisioned" ]; then
      echo "  - provision marker present: this is a provisioned production host"
    fi
    if [ -f "$EDGE_REPO/rescue/scripts/reinstall-guide.sh" ]; then
      echo "  - Rescue reinstall tooling is present in this repository"
    else
      echo "  - WARNING: rescue/scripts/reinstall-guide.sh is missing from this checkout"
    fi
    if [ -d "$RESCUE_ROOT/scripts" ]; then
      echo "  - $RESCUE_ROOT/scripts exists on this host"
    else
      echo "  - the Rescue Layer lives on its own disk (typically eMMC) and is"
      echo "    expected to be invisible from the Production OS"
    fi
    cat <<HANDOFF

The Production OS cannot safely erase the disk it is running from, and no
verified one-time reboot-into-rescue mechanism exists in this repository.
Nothing was deleted.

To perform the factory reset:
  1. Reboot and select the Rescue Layer boot entry (the eMMC disk) in the
     firmware boot menu.
  2. Log into the Rescue OS.
  3. From the lisa-edge checkout on the Rescue OS, rerun:
       sudo ./lisa-edge reset factory

NO factory reset was performed.
HANDOFF
    exit 0
  fi

  # Running on the Rescue Layer: guarded handoff to the canonical
  # production reinstall workflow. This repository intentionally has no
  # automated disk-wipe path; the reviewed production autoinstall USB
  # (serial-matched target selection) is the only sanctioned wipe/reinstall
  # mechanism, so this command never selects or erases a disk itself.
  confirm_or_abort "RESET UBUNTU"

  echo
  info "Canonical production reinstall procedure follows. Identify the"
  info "production SSD by serial; ambiguous or unverified targets must be"
  info "refused by you and by the autoinstall profile."
  echo
  if [ -x "$RESCUE_ROOT/scripts/reinstall-guide.sh" ]; then
    "$RESCUE_ROOT/scripts/reinstall-guide.sh"
  else
    bash "$EDGE_REPO/rescue/scripts/reinstall-guide.sh"
  fi
  cat <<AFTER

Factory reset handoff complete. The disk wipe and Ubuntu reinstall happen
ONLY when you boot the reviewed production autoinstall USB against the
serial-matched production disk. After the reinstall, the Production OS
boots unprovisioned with lisa-first-boot.service enabled and
lisa-edge-provision available; external backups remain intact.

This command did NOT erase any disk. The factory reset is complete only
after the autoinstall workflow has run and the new Production OS has been
provisioned.
AFTER
  report_external_backups
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Preflight: when Docker exists but its daemon is unreachable, project-scoped
# cleanup cannot be verified. Fail before anything is stopped or deleted.
if [ "$DRY_RUN" -eq 0 ] && [ "$MODE" != "factory" ]; then
  if docker_available && ! docker_daemon_ready; then
    die "Docker is installed but not reachable; start Docker and rerun so project cleanup can be verified."
  fi
fi

print_plan

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "[dry-run] No services were stopped, no systemd state was changed,"
  echo "[dry-run] no files were deleted, no Docker resources were touched,"
  echo "[dry-run] nothing was deployed. Re-run without --dry-run to reset."
  exit 0
fi

case "$MODE" in
  data)
    confirm_or_abort "RESET DATA"
    run_reset_data
    ;;
  provisioning)
    confirm_or_abort "RESET LISA"
    run_reset_provisioning
    ;;
  factory)
    run_reset_factory
    ;;
esac
