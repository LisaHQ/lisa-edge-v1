#!/usr/bin/env bash
set -euo pipefail

# Setup workflow contract: the menu offers the six operator actions, the
# service-refresh action invokes the internal deployment engine WITHOUT a
# Git update and WITHOUT an intentional image refresh, the bootstrap/repair
# action invokes the internal bootstrap implementation, and both require an
# existing configuration. Everything runs against an isolated repository
# copy with the engine and bootstrap stubbed; no live host is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "SETUP MENU TEST ERROR: $*" >&2
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
cat > "$TREE/ops/deploy/deploy.sh" <<EOF
#!/usr/bin/env bash
echo "deploy \$*" >> "$CALL_LOG"
EOF
cat > "$TREE/install/bootstrap/bootstrap.sh" <<EOF
#!/usr/bin/env bash
echo "bootstrap \$*" >> "$CALL_LOG"
EOF
cat > "$TREE/services/matter-server/thread-sync-if-needed.sh" <<EOF
#!/usr/bin/env bash
echo "thread-sync-if-needed \$*" >> "$CALL_LOG"
EOF
cat > "$TREE/install/bootstrap/finalize-admin-access.sh" <<EOF
#!/usr/bin/env bash
echo "finalize-admin-access \$*" >> "$CALL_LOG"
EOF
chmod +x "$TREE/ops/deploy/deploy.sh" "$TREE/install/bootstrap/bootstrap.sh" \
  "$TREE/services/matter-server/thread-sync-if-needed.sh" \
  "$TREE/install/bootstrap/finalize-admin-access.sh"

# A git PATH shim records any git invocation: setup actions must never
# update the repository (that is what 'lisa-edge update' is for).
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$CALL_LOG"
EOF
chmod +x "$WORK_DIR/bin/git"
export PATH="$WORK_DIR/bin:$PATH"

WIZARD="$TREE/install/provisioning/lisa-first-boot.sh"

cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES="mqtt uptime-kuma"
MQTT_PASSWORD=test-password-value
EOF

# --- the interactive menu offers all six actions -----------------------------
menu_output="$(printf '4\n' | LISA_EDGE_TESTING=1 bash "$WIZARD" --dry-run 2>&1 || true)"
grep -q '1) Fresh setup' <<<"$menu_output" || fail "menu must offer fresh setup"
grep -q '2) Restore from removable storage' <<<"$menu_output" || fail "menu must offer USB restore"
grep -q '3) Restore from a mounted local/NAS path' <<<"$menu_output" || fail "menu must offer path restore"
grep -q '4) Edit configuration only' <<<"$menu_output" || fail "menu must offer configuration-only"
grep -q '5) Refresh services using the current configuration' <<<"$menu_output" ||
  fail "menu must offer the service-refresh action"
grep -q '6) Bootstrap or repair this host' <<<"$menu_output" ||
  fail "menu must offer the bootstrap/repair action"

# --- refresh: engine only, no Git, no intentional image refresh --------------
: > "$CALL_LOG"
output="$(LISA_EDGE_TESTING=1 bash "$WIZARD" --mode refresh 2>&1)" ||
  fail "refresh action failed: $output"
grep -q '^deploy $' "$CALL_LOG" ||
  fail "refresh must invoke the internal engine without extra options (no --pull/--offline)"
if grep -q '^git' "$CALL_LOG"; then
  fail "refresh must not run any Git command"
fi
if grep -q -- '--pull' "$CALL_LOG"; then
  fail "refresh must not intentionally refresh images"
fi
grep -q 'Service refresh completed' <<<"$output" || fail "refresh must report completion"

# --- repair: internal bootstrap implementation -------------------------------
: > "$CALL_LOG"
output="$(LISA_EDGE_TESTING=1 bash "$WIZARD" --mode repair 2>&1)" ||
  fail "repair action failed: $output"
grep -q '^bootstrap' "$CALL_LOG" || fail "repair must invoke the internal bootstrap"
if grep -q '^git' "$CALL_LOG"; then
  fail "repair must not run any Git command"
fi

# --- an interactive workflow with matter+otbr runs the shared thread check ---
cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES="mqtt matter otbr"
MQTT_PASSWORD=test-password-value
EOF
: > "$CALL_LOG"
output="$(LISA_EDGE_TESTING=1 bash "$WIZARD" --mode refresh 2>&1)" ||
  fail "refresh with matter+otbr failed: $output"
grep -q '^thread-sync-if-needed' "$CALL_LOG" ||
  fail "an interactive workflow with matter and otbr selected must run the shared check-and-sync path"
sync_line="$(grep -n '^thread-sync-if-needed' "$CALL_LOG" | head -1 | cut -d: -f1)"
deploy_line="$(grep -n '^deploy' "$CALL_LOG" | head -1 | cut -d: -f1)"
[ "$deploy_line" -lt "$sync_line" ] ||
  fail "the thread check must run only after the internal engine completed"

# --- refresh succeeds with an explicitly empty service selection --------------
cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES=""
EOF
: > "$CALL_LOG"
output="$(LISA_EDGE_TESTING=1 bash "$WIZARD" --mode refresh 2>&1)" ||
  fail "refresh with zero selected services failed: $output"
grep -q '^deploy $' "$CALL_LOG" || fail "refresh with zero services must still run the engine"
grep -q 'Service refresh completed' <<<"$output" || fail "the empty refresh must report completion"

# --- config-only never mutates host sudo state (and 'none' is accepted) -------
cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES="mqtt uptime-kuma"
MQTT_PASSWORD=test-password-value
EOF
: > "$CALL_LOG"
output="$(printf '\n\n\n\n\n\n\n\n\n\nnone\n' |
  LISA_EDGE_TESTING=1 bash "$WIZARD" --mode config-only 2>&1)" ||
  fail "config-only with 'none' failed: $output"
if grep -q '^bootstrap' "$CALL_LOG"; then
  fail "config-only must never run the host bootstrap"
fi
if grep -q '^finalize-admin-access' "$CALL_LOG"; then
  fail "config-only must never touch host sudo configuration"
fi
if grep -q '^deploy' "$CALL_LOG"; then
  fail "config-only must not apply anything"
fi
grep -q "^LISA_COMPOSE_SERVICES=''" "$TREE/.env" ||
  fail "config-only with 'none' must write an explicitly empty selection"
grep -q 'Bootstrap or repair this host' <<<"$output" ||
  fail "config-only guidance must point host-level changes at Bootstrap/repair"

# --- both require an existing configuration ----------------------------------
rm -f "$TREE/.env"
rc=0
output="$(LISA_EDGE_TESTING=1 bash "$WIZARD" --mode refresh 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "refresh without .env must fail"
grep -q 'No configuration found' <<<"$output" || fail "refresh must explain the missing configuration"
rc=0
output="$(LISA_EDGE_TESTING=1 bash "$WIZARD" --mode repair 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "repair without .env must fail"

# --- unknown mode is rejected -------------------------------------------------
rc=0
LISA_EDGE_TESTING=1 bash "$WIZARD" --mode reconcile >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown setup mode must be rejected"

echo "Setup menu tests passed."
