#!/usr/bin/env bash
set -euo pipefail

# Service lifecycle contract (services/lifecycle.sh): add idempotency and
# dependency handling, safe .env mutation, remove safety (plan, exact
# confirmation, dependents refusal, pre-remove backups, backup/image
# preservation, --dry-run, --all-backups guards, --purge-image guards),
# start/stop ordering and rejection rules, and the no-prompt Thread check
# on runtime starts. Everything runs against an isolated repository copy
# with the engine, systemd installer, health check, hooks, docker,
# systemctl, and findmnt stubbed. No live host is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "SERVICE LIFECYCLE TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
DATA_ROOT="$WORK_DIR/data-root"
mkdir -p "$TREE" "$DATA_ROOT"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" \
  "$REPO_ROOT/install" "$REPO_ROOT/.env.template" "$TREE/"

CALL_LOG="$WORK_DIR/calls.log"
export CALL_LOG
MOCK_DIR="$WORK_DIR/mock"
mkdir -p "$MOCK_DIR/containers"
export MOCK_DIR

stub_script() {
  local path="$1" name="$2" extra="${3:-}"
  cat > "$path" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "\$CALL_LOG"
$extra
EOF
  chmod +x "$path"
}

stub_script "$TREE/ops/deploy/deploy.sh" deploy \
  'if [ "${MOCK_DEPLOY_FAIL:-0}" = "1" ]; then exit 1; fi'
stub_script "$TREE/ops/deploy/install-systemd.sh" install-systemd
stub_script "$TREE/ops/deploy/healthcheck.sh" healthcheck
stub_script "$TREE/install/bootstrap/phases/30-directories.sh" phase-30
stub_script "$TREE/install/bootstrap/phases/40-core-service-prep.sh" phase-40
stub_script "$TREE/services/mqtt/prepare.sh" mqtt-prepare
stub_script "$TREE/services/matter-server/data/init-or-restore.sh" matter-init
stub_script "$TREE/services/otbr/dataset/init-or-restore.sh" otbr-init
stub_script "$TREE/services/matter-server/data/backup.sh" matter-backup \
  'if [ "${MOCK_BACKUP_FAIL:-0}" = "1" ]; then exit 1; fi'
stub_script "$TREE/services/otbr/dataset/backup.sh" otbr-backup
stub_script "$TREE/services/matter-server/thread-sync-if-needed.sh" thread-sync \
  'echo "thread-sync-noprompt=${LISA_THREAD_SYNC_NO_PROMPT:-0}" >> "$CALL_LOG"'

