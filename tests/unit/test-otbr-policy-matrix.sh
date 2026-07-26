#!/usr/bin/env bash
set -euo pipefail

# OTBR dataset init-or-restore decision matrix: the pure policy function and
# the deploy-time script behavior for every supported recovery policy, with
# pending one-shot markers, active datasets, ambiguous reads, and the
# fail-closed rule that a new Thread network is NEVER created automatically
# while a latest backup exists. Docker/ot-ctl are stubbed on PATH; the
# script runs against an isolated temporary repository tree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
. "$REPO_ROOT/services/otbr/dataset/lib.sh"

fail() {
  echo "OTBR POLICY MATRIX TEST ERROR: $*" >&2
  exit 1
}

# --- pure decision function: full policy x backup-existence table -------------
# columns: auto_restore auto_create latest_exists expected_action
matrix="
1 0 1 restore-latest
1 0 0 fail-no-backup
1 1 1 restore-latest
1 1 0 create-network
0 1 1 fail-backup-restore-disabled
0 1 0 create-network
0 0 1 fail-backup-restore-disabled
0 0 0 fail-no-backup
"
while read -r auto_restore auto_create latest_exists expected; do
  [ -n "$auto_restore" ] || continue
  actual="$(otbr_empty_dataset_action "$auto_restore" "$auto_create" "$latest_exists")"
  [ "$actual" = "$expected" ] ||
    fail "policy restore=$auto_restore create=$auto_create latest=$latest_exists: expected $expected, got $actual"
done <<<"$matrix"

# --- deploy-time harness ------------------------------------------------------
WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE/services/otbr/dataset" "$TREE/lib" "$WORK_DIR/bin"
cp -a "$REPO_ROOT/services/otbr/dataset/init-or-restore.sh" \
  "$REPO_ROOT/services/otbr/dataset/lib.sh" "$TREE/services/otbr/dataset/"
cp -a "$REPO_ROOT/lib/paths.sh" "$TREE/lib/"

CALL_LOG="$WORK_DIR/calls.log"
stub() {
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo "$2 \$*" >> "$CALL_LOG"
EOF
  chmod +x "$1"
}
stub "$TREE/services/otbr/dataset/restore.sh" restore
stub "$TREE/services/otbr/dataset/backup.sh" backup
mkdir -p "$TREE/services/otbr"
stub "$TREE/services/otbr/network-create.sh" network-create

# docker stub: 'ot-ctl state' is always ready; 'dataset active -x' behavior
# is driven by the OTBR_TEST_DATASET_MODE environment variable.
cat > "$WORK_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "ps --format {{.Names}}") echo "lisa-otbr" ;;
  *"ot-ctl state"*) echo "leader" ;;
  *"ot-ctl dataset active -x"*)
    case "${OTBR_TEST_DATASET_MODE:-absent}" in
      present) printf '0e080000000000010000\r\nDone\r\n' ;;
      absent) printf 'Error 23: NotFound\r\n'; exit 1 ;;
      ambiguous) printf 'connect session failed\r\n'; exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK_DIR/bin/docker"
export PATH="$WORK_DIR/bin:$PATH"

BACKUP_DIR="$WORK_DIR/data/backups/otbr"
mkdir -p "$BACKUP_DIR"
LATEST="$BACKUP_DIR/latest.dataset.hex"

write_env() {
  local auto_restore="$1" auto_create="$2"
  cat > "$TREE/.env" <<EOF
DATA_ROOT=$WORK_DIR/data
OTBR_DATASET_BACKUP_DIR=$BACKUP_DIR
OTBR_DATASET_LATEST=$LATEST
OTBR_AUTO_RESTORE_DATASET=$auto_restore
OTBR_AUTO_CREATE_NETWORK=$auto_create
EOF
}

run_script() {
  local mode="$1" rc=0
  : > "$CALL_LOG"
  RUN_OUTPUT="$(LISA_EDGE_TESTING=1 \
    OTBR_TEST_DATASET_MODE="$mode" \
    OTBR_DATASET_WAIT_ATTEMPTS=2 OTBR_DATASET_WAIT_DELAY=0 \
    OTBR_DATASET_CLASSIFY_ATTEMPTS=2 \
    bash "$TREE/services/otbr/dataset/init-or-restore.sh" 2>&1)" || rc=$?
  return "$rc"
}

# --- active dataset present: backup only -------------------------------------
write_env 1 0
run_script present || fail "an active dataset must succeed: $RUN_OUTPUT"
grep -q '^backup' "$CALL_LOG" || fail "an active dataset must be backed up"
grep -q '^restore' "$CALL_LOG" && fail "an active dataset must not trigger a restore"
grep -q '^network-create' "$CALL_LOG" && fail "an active dataset must not trigger network creation"

