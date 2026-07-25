#!/usr/bin/env bash
set -euo pipefail

# Shared internal Matter/OTBR check-and-sync path
# (services/matter-server/thread-sync-if-needed.sh), exercised through the
# real ws.sh wrapper and ws-client.js with docker mocked by a PATH shim
# (same protocol mock as test-matter-cli.sh). Covers: state classification,
# no-op on match, non-interactive no-prompt behavior, pre-consented
# affirmative mode, interactive accept/decline (via a pty), OTBR without a
# dataset, unselected/not-running services, check-only exit codes, and
# secret safety. No live host is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "THREAD SYNC TEST ERROR: $*" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required for the thread sync tests"

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" "$TREE/"
cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES="matter otbr"
MATTER_SERVER_PORT=5580
MATTER_LISTEN_ADDRESS=127.0.0.1
EOF

# Mocked `ws` module (see test-matter-cli.sh for the protocol shape).
mkdir -p "$WORK_DIR/node_modules/ws"
cat > "$WORK_DIR/node_modules/ws/index.js" <<'EOF'
const { EventEmitter } = require("events");
const fs = require("fs");
let defaultConfigured = false;
class WebSocket extends EventEmitter {
  constructor(url) {
    super();
    const scenario = process.env.MOCK_SCENARIO || "ok";
    setImmediate(() => {
      if (scenario === "connect-fail") { this.emit("error", new Error("ECONNREFUSED")); return; }
      this.emit("open");
      this.emit("message", JSON.stringify({
        schema_version: 12, min_supported_schema_version: 11,
        sdk_version: "0.17.5", wifi_credentials_set: false,
        thread_credentials_set: scenario !== "legacy-only",
        bluetooth_enabled: true,
      }));
    });
  }
  threadEntries() {
    const scenario = process.env.MOCK_SCENARIO || "ok";
    if (scenario === "mismatch") {
      return [{ id: null, networkName: "OTHER-NET", extPanId: "9999999999999999" }];
    }
    if (scenario === "legacy-only") {
      const entries = [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" }];
      if (defaultConfigured) {
        entries.push({ id: null, networkName: "LISA-HOME-01", extPanId: "1122334455667788" });
      }
      return entries;
    }
    return [{ id: null, networkName: "LISA-HOME-01", extPanId: "1122334455667788" }];
  }
  send(raw) {
    if (process.env.WS_MSG_LOG) fs.appendFileSync(process.env.WS_MSG_LOG, raw + "\n");
    const msg = JSON.parse(raw);
    const scenario = process.env.MOCK_SCENARIO || "ok";
    setImmediate(() => {
      this.emit("message", JSON.stringify({ event: "node_updated", data: {} }));
      if (msg.command === "set_thread_dataset") {
        if (msg.args.id === undefined) defaultConfigured = true;
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: null }));
      } else if (msg.command === "server_info") {
        this.emit("message", JSON.stringify({
          message_id: msg.message_id,
          result: {
            schema_version: 12, min_supported_schema_version: 11,
            sdk_version: "0.17.5", wifi_credentials_set: false,
            thread_credentials_set: scenario === "legacy-only" ? defaultConfigured : true,
            bluetooth_enabled: true,
          },
        }));
      } else if (msg.command === "get_all_credentials") {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: { wifi: [], thread: this.threadEntries() } }));
      } else if (msg.command === "get_fabric_label") {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: { fabric_label: "LISA Home" } }));
      } else if (msg.command === "get_nodes") {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: [] }));
      } else if (msg.command === "remove_thread_dataset") {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: null }));
      }
    });
  }
  close() {}
}
module.exports = WebSocket;
module.exports.WebSocket = WebSocket;
EOF

# OTBR dataset matching the mock's default credential (LISA-HOME-01 /
# 1122334455667788).
OTBR_DATASET="0e080000000000010000000300000f02081122334455667788030c4c4953412d484f4d452d30310510000102030405060708090a0b0c0d0e0f0102abcd"
export MOCK_OTBR_DATASET="$OTBR_DATASET"
export MOCK_RUNNING_CONTAINERS="lisa-otbr lisa-matter"

WS_MSG_LOG="$WORK_DIR/ws-messages.log"
export WS_MSG_LOG
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\$1" = "ps" ]; then
  for c in \$MOCK_RUNNING_CONTAINERS; do printf '%s\n' "\$c"; done
  exit 0
fi
if [ "\$1" != "exec" ]; then
  exit 0
