#!/usr/bin/env bash
set -euo pipefail

# LISA Edge service lifecycle (operator entry points:
#   lisa-edge service add <service-key>
#   lisa-edge service remove <service-key> [--dry-run] [--all-backups] [--purge-image]
#   lisa-edge service start [service-key ...]
#   lisa-edge service stop [service-key ...]
# 'service list' stays in services/list.sh).
#
# Meaning of the verbs:
#   add     select, configure, prepare, start/refresh through the internal
#           deployment engine, and verify one new service
#   remove  unselect one service and safely delete ONLY its active data;
#           backups and images are preserved by default
#   start   change runtime state without changing selection
#   stop    change runtime state without changing selection (Compose stop
#           semantics - containers, data, and images are preserved)
#
# Safety model for remove mirrors ops/deploy/reset-node.sh: validate
# everything before the first mutation, fail closed on ambiguity, require an
# exact typed confirmation, never follow symlinks, never delete through a
# nested mount, and never touch Docker resources of unrelated projects.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$EDGE_REPO"

TESTING="${LISA_EDGE_TESTING:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "[LISA] $*"; }

usage() {
  cat <<'EOF'
Usage: lisa-edge service <subcommand> [arguments]

Subcommands:
  list                          List available service selection keys and
                                their installation/runtime status
  add [service-key]             Select, configure, start, and verify one
                                new service (dependencies are added too).
                                Without a key, an interactive menu offers
                                the services that are not selected yet.
  remove [service-key] [opts]   Unselect one service and safely remove its
                                active data. Backups and images are
                                preserved by default. Without a key, an
                                interactive menu offers the selected
                                services (options still apply).
      --dry-run                 Print the complete removal plan only
      --all-backups             Also delete backups dedicated to this
                                service (second confirmation required)
      --purge-image             Also delete the service image when it is
                                provably unused and unshared
  start [service-key ...]       Start selected services that are not
                                running. Without keys, an interactive menu
                                offers the startable services (numbers,
                                keys, or 'all').
  stop [service-key ...]        Stop running selected services. Without
                                keys, an interactive menu offers the
                                active services (numbers, keys, or 'all').

Service keys are shell-separated; see 'lisa-edge service list'.
Interactive menus need a terminal; non-interactive callers must pass
explicit service keys. In a menu, blank input or 'q' cancels safely.
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ] && [ "$TESTING" != "1" ]; then
    die "Run as root: sudo ./lisa-edge service $*"
  fi
}

require_env() {
  [ -f "$EDGE_REPO/.env" ] || die "missing .env; run 'sudo ./lisa-edge setup' first."
  set -a
  # Template defaults first (like the setup wizard), so newly added
  # services get concrete defaults for values the operator did not set.
  # shellcheck disable=SC1091
  [ -f "$EDGE_REPO/.env.template" ] && . "$EDGE_REPO/.env.template"
  # shellcheck disable=SC1091
  . "$EDGE_REPO/.env"
  set +a
}

load_libs() {
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/paths.sh"
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/compose.sh"
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/env-file.sh"
}

# True when this host runs systemd (same rule as the health check).
has_systemd() {
  case "${LISA_HEALTH_ASSUME_SYSTEMD:-auto}" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

docker_ready() {
  command -v docker >/dev/null 2>&1 && docker ps -q >/dev/null 2>&1
}

normalize_key_or_die() {
  local key
  key="$(lisa_normalize_service_id "$1")"
  case " $LISA_ALL_SERVICES " in
    *" $key "*) printf '%s\n' "$key" ;;
    *) die "unknown service key: $1 (see 'lisa-edge service list')" ;;
  esac
}

service_is_selected() {
  lisa_has_service "$1"
}

container_state() {
  local container state
  container="$(lisa_service_container_name "$1")"
  # Some Docker versions print a blank stdout line before failing on a
  # missing container; trust the output only on success and non-empty.
  if state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)"; then
    state="${state//[$'\r\n']/}"
    [ -n "$state" ] && { printf '%s\n' "$state"; return 0; }
  fi
  echo absent
}

container_is_running() {
  [ "$(container_state "$1")" = "running" ]
}

# ---------------------------------------------------------------------------
# Interactive selection (used when a lifecycle command is called without
# service arguments). Menus are offered only on a real terminal; in a
# non-interactive context a missing service argument fails with usage
# guidance instead of waiting for input.
# ---------------------------------------------------------------------------

