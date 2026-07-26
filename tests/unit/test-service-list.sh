#!/usr/bin/env bash
set -euo pipefail

# 'service list' STATUS contract: not-installed (unselected), installed
# (selected without a container), running, stopped, error (unhealthy /
# restarting / dead), and unknown (Docker unreachable). "Installed" means
# selected in LISA_COMPOSE_SERVICES - image presence never counts. The
# command works without root, without .env, and without Docker. Docker is
# mocked with a PATH shim; everything runs in an isolated repository copy.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "SERVICE LIST TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$TREE/"

MOCK_DIR="$WORK_DIR/mock"
mkdir -p "$MOCK_DIR/containers" "$WORK_DIR/bin"
export MOCK_DIR

# Docker shim: MOCK_DOCKER_DOWN=1 simulates an unreachable daemon; container
# states (and optional |health suffix) live in $MOCK_DIR/containers/<name>.
cat > "$WORK_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${MOCK_DOCKER_DOWN:-0}" = "1" ] && exit 1
case "$1" in
  ps) exit 0 ;;
  inspect)
    name="${*: -1}"
    state_file="$MOCK_DIR/containers/$name"
    [ -f "$state_file" ] || exit 1
    IFS='|' read -r state health < "$state_file"
    printf '%s|%s\n' "$state" "${health:-}"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK_DIR/bin/docker"
export PATH="$WORK_DIR/bin:$PATH"

LIST="$TREE/services/list.sh"

status_of() {
  local service="$1"
  awk -v s="$service" '$1 == s {print $2}' <<<"$LIST_OUTPUT"
}

# --- no .env: every service is not-installed ---------------------------------
rm -f "$TREE/.env"
LIST_OUTPUT="$(bash "$LIST")" || fail "service list must work without .env"
grep -q '^SERVICE' <<<"$LIST_OUTPUT" || fail "the table header must be printed"
for service in mqtt uptime-kuma ha matter otbr zigbee2mqtt node-red vpn-tailscale; do
  [ "$(status_of "$service")" = "not-installed" ] ||
    fail "without .env every service must be not-installed, $service was '$(status_of "$service")'"
done
grep -q 'not-installed (not selected)' <<<"$LIST_OUTPUT" ||
  fail "the status legend must be printed"
grep -q 'never mere image presence' <<<"$LIST_OUTPUT" ||
  fail "the legend must state that image presence never counts as installed"

# --- every runtime status category -------------------------------------------
cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES="mqtt uptime-kuma ha matter otbr zigbee2mqtt"
EOF
chmod 0600 "$TREE/.env"
echo 'running|' > "$MOCK_DIR/containers/lisa-mqtt"        # running
echo 'running|healthy' > "$MOCK_DIR/containers/lisa-uptime" # running (healthy)
echo 'exited|' > "$MOCK_DIR/containers/lisa-ha"           # stopped
echo 'running|unhealthy' > "$MOCK_DIR/containers/lisa-matter" # error (unhealthy)
echo 'restarting|' > "$MOCK_DIR/containers/lisa-otbr"     # error (restarting)
rm -f "$MOCK_DIR/containers/lisa-zigbee2mqtt"             # installed (no container)

LIST_OUTPUT="$(bash "$LIST")" || fail "service list failed with .env present"
[ "$(status_of mqtt)" = "running" ] || fail "a running container must be 'running', got $(status_of mqtt)"
[ "$(status_of uptime-kuma)" = "running" ] || fail "a healthy container must be 'running'"
[ "$(status_of ha)" = "stopped" ] || fail "an exited container must be 'stopped', got $(status_of ha)"
[ "$(status_of matter)" = "error" ] || fail "an unhealthy container must be 'error', got $(status_of matter)"
[ "$(status_of otbr)" = "error" ] || fail "a restarting container must be 'error', got $(status_of otbr)"
[ "$(status_of zigbee2mqtt)" = "installed" ] ||
  fail "a selected service without a container must be 'installed', got $(status_of zigbee2mqtt)"
[ "$(status_of node-red)" = "not-installed" ] ||
  fail "an unselected service must be 'not-installed', got $(status_of node-red)"

# --- remaining stopped-family and dead states --------------------------------
echo 'created|' > "$MOCK_DIR/containers/lisa-ha"
echo 'paused|' > "$MOCK_DIR/containers/lisa-mqtt"
echo 'dead|' > "$MOCK_DIR/containers/lisa-otbr"
LIST_OUTPUT="$(bash "$LIST")" || fail "service list failed on stopped-family states"
[ "$(status_of ha)" = "stopped" ] || fail "a created container must be 'stopped'"
[ "$(status_of mqtt)" = "stopped" ] || fail "a paused container must be 'stopped'"
[ "$(status_of otbr)" = "error" ] || fail "a dead container must be 'error'"

# --- Docker unavailable: unknown for selected, not a failure ------------------
rc=0
LIST_OUTPUT="$(MOCK_DOCKER_DOWN=1 bash "$LIST" 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "service list must not fail when Docker is unreachable, got $rc"
[ "$(status_of mqtt)" = "unknown" ] ||
  fail "with Docker down a selected service must be 'unknown', got $(status_of mqtt)"
[ "$(status_of node-red)" = "not-installed" ] ||
  fail "with Docker down an unselected service stays 'not-installed'"
LIST_STDERR="$(MOCK_DOCKER_DOWN=1 bash "$LIST" 2>&1 >/dev/null)" || true
grep -q 'Docker is not reachable' <<<"$LIST_STDERR" ||
  fail "the Docker-unreachable condition must be explained"

# --- catalog information stays present ---------------------------------------
LIST_OUTPUT="$(bash "$LIST")"
grep -q 'DEPENDENCIES' <<<"$LIST_OUTPUT" || fail "the dependencies column must remain"
grep -Eq 'zigbee2mqtt +[a-z-]+ +mqtt ' <<<"$LIST_OUTPUT" ||
  fail "zigbee2mqtt must list its mqtt dependency"
grep -q 'home-assistant -> ha' <<<"$LIST_OUTPUT" || fail "the alias footer must remain"

echo "Service list tests passed."
