#!/usr/bin/env bash
set -euo pipefail

# Security audit and hardening contract: the audit is read-only, detects
# the required findings (NOPASSWD state vs configuration, SSH effective
# settings, key/permission problems, .env protection, Git tracking, Docker
# exposure, docker group, Matter wildcard bind), and uses the stable
# HEALTHY/DEGRADED/FAILED exit model with --strict. Hardening refuses the
# lockout-prone remediations. All host state is mocked with PATH shims and
# /tmp fixtures; no live host is touched or changed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "SECURITY AUDIT TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" \
  "$REPO_ROOT/install" "$REPO_ROOT/.env.template" "$TREE/"
AUDIT="$TREE/ops/security/audit.sh"
HARDEN="$TREE/ops/security/harden.sh"

# --- static proof: the audit contains no mutating commands -------------------
if grep -En '^[[:space:]]*(chmod|chown|rm|mv|mkdir|install|ln|visudo|passwd|sed -i|gpasswd|usermod)\b' \
  "$REPO_ROOT/ops/security/audit.sh"; then
  fail "ops/security/audit.sh must not contain mutating commands"
fi
if grep -En 'systemctl[[:space:]]+(start|stop|restart|reload|enable|disable)' \
  "$REPO_ROOT/ops/security/audit.sh"; then
  fail "ops/security/audit.sh must not manage services"
fi

# --- pure helper checks -------------------------------------------------------
# shellcheck disable=SC1091
. "$REPO_ROOT/ops/security/lib.sh"
security_mode_world_accessible 644 || fail "644 must count as world-accessible"
security_mode_world_accessible 600 && fail "600 must not count as world-accessible"
security_mode_group_accessible 640 || fail "640 must count as group-accessible"
security_mode_group_accessible 600 && fail "600 must not count as group-accessible"
printf 'permitrootlogin no\npasswordauthentication yes\n' |
  security_sshd_effective passwordauthentication | grep -qx yes ||
  fail "sshd -T parsing must extract effective values"
SUDOERS_FIXTURE="$WORK_DIR/sudoers"
echo 'lisa ALL=(ALL) NOPASSWD:ALL' > "$SUDOERS_FIXTURE"
security_sudoers_grants_nopasswd "$SUDOERS_FIXTURE" lisa || fail "NOPASSWD grant must be detected"
security_sudoers_grants_nopasswd "$SUDOERS_FIXTURE" other && fail "NOPASSWD must be user-specific"
KEYS_FIXTURE="$WORK_DIR/authorized_keys"
echo 'ssh-ed25519 AAAAC3Nza... test@host' > "$KEYS_FIXTURE"
security_file_has_authorized_key "$KEYS_FIXTURE" || fail "a valid key line must be detected"
echo '# nothing' > "$KEYS_FIXTURE"
security_file_has_authorized_key "$KEYS_FIXTURE" && fail "comments are not usable keys"

# --- host-state shims ---------------------------------------------------------
ADMIN_HOME="$WORK_DIR/home/lisa"
mkdir -p "$ADMIN_HOME/.ssh"
chmod 0700 "$ADMIN_HOME/.ssh"
echo 'ssh-ed25519 AAAAC3Nza... lisa@host' > "$ADMIN_HOME/.ssh/authorized_keys"
chmod 0600 "$ADMIN_HOME/.ssh/authorized_keys"
REAL_UID="$(id -u)"

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/getent" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "passwd lisa") echo "lisa:x:$REAL_UID:$REAL_UID::$ADMIN_HOME:/bin/bash" ;;
  "group docker") echo "docker:x:999:\${MOCK_DOCKER_MEMBERS:-}" ;;
  *) exit 2 ;;
esac
EOF
cat > "$WORK_DIR/bin/id" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-Gn lisa") echo "lisa sudo" ;;
  "-u lisa") echo "$REAL_UID" ;;
  "-u") echo "$REAL_UID" ;;
  *) echo "$REAL_UID" ;;
esac
EOF
cat > "$WORK_DIR/bin/sshd" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -t) exit "${MOCK_SSHD_SYNTAX_RC:-0}" ;;
  -T)
    echo "permitrootlogin ${MOCK_PERMIT_ROOT:-no}"
    echo "passwordauthentication ${MOCK_PASSWORD_AUTH:-no}"
    echo "kbdinteractiveauthentication ${MOCK_KBD_AUTH:-no}"
    ;;
esac
EOF
cat > "$WORK_DIR/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%b' "${MOCK_SS_OUTPUT:-}"
EOF
chmod +x "$WORK_DIR/bin/"*
export PATH="$WORK_DIR/bin:$PATH"

SUDOERS_TEST_FILE="$WORK_DIR/90-lisa-admin"