# True when an interactive menu may be shown. Test seam (mirrors the
# repository's LISA_EDGE_TESTING contract): under LISA_EDGE_TESTING=1,
# LISA_TEST_FORCE_TTY=1/0 overrides the real terminal check so both paths
# are testable without a pty.
interactive_ok() {
  if [ "$TESTING" = "1" ] && [ -n "${LISA_TEST_FORCE_TTY:-}" ]; then
    [ "$LISA_TEST_FORCE_TTY" = "1" ]
    return
  fi
  [ -t 0 ] && [ -t 1 ]
}

require_menu_context_or_die() {
  local verb="$1"
  if ! interactive_ok; then
    usage >&2
    die "service $verb requires a <service-key> when no terminal is available for interactive selection."
  fi
}

# Runtime state for menu display: 'unknown' when Docker cannot be queried,
# otherwise the container state (running, exited, absent, ...).
menu_runtime_state() {
  if [ "${MENU_DOCKER_READY:-0}" -eq 1 ]; then
    container_state "$1"
  else
    printf 'unknown\n'
  fi
}

# One catalog line per candidate (add menu): key, display name,
# dependencies, and purpose.
menu_line_catalog() {
  local key="$1" deps
  deps="$(lisa_service_dependencies "$key")"
  printf '%-14s %-26s %s%s' "$key" "$(lisa_service_name "$key")" \
    "$(lisa_service_description "$key")" "${deps:+ [requires: $deps]}"
}

# One runtime line per candidate (remove/start/stop menus): key, display
# name, and current container state.
menu_line_runtime() {
  local key="$1"
  printf '%-14s %-26s state: %s' "$key" "$(lisa_service_name "$key")" \
    "$(menu_runtime_state "$key")"
}

# Print one numbered menu and read a selection.
#   prompt_service_menu <multi 0|1> <allow-all 0|1> <render-fn> <prompt> <candidate...>
# Accepts numbers and service keys (aliases included); 'all' selects every
# candidate when allowed. Blank input or 'q' cancels safely (exit 0, no
# mutation). The chosen keys land in MENU_SELECTED in candidate order.
prompt_service_menu() {
  local multi="$1" allow_all="$2" render="$3" prompt="$4"
  shift 4
  local candidates=("$@")
  local index=1 key input token chosen="" matched candidate count=0

  MENU_DOCKER_READY=0
  docker_ready && MENU_DOCKER_READY=1

  echo
  for key in "${candidates[@]}"; do
    printf '  %d) %s\n' "$index" "$($render "$key")"
    index=$((index + 1))
  done
  [ "$allow_all" = "1" ] && echo "  all) every service listed above"
  echo "  q) cancel"
  echo
  read -r -p "$prompt" input || input=""
  input="${input//,/ }"

  # Blank input cancels; so does a lone q/Q anywhere in the input.
  if [ -z "${input// /}" ]; then
    echo "Cancelled. No changes were made."
    exit 0
  fi
  for token in $input; do
    case "$token" in
      q|Q)
        echo "Cancelled. No changes were made."
        exit 0
        ;;
    esac
  done

  # shellcheck disable=SC2086
  set -- $input
  if [ "$allow_all" = "1" ] && [ "$#" -eq 1 ] && [ "${1,,}" = "all" ]; then
    chosen="${candidates[*]}"
  else
    for token in $input; do
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        [ "$token" -ge 1 ] && [ "$token" -le "${#candidates[@]}" ] ||
          die "invalid menu number: $token (nothing was changed)."
        key="${candidates[$((token - 1))]}"
      else
        key="$(lisa_normalize_service_id "$token")"
        matched=0
        for candidate in "${candidates[@]}"; do
          [ "$candidate" = "$key" ] && matched=1
        done
        [ "$matched" -eq 1 ] ||
          die "$token is not one of the listed candidates (nothing was changed)."
      fi
      case " $chosen " in
        *" $key "*) ;;
        *) chosen="${chosen:+$chosen }$key" ;;
      esac
    done
  fi

  count=0
  for key in $chosen; do count=$((count + 1)); done
  if [ "$multi" != "1" ] && [ "$count" -ne 1 ]; then
    die "select exactly one service (nothing was changed)."
  fi
  # Preserve candidate (registry) order.
  MENU_SELECTED=""
  for candidate in "${candidates[@]}"; do
    case " $chosen " in
      *" $candidate "*) MENU_SELECTED="${MENU_SELECTED:+$MENU_SELECTED }$candidate" ;;
    esac
  done
}

