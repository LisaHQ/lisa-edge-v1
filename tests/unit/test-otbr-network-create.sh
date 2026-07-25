#!/usr/bin/env bash
set -euo pipefail

# Thread network creation flow, exercised against a stateful ot-ctl mock in
# an isolated copy of the repository: command order, PSKc-after-name,
# confirmation handling, backup-before-replace, read-back verification,
# attachment timeout, and Matter sync invocation. No live host is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "OTBR NETWORK CREATE TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# Isolated repository copy so sibling-script calls (backup, matter sync) can
# be stubbed without touching the real tree.
TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" "$TREE/"

CALL_LOG="$WORK_DIR/calls.log"
cat > "$TREE/services/otbr/dataset/backup.sh" <<EOF
#!/usr/bin/env bash
echo "backup \$*" >> "$CALL_LOG"
EOF
cat > "$TREE/services/matter-server/thread.sh" <<EOF
#!/usr/bin/env bash
echo "matter-thread \$*" >> "$CALL_LOG"
EOF
cat > "$TREE/services/matter-server/thread-sync-if-needed.sh" <<EOF
#!/usr/bin/env bash
echo "thread-sync-if-needed \$*" >> "$CALL_LOG"
EOF
chmod +x "$TREE/services/otbr/dataset/backup.sh" "$TREE/services/matter-server/thread.sh" \
  "$TREE/services/matter-server/thread-sync-if-needed.sh"

cat > "$TREE/.env" <<'EOF'
THREAD_NETWORK_NAME=LISA-HOME-01
LISA_COMPOSE_SERVICES="matter otbr"
OTBR_AGENT_WAIT_ATTEMPTS=2
OTBR_DATASET_CLASSIFY_ATTEMPTS=2
OTBR_ATTACH_WAIT_ATTEMPTS=2
OTBR_WAIT_DELAY_SECONDS=0
EOF

# Stateful docker/ot-ctl mock.
MOCK_DIR="$WORK_DIR/mock"
mkdir -p "$MOCK_DIR" "$WORK_DIR/bin"
export MOCK_DIR
cat > "$WORK_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log() { echo "$*" >> "$MOCK_DIR/ot.log"; }
if [ "$1" = "ps" ]; then
  printf 'lisa-otbr\nlisa-matter\n'
  exit 0
fi
# docker exec lisa-otbr ot-ctl ...
shift 2 # exec lisa-otbr
[ "$1" = "ot-ctl" ] || exit 0
shift
case "$*" in
  "state")
    if [ -f "$MOCK_DIR/thread-started" ] && [ "${MOCK_ATTACH_FAIL:-0}" != "1" ]; then
      printf 'leader\r\nDone\r\n'
    else
      printf 'detached\r\nDone\r\n'
    fi
    ;;
  "dataset active -x")
    if [ -f "$MOCK_DIR/active.hex" ]; then
      printf '%s\r\nDone\r\n' "$(cat "$MOCK_DIR/active.hex")"
    else
      printf 'Error 23: NotFound\r\n'
      exit 1
    fi
    ;;
  "dataset init new")
    log "dataset init new"
    : > "$MOCK_DIR/staged"
    ;;
  "dataset networkname "*)
    log "dataset networkname $3"
    printf '%s' "$3" > "$MOCK_DIR/staged-name"
    ;;
  "dataset pskc "*)
    log "dataset pskc <hex>"
    ;;
  "dataset commit active")
    log "dataset commit active"
    name="$(cat "$MOCK_DIR/staged-name" 2>/dev/null || echo UNSET)"
    name="${MOCK_COMMIT_NAME:-$name}"
    name_hex="$(printf '%s' "$name" | od -An -tx1 | tr -d ' \n')"
    name_len="$(printf '%02x' "${#name}")"
    printf '03%s%s0208aabbccddeeff00110102face0510000102030405060708090a0b0c0d0e0f' \
      "$name_len" "$name_hex" > "$MOCK_DIR/active.hex"
    ;;
  "ifconfig up") log "ifconfig up" ;;
  "thread start")
    log "thread start"
    : > "$MOCK_DIR/thread-started"
    ;;
  "thread stop"|"ifconfig down"|"dataset clear") log "$*" ;;
  *) log "unhandled: $*" ;;
esac
printf 'Done\r\n'
EOF
chmod +x "$WORK_DIR/bin/docker"
export PATH="$WORK_DIR/bin:$PATH"