# Stateful docker shim: container states live in $MOCK_DIR/containers.
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/docker" <<'DOCKER_EOF'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "docker $*" >> "$CALL_LOG"; }
container_for() {
  case "$1" in
    mosquitto) echo lisa-mqtt ;;
    uptime-kuma) echo lisa-uptime ;;
    homeassistant) echo lisa-ha ;;
    matter-server) echo lisa-matter ;;
    otbr) echo lisa-otbr ;;
    zigbee2mqtt) echo lisa-zigbee2mqtt ;;
    node-red) echo lisa-node-red ;;
    tailscale) echo lisa-tailscale ;;
    *) echo "unknown-$1" ;;
  esac
}
case "$1" in
  ps)
    shift
    if [ "${1:-}" = "-q" ]; then exit 0; fi
    if [ "${1:-}" = "-aq" ]; then
      # docker ps -aq --filter ancestor=...
      printf '%s' "${MOCK_IMAGE_USERS:-}"
      exit 0
    fi
    # docker ps --format '{{.Names}}'
    for f in "$MOCK_DIR"/containers/*; do
      [ -e "$f" ] || continue
      [ "$(cat "$f")" = "running" ] && basename "$f"
    done
    exit 0
    ;;
  inspect)
    # docker inspect -f '{{.State.Status}}' <name> - the name is last.
    name="${*: -1}"
    state_file="$MOCK_DIR/containers/$name"
    if [ -f "$state_file" ]; then cat "$state_file"; exit 0; fi
    exit 1
    ;;
  image)
    log "$@"
    # docker image inspect -f '{{.Id}}' <ref>
    if [ "${MOCK_IMAGE_PRESENT:-1}" = "1" ]; then
      echo "sha256:mockimageid"
      exit 0
    fi
    exit 1
    ;;
  rmi)
    log "$@"
    exit 0
    ;;
  compose)
    shift
    # Global flags (--env-file/-f pairs) come before the verb; -f AFTER the
    # verb (e.g. 'rm -f') belongs to the subcommand and must be kept.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --env-file|-f) shift 2 ;;
        *) break ;;
      esac
    done
    args=("$@")
    verb="${args[0]:-}"
    log "compose $verb ${args[*]:1}"
    case "$verb" in
      up)
        for token in "${args[@]:1}"; do
          case "$token" in
            -*|-d) ;;
            *) echo running > "$MOCK_DIR/containers/$(container_for "$token")" ;;
          esac
        done
        ;;
      stop)
        for token in "${args[@]:1}"; do
          case "$token" in
            -*) ;;
            *)
              c="$(container_for "$token")"
              [ -f "$MOCK_DIR/containers/$c" ] && echo exited > "$MOCK_DIR/containers/$c"
              ;;
          esac
        done
        ;;
      rm)
        for token in "${args[@]:1}"; do
          case "$token" in
            -*) ;;
            *) rm -f "$MOCK_DIR/containers/$(container_for "$token")" ;;
          esac
        done
        ;;
    esac
    exit 0
    ;;
  *)
    log "$@"
    exit 0
    ;;
esac
DOCKER_EOF
chmod +x "$WORK_DIR/bin/docker"

cat > "$WORK_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$WORK_DIR/bin/systemctl"

cat > "$WORK_DIR/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '/\n'
EOF
chmod +x "$WORK_DIR/bin/findmnt"
export PATH="$WORK_DIR/bin:$PATH"

LIFECYCLE="$TREE/services/lifecycle.sh"
run_lifecycle() {
  LISA_EDGE_TESTING=1 LISA_HEALTH_ASSUME_SYSTEMD=1 bash "$LIFECYCLE" "$@"
}

write_env() {
  cat > "$TREE/.env" <<EOF
DATA_ROOT=$DATA_ROOT
BACKUP_DEST=$DATA_ROOT/backups
LISA_COMPOSE_SERVICES="$1"
MQTT_PASSWORD=test-password-value
MATTER_DATA_BACKUP_DIR=$DATA_ROOT/backups/matter
OTBR_DATASET_BACKUP_DIR=$DATA_ROOT/backups/otbr
EOF
  chmod 0600 "$TREE/.env"
}

env_selection() {
  sed -n 's/^LISA_COMPOSE_SERVICES=//p' "$TREE/.env" | tr -d "'\""
}

# --- unknown keys are rejected everywhere ------------------------------------
write_env "mqtt uptime-kuma"
for verb in add remove start stop; do
  rc=0
  run_lifecycle "$verb" not-a-service >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "service $verb must reject an unknown key"
done

# --- add is idempotent for an already selected service -----------------------
: > "$CALL_LOG"
before="$(cat "$TREE/.env")"
output="$(run_lifecycle add mqtt)" || fail "add of a selected service must succeed"
grep -q 'already selected' <<<"$output" || fail "idempotent add must say already selected"
[ "$(cat "$TREE/.env")" = "$before" ] || fail "idempotent add must not change .env"
if grep -q '^deploy' "$CALL_LOG"; then
  fail "idempotent add must not run the engine"
fi
grep -q '^healthcheck --services mqtt' "$CALL_LOG" ||
  fail "idempotent add must report the service's health"

# --- add with dependency resolution, wizard, .env update, engine -------------
: > "$CALL_LOG"
write_env "uptime-kuma"
output="$(printf '\n\n\n\n\n\n\n\n\n\n' | run_lifecycle add zigbee2mqtt 2>&1)" ||
  fail "add zigbee2mqtt failed: $output"
grep -q 'Also adding mqtt because zigbee2mqtt depends on it' <<<"$output" ||
  fail "dependency addition must be reported"
selection="$(env_selection)"
[ "$selection" = "mqtt uptime-kuma zigbee2mqtt" ] ||
  fail "selection must contain the service and its dependency in registry order, got: $selection"
grep -q "^ZIGBEE_DONGLE=" "$TREE/.env" || fail "service-owned keys must be persisted"
grep -q "^MQTT_PASSWORD=" "$TREE/.env" || fail "dependency-owned keys must be persisted"
grep -q '^phase-30' "$CALL_LOG" || fail "add must run the directory preparation phase"
grep -q '^install-systemd' "$CALL_LOG" || fail "add must reconcile systemd timers"
grep -q '^deploy $' "$CALL_LOG" || fail "add must invoke the internal engine"
ls "$TREE"/.env.before-service-* >/dev/null 2>&1 || fail "add must keep a pre-change .env copy"
mode="$(stat -c '%a' "$TREE/.env")"
[ "$mode" = "600" ] || fail ".env must stay 0600 after mutation, got $mode"
if grep -q '^phase-40' "$CALL_LOG"; then
  fail "thread host prep must not run when otbr was not added"
fi

# --- add otbr runs thread host prep and the shared thread check --------------
: > "$CALL_LOG"
write_env "mqtt uptime-kuma matter"
echo running > "$MOCK_DIR/containers/lisa-matter"
# Stub the otbr wizard: the real one probes hardware.
cat > "$TREE/services/otbr/provision.sh" <<'EOF'
#!/usr/bin/env bash
configure_otbr() {
  THREAD_NETWORK_NAME="LISA-HOME-01"
  OTBR_BACKBONE_IF="eth0"
  LISA_ENABLE_THREAD_HOST_PREP=1
}
EOF
output="$(run_lifecycle add otbr 2>&1)" || fail "add otbr failed: $output"
grep -q '^phase-40' "$CALL_LOG" || fail "adding otbr must run the thread host prep phase"
grep -q '^thread-sync' "$CALL_LOG" ||
  fail "adding otbr next to matter must run the shared thread check-and-sync path"
grep -q "^THREAD_NETWORK_NAME='LISA-HOME-01'" "$TREE/.env" ||
  fail "otbr wizard values must be persisted"

# --- a failed engine run reports rollback/retry guidance ---------------------
: > "$CALL_LOG"
write_env "uptime-kuma"
rc=0
output="$(printf '\n\n\n\n\n\n\n\n\n\n' | MOCK_DEPLOY_FAIL=1 run_lifecycle add zigbee2mqtt 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a failed engine run must fail the add"
grep -q 'service refresh FAILED' <<<"$output" || fail "the failure must be reported"
grep -q 'Refresh services' <<<"$output" || fail "a retry path must be printed"
grep -q '\.env\.before-service-' <<<"$output" || fail "the rollback file must be named"

# --- remove refuses while dependents remain ----------------------------------
write_env "mqtt uptime-kuma zigbee2mqtt"
rc=0
output="$(run_lifecycle remove mqtt 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "removing a required dependency must be refused"
grep -q 'required by the selected service' <<<"$output" || fail "the dependents must be named"
grep -q 'zigbee2mqtt' <<<"$output" || fail "the blocking dependent must be listed"
[ "$(env_selection)" = "mqtt uptime-kuma zigbee2mqtt" ] || fail "a refused removal must not change .env"

# --- remove --dry-run prints the plan and mutates nothing --------------------
mkdir -p "$DATA_ROOT/docker/volumes/zigbee2mqtt"
echo state > "$DATA_ROOT/docker/volumes/zigbee2mqtt/db.json"
: > "$CALL_LOG"
output="$(run_lifecycle remove zigbee2mqtt --dry-run)" || fail "remove --dry-run failed"
grep -q 'service removal plan' <<<"$output" || fail "dry-run must print the plan"
grep -q 'docker/volumes/zigbee2mqtt' <<<"$output" || fail "the plan must list the owned data"
grep -q 'backups:       preserved' <<<"$output" || fail "the plan must state backup preservation"
grep -q 'Image:                   preserved' <<<"$output" || fail "the plan must state image preservation"
[ -f "$DATA_ROOT/docker/volumes/zigbee2mqtt/db.json" ] || fail "dry-run must not delete data"
[ "$(env_selection)" = "mqtt uptime-kuma zigbee2mqtt" ] || fail "dry-run must not change .env"
if grep -q '^docker compose' "$CALL_LOG"; then
  fail "dry-run must not touch containers"
fi

# --- remove requires the exact confirmation phrase ---------------------------
rc=0
output="$(printf 'remove zigbee2mqtt\n' | run_lifecycle remove zigbee2mqtt 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a wrong confirmation phrase must abort"
grep -q 'Aborted' <<<"$output" || fail "the aborted removal must say so"
[ -f "$DATA_ROOT/docker/volumes/zigbee2mqtt/db.json" ] || fail "an aborted removal must not delete data"

# --- confirmed remove: container, selection, data; backups/images preserved --
mkdir -p "$DATA_ROOT/backups"
echo shared > "$DATA_ROOT/backups/lisa-edge-backup-20260101.tar.gz"
echo running > "$MOCK_DIR/containers/lisa-zigbee2mqtt"
: > "$CALL_LOG"
output="$(printf 'REMOVE ZIGBEE2MQTT\n' | run_lifecycle remove zigbee2mqtt 2>&1)" ||
  fail "confirmed removal failed: $output"
grep -q '^docker compose stop zigbee2mqtt' "$CALL_LOG" || fail "the container must be stopped"
grep -q '^docker compose rm -f zigbee2mqtt' "$CALL_LOG" || fail "the container must be removed"
[ "$(env_selection)" = "mqtt uptime-kuma" ] || fail "the selection must drop the removed service"
[ ! -e "$DATA_ROOT/docker/volumes/zigbee2mqtt" ] || fail "the owned data must be deleted"
[ -f "$DATA_ROOT/backups/lisa-edge-backup-20260101.tar.gz" ] ||
  fail "shared full-stack backups must be preserved"
grep -q '^deploy $' "$CALL_LOG" || fail "the remaining stack must be refreshed and verified"
if grep -q '^docker rmi' "$CALL_LOG"; then
  fail "images must be preserved by default"
fi

# --- matter remove: pre-remove backup is required (fail closed) --------------
write_env "mqtt uptime-kuma matter"
mkdir -p "$DATA_ROOT/docker/volumes/matter-server"
echo fabric > "$DATA_ROOT/docker/volumes/matter-server/config.json"
rc=0
output="$(printf 'REMOVE MATTER\n' | MOCK_BACKUP_FAIL=1 run_lifecycle remove matter 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a failed pre-remove backup must fail closed"
grep -q 'pre-removal matter backup' <<<"$output" || fail "the backup failure must be explained"
[ -f "$DATA_ROOT/docker/volumes/matter-server/config.json" ] ||
  fail "a failed backup must leave the data untouched"

: > "$CALL_LOG"
output="$(printf 'REMOVE MATTER\n' | run_lifecycle remove matter 2>&1)" ||
  fail "matter removal failed: $output"
grep -q '^matter-backup --label pre-remove' "$CALL_LOG" ||
  fail "matter removal must create a fresh dedicated backup first"
backup_line="$(grep -n '^matter-backup' "$CALL_LOG" | head -1 | cut -d: -f1)"
deploy_line="$(grep -n '^deploy' "$CALL_LOG" | head -1 | cut -d: -f1)"
[ "$backup_line" -lt "$deploy_line" ] || fail "the backup must happen before the stack refresh"
[ ! -e "$DATA_ROOT/docker/volumes/matter-server" ] || fail "matter data must be deleted"
grep -q 'systemctl disable --now lisa-matter-data-backup.timer' "$CALL_LOG" ||
  fail "the matter timer must be disabled"

# --- --all-backups deletes only service-dedicated backups --------------------
write_env "mqtt uptime-kuma matter"
mkdir -p "$DATA_ROOT/docker/volumes/matter-server" "$DATA_ROOT/backups/matter"
echo fabric > "$DATA_ROOT/docker/volumes/matter-server/config.json"
echo a > "$DATA_ROOT/backups/matter/matter-data-20260101T000000Z-x.tar.gz"
ln -sfn matter-data-20260101T000000Z-x.tar.gz "$DATA_ROOT/backups/matter/latest.matter-data.tar.gz"
output="$(printf 'REMOVE MATTER\nDELETE MATTER BACKUPS\n' | run_lifecycle remove matter --all-backups 2>&1)" ||
  fail "remove --all-backups failed: $output"
[ ! -e "$DATA_ROOT/backups/matter/matter-data-20260101T000000Z-x.tar.gz" ] ||
  fail "--all-backups must delete the dedicated archives"
[ ! -e "$DATA_ROOT/backups/matter/latest.matter-data.tar.gz" ] ||
  fail "--all-backups must delete the latest pointer"
[ -f "$DATA_ROOT/backups/lisa-edge-backup-20260101.tar.gz" ] ||
  fail "--all-backups must never delete shared full-stack archives"

# --- --purge-image guards -----------------------------------------------------
write_env "mqtt uptime-kuma"
# In-use image is preserved.
: > "$CALL_LOG"
output="$(printf 'REMOVE UPTIME-KUMA\n' | MOCK_IMAGE_USERS="abc123" \
  run_lifecycle remove uptime-kuma --purge-image 2>&1)" || fail "remove --purge-image failed: $output"
grep -q 'Image preserved: containers still use' <<<"$output" ||
  fail "an in-use image must be preserved with a reason"
if grep -q '^docker rmi' "$CALL_LOG"; then
  fail "an in-use image must not be removed"
fi
# Unused, unshared image is removed by exact reference.
write_env "mqtt uptime-kuma"
: > "$CALL_LOG"
output="$(printf 'REMOVE UPTIME-KUMA\n' | run_lifecycle remove uptime-kuma --purge-image 2>&1)" ||
  fail "remove --purge-image (unused) failed: $output"
grep -q '^docker rmi louislam/uptime-kuma:1' "$CALL_LOG" ||
  fail "a provably unused image must be removed by exact reference"
if grep -Eq '^docker (system|image prune|volume)' "$CALL_LOG"; then
  fail "no prune command may ever run"
fi

# --- non-TTY missing service arguments must fail with usage guidance ---------
write_env "mqtt uptime-kuma"
for verb in add remove start stop; do
  rc=0
  output="$(run_lifecycle "$verb" </dev/null 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "service $verb without a key must fail in a non-interactive context"
  grep -q 'Usage: lisa-edge service' <<<"$output" ||
    fail "the non-interactive $verb rejection must print usage guidance"
  grep -q 'requires a <service-key>' <<<"$output" ||
    fail "the non-interactive $verb rejection must explain the missing key"
done

# Interactive menus below use the LISA_EDGE_TESTING-gated TTY seam.
run_interactive() {
  LISA_TEST_FORCE_TTY=1 run_lifecycle "$@"
}

# --- explicit start of several services runs hooks in order -------------------
write_env "mqtt uptime-kuma"
rm -f "$MOCK_DIR"/containers/*
: > "$CALL_LOG"
output="$(run_lifecycle start mqtt uptime-kuma 2>&1)" || fail "service start failed: $output"
grep -q '^mqtt-prepare' "$CALL_LOG" || fail "the mqtt prepare hook must run"
prepare_line="$(grep -n '^mqtt-prepare' "$CALL_LOG" | head -1 | cut -d: -f1)"
up_line="$(grep -n '^docker compose up -d --no-deps mosquitto' "$CALL_LOG" | head -1 | cut -d: -f1)"
[ -n "$up_line" ] || fail "mqtt must be created/started through compose up"
[ "$prepare_line" -lt "$up_line" ] || fail "mqtt preparation must run before its start"
grep -q '^docker compose up -d --no-deps uptime-kuma' "$CALL_LOG" ||
  fail "all selected services must start"
grep -q '^healthcheck --services' "$CALL_LOG" || fail "start must report health"
[ "$(cat "$MOCK_DIR/containers/lisa-mqtt")" = "running" ] || fail "mqtt must be running afterwards"

# --- start of an unselected service is rejected -------------------------------
rc=0
output="$(run_lifecycle start otbr 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "starting an unselected service must be rejected"
grep -q 'service add otbr' <<<"$output" || fail "the rejection must point at service add"

# --- start orders dependencies first ------------------------------------------
write_env "mqtt uptime-kuma zigbee2mqtt"
rm -f "$MOCK_DIR"/containers/*
: > "$CALL_LOG"
output="$(run_lifecycle start zigbee2mqtt 2>&1)" || fail "targeted start failed: $output"
grep -q 'Also starting mqtt' <<<"$output" || fail "the stopped dependency must be started too"
mqtt_line="$(grep -n '^docker compose up -d --no-deps mosquitto' "$CALL_LOG" | head -1 | cut -d: -f1)"
z2m_line="$(grep -n '^docker compose up -d --no-deps zigbee2mqtt' "$CALL_LOG" | head -1 | cut -d: -f1)"
[ -n "$mqtt_line" ] && [ -n "$z2m_line" ] || fail "both services must start"
[ "$mqtt_line" -lt "$z2m_line" ] || fail "the dependency must start before the dependent"
if grep -q '^docker compose up -d --no-deps uptime-kuma' "$CALL_LOG"; then
  fail "a targeted start must not touch unrequested services"
fi

# --- matter/otbr start never prompts for a thread sync ------------------------
write_env "mqtt uptime-kuma matter otbr"
rm -f "$MOCK_DIR"/containers/*
: > "$CALL_LOG"
output="$(run_lifecycle start matter otbr 2>&1)" || fail "matter/otbr start failed: $output"
grep -q '^matter-init' "$CALL_LOG" || fail "matter data init must run before its start"
grep -q '^otbr-init' "$CALL_LOG" || fail "otbr dataset init must run after its start"
grep -q '^thread-sync-noprompt=1' "$CALL_LOG" ||
  fail "a runtime start must run the thread check strictly without prompting"

# --- stop refuses to strand a running dependent -------------------------------
write_env "mqtt uptime-kuma zigbee2mqtt"
echo running > "$MOCK_DIR/containers/lisa-mqtt"
echo running > "$MOCK_DIR/containers/lisa-zigbee2mqtt"
rc=0
output="$(run_lifecycle stop mqtt 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "stopping a dependency under a running dependent must be refused"
grep -q 'depends on it' <<<"$output" || fail "the dependent must be named in the refusal"
[ "$(cat "$MOCK_DIR/containers/lisa-mqtt")" = "running" ] || fail "a refused stop must not stop anything"

# --- stopping both stops the dependent first ----------------------------------
: > "$CALL_LOG"
output="$(run_lifecycle stop mqtt zigbee2mqtt 2>&1)" || fail "stop of both failed: $output"
z2m_stop="$(grep -n '^docker compose stop zigbee2mqtt' "$CALL_LOG" | head -1 | cut -d: -f1)"
mqtt_stop="$(grep -n '^docker compose stop mosquitto' "$CALL_LOG" | head -1 | cut -d: -f1)"
[ -n "$z2m_stop" ] && [ -n "$mqtt_stop" ] || fail "both services must stop"
[ "$z2m_stop" -lt "$mqtt_stop" ] || fail "the dependent must stop before its dependency"
[ "$(cat "$MOCK_DIR/containers/lisa-mqtt")" = "exited" ] || fail "mqtt must be stopped"

# --- interactive stop: menu lists only active services, 'all' works ----------
echo running > "$MOCK_DIR/containers/lisa-mqtt"
echo running > "$MOCK_DIR/containers/lisa-uptime"
echo running > "$MOCK_DIR/containers/lisa-zigbee2mqtt"
: > "$CALL_LOG"
output="$(printf 'all\n' | run_interactive stop 2>&1)" || fail "interactive stop-all failed: $output"
grep -q 'currently active' <<<"$output" || fail "the stop menu must announce the active candidates"
[ "$(cat "$MOCK_DIR/containers/lisa-mqtt")" = "exited" ] || fail "interactive stop-all must stop mqtt"
[ "$(cat "$MOCK_DIR/containers/lisa-zigbee2mqtt")" = "exited" ] || fail "interactive stop-all must stop zigbee2mqtt"
if grep -q '^docker compose down' "$CALL_LOG"; then
  fail "service stop must use stop semantics, never down/remove"
fi

# --- interactive stop menu excludes stopped services --------------------------
echo running > "$MOCK_DIR/containers/lisa-mqtt"
echo running > "$MOCK_DIR/containers/lisa-zigbee2mqtt"
output="$(printf '\n' | run_interactive stop 2>&1)" || fail "blank-cancel stop failed: $output"
grep -q 'Cancelled' <<<"$output" || fail "blank input must cancel the stop menu"
if grep -q 'lisa-uptime' <<<"$output" || grep -Eq '[0-9]\) uptime-kuma ' <<<"$output"; then
  fail "the stop menu must not list stopped services"
fi
[ "$(cat "$MOCK_DIR/containers/lisa-mqtt")" = "running" ] || fail "a cancelled stop must not stop anything"

# --- interactive stop by number stops only the chosen dependent ---------------
: > "$CALL_LOG"
# Active candidates in registry order: mqtt (1), zigbee2mqtt (2).
output="$(printf '2\n' | run_interactive stop 2>&1)" || fail "numbered interactive stop failed: $output"
[ "$(cat "$MOCK_DIR/containers/lisa-zigbee2mqtt")" = "exited" ] || fail "the chosen service must stop"
[ "$(cat "$MOCK_DIR/containers/lisa-mqtt")" = "running" ] || fail "unchosen services must keep running"

# --- interactive start: multi-select via numbers and keys ---------------------
write_env "mqtt uptime-kuma zigbee2mqtt"
rm -f "$MOCK_DIR"/containers/*
: > "$CALL_LOG"
output="$(printf '1 uptime-kuma\n' | run_interactive start 2>&1)" ||
  fail "interactive multi start failed: $output"
grep -q 'not running' <<<"$output" || fail "the start menu must announce the startable candidates"
grep -q '^docker compose up -d --no-deps mosquitto' "$CALL_LOG" ||
  fail "the numbered start choice must start mqtt"
grep -q '^docker compose up -d --no-deps uptime-kuma' "$CALL_LOG" ||
  fail "the key-based start choice must start uptime-kuma"
if grep -q '^docker compose up -d --no-deps zigbee2mqtt' "$CALL_LOG"; then
  fail "unchosen services must not be started"
fi

# --- interactive start menu lists only non-running services -------------------
rm -f "$MOCK_DIR"/containers/*
echo running > "$MOCK_DIR/containers/lisa-mqtt"
echo running > "$MOCK_DIR/containers/lisa-uptime"
: > "$CALL_LOG"
output="$(printf 'all\n' | run_interactive start 2>&1)" || fail "interactive start-all failed: $output"
grep -q '^docker compose up -d --no-deps zigbee2mqtt' "$CALL_LOG" ||
  fail "'all' must start every startable candidate"
if grep -Eq '^  [0-9]+\) mqtt ' <<<"$output"; then
  fail "the start menu must not list already running services"
fi

# --- interactive start: 'q' cancels without mutation --------------------------
rm -f "$MOCK_DIR"/containers/*
: > "$CALL_LOG"
output="$(printf 'q\n' | run_interactive start 2>&1)" || fail "q-cancel start failed: $output"
grep -q 'Cancelled' <<<"$output" || fail "'q' must cancel the start menu"
if grep -q '^docker compose up' "$CALL_LOG"; then
  fail "a cancelled start must not start anything"
fi

# --- interactive start with no eligible candidate exits successfully ----------
echo running > "$MOCK_DIR/containers/lisa-mqtt"
echo running > "$MOCK_DIR/containers/lisa-uptime"
echo running > "$MOCK_DIR/containers/lisa-zigbee2mqtt"
output="$(run_interactive start </dev/null 2>&1)" ||
  fail "start with everything running must exit successfully"
grep -q 'already running' <<<"$output" || fail "the no-candidate start must explain itself"

# --- interactive add: menu lists only unselected services ---------------------
write_env "mqtt uptime-kuma"
rm -f "$MOCK_DIR"/containers/*
: > "$CALL_LOG"
# Unselected candidates in registry order: ha(1) matter(2) otbr(3)
# zigbee2mqtt(4) node-red(5) vpn-tailscale(6).
output="$(printf '4\n\n\n\n\n\n\n\n\n\n' | run_interactive add 2>&1)" ||
  fail "interactive add failed: $output"
grep -q 'Services available to add' <<<"$output" || fail "the add menu must be announced"
if grep -Eq '^  [0-9]+\) mqtt ' <<<"$output"; then
  fail "the add menu must not list already selected services"
fi
grep -q 'requires: mqtt' <<<"$output" || fail "the add menu must show dependencies"
selection="$(env_selection)"
[ "$selection" = "mqtt uptime-kuma zigbee2mqtt" ] ||
  fail "the interactive add must persist the chosen service, got: $selection"
grep -q '^deploy $' "$CALL_LOG" || fail "the interactive add must invoke the internal engine"

# --- interactive add: blank input cancels without mutation --------------------
before="$(cat "$TREE/.env")"
output="$(printf '\n' | run_interactive add 2>&1)" || fail "blank-cancel add failed: $output"
grep -q 'Cancelled' <<<"$output" || fail "blank input must cancel the add menu"
[ "$(cat "$TREE/.env")" = "$before" ] || fail "a cancelled add must not change .env"

# --- interactive add with everything selected exits successfully --------------
write_env "mqtt uptime-kuma ha matter otbr zigbee2mqtt node-red vpn-tailscale"
output="$(run_interactive add </dev/null 2>&1)" ||
  fail "add with everything selected must exit successfully"
grep -q 'already selected' <<<"$output" || fail "the no-candidate add must explain itself"

# --- interactive remove: menu shows runtime state, options still apply --------
write_env "mqtt uptime-kuma zigbee2mqtt"
mkdir -p "$DATA_ROOT/docker/volumes/zigbee2mqtt"
echo state > "$DATA_ROOT/docker/volumes/zigbee2mqtt/db.json"
echo running > "$MOCK_DIR/containers/lisa-zigbee2mqtt"
: > "$CALL_LOG"
# Selected candidates in registry order: mqtt(1) uptime-kuma(2) zigbee2mqtt(3).
output="$(printf '3\n' | run_interactive remove --dry-run 2>&1)" ||
  fail "interactive remove --dry-run failed: $output"
grep -q 'state: running' <<<"$output" || fail "the remove menu must show the runtime state"
grep -q 'service removal plan' <<<"$output" || fail "the interactive choice must reach the plan"
grep -q 'docker/volumes/zigbee2mqtt' <<<"$output" || fail "the plan must list the owned data"
[ -f "$DATA_ROOT/docker/volumes/zigbee2mqtt/db.json" ] || fail "--dry-run must not delete data"
[ "$(env_selection)" = "mqtt uptime-kuma zigbee2mqtt" ] || fail "--dry-run must not change .env"

# --- interactive remove: selecting a required dependency is still refused -----
rc=0
output="$(printf '1\n' | run_interactive remove --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "interactively choosing a required dependency must be refused"
grep -q 'required by the selected service' <<<"$output" ||
  fail "the interactive dependency refusal must name the dependents"

# --- removing the final service leaves a valid explicitly empty selection -----
write_env "uptime-kuma"
rm -f "$MOCK_DIR"/containers/*
echo running > "$MOCK_DIR/containers/lisa-uptime"
: > "$CALL_LOG"
output="$(printf 'REMOVE UPTIME-KUMA\n' | run_lifecycle remove uptime-kuma 2>&1)" ||
  fail "removing the final service failed: $output"
grep -q -- "-> '(none)'" <<<"$output" || fail "the plan must show the empty selection as (none)"
grep -q 'No service remains selected' <<<"$output" ||
  fail "the final-service removal must explain the empty deployment"
[ -z "$(env_selection)" ] || fail "the selection must become explicitly empty"
grep -q "^LISA_COMPOSE_SERVICES=''" "$TREE/.env" ||
  fail ".env must keep an explicitly empty LISA_COMPOSE_SERVICES value"
grep -q '^deploy $' "$CALL_LOG" || fail "the empty deployment must still be reconciled by the engine"

# --- start/stop with zero selected services exit successfully -----------------
output="$(run_interactive start </dev/null 2>&1)" || fail "start with zero services must exit 0"
grep -q 'No service is selected' <<<"$output" || fail "the zero-service start must explain itself"
output="$(run_interactive stop </dev/null 2>&1)" || fail "stop with zero services must exit 0"
grep -q 'No service is selected' <<<"$output" || fail "the zero-service stop must explain itself"

# --- interactive remove with nothing selected exits successfully --------------
output="$(run_interactive remove --dry-run </dev/null 2>&1)" ||
  fail "remove with zero services must exit successfully"
grep -q 'nothing to remove' <<<"$output" || fail "the zero-service remove must explain itself"

# --- service delete does not exist --------------------------------------------
rc=0
run_lifecycle delete mqtt >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "'service delete' must be rejected"

echo "Service lifecycle tests passed."