# --- pending one-shot restore takes precedence over every policy -------------
write_env 0 0
printf '0e080000000000010000\n' > "$BACKUP_DIR/pending.dataset.hex"
run_script absent || fail "a pending restore must succeed: $RUN_OUTPUT"
grep -q "^restore .*pending.dataset.hex" "$CALL_LOG" ||
  fail "the pending dataset must be restored"
grep -q '^backup --label post-restore' "$CALL_LOG" ||
  fail "the restored dataset must be snapshotted"
[ ! -e "$BACKUP_DIR/pending.dataset.hex" ] ||
  fail "the pending restore marker must be consumed"

# --- pending one-shot new network takes precedence over every policy ---------
write_env 1 0
: > "$BACKUP_DIR/pending.new-network"
run_script absent || fail "a pending new network must succeed: $RUN_OUTPUT"
grep -q '^network-create' "$CALL_LOG" || fail "the pending new network must be created"
[ ! -e "$BACKUP_DIR/pending.new-network" ] ||
  fail "the pending new-network marker must be consumed"

# --- empty dataset: policy 1 (restore; fail without backup) ------------------
write_env 1 0
printf '0e080000000000010000\n' > "$LATEST"
run_script absent || fail "policy 1 with a latest backup must restore: $RUN_OUTPUT"
grep -q "^restore .*latest.dataset.hex" "$CALL_LOG" || fail "policy 1 must restore the latest backup"

rm -f "$LATEST"
if run_script absent; then
  fail "policy 1 without a backup must fail"
fi
grep -q 'no latest backup' <<<"$RUN_OUTPUT" || fail "policy 1 failure must explain the missing backup"
grep -q '^network-create' "$CALL_LOG" && fail "policy 1 must never create a network"

# --- empty dataset: policy 2 (restore; create only when no backup) -----------
write_env 1 1
printf '0e080000000000010000\n' > "$LATEST"
run_script absent || fail "policy 2 with a latest backup must restore: $RUN_OUTPUT"
grep -q "^restore .*latest.dataset.hex" "$CALL_LOG" || fail "policy 2 must prefer the restore"
grep -q '^network-create' "$CALL_LOG" && fail "policy 2 must not create while a backup exists"

rm -f "$LATEST"
run_script absent || fail "policy 2 without a backup must create: $RUN_OUTPUT"
grep -q '^network-create' "$CALL_LOG" || fail "policy 2 must create when no backup exists"

# --- empty dataset: policy 3 (no restore; create only when no backup) --------
# THE fail-closed case: a latest backup exists but restoration is disabled;
# a replacement network must NOT be created silently.
write_env 0 1
printf '0e080000000000010000\n' > "$LATEST"
if run_script absent; then
  fail "policy 3 with an existing backup must fail closed"
fi
grep -q 'backup exists' <<<"$RUN_OUTPUT" ||
  fail "policy 3 failure must state that a backup exists: $RUN_OUTPUT"
grep -qi 'restoration is disabled\|restore.*disabled\|OTBR_AUTO_RESTORE_DATASET=0' <<<"$RUN_OUTPUT" ||
  fail "policy 3 failure must explain that restoration is disabled: $RUN_OUTPUT"
grep -q '^network-create' "$CALL_LOG" &&
  fail "policy 3 must NEVER create a network while a backup exists"
grep -q '^restore' "$CALL_LOG" && fail "policy 3 must not restore either"

rm -f "$LATEST"
run_script absent || fail "policy 3 without a backup must create: $RUN_OUTPUT"
grep -q '^network-create' "$CALL_LOG" || fail "policy 3 must create when no backup exists"

# --- empty dataset: policy 4 (never restore or create) -----------------------
write_env 0 0
printf '0e080000000000010000\n' > "$LATEST"
if run_script absent; then
  fail "policy 4 with a backup must fail"
fi
grep -q '^network-create' "$CALL_LOG" && fail "policy 4 must never create a network"

rm -f "$LATEST"
if run_script absent; then
  fail "policy 4 without a backup must fail"
fi
grep -q 'lisa-edge otbr network create' <<<"$RUN_OUTPUT" ||
  fail "policy 4 failure must give actionable guidance: $RUN_OUTPUT"

# --- ambiguous dataset reads refuse every mutation ---------------------------
write_env 1 1
printf '0e080000000000010000\n' > "$LATEST"
if run_script ambiguous; then
  fail "an ambiguous dataset state must fail"
fi
grep -q 'ambiguous' <<<"$RUN_OUTPUT" || fail "the ambiguous failure must say so: $RUN_OUTPUT"
grep -q '^restore\|^network-create' "$CALL_LOG" &&
  fail "an ambiguous state must not trigger restore or creation"

echo "OTBR policy matrix tests passed."