reset_mock() {
  rm -rf "$MOCK_DIR"
  mkdir -p "$MOCK_DIR"
  : > "$CALL_LOG"
}

# --- 1. fresh creation (no existing dataset) -------------------------------
reset_mock
output="$(bash "$TREE/services/otbr/network-create.sh" </dev/null)" ||
  fail "fresh network creation failed: $output"
grep -q 'Thread network:       LISA-HOME-01' <<<"$output" ||
  fail "creation output must show the new network name"
grep -q 'must be factory-reset and re-commissioned' <<<"$output" ||
  fail "creation must state that devices need re-commissioning"
# Verified OpenThread command order, PSKc strictly after the network name.
ORDER="$(grep -vE '^(thread stop|ifconfig down|dataset clear)' "$MOCK_DIR/ot.log" | tr '\n' '|')"
case "$ORDER" in
  "dataset init new|dataset networkname LISA-HOME-01|dataset pskc <hex>|dataset commit active|ifconfig up|thread start|") ;;
  *) fail "unexpected ot-ctl command order: $ORDER" ;;
esac
grep -q '^backup --label network-create' "$CALL_LOG" ||
  fail "the new dataset must be backed up"
grep -q '^thread-sync-if-needed' "$CALL_LOG" ||
  fail "creation must run the shared Matter check-and-sync path when matter is selected"
if grep -q '^matter-thread sync' "$CALL_LOG"; then
  fail "creation must not call the sync CLI directly (shared path only)"
fi
if grep -q '^backup --label pre-network-create' "$CALL_LOG"; then
  fail "fresh creation must not claim a pre-replacement backup"
fi

# --- 2. existing dataset: refused confirmation leaves it untouched ----------
reset_mock
printf '03084c4953412d5453540208112233445566778801020abc' > "$MOCK_DIR/active.hex"
: > "$MOCK_DIR/thread-started"
rc=0
output="$(printf 'no\n' | bash "$TREE/services/otbr/network-create.sh" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "refused confirmation must exit nonzero"
grep -q 'Aborted' <<<"$output" || fail "refusal must report Aborted"
if [ -f "$MOCK_DIR/ot.log" ] && grep -q 'dataset init new' "$MOCK_DIR/ot.log"; then
  fail "refused confirmation must not mutate the dataset"
fi
[ ! -s "$CALL_LOG" ] || fail "refused confirmation must not call backup or sync"

# --- 3. existing dataset: typed CREATE replaces it, backup first -------------
reset_mock
printf '03084c4953412d5453540208112233445566778801020abc' > "$MOCK_DIR/active.hex"
: > "$MOCK_DIR/thread-started"
output="$(printf 'CREATE\n' | bash "$TREE/services/otbr/network-create.sh")" ||
  fail "confirmed replacement failed: $output"
head -n 1 "$CALL_LOG" | grep -q '^backup --label pre-network-create' ||
  fail "the current dataset must be backed up before replacement"
grep -q 'dataset init new' "$MOCK_DIR/ot.log" || fail "replacement must create a new dataset"

# --- 4. attachment timeout fails clearly -----------------------------------
reset_mock
rc=0
output="$(MOCK_ATTACH_FAIL=1 bash "$TREE/services/otbr/network-create.sh" </dev/null 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "attachment timeout must fail"
grep -q 'did not attach' <<<"$output" || fail "attachment timeout must be reported"

# --- 5. read-back name mismatch fails ---------------------------------------
reset_mock
rc=0
output="$(MOCK_COMMIT_NAME=WRONG-NAME bash "$TREE/services/otbr/network-create.sh" </dev/null 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "read-back mismatch must fail"
grep -q 'Read-back verification failed' <<<"$output" || fail "read-back mismatch must be reported"

# --- 6. invalid configured name refuses before touching anything -------------
reset_mock
cp "$TREE/.env" "$TREE/.env.good"
sed -i 's/^THREAD_NETWORK_NAME=.*/THREAD_NETWORK_NAME=THIS-NAME-IS-XXL-17/' "$TREE/.env"
rc=0
output="$(bash "$TREE/services/otbr/network-create.sh" </dev/null 2>&1)" || rc=$?
mv "$TREE/.env.good" "$TREE/.env"
[ "$rc" -ne 0 ] || fail "invalid THREAD_NETWORK_NAME must fail"
[ ! -s "$MOCK_DIR/ot.log" ] || fail "invalid name must not reach ot-ctl"

echo "OTBR network creation tests passed."