fi
shift
declare -a client_env=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -i) shift ;;
    -e) client_env+=("\$2"); shift 2 ;;
    lisa-matter)
      shift
      if [ "\$1" = "node" ] && [ "\$2" = "-" ]; then
        exec env "\${client_env[@]}" NODE_PATH="$WORK_DIR/node_modules" node -
      fi
      exit 0
      ;;
    lisa-otbr)
      shift
      case "\$*" in
        *"dataset active -x"*)
          if [ -n "\$MOCK_OTBR_DATASET" ]; then
            printf '%s\r\nDone\r\n' "\$MOCK_OTBR_DATASET"
          else
            printf 'Error 23: NotFound\r\n'
            exit 1
          fi
          exit 0
          ;;
        *"state"*) printf 'leader\r\nDone\r\n'; exit 0 ;;
      esac
      exit 0
      ;;
    *) shift ;;
  esac
done
exit 0
EOF
chmod +x "$WORK_DIR/bin/docker"
export PATH="$WORK_DIR/bin:$PATH"

SYNC_IF_NEEDED="$TREE/services/matter-server/thread-sync-if-needed.sh"

# Run under a pty so stdin AND stdout are terminals (interactive path).
run_tty() {
  local input="$1"
  shift
  printf '%s' "$input" | script -qec "bash $SYNC_IF_NEEDED $*" /dev/null
}

# --- already matching: no prompt, no mutation, concise no-op -----------------
: > "$WS_MSG_LOG"
rc=0
output="$(bash "$SYNC_IF_NEEDED" </dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "matching state must exit 0, got $rc"
grep -q 'already matches' <<<"$output" || fail "matching state must report the no-op"
grep -q 'LISA-HOME-01' <<<"$output" || fail "the no-op report should name the network"
if grep -q '"command":"set_thread_dataset"' "$WS_MSG_LOG"; then
  fail "matching state must not store anything"
fi
if grep -qi 'Copy OTBR' <<<"$output"; then
  fail "matching state must not prompt"
fi
if grep -qi "$OTBR_DATASET" <<<"$output"; then
  fail "output must never contain the dataset"
fi

# Matching state under a REAL terminal must not prompt either.
if command -v script >/dev/null 2>&1; then
  rc=0
  output="$(run_tty '' )" || rc=$?
  [ "$rc" -eq 0 ] || fail "matching state (tty) must exit 0, got $rc"
  if grep -qi 'Copy OTBR' <<<"$output"; then
    fail "matching state (tty) must not prompt"
  fi
fi

# --- default missing, non-interactive: no prompt, no hang, remediation -------
: > "$WS_MSG_LOG"
rc=0
output="$(MOCK_SCENARIO=legacy-only timeout 30 bash "$SYNC_IF_NEEDED" </dev/null)" || rc=$?
[ "$rc" -eq 3 ] || fail "non-interactive needed-sync must exit 3, got $rc"
grep -q 'NOT configured' <<<"$output" || fail "missing default must be reported"
grep -q 'matter thread sync' <<<"$output" || fail "remediation command must be printed"
if grep -q '"command":"set_thread_dataset"' "$WS_MSG_LOG"; then
  fail "non-interactive path must not mutate"
fi

# --- drift, LISA_THREAD_SYNC_NO_PROMPT=1 on a tty: still no prompt -----------
if command -v script >/dev/null 2>&1; then
  : > "$WS_MSG_LOG"
  rc=0
  output="$(MOCK_SCENARIO=mismatch LISA_THREAD_SYNC_NO_PROMPT=1 run_tty '')" || rc=$?
  [ "$rc" -eq 3 ] || fail "no-prompt drift must exit 3, got $rc"
  grep -q 'differs from OTBR' <<<"$output" || fail "drift must be described"
  if grep -qi 'Copy OTBR' <<<"$output"; then
    fail "LISA_THREAD_SYNC_NO_PROMPT=1 must suppress the prompt"
  fi
  if grep -q '"command":"set_thread_dataset"' "$WS_MSG_LOG"; then
    fail "no-prompt drift must not mutate"
  fi
fi

# --- pre-consented affirmative mode syncs without prompting ------------------
: > "$WS_MSG_LOG"
rc=0
output="$(MOCK_SCENARIO=legacy-only LISA_THREAD_SYNC_ASSUME_YES=1 bash "$SYNC_IF_NEEDED" </dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "pre-consented sync must succeed, got $rc: $output"
grep -q '"command":"set_thread_dataset"' "$WS_MSG_LOG" ||
  fail "pre-consented mode must store the dataset"
