#!/usr/bin/env bash
set -euo pipefail

# Restore CLI options: the operator-facing service-start options are
# --start-services / --no-start-services; the obsolete public deploy
# wording (--deploy / --no-deploy) is rejected before any validation or
# mutation. No live host is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESTORE="$REPO_ROOT/ops/backup-restore/restore.sh"

fail() {
  echo "RESTORE ARGS TEST ERROR: $*" >&2
  exit 1
}

for stale in --deploy --no-deploy; do
  rc=0
  output="$(bash "$RESTORE" "$stale" /tmp/does-not-exist.tar.gz 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "obsolete option $stale must be rejected"
  grep -q "Unknown option: $stale" <<<"$output" ||
    fail "obsolete option $stale must be reported as unknown, got: $output"
done

usage_output="$(bash "$RESTORE" --help 2>&1 || true)"
grep -q -- '--start-services' <<<"$usage_output" ||
  fail "restore usage must document --start-services"
grep -q -- '--no-start-services' <<<"$usage_output" ||
  fail "restore usage must document --no-start-services"
if grep -Eq -- '--no-deploy|--deploy\b' <<<"$usage_output"; then
  fail "restore usage must not mention the obsolete deploy options"
fi

echo "Restore argument tests passed."