# Print the requested set ordered dependencies-first (input: words).
order_dependencies_first() {
  local pending=" $* " ordered="" service dependency ready
  while [ -n "${pending// /}" ]; do
    ready=""
    for service in $pending; do
      local blocked=0
      for dependency in $(lisa_service_dependencies "$service"); do
        case " $pending " in
          *" $dependency "*) blocked=1 ;;
        esac
      done
      if [ "$blocked" -eq 0 ]; then
        ready="${ready:+$ready }$service"
      fi
    done
    [ -n "$ready" ] || die "dependency cycle in service selection: $pending"
    ordered="${ordered:+$ordered }$ready"
    for service in $ready; do
      pending="${pending// $service / }"
    done
  done
  printf '%s\n' "$ordered"
}

reverse_words() {
  local result="" word
  for word in $*; do
    result="$word${result:+ $result}"
  done
  printf '%s\n' "$result"
}

# Canonical LISA_COMPOSE_SERVICES value for a selection (registry order).
canonical_selection() {
  local selection=" $* " service result=""
  for service in $LISA_ALL_SERVICES; do
    case "$selection" in
      *" $service "*) result="${result:+$result }$service" ;;
    esac
  done
  printf '%s\n' "$result"
}

compose_cmd() {
  docker compose --env-file .env "${LISA_COMPOSE_FILES[@]}" "$@"
}

run_hook() {
  local hook="$1"
  [ -n "$hook" ] || return 0
  bash "$EDGE_REPO/$hook"
}

report_service_state() {
  local service
  for service in "$@"; do
    printf '[LISA] %-16s container %-18s state: %s\n' \
      "$service" "$(lisa_service_container_name "$service")" "$(container_state "$service")"
  done
}

run_targeted_health() {
  bash "$EDGE_REPO/ops/deploy/healthcheck.sh" --services "$*" || true
}

check_thread_relationship_interactive() {
  if lisa_has_service matter && lisa_has_service otbr; then
    echo
    "$EDGE_REPO/services/matter-server/thread-sync-if-needed.sh" || true
  fi
}

# ---------------------------------------------------------------------------
# service add
# ---------------------------------------------------------------------------
cmd_add() {
  [ "$#" -le 1 ] || { usage >&2; die "service add accepts at most one <service-key>"; }
  require_root add "$@"
  require_env
  load_libs

  local key
  if [ "$#" -eq 1 ]; then
    key="$(normalize_key_or_die "$1")"
  else
    require_menu_context_or_die add
    local candidates=() service
    for service in $LISA_ALL_SERVICES; do
      service_is_selected "$service" || candidates+=("$service")
    done
    if [ "${#candidates[@]}" -eq 0 ]; then
      info "Every available service is already selected; there is nothing to add."
      return 0
    fi
    echo "Services available to add:"
    prompt_service_menu 0 0 menu_line_catalog \
      "Select ONE service to add (number or key, blank/q cancels): " \
      "${candidates[@]}"
    key="$MENU_SELECTED"
  fi

  if service_is_selected "$key"; then
    info "$key is already selected; the configuration was not changed."
    report_service_state "$key"
    run_targeted_health "$key"
    return 0
  fi

  # Resolve dependencies that must be added along with the service.
  local to_add="$key" dependency
  for dependency in $(lisa_service_dependencies "$key"); do
    if ! service_is_selected "$dependency"; then
      to_add="$dependency $to_add"
      info "Also adding $dependency because $key depends on it."
    fi
  done

  # Configure ONLY the newly added services (never the complete wizard).
  # shellcheck disable=SC1091
  . "$EDGE_REPO/install/provisioning/lib/ui.sh"
  local service wizard configure_function
  DRY_RUN=0
  for service in $to_add; do
    wizard="$EDGE_REPO/services/$(lisa_service_directory "$service")/provision.sh"
    # shellcheck disable=SC1090
    . "$wizard"
    configure_function="$(lisa_service_configure_function "$service")"
    declare -F "$configure_function" >/dev/null ||
      die "missing provisioning function for $service: $configure_function"
    "$configure_function"
  done

  # Host preparation needed by the new services (idempotent phases only).
  bash "$EDGE_REPO/install/bootstrap/phases/30-directories.sh"
  for service in $to_add; do
    if lisa_service_needs_thread_host_prep "$service"; then
      LISA_ENABLE_THREAD_HOST_PREP=1
      LISA_COMPOSE_SERVICES="$LISA_COMPOSE_SERVICES $service" \
        bash "$EDGE_REPO/install/bootstrap/phases/40-core-service-prep.sh"
    fi
  done

  # Atomically update .env: the new selection plus the keys owned by the
  # newly configured services.
  local new_selection updates=() env_key
  new_selection="$(canonical_selection "$(lisa_selected_services) $to_add")"
  updates+=("LISA_COMPOSE_SERVICES=$new_selection")
  for service in $to_add; do
    for env_key in $(lisa_service_env_vars "$service"); do
      updates+=("$env_key=${!env_key-}")
    done
  done
  lisa_env_update_keys "$EDGE_REPO/.env" "${updates[@]}" ||
    die "could not update .env; nothing was changed."
  info "Configuration updated (pre-change copy: ${LISA_ENV_BACKUP_FILE:-n/a})."

  # Reload the new configuration for everything that follows.
  require_env

  # Install/enable/disable service timers according to the new selection.
  if has_systemd; then
    bash "$EDGE_REPO/ops/deploy/install-systemd.sh"
  else
    info "systemd not detected; service timers were not changed."
  fi

  # Create/update/start and verify the updated stack through the internal
  # deployment engine (validates configuration, runs service preparation,
  # and finishes with the canonical health check).
  if ! bash "$EDGE_REPO/ops/deploy/deploy.sh"; then
    echo >&2
    echo "ERROR: the service refresh FAILED after $key was added." >&2
    echo "The selection change is kept so you can fix the cause and retry with:" >&2
    echo "  sudo ./lisa-edge setup   (choose 'Refresh services')" >&2
    echo "To roll the configuration back instead:" >&2
    echo "  sudo cp '$LISA_ENV_BACKUP_FILE' '$EDGE_REPO/.env'" >&2
    echo "  sudo ./lisa-edge setup   (choose 'Refresh services')" >&2
    exit 1
  fi

  echo
  info "Added: $to_add"
  report_service_state $to_add
  run_targeted_health "$to_add"

  # Adding Matter or OTBR next to the other one: run the shared interactive
  # Thread check-and-sync path now that both are inspectable.
  case " $to_add " in
    *" matter "*|*" otbr "*) check_thread_relationship_interactive ;;
  esac
}

