#!/usr/bin/env bash
set -euo pipefail

# Passwordless-sudo reconciler contract
# (install/bootstrap/finalize-admin-access.sh): with
# LISA_KEEP_PASSWORDLESS_SUDO=1 the grant is created, corrected (stale
# user, wrong mode), or confirmed, always through a visudo-validated
# temporary file, failing closed on validation errors; with
# LISA_KEEP_PASSWORDLESS_SUDO=0 removal stays lockout-safe and an absent
# file is a successful no-op. All host state is mocked with PATH shims and
# /tmp fixtures via the LISA_EDGE_TESTING seam; the real /etc/sudoers.d is
# never read or written.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "SUDO RECONCILE TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/install" "$TREE/"
FINALIZE="$TREE/install/bootstrap/finalize-admin-access.sh"

CALL_LOG="$WORK_DIR/calls.log"
export CALL_LOG

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -u) echo 1000 ;;
  lisa|other-admin) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$WORK_DIR/bin/passwd" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-S" ]; then
  echo "$2 ${MOCK_PASSWD_STATE:-P} 2026-01-01 0 99999 7 -1"
  exit 0
fi
exit 0
EOF
cat > "$WORK_DIR/bin/visudo" <<'EOF'
#!/usr/bin/env bash
echo "visudo $*" >> "$CALL_LOG"
exit "${MOCK_VISUDO_RC:-0}"
EOF
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

SUDOERS_DIR="$WORK_DIR/sudoers.d"
mkdir -p "$SUDOERS_DIR"
SUDOERS_FILE="$SUDOERS_DIR/90-lisa-admin"

write_env() {
  cat > "$TREE/.env" <<EOF
LISA_ADMIN_USER=${2:-lisa}
LISA_KEEP_PASSWORDLESS_SUDO=$1
EOF
  chmod 0600 "$TREE/.env"
}

run_finalize() {
  LISA_EDGE_TESTING=1 LISA_SECURITY_SUDOERS_FILE="$SUDOERS_FILE" bash "$FINALIZE" "$@"
}

DESIRED='lisa ALL=(ALL) NOPASSWD:ALL'

# --- keep=1: a missing grant is created (visudo-validated, mode 0440) ---------
write_env 1
rm -f "$SUDOERS_FILE"
: > "$CALL_LOG"
output="$(run_finalize 2>&1)" || fail "creating the grant failed: $output"
grep -q 'grant created' <<<"$output" || fail "the creation must be reported"
[ -f "$SUDOERS_FILE" ] || fail "the grant file must exist"
[ "$(cat "$SUDOERS_FILE")" = "$DESIRED" ] || fail "the grant content is wrong: $(cat "$SUDOERS_FILE")"
[ "$(stat -c '%a' "$SUDOERS_FILE")" = "440" ] || fail "the grant must be mode 0440"
grep -q '^visudo -cf' "$CALL_LOG" || fail "the candidate must be visudo-validated"

# --- keep=1: rerun on a valid grant is an idempotent no-op --------------------
output="$(run_finalize 2>&1)" || fail "reconciling a valid grant failed: $output"
grep -q 'already valid' <<<"$output" || fail "an already-correct grant must be reported as valid"
[ "$(cat "$SUDOERS_FILE")" = "$DESIRED" ] || fail "a valid grant must stay unchanged"

# --- keep=1: stale content for a previous admin user is corrected -------------
echo 'old-admin ALL=(ALL) NOPASSWD:ALL' > "$SUDOERS_FILE"
output="$(run_finalize 2>&1)" || fail "correcting a stale grant failed: $output"
grep -q 'grant corrected' <<<"$output" || fail "the correction must be reported"
[ "$(cat "$SUDOERS_FILE")" = "$DESIRED" ] || fail "the stale user must be replaced"

# --- keep=1: correct content with a wrong mode is corrected -------------------
chmod 0644 "$SUDOERS_FILE"
output="$(run_finalize 2>&1)" || fail "correcting the mode failed: $output"
grep -q 'grant corrected' <<<"$output" || fail "a wrong mode must be corrected, not accepted"
[ "$(stat -c '%a' "$SUDOERS_FILE")" = "440" ] || fail "the mode must return to 0440"

# --- keep=1: a failed visudo validation fails closed --------------------------
rm -f "$SUDOERS_FILE"
rc=0
output="$(MOCK_VISUDO_RC=1 run_finalize 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a failed visudo validation must fail the reconciliation"
grep -q 'failed visudo validation' <<<"$output" || fail "the validation failure must be explained"
[ ! -e "$SUDOERS_FILE" ] || fail "no file may be installed after a failed validation"
if find "$SUDOERS_DIR" -name '.90-lisa-admin.*' | grep -q .; then
  fail "the temporary candidate must be cleaned up after a failed validation"
fi

# --- keep=1: a nonexistent admin account fails --------------------------------
write_env 1 ghost
rc=0
output="$(run_finalize 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a nonexistent admin account must fail"
grep -q 'does not exist' <<<"$output" || fail "the missing account must be named"

# --- keep=1: a root admin account fails ---------------------------------------
write_env 1 root
rc=0
output="$(run_finalize 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "LISA_ADMIN_USER=root must be rejected"

# --- keep=0: an absent grant is a successful no-op ----------------------------
write_env 0
rm -f "$SUDOERS_FILE"
output="$(run_finalize 2>&1)" || fail "keep=0 with an absent grant must succeed"
grep -q 'nothing to remove' <<<"$output" || fail "the absent-grant no-op must be reported"

# --- keep=0: removal succeeds when the admin has a usable password ------------
printf '%s\n' "$DESIRED" > "$SUDOERS_FILE"
output="$(run_finalize 2>&1)" || fail "keep=0 removal failed: $output"
grep -q 'grant removed' <<<"$output" || fail "the removal must be reported"
[ ! -e "$SUDOERS_FILE" ] || fail "the grant must be removed"

# --- keep=0: no usable password and no terminal fails safely ------------------
printf '%s\n' "$DESIRED" > "$SUDOERS_FILE"
rc=0
output="$(MOCK_PASSWD_STATE=NP run_finalize </dev/null 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a lockout-prone removal must be refused non-interactively"
grep -q 'non-interactive' <<<"$output" || fail "the refusal must explain the non-interactive lockout risk"
[ -f "$SUDOERS_FILE" ] || fail "a refused removal must preserve the grant"

# --- the testing seam refuses paths outside /tmp ------------------------------
write_env 1
rc=0
LISA_EDGE_TESTING=1 LISA_SECURITY_SUDOERS_FILE="/etc/sudoers.d/evil" \
  bash "$FINALIZE" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a testing override outside /tmp must be rejected"

# --- an invalid keep value is rejected ----------------------------------------
cat > "$TREE/.env" <<'EOF'
LISA_ADMIN_USER=lisa
LISA_KEEP_PASSWORDLESS_SUDO=2
EOF
chmod 0600 "$TREE/.env"
rc=0
run_finalize >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "LISA_KEEP_PASSWORDLESS_SUDO=2 must be rejected"

echo "Sudo reconcile tests passed."
