#!/usr/bin/env bash
set -euo pipefail

# Matter CLI behavior end-to-end through the real ws.sh wrapper and the real
# ws-client.js under node, with docker mocked by a PATH shim: reserved
# default-credential sync and verification (set_thread_dataset without an
# id), accurate sync wording, no server restart, no dataset in process
# arguments, drift detection, legacy named-credential handling, credential
# listing, removal confirmation, and tolerance of the legacy
# MATTER_THREAD_CREDENTIAL_ID .env variable. No live host is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "MATTER CLI TEST ERROR: $*" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required for the Matter CLI tests"

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" "$TREE/"
# The legacy MATTER_THREAD_CREDENTIAL_ID line stays in the .env on purpose:
# upgraded deployments still carry it and it must be ignored, never fatal.
cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES="matter otbr"
MATTER_SERVER_PORT=5580
MATTER_LISTEN_ADDRESS=127.0.0.1
MATTER_THREAD_CREDENTIAL_ID=lisa-home-01
EOF

# Mocked `ws` module (same protocol mock as test-matter-ws-client.sh).
# Scenarios: ok (configured default + legacy named duplicate), mismatch
# (drifted default), legacy-only (named entry only, default unconfigured),
# reject. Command frames are appended to WS_MSG_LOG for wire assertions.
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
      // Drifted default (null id = reserved default) plus the legacy entry.
      return [{ id: "lisa-home-01", networkName: "OTHER-NET", extPanId: "9999999999999999" },
              { id: null, networkName: "OTHER-NET", extPanId: "9999999999999999" }];
    }
    if (scenario === "legacy-only") {
      // Migration starting point: named entry only, default unconfigured
      // until a sync in this process populates it.
      const entries = [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" }];
      if (defaultConfigured) {
        entries.push({ id: null, networkName: "LISA-HOME-01", extPanId: "1122334455667788" });
      }
      return entries;
    }
    return [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" },
            { id: null, networkName: "LISA-HOME-01", extPanId: "1122334455667788" }];
  }
  send(raw) {
    if (process.env.WS_MSG_LOG) fs.appendFileSync(process.env.WS_MSG_LOG, raw + "\n");
    const msg = JSON.parse(raw);
    const scenario = process.env.MOCK_SCENARIO || "ok";
    setImmediate(() => {
      this.emit("message", JSON.stringify({ event: "node_updated", data: {} }));
      if (msg.command === "set_thread_dataset") {
        if (scenario === "reject") {
          this.emit("message", JSON.stringify({ message_id: msg.message_id, error_code: 9, details: "rejected by server" }));
          return;
        }
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

# OTBR active dataset matching the mock's stored credential summary
# (network name LISA-HOME-01, extended PAN ID 1122334455667788).
OTBR_DATASET="0e080000000000010000000300000f02081122334455667788030c4c4953412d484f4d452d30310510000102030405060708090a0b0c0d0e0f0102abcd"
export MOCK_OTBR_DATASET="$OTBR_DATASET"

ARGV_LOG="$WORK_DIR/docker-argv.log"
export ARGV_LOG
WS_MSG_LOG="$WORK_DIR/ws-messages.log"
export WS_MSG_LOG
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "\$ARGV_LOG"
if [ "\$1" = "ps" ]; then
  printf 'lisa-otbr\nlisa-matter\n'
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
        *"dataset active -x"*) printf '%s\r\nDone\r\n' "\$MOCK_OTBR_DATASET"; exit 0 ;;
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

THREAD_CLI="$TREE/services/matter-server/thread.sh"
CRED_CLI="$TREE/services/matter-server/credentials.sh"

# --- sync --from-otbr targets the reserved default with accurate wording ------
: > "$ARGV_LOG"
: > "$WS_MSG_LOG"
output="$(bash "$THREAD_CLI" sync --from-otbr)" || fail "sync --from-otbr failed: $output"
grep -q 'reserved default credential' <<<"$output" || fail "sync must name the default credential slot"
grep -q 'thread_credentials_set: true' <<<"$output" || fail "sync must report thread_credentials_set"
grep -q 'identity fields match' <<<"$output" || fail "sync must use identity-field language"
grep -q 'Network Key' <<<"$output" || fail "sync must state that the network key is not comparable"
grep -q 'NOT restarted' <<<"$output" || fail "sync must state the server was not restarted"
if grep -qi 'dataset.*equal\|identical dataset' <<<"$output"; then
  fail "sync must not claim complete dataset equality"
fi
if grep -qi "$OTBR_DATASET" <<<"$output"; then
  fail "sync output must never contain the dataset"
fi
# The wire call must OMIT the id field (upstream reserved-default semantics).
sync_frame="$(grep '"command":"set_thread_dataset"' "$WS_MSG_LOG")" ||
  fail "sync must send set_thread_dataset"
if grep -q '"id"' <<<"$sync_frame"; then
  fail "sync must not send an id field for the reserved default, sent: $sync_frame"
fi
# The dataset must never appear in any docker process argument.
if grep -qi "$OTBR_DATASET" "$ARGV_LOG"; then
  fail "the dataset must not be passed through process arguments"
fi
if grep -qiE 'restart|stop lisa-matter|start lisa-matter' "$ARGV_LOG"; then
  fail "sync must not restart the Matter server"
fi

# --- migration path: legacy named entry only, then sync populates default -----
: > "$WS_MSG_LOG"
output="$(MOCK_SCENARIO=legacy-only bash "$THREAD_CLI" sync --from-otbr)" ||
  fail "sync must succeed while only the legacy named credential exists: $output"
grep -q 'reserved default credential' <<<"$output" || fail "migration sync must target the default"
sync_frame="$(grep '"command":"set_thread_dataset"' "$WS_MSG_LOG")"
if grep -q '"id"' <<<"$sync_frame"; then
  fail "migration sync must not send an id field, sent: $sync_frame"
fi
if grep -q '"command":"remove_thread_dataset"' "$WS_MSG_LOG"; then
  fail "sync must never delete the legacy named credential"
fi

# --- sync --file and --stdin ---------------------------------------------------
DATASET_FILE="$WORK_DIR/dataset.hex"
printf '%s\n' "$OTBR_DATASET" > "$DATASET_FILE"
bash "$THREAD_CLI" sync --file "$DATASET_FILE" >/dev/null || fail "sync --file failed"
printf '%s\n' "$OTBR_DATASET" | bash "$THREAD_CLI" sync --stdin >/dev/null || fail "sync --stdin failed"

# Checksum sidecar mismatch must refuse the file.
printf 'deadbeef  dataset.hex\n' > "$DATASET_FILE.sha256"
rc=0
bash "$THREAD_CLI" sync --file "$DATASET_FILE" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "sync must refuse a dataset failing its checksum"
rm -f "$DATASET_FILE.sha256"

# --- argument validation ---------------------------------------------------------
rc=0
bash "$THREAD_CLI" sync "$OTBR_DATASET" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "positional dataset must be rejected with exit 2, got $rc"
rc=0
bash "$THREAD_CLI" sync --from-otbr --file "$DATASET_FILE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "conflicting sources must be rejected, got $rc"
rc=0
bash "$THREAD_CLI" sync --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown sync option must exit 2, got $rc"
rc=0
output="$(bash "$THREAD_CLI" sync --id lisa-home-01 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "sync --id must be rejected (default-only interface), got $rc"
grep -q 'reserved default' <<<"$output" || fail "sync --id rejection must explain the default model"
rc=0
bash "$THREAD_CLI" bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown thread subcommand must exit 2, got $rc"

# --- server rejection is surfaced ------------------------------------------------
rc=0
output="$(MOCK_SCENARIO=reject bash "$THREAD_CLI" sync --from-otbr 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "server rejection must exit 1, got $rc"
grep -qi 'rejected' <<<"$output" || fail "rejection must be reported"

# --- stored-summary mismatch is a failure ------------------------------------------
rc=0
output="$(MOCK_SCENARIO=mismatch bash "$THREAD_CLI" sync --from-otbr 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "stored-summary mismatch must exit 1, got $rc"
grep -qi 'does not match' <<<"$output" || fail "mismatch must be explained"

# --- thread status: match, drift, and legacy-only ------------------------------
output="$(bash "$THREAD_CLI" status)" || fail "thread status (in sync) failed: $output"
grep -q 'Default credential:' <<<"$output" || fail "status must report the default credential slot"
grep -q 'configured -> LISA-HOME-01' <<<"$output" ||
  fail "status must show the default credential's network summary"
grep -q 'legacy duplicate of the default' <<<"$output" ||
  fail "status must mark the matching named entry as a legacy duplicate"
grep -q 'No detectable Thread' <<<"$output" ||
  fail "in-sync status must use the accurate no-drift wording"
grep -q 'expected to WORK' <<<"$output" || fail "in-sync status must state commissioning readiness"

rc=0
output="$(MOCK_SCENARIO=mismatch bash "$THREAD_CLI" status 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "drifted status must exit nonzero, got $rc"
grep -q 'DRIFT' <<<"$output" || fail "drift must be reported"
grep -q 'expected to FAIL' <<<"$output" || fail "drifted status must state commissioning impact"
grep -q 'matter thread sync' <<<"$output" || fail "drifted status must point at the sync command"

# A matching named credential with an unconfigured default must NOT be ready.
rc=0
output="$(MOCK_SCENARIO=legacy-only bash "$THREAD_CLI" status 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "legacy-only status must exit nonzero, got $rc"
grep -q 'NOT CONFIGURED' <<<"$output" || fail "legacy-only status must report the default as unconfigured"
grep -q 'expected to FAIL' <<<"$output" || fail "legacy-only status must state commissioning impact"
grep -q 'named entries' <<<"$output" ||
  fail "legacy-only status must explain that named entries do not make commissioning ready"

# --- credentials list ---------------------------------------------------------------
output="$(bash "$CRED_CLI" list)" || fail "credentials list failed"
grep -q 'Reserved default credential' <<<"$output" || fail "credentials list must lead with the default slot"
grep -q 'configured -> network LISA-HOME-01' <<<"$output" ||
  fail "credentials list must show the configured default summary"
grep -q 'lisa-home-01' <<<"$output" || fail "credentials list must show the named entry"
grep -q 'legacy duplicate of the default' <<<"$output" ||
  fail "credentials list must mark the legacy duplicate"
grep -q '1122334455667788' <<<"$output" || fail "credentials list must show the extended PAN ID"

# The unconfigured default must never be presented as configured.
output="$(MOCK_SCENARIO=legacy-only bash "$CRED_CLI" list)" || fail "legacy-only credentials list failed"
grep -q 'NOT CONFIGURED' <<<"$output" ||
  fail "credentials list must mark an unconfigured default"
grep -q 'matter thread sync' <<<"$output" ||
  fail "credentials list must point at the sync command when the default is unconfigured"
rc=0
bash "$CRED_CLI" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "credentials without 'list' must exit 2, got $rc"

# --- remove: explicit id and confirmation --------------------------------------------
rc=0
bash "$THREAD_CLI" remove >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "remove without --id must exit 2, got $rc"
rc=0
output="$(printf 'no\n' | bash "$THREAD_CLI" remove --id lisa-home-01 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "refused removal must exit 1, got $rc"
grep -q 'Aborted' <<<"$output" || fail "refused removal must report Aborted"
grep -q 'legacy' <<<"$output" || fail "named removal must mention the legacy cleanup context"

# remove --id default is normalized to the reserved-default operation (no id
# on the wire).
: > "$WS_MSG_LOG"
rc=0
output="$(printf 'REMOVE\n' | MOCK_SCENARIO=legacy-only bash "$THREAD_CLI" remove --id default 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "confirmed default removal must succeed, got $rc: $output"
grep -q 'RESERVED DEFAULT' <<<"$output" || fail "default removal must warn about the default slot"
remove_frame="$(grep '"command":"remove_thread_dataset"' "$WS_MSG_LOG")" ||
  fail "default removal must send remove_thread_dataset"
if grep -q '"id"' <<<"$remove_frame"; then
  fail "remove --id default must omit the id field on the wire, sent: $remove_frame"
fi

# --- matter reset: argument validation and confirmation refusal ---------------
RESET_CLI="$TREE/services/matter-server/data/reset.sh"
rc=0
bash "$RESET_CLI" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "reset must reject unknown options, got $rc"
rc=0
bash "$RESET_CLI" extra >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "reset must reject positional arguments, got $rc"
rc=0
output="$(printf 'no\n' | bash "$RESET_CLI" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "refused reset must exit 1, got $rc"
grep -q 'Aborted' <<<"$output" || fail "refused reset must report Aborted"
grep -q 're-commissioned' <<<"$output" || fail "reset must warn about re-commissioning"

# --- matter reset: full flow in an isolated data tree --------------------------
# The persistent-path validator intentionally rejects temporary directories,
# so the isolated COPY of the tree gets a test-only override that admits the
# work directory; the real validator has its own security tests.
cat >> "$TREE/lib/paths.sh" <<EOF

# TEST OVERRIDE (isolated copy only): admit the test work directory.
lisa_validate_persistent_path() {
  case "\$2" in
    "$WORK_DIR"*) return 0 ;;
    *) return 1 ;;
  esac
}
EOF
DATA_TREE="$WORK_DIR/data"
STORE="$DATA_TREE/docker/volumes/matter-server"
BACKUPS="$DATA_TREE/backups/matter"
mkdir -p "$STORE" "$BACKUPS"
echo '{"fabric":"old"}' > "$STORE/config.json"
mkdir -p "$STORE/nodes"
echo '{}' > "$STORE/nodes/17.json"
ln -sfn nothing "$BACKUPS/latest.matter-data.tar.gz"

cat >> "$TREE/.env" <<EOF
DATA_ROOT=$DATA_TREE
MATTER_DATA_BACKUP_DIR=$BACKUPS
EOF

output="$(printf 'RESET\n' | bash "$RESET_CLI" 2>&1)" || fail "confirmed reset failed: $output"
[ -z "$(find "$STORE" -mindepth 1 -print -quit)" ] || fail "reset must wipe the store"
pre_reset_archive="$(find "$BACKUPS" -name 'matter-data-*-pre-reset.tar.gz' -print -quit)"
[ -n "$pre_reset_archive" ] || fail "reset must create a pre-reset backup first"
[ -f "$pre_reset_archive.sha256" ] || fail "pre-reset backup must have a checksum sidecar"
[ -f "$pre_reset_archive.meta" ] || fail "pre-reset backup must have a metadata sidecar"
tar -tzf "$pre_reset_archive" | grep -q 'config.json' || fail "pre-reset archive must contain the old store"
[ ! -e "$BACKUPS/latest.matter-data.tar.gz" ] ||
  fail "reset must drop the latest symlink so auto-restore cannot resurrect the fabric"

echo "Matter CLI tests passed."