# ---------------------------------------------------------------------------
# service remove
# ---------------------------------------------------------------------------

# Resolve and validate DATA_ROOT exactly like reset-node.sh (test overrides
# are honored only under LISA_EDGE_TESTING=1 and below /tmp).
resolve_data_root() {
  local value="${DATA_ROOT:-/srv/lisa-edge}" resolved
  [ -n "$value" ] || die "DATA_ROOT is empty; refusing to continue."
  resolved="$(readlink -m -- "$value")" || die "cannot resolve DATA_ROOT: $value"
  if [ "$TESTING" = "1" ]; then
    case "$resolved" in
      /tmp/*) printf '%s\n' "$resolved"; return 0 ;;
    esac
  fi
  lisa_validate_persistent_path DATA_ROOT "$value" || exit 1
  lisa_validate_persistent_path DATA_ROOT "$resolved" || exit 1
  printf '%s\n' "$resolved"
}

mounts_below() {
  local root="$1" table target
  command -v findmnt >/dev/null 2>&1 || return 2
  table="$(findmnt -rn -o TARGET 2>/dev/null)" || return 2
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
  local root="$1" found=""
  if ! found="$(mounts_below "$root")"; then
    die "cannot read the mount table (findmnt unavailable or failing); refusing to delete under $root."
  fi
  if [ -n "$found" ]; then
    echo "ERROR: mounted filesystems exist below $root:" >&2
    printf '  %s\n' "$found" >&2
    die "refusing to delete through a mount."
  fi
}

# Delete one subtree proven to live under the validated DATA_ROOT. Symlinks
# are removed as links and never followed.
delete_service_tree() {
  local path="$1"
  case "$path" in
    ""|/) die "refusing to delete unsafe path: '$path'" ;;
    "$DATA_ROOT_RESOLVED"/*) ;;
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

confirm_exact() {
  local phrase="$1" answer=""
  printf "Type '%s' to continue (anything else aborts): " "$phrase"
  read -r answer || answer=""
  if [ "$answer" != "$phrase" ]; then
    echo "Aborted. No changes were made."
    exit 1
  fi
}

# Delete only backup files dedicated to the service, by exact name pattern,
# never recursing and never touching shared full-stack archives.
purge_service_backups() {
  local service="$1" backup_dir resolved
  backup_dir="$(lisa_service_backup_dir "$service")"
  [ -n "$backup_dir" ] || return 0
  [ -d "$backup_dir" ] || { info "No dedicated backup directory for $service."; return 0; }
  resolved="$(readlink -m -- "$backup_dir")" || die "cannot resolve backup directory: $backup_dir"

  local shared_dest
  shared_dest="$(readlink -m -- "${BACKUP_DEST:-${DATA_ROOT:-/srv/lisa-edge}/backups}")"
  [ "$resolved" != "$shared_dest" ] ||
    die "the $service backup directory equals BACKUP_DEST; refusing to delete shared backups."
  if find "$resolved" -maxdepth 1 -type f -name 'lisa-edge-backup-*.tar.gz' -print -quit 2>/dev/null | grep -q .; then
    die "$resolved contains shared full-stack archives; refusing --all-backups."
  fi
  require_no_nested_mounts "$resolved"

  local patterns=()
  case "$service" in
    matter) patterns=('matter-data-*.tar.gz' 'matter-data-*.tar.gz.sha256' 'matter-data-*.tar.gz.meta' \
      'latest.matter-data.tar.gz' 'pending.matter-data.tar.gz' 'pending.reset') ;;
    otbr) patterns=('thread-dataset-*.hex' 'thread-dataset-*.hex.sha256' 'thread-dataset-*.hex.meta' \
      'latest.dataset.hex' 'pending.dataset.hex' 'pending.new-network') ;;
    *) return 0 ;;
  esac
  local pattern
  for pattern in "${patterns[@]}"; do
    find "$resolved" -maxdepth 1 \( -type f -o -type l \) -name "$pattern" -exec rm -f -- {} +
  done
  info "Deleted $service-dedicated backups under $resolved (shared archives untouched)."
}

# Remove the exact selected image only when every safety condition is proven.
purge_service_image() {
  local service="$1" image_var image_ref image_id other other_var other_ref
  image_var="$(lisa_service_image_variable "$service")"
  image_ref="${!image_var-}"
  if [ -z "$image_ref" ]; then
    info "Image preserved: $image_var is not set, so the exact image is unknown."
    return 0
  fi
  if ! image_id="$(docker image inspect -f '{{.Id}}' "$image_ref" 2>/dev/null)"; then
    info "Image preserved: $image_ref is not present locally (nothing to remove)."
    return 0
  fi
  for other in $(lisa_selected_services); do
    [ "$other" = "$service" ] && continue
    other_var="$(lisa_service_image_variable "$other")" || continue
    other_ref="${!other_var-}"
    if [ "$other_ref" = "$image_ref" ]; then
      info "Image preserved: $image_ref is also referenced by the selected service '$other'."
      return 0
    fi
  done
  local users
  if ! users="$(docker ps -aq --filter "ancestor=$image_id" 2>/dev/null)"; then
    info "Image preserved: could not verify that no container uses $image_ref."
    return 0
  fi
  if [ -n "$users" ]; then
    info "Image preserved: containers still use $image_ref (including unrelated projects)."
    return 0
  fi
  if docker rmi "$image_ref" >/dev/null; then
    info "Removed image $image_ref ($image_id)."
  else
    info "Image preserved: docker could not remove $image_ref safely."
  fi
}

cmd_remove() {
  local key="" dry_run=0 all_backups=0 purge_image=0 arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --dry-run) dry_run=1 ;;
      --all-backups) all_backups=1 ;;
      --purge-image) purge_image=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) usage >&2; die "unknown service remove option: $arg" ;;
      *)
        [ -z "$key" ] || { usage >&2; die "service remove accepts exactly one <service-key>"; }
        key="$arg"
        ;;
    esac
    shift
  done
  [ "$dry_run" -eq 1 ] || require_root remove "${key:-}"
  require_env
  load_libs
  lisa_env_file_is_valid "$EDGE_REPO/.env" || die ".env does not parse; fix it before removing services."

  if [ -z "$key" ]; then
    require_menu_context_or_die remove
    local selected_candidates=() candidate_key
    for candidate_key in $(lisa_selected_services); do
      selected_candidates+=("$candidate_key")
    done
    if [ "${#selected_candidates[@]}" -eq 0 ]; then
      info "No service is selected; there is nothing to remove."
      return 0
    fi
    echo "Selected services (removal is possible in any runtime state):"
    prompt_service_menu 0 0 menu_line_runtime \
      "Select ONE service to remove (number or key, blank/q cancels): " \
      "${selected_candidates[@]}"
    key="$MENU_SELECTED"
  fi
  key="$(normalize_key_or_die "$key")"

  service_is_selected "$key" || die "$key is not selected; nothing to remove."

  # Refuse to remove a dependency while selected dependents remain.
  local dependent blocked=""
  for dependent in $(lisa_service_dependents "$key"); do
    if service_is_selected "$dependent"; then
      blocked="${blocked:+$blocked }$dependent"
    fi
  done
  if [ -n "$blocked" ]; then
    die "$key is required by the selected service(s): $blocked. Remove them first; services are never cascade-removed."
  fi

  if [ "$dry_run" -eq 0 ]; then
    docker_ready || die "Docker is not reachable; start Docker so the removal can be verified."
  fi

  DATA_ROOT_RESOLVED="$(resolve_data_root)"
  case "$EDGE_REPO/" in
    "$DATA_ROOT_RESOLVED/"*) die "DATA_ROOT contains the repository checkout; refusing." ;;
  esac

  # Validate the owned paths and the mount table BEFORE any mutation.
  local relative absolute owned_paths=()
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    absolute="$DATA_ROOT_RESOLVED/$relative"
    owned_paths+=("$absolute")
    if [ -d "$absolute" ] && [ ! -L "$absolute" ]; then
      require_no_nested_mounts "$absolute"
    fi
  done < <(lisa_service_data_paths "$key")

  lisa_build_compose_files "$EDGE_REPO" || die "the current service selection is invalid; fix .env first."

  local compose_name container_name timer backup_dir image_var
  compose_name="$(lisa_service_compose_name "$key")"
  container_name="$(lisa_service_container_name "$key")"
  timer="$(lisa_service_timer "$key")"
  backup_dir="$(lisa_service_backup_dir "$key")"
  image_var="$(lisa_service_image_variable "$key")"

  local new_selection remaining="" candidate
  for candidate in $(lisa_selected_services); do
    [ "$candidate" = "$key" ] || remaining="${remaining:+$remaining }$candidate"
  done
  new_selection="$(canonical_selection "$remaining")"
  # Removing the final service is allowed: the selection becomes explicitly
  # empty and the empty deployment is reconciled by the internal engine.

  echo "==================================================================="
  echo " LISA Edge service removal plan"
  echo "==================================================================="
  echo "  Service:                 $key ($(lisa_service_name "$key"))"
  echo "  Selection change:        '$(lisa_selected_services)' -> '${new_selection:-(none)}'"
  echo "  Container to remove:     $container_name (Compose service $compose_name)"
  echo "  Active data to DELETE:"
  printf '    - %s\n' "${owned_paths[@]}"
  if [ -n "$timer" ]; then
    echo "  Timer to disable:        $timer"
  else
    echo "  Timer to disable:        (none)"
  fi
  if [ "$all_backups" -eq 1 ] && [ -n "$backup_dir" ]; then
    echo "  Dedicated backups:       DELETED from $backup_dir (--all-backups)"
  else
    echo "  Dedicated backups:       preserved${backup_dir:+ ($backup_dir)}"
  fi
  echo "  Shared full-stack backups: always preserved"
  if [ "$purge_image" -eq 1 ]; then
    echo "  Image:                   removed only if provably unused (${!image_var-unknown})"
  else
    echo "  Image:                   preserved (${!image_var-unknown})"
  fi
  echo "  Repository files:        preserved (Compose, scripts, documentation)"
  echo "==================================================================="

  if [ "$dry_run" -eq 1 ]; then
    echo
    echo "[dry-run] No confirmation was requested, no container was stopped,"
    echo "[dry-run] no file was deleted, and the configuration was not changed."
    return 0
  fi

  echo
  echo "This operation is destructive: the service's active data is deleted."
  confirm_exact "REMOVE ${key^^}"

  # Fresh dedicated backup before deleting active data (fail closed).
  local backup_hook
  backup_hook="$(lisa_service_pre_remove_backup_hook "$key")"
  if [ -n "$backup_hook" ]; then
    local has_state=0 path
    for path in "${owned_paths[@]}"; do
      if [ -e "$path" ] && [ -n "$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        has_state=1
      fi
    done
    if [ "$has_state" -eq 1 ]; then
      info "Creating a fresh $key backup before its active data is deleted..."
      if ! bash "$EDGE_REPO/$backup_hook" --label pre-remove; then
        echo "ERROR: could not create the pre-removal $key backup; nothing was deleted." >&2
        if [ "$key" = "otbr" ]; then
          echo "OTBR's dataset can only be exported from a RUNNING border router;" >&2
          echo "start it first with: sudo ./lisa-edge service start otbr" >&2
        fi
        exit 1
      fi
    else
      info "$key has no active data; skipping the pre-removal backup."
    fi
  fi

  # Stop and remove only the target service's Compose container.
  info "Stopping and removing the $container_name container..."
  compose_cmd stop "$compose_name" || warn "could not stop $compose_name (continuing)."
  compose_cmd rm -f "$compose_name" || warn "could not remove $compose_name (continuing)."

  # Unselect the service (atomic .env update with a pre-change copy).
  lisa_env_update_keys "$EDGE_REPO/.env" "LISA_COMPOSE_SERVICES=$new_selection" ||
    die "could not update .env; the service data was NOT deleted."
  info "Selection updated (pre-change copy: ${LISA_ENV_BACKUP_FILE:-n/a})."
  require_env

  # Delete only the validated service-owned active data.
  local target
  for target in "${owned_paths[@]}"; do
    delete_service_tree "$target"
  done
  info "Deleted the $key active data."

  # Disable the dedicated timer.
  if [ -n "$timer" ] && has_systemd; then
    systemctl disable --now "$timer" >/dev/null 2>&1 || true
    info "Disabled $timer."
  fi

  if [ "$all_backups" -eq 1 ]; then
    echo
    echo "WARNING: --all-backups deletes every backup dedicated to $key."
    echo "Without them, $key data cannot be restored after this point."
    confirm_exact "DELETE ${key^^} BACKUPS"
    purge_service_backups "$key"
  fi

  # Refresh and verify the remaining stack through the internal engine
  # (removes obsolete Compose orphans and ends with the health check). With
  # an empty remaining selection the engine reconciles the intentionally
  # empty deployment instead of starting anything.
  if [ -n "$new_selection" ]; then
    info "Refreshing the remaining selected stack..."
  else
    info "No service remains selected; reconciling the empty deployment..."
  fi
  if ! bash "$EDGE_REPO/ops/deploy/deploy.sh"; then
    echo "ERROR: the remaining stack failed its refresh/health check." >&2
    echo "Inspect next: sudo ./lisa-edge health; sudo ./lisa-edge status" >&2
    exit 1
  fi

  if [ "$purge_image" -eq 1 ]; then
    purge_service_image "$key"
  fi

  echo
  echo "service remove completed: $key was unselected, its container and"
  if [ -n "$new_selection" ]; then
    echo "active data were removed, and the remaining stack passed the health"
    echo "check. Backups were preserved$( [ "$all_backups" -eq 1 ] && echo " except the $key-dedicated ones (deleted on request)" )."
  else
    echo "active data were removed. No service remains selected; the host"
    echo "stays configured and provisioned with an intentionally empty"
    echo "deployment. Backups were preserved$( [ "$all_backups" -eq 1 ] && echo " except the $key-dedicated ones (deleted on request)" )."
  fi
}

# ---------------------------------------------------------------------------
# service start / service stop
# ---------------------------------------------------------------------------

# Parse and validate explicitly requested keys against the selection.
# Rejects unselected services. (Called with at least one key; the no-key
# case is handled by the interactive menus.)
resolve_runtime_targets() {
  local action="$1"
  shift
  local targets="" key
  for key in "$@"; do
    key="$(normalize_key_or_die "$key")"
    service_is_selected "$key" ||
      die "$key is not selected. Select and configure it first with: sudo ./lisa-edge service add $key"
    case " $targets " in
      *" $key "*) ;;
      *) targets="${targets:+$targets }$key" ;;
    esac
  done
  [ -n "$targets" ] || die "no service to $action."
  printf '%s\n' "$targets"
}

# Interactive candidate selection for start/stop. mode=start offers the
# selected services that are not active (absent, exited, created, or dead);
# mode=stop offers the active ones (running, restarting, or paused). Multi-
# select with numbers, keys, or 'all'. Exits 0 with a clear message when
# there is no eligible candidate. The chosen keys land in MENU_SELECTED
# (this function must be called directly, never inside a command
# substitution, so the menu is displayed and cancel exits work).
choose_runtime_targets_interactive() {
  local mode="$1" verb_label="$2"
  require_menu_context_or_die "$mode"

  local candidates=() service state
  for service in $(lisa_selected_services); do
    state="$(container_state "$service")"
    case "$mode:$state" in
      start:running|start:restarting|start:paused) ;;
      start:*) candidates+=("$service") ;;
      stop:running|stop:restarting|stop:paused) candidates+=("$service") ;;
      stop:*) ;;
    esac
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    if [ -z "$(lisa_selected_services)" ]; then
      info "No service is selected; there is nothing to $mode."
    elif [ "$mode" = "start" ]; then
      info "Every selected service is already running; there is nothing to start."
    else
      info "No selected service is currently active; there is nothing to stop."
    fi
    exit 0
  fi

  echo "$verb_label"
  prompt_service_menu 1 1 menu_line_runtime \
    "Select services to $mode (numbers/keys, 'all', blank/q cancels): " \
    "${candidates[@]}"
}

cmd_start() {
  require_root start "$@"
  require_env
  load_libs
  lisa_build_compose_files "$EDGE_REPO" || die "the current service selection is invalid; fix .env first."
  docker_ready || die "Docker is not reachable; start Docker first."

  local targets service dependency
  if [ "$#" -eq 0 ]; then
    choose_runtime_targets_interactive start "Selected services that are not running:"
    targets="$MENU_SELECTED"
  else
    targets="$(resolve_runtime_targets start "$@")"
  fi

  # Selected dependencies start first, even when not requested explicitly.
  for service in $targets; do
    for dependency in $(lisa_service_dependencies "$service"); do
      if service_is_selected "$dependency" && ! container_is_running "$dependency"; then
        case " $targets " in
          *" $dependency "*) ;;
          *)
            info "Also starting $dependency because $service depends on it."
            targets="$dependency $targets"
            ;;
        esac
      fi
    done
  done
  targets="$(order_dependencies_first $targets)"

  local started=""
  for service in $targets; do
    if container_is_running "$service"; then
      info "$service is already running."
      continue
    fi
    info "Starting $service..."
    run_hook "$(lisa_service_pre_start_hook "$service")"
    # 'compose up -d <name>' creates the container when it is absent;
    # plain 'compose start' cannot.
    compose_cmd up -d --no-deps "$(lisa_service_compose_name "$service")"
    run_hook "$(lisa_service_post_start_hook "$service")"
    started="${started:+$started }$service"
  done

  echo
  report_service_state $targets
  run_targeted_health "$targets"

  # A runtime start never prompts for a Thread sync: report drift only.
  if lisa_has_service matter && lisa_has_service otbr &&
     container_is_running matter && container_is_running otbr; then
    LISA_THREAD_SYNC_NO_PROMPT=1 \
      "$EDGE_REPO/services/matter-server/thread-sync-if-needed.sh" || true
  fi
}

cmd_stop() {
  require_root stop "$@"
  require_env
  load_libs
  lisa_build_compose_files "$EDGE_REPO" || die "the current service selection is invalid; fix .env first."
  docker_ready || die "Docker is not reachable; start Docker first."

  local targets service dependent
  if [ "$#" -eq 0 ]; then
    choose_runtime_targets_interactive stop "Selected services that are currently active:"
    targets="$MENU_SELECTED"
  else
    targets="$(resolve_runtime_targets stop "$@")"
  fi

  # Refuse to stop a dependency while a selected running dependent stays up.
  for service in $targets; do
    for dependent in $(lisa_service_dependents "$service"); do
      service_is_selected "$dependent" || continue
      container_is_running "$dependent" || continue
      case " $targets " in
        *" $dependent "*) ;;
        *) die "cannot stop $service while the selected running service $dependent depends on it. Stop $dependent too, or first." ;;
      esac
    done
  done

  # Dependents stop before their dependencies.
  targets="$(reverse_words "$(order_dependencies_first $targets)")"

  for service in $targets; do
    if ! container_is_running "$service"; then
      info "$service is not running."
      continue
    fi
    info "Stopping $service (container, data, image, and selection are preserved)..."
    compose_cmd stop "$(lisa_service_compose_name "$service")"
  done

  echo
  report_service_state $targets
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
[ "$#" -ge 1 ] || { usage >&2; exit 2; }
ACTION="$1"
shift
case "$ACTION" in
  add) cmd_add "$@" ;;
  remove) cmd_remove "$@" ;;
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; die "unknown service subcommand: $ACTION" ;;
esac
