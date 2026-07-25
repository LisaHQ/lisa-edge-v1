#!/usr/bin/env bash
set -euo pipefail

# Root CLI command-model contract: the operator-facing model is setup,
# update, service add/remove/start/stop, security audit/harden plus the
# existing status/health/data-protection commands. The removed root
# commands (configure, bootstrap, deploy, stop) and the never-added ones
# (apply, refresh, reconcile, service delete) must be rejected as unknown.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/lisa-edge"

fail() {
  echo "ROOT CLI TEST ERROR: $*" >&2
  exit 1
}

expect_rejected() {
  local label="$1"
  shift
  local rc=0 output
  output="$(bash "$CLI" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must be rejected with exit 2, got $rc"
  printf '%s\n' "$output"
}

# --- removed root commands are unknown --------------------------------------
output="$(expect_rejected "root 'configure'" configure)"
grep -q 'Unknown command: configure' <<<"$output" || fail "configure rejection must name the command"
output="$(expect_rejected "root 'bootstrap'" bootstrap)"
grep -q 'Unknown command: bootstrap' <<<"$output" || fail "bootstrap rejection must name the command"
output="$(expect_rejected "root 'deploy'" deploy)"
grep -q 'Unknown command: deploy' <<<"$output" || fail "deploy rejection must name the command"
output="$(expect_rejected "root 'stop'" stop)"
grep -q 'Unknown command: stop' <<<"$output" || fail "stop rejection must name the command"

# --- no replacement aliases --------------------------------------------------
expect_rejected "root 'apply'" apply >/dev/null
expect_rejected "root 'refresh'" refresh >/dev/null
expect_rejected "root 'reconcile'" reconcile >/dev/null

# --- no 'matter thread reconcile' subcommand ---------------------------------
rc=0
output="$(bash "$CLI" matter thread reconcile 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "'matter thread reconcile' must be rejected, got $rc"
grep -qi 'unknown matter thread subcommand' <<<"$output" ||
  fail "'matter thread reconcile' rejection must come from the thread CLI"

# --- no 'service delete' alias ----------------------------------------------
rc=0
output="$(bash "$CLI" service delete mqtt 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "'service delete' must be rejected, got $rc"
grep -q 'unknown service subcommand' <<<"$output" ||
  fail "'service delete' rejection must list the valid subcommands"

# --- security usage ----------------------------------------------------------
output="$(bash "$CLI" security)" || fail "bare 'security' must show usage and exit 0"
grep -q 'security audit' <<<"$output" || fail "security usage must mention audit"
grep -q 'security harden' <<<"$output" || fail "security usage must mention harden"
rc=0
bash "$CLI" security bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown security subcommand must exit 2, got $rc"

# --- help advertises the new model and drops the old one ---------------------
help_output="$(bash "$CLI" help)"
for expected in 'service add' 'service remove' 'service start' 'service stop' \
  'security audit' 'security harden' 'setup' 'update'
do
  grep -Fq "$expected" <<<"$help_output" || fail "help must advertise: $expected"
done
for removed in configure bootstrap deploy apply refresh reconcile; do
  if grep -Eq "^  ${removed}([[:space:]]|\$)" <<<"$help_output"; then
    fail "help must not advertise removed command: $removed"
  fi
done

# --- stale error guidance is gone --------------------------------------------
if grep -RIn "lisa-edge configure" \
  "$REPO_ROOT/lib" "$REPO_ROOT/ops" "$REPO_ROOT/services" "$REPO_ROOT/install" \
  --include='*.sh' 2>/dev/null | grep -v 'thread-sync\|#'; then
  fail "implementation still recommends the removed 'configure' command"
fi

# --- MATTER_THREAD_CREDENTIAL_ID must not return as a config concept ---------
if grep -RIn 'MATTER_THREAD_CREDENTIAL_ID=' \
  "$REPO_ROOT/.env.template" "$REPO_ROOT/ops" "$REPO_ROOT/install" 2>/dev/null; then
  fail "MATTER_THREAD_CREDENTIAL_ID must not be reintroduced as configuration"
fi

echo "Root CLI command-model tests passed."