sync_frame="$(grep '"command":"set_thread_dataset"' "$WS_MSG_LOG")"
if grep -q '"id"' <<<"$sync_frame"; then
  fail "the sync must target the reserved default (no id field), sent: $sync_frame"
fi
if grep -qi 'Copy OTBR' <<<"$output"; then
  fail "pre-consented mode must not prompt"
fi

# --- interactive accept (default Yes on Enter) and decline -------------------
if command -v script >/dev/null 2>&1; then
  : > "$WS_MSG_LOG"
  rc=0
  output="$(MOCK_SCENARIO=legacy-only run_tty $'\n')" || rc=$?
  [ "$rc" -eq 0 ] || fail "interactive accept (Enter = default Yes) must sync, got $rc"
  grep -q "Copy OTBR's active Thread dataset to Matter Server's default credential? \[Y/n\]" <<<"$output" ||
    fail "the prompt must state direction and destination with a [Y/n] default"
  grep -q '"command":"set_thread_dataset"' "$WS_MSG_LOG" ||
    fail "interactive accept must store the dataset"

  : > "$WS_MSG_LOG"
  rc=0
  output="$(MOCK_SCENARIO=legacy-only run_tty $'n\n')" || rc=$?
  [ "$rc" -eq 3 ] || fail "interactive decline must exit 3, got $rc"
  grep -q 'matter thread sync' <<<"$output" || fail "decline must print the remediation command"
  if grep -q '"command":"set_thread_dataset"' "$WS_MSG_LOG"; then
    fail "interactive decline must not mutate"
  fi
else
  echo "NOTE: 'script' unavailable; interactive pty scenarios skipped." >&2
fi

# --- OTBR has no readable dataset --------------------------------------------
rc=0
output="$(MOCK_OTBR_DATASET= bash "$SYNC_IF_NEEDED" </dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "no-dataset state must exit 0, got $rc"
grep -q 'no readable active Thread dataset' <<<"$output" ||
  fail "no-dataset state must be explained"
grep -q 'matter thread sync' <<<"$output" || fail "no-dataset state must print the later command"

# --- Matter not running / not selected ---------------------------------------
rc=0
output="$(MOCK_RUNNING_CONTAINERS="lisa-otbr" bash "$SYNC_IF_NEEDED" </dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "matter-not-running must exit 0, got $rc"
grep -q 'not running' <<<"$output" || fail "matter-not-running must be reported"

sed -i 's/^LISA_COMPOSE_SERVICES=.*/LISA_COMPOSE_SERVICES="otbr"/' "$TREE/.env"
rc=0
output="$(bash "$SYNC_IF_NEEDED" </dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "not-selected must exit 0, got $rc"
sed -i 's/^LISA_COMPOSE_SERVICES=.*/LISA_COMPOSE_SERVICES="matter otbr"/' "$TREE/.env"

# --- check-only mode: read-only classification with stable exit codes --------
: > "$WS_MSG_LOG"
rc=0
output="$(bash "$SYNC_IF_NEEDED" --check-only </dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "check-only on match must exit 0, got $rc"
grep -q 'thread-sync-state=match' <<<"$output" || fail "check-only must print the match state"
rc=0
output="$(MOCK_SCENARIO=legacy-only bash "$SYNC_IF_NEEDED" --check-only </dev/null)" || rc=$?
[ "$rc" -eq 3 ] || fail "check-only on missing default must exit 3, got $rc"
grep -q 'thread-sync-state=default-missing' <<<"$output" || fail "check-only must classify default-missing"
rc=0
output="$(MOCK_SCENARIO=mismatch bash "$SYNC_IF_NEEDED" --check-only </dev/null)" || rc=$?
[ "$rc" -eq 3 ] || fail "check-only on drift must exit 3, got $rc"
grep -q 'thread-sync-state=drift' <<<"$output" || fail "check-only must classify drift"
rc=0
output="$(MOCK_OTBR_DATASET= bash "$SYNC_IF_NEEDED" --check-only </dev/null)" || rc=$?
[ "$rc" -eq 4 ] || fail "check-only without a dataset must exit 4, got $rc"
grep -q 'thread-sync-state=otbr-no-dataset' <<<"$output" || fail "check-only must classify otbr-no-dataset"
if grep -q '"command":"set_thread_dataset"' "$WS_MSG_LOG"; then
  fail "check-only must never mutate"
fi

echo "Thread sync check-and-sync tests passed."
