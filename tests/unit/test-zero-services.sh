#!/usr/bin/env bash
set -euo pipefail

# Zero-service runtime contract: with an explicitly empty
# LISA_COMPOSE_SERVICES the internal deployment engine reconciles the
# project without 'compose up'/'pull' (which fail on an empty project),
# removes only this project's obsolete containers (never a prune), update
# succeeds, status prints '(none)', and the internal stop implementation
# keeps working. Docker and systemctl are mocked; no live host is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "ZERO SERVICES TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" \
  "$REPO_ROOT/install" "$REPO_ROOT/.env.template" "$TREE/"

CALL_LOG="$WORK_DIR/calls.log"
export CALL_LOG
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "compose" ]; then
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env-file|-f) shift 2 ;;
      *) break ;;
    esac
  done
  echo "compose $*" >> "$CALL_LOG"
  exit 0
fi
echo "docker $*" >> "$CALL_LOG"
exit 0
EOF
cat > "$WORK_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALL_LOG"
echo inactive
exit 0
EOF
chmod +x "$WORK_DIR/bin/docker" "$WORK_DIR/bin/systemctl"
export PATH="$WORK_DIR/bin:$PATH"

cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES=""
EOF
chmod 0600 "$TREE/.env"

# --- deploy: reconciles the empty project, never up/pull/prune ----------------
: > "$CALL_LOG"
output="$(bash "$TREE/ops/deploy/deploy.sh" 2>&1)" ||
  fail "deploy with zero services failed: $output"
grep -q 'No services selected' <<<"$output" || fail "deploy must announce the empty selection"
grep -q '(none - no services selected)' <<<"$output" ||
  fail "deploy must print an empty image list explicitly"
grep -q 'Overall status: HEALTHY' <<<"$output" ||
  fail "deploy must finish with a HEALTHY health check"
grep -q '^compose down --remove-orphans' "$CALL_LOG" ||
  fail "deploy must reconcile obsolete project containers with compose down --remove-orphans"
if grep -q '^compose up' "$CALL_LOG"; then
  fail "deploy must not call compose up on an empty project"
fi
if grep -q '^compose pull' "$CALL_LOG"; then
  fail "deploy must not call compose pull on an empty project"
fi
if grep -Eq 'prune|volume rm|rmi' "$CALL_LOG"; then
  fail "no broad Docker cleanup may ever run"
fi

# --- update (engine with --pull): still safe with zero services ---------------
: > "$CALL_LOG"
output="$(bash "$TREE/ops/deploy/update.sh" 2>&1)" ||
  fail "update with zero services failed: $output"
if grep -Eq '^compose (up|pull)' "$CALL_LOG"; then
  fail "update must not up/pull an empty project"
fi
grep -q '^compose down --remove-orphans' "$CALL_LOG" ||
  fail "update must still reconcile the empty project"

# --- status: prints (none) and keeps the host/systemd state -------------------
: > "$CALL_LOG"
output="$(bash "$TREE/ops/deploy/status.sh" 2>&1)" ||
  fail "status with zero services failed: $output"
grep -q 'Selected services: (none)' <<<"$output" ||
  fail "status must print 'Selected services: (none)'"
grep -q 'Runtime unit' <<<"$output" || fail "status must keep reporting the systemd state"
grep -q '^compose ps' "$CALL_LOG" || fail "status must still query the Compose project"

# --- internal stop implementation stays functional ----------------------------
: > "$CALL_LOG"
bash "$TREE/ops/deploy/stop.sh" || fail "the internal stop must succeed with zero services"
grep -q '^compose down --remove-orphans' "$CALL_LOG" ||
  fail "the internal stop must still run compose down"

echo "Zero-service runtime tests passed."