write_env() {
  cat > "$TREE/.env" <<EOF
LISA_ADMIN_USER=lisa
LISA_KEEP_PASSWORDLESS_SUDO=${1:-0}
LISA_COMPOSE_SERVICES="${2:-mqtt uptime-kuma}"
MATTER_LISTEN_ADDRESS=${3:-127.0.0.1}
EOF
  chmod 0600 "$TREE/.env"
}

run_audit() {
  LISA_EDGE_TESTING=1 LISA_SECURITY_SUDOERS_FILE="$SUDOERS_TEST_FILE" bash "$AUDIT" "$@"
}

# --- fully clean state: HEALTHY ----------------------------------------------
write_env 0
rm -f "$SUDOERS_TEST_FILE"
rc=0
output="$(run_audit)" || rc=$?
[ "$rc" -eq 0 ] || fail "a clean state must be HEALTHY (exit 0), got $rc: $output"
grep -q 'Security audit result: HEALTHY' <<<"$output" || fail "the clean state must report HEALTHY"
grep -q 'no passwordless sudo grant' <<<"$output" || fail "the sudo state must be reported"
grep -q 'firewall allowlists remain deployment-specific' <<<"$output" ||
  fail "the audit must state that firewalls stay deployment-specific"

# --- audit is read-only -------------------------------------------------------
before="$(find "$WORK_DIR/home" "$TREE/.env" -exec stat -c '%n %a %u' {} \; | sort)"
run_audit >/dev/null || true
after="$(find "$WORK_DIR/home" "$TREE/.env" -exec stat -c '%n %a %u' {} \; | sort)"
[ "$before" = "$after" ] || fail "the audit must not change any file mode or owner"

# --- stale NOPASSWD grant: DEGRADED, strict exit 3 ---------------------------
echo 'lisa ALL=(ALL) NOPASSWD:ALL' > "$SUDOERS_TEST_FILE"
rc=0
output="$(run_audit)" || rc=$?
[ "$rc" -eq 0 ] || fail "a degraded state must exit 0 without --strict, got $rc"
grep -q 'Security audit result: DEGRADED' <<<"$output" || fail "the stale grant must degrade the result"
grep -q 'passwordless sudo grant still exists' <<<"$output" || fail "the mismatch must be explained"
grep -q 'security harden' <<<"$output" || fail "the remediation command must be suggested"
rc=0
output="$(run_audit --strict)" || rc=$?
[ "$rc" -eq 3 ] || fail "--strict must exit 3 on DEGRADED, got $rc"

# --- configured exception still surfaces as a warning ------------------------
write_env 1
rc=0
output="$(run_audit)" || rc=$?
grep -q 'lab/emergency exception' <<<"$output" ||
  fail "LISA_KEEP_PASSWORDLESS_SUDO=1 must be reported as an exception"
rm -f "$SUDOERS_TEST_FILE"

# --- SSH effective settings --------------------------------------------------
write_env 0
rc=0
output="$(MOCK_PASSWORD_AUTH=yes run_audit)" || rc=$?
grep -q "PasswordAuthentication is 'yes'" <<<"$output" || fail "password auth must be flagged"
grep -q 'Security audit result: DEGRADED' <<<"$output" || fail "password auth must degrade"
rc=0
output="$(MOCK_PERMIT_ROOT=yes run_audit)" || rc=$?
[ "$rc" -eq 1 ] || fail "PermitRootLogin yes must FAIL the audit, got $rc"
rc=0
output="$(MOCK_SSHD_SYNTAX_RC=1 run_audit)" || rc=$?
[ "$rc" -eq 1 ] || fail "invalid sshd syntax must FAIL the audit, got $rc"
grep -q 'INVALID' <<<"$output" || fail "invalid sshd syntax must be reported"

# --- missing admin key: lockout-aware severity --------------------------------
mv "$ADMIN_HOME/.ssh/authorized_keys" "$ADMIN_HOME/.ssh/authorized_keys.away"
rc=0
output="$(MOCK_PASSWORD_AUTH=yes run_audit)" || rc=$?
[ "$rc" -eq 0 ] || fail "no key with password auth enabled is DEGRADED, got $rc"
grep -q 'no usable authorized key' <<<"$output" || fail "the missing key must be reported"
rc=0
output="$(run_audit)" || rc=$?
[ "$rc" -eq 1 ] || fail "no key with password auth DISABLED is a lockout risk (FAILED), got $rc"
mv "$ADMIN_HOME/.ssh/authorized_keys.away" "$ADMIN_HOME/.ssh/authorized_keys"

# --- .env permissions ---------------------------------------------------------
chmod 0644 "$TREE/.env"
rc=0
output="$(run_audit)" || rc=$?
[ "$rc" -eq 1 ] || fail "a world-readable .env must FAIL the audit, got $rc"
grep -q 'world-accessible' <<<"$output" || fail "the .env exposure must be explained"
chmod 0640 "$TREE/.env"
rc=0
output="$(run_audit)" || rc=$?
[ "$rc" -eq 0 ] || fail "a group-readable .env is DEGRADED (exit 0 non-strict), got $rc"
grep -q 'group-accessible' <<<"$output" || fail "the group-readable .env must be reported"
chmod 0600 "$TREE/.env"

# --- .env tracked by Git ------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  git -C "$TREE" init -q
  git -C "$TREE" add -f .env
  rc=0
  output="$(run_audit)" || rc=$?
  [ "$rc" -eq 1 ] || fail "a Git-tracked .env must FAIL the audit, got $rc"
  grep -q 'tracked by Git' <<<"$output" || fail "the Git tracking must be explained"
  rm -rf "$TREE/.git"
fi

# --- Docker exposure and group -----------------------------------------------
rc=0
output="$(MOCK_SS_OUTPUT='LISTEN 0 128 0.0.0.0:2375 0.0.0.0:*\n' run_audit)" || rc=$?
[ "$rc" -eq 1 ] || fail "an unauthenticated Docker TCP listener must FAIL, got $rc"
grep -q '2375' <<<"$output" || fail "the Docker TCP finding must name the port"
rc=0
output="$(MOCK_DOCKER_MEMBERS=eve run_audit)" || rc=$?
[ "$rc" -eq 0 ] || fail "docker group members are DEGRADED, got $rc"
grep -q 'root-equivalent' <<<"$output" || fail "the docker group risk must be explained"
grep -q 'eve' <<<"$output" || fail "the members must be listed"

# --- Matter wildcard bind -----------------------------------------------------
write_env 0 "mqtt matter" 0.0.0.0
rc=0
output="$(run_audit)" || rc=$?
[ "$rc" -eq 0 ] || fail "the Matter wildcard bind is DEGRADED, got $rc"
grep -q 'MATTER_LISTEN_ADDRESS=0.0.0.0' <<<"$output" || fail "the wildcard bind must be flagged"
write_env 0 "mqtt matter" 192.168.10.5
output="$(run_audit)" || true
grep -q 'not a wildcard' <<<"$output" || fail "a specific bind must be reported as OK"

# --- harden: refuses lockout-prone SSH change without a key -------------------
write_env 0
mv "$ADMIN_HOME/.ssh/authorized_keys" "$ADMIN_HOME/.ssh/authorized_keys.away"
SSHD_CONFIG_FIXTURE="$WORK_DIR/sshd_config"
SSHD_DROP_IN_FIXTURE="$WORK_DIR/sshd_config.d"
: > "$SSHD_CONFIG_FIXTURE"
mkdir -p "$SSHD_DROP_IN_FIXTURE"
run_harden() {
  LISA_EDGE_TESTING=1 \
    LISA_SECURITY_SSHD_CONFIG="$SSHD_CONFIG_FIXTURE" \
    LISA_SECURITY_SSHD_DROP_IN_DIR="$SSHD_DROP_IN_FIXTURE" \
    bash "$HARDEN" "$@"
}
rc=0
output="$(MOCK_PASSWORD_AUTH=yes run_harden </dev/null 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "harden must not fail outright, got $rc: $output"
grep -q 'risk remote lockout' <<<"$output" ||
  fail "harden must refuse to disable password login without a usable key"
mv "$ADMIN_HOME/.ssh/authorized_keys.away" "$ADMIN_HOME/.ssh/authorized_keys"
[ ! -e "$SSHD_DROP_IN_FIXTURE/99-lisa-edge-hardening.conf" ] ||
  fail "harden must not write the SSH drop-in without a verified key"

# --- harden: fixes .env mode, never touches docker group ----------------------
chmod 0644 "$TREE/.env"
output="$(MOCK_PASSWORD_AUTH=yes run_harden </dev/null 2>&1)" ||
  fail "harden failed: $output"
[ "$(stat -c '%a' "$TREE/.env")" = "600" ] || fail "harden must restore .env to 0600"
if grep -q 'gpasswd\|deluser' <<<"$output"; then
  fail "harden must never change docker group membership"
fi
grep -q 'left unchanged (no interactive confirmation)' <<<"$output" ||
  fail "non-interactive harden must skip the SSH change even with a key present"

# --- passwordless sudo default stays disabled ---------------------------------
grep -q '^LISA_KEEP_PASSWORDLESS_SUDO=0' "$REPO_ROOT/.env.template" ||
  fail "the template must keep passwordless sudo disabled by default"

echo "Security audit and hardening tests passed."
