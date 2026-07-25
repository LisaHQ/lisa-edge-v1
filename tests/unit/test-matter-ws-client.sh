#!/usr/bin/env bash
set -euo pipefail

# Matter WebSocket client behavior against a scripted mock of the `ws`
# module: server_info handling, schema validation, reserved-default
# set_thread_dataset (id omitted), thread_credentials_set verification,
# get_all_credentials verification, empty-default semantics, named-entry
# support, API rejection, timeout, disconnect, unrelated events, credential
# mismatch, and secret redaction. Runs the real ws-client.js under node; no
# network and no docker are involved.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLIENT="$REPO_ROOT/services/matter-server/lib/ws-client.js"

fail() {
  echo "MATTER WS CLIENT TEST ERROR: $*" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required for the Matter WebSocket client tests"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/matter-ws-test.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$WORK_DIR/node_modules/ws"
cat > "$WORK_DIR/node_modules/ws/index.js" <<'EOF'
// Scripted mock of the `ws` module for ws-client.js tests. The scenario is
// selected via MOCK_SCENARIO. Every command frame the client sends is
// appended to WS_MSG_LOG so the tests can assert the exact wire arguments
// (most importantly: no `id` field for reserved-default operations).
const { EventEmitter } = require("events");
const fs = require("fs");
let defaultConfigured = false; // flips after set_thread_dataset without id
let defaultRemoved = false;    // flips after remove_thread_dataset without id
class WebSocket extends EventEmitter {
  constructor(url) {
    super();
    this.url = url;
    const scenario = process.env.MOCK_SCENARIO || "ok";
    setImmediate(() => {
      if (scenario === "connect-fail") { this.emit("error", new Error("ECONNREFUSED")); return; }
      this.emit("open");
      if (scenario === "no-server-info") return;
      // An unrelated event BEFORE server info must be ignored.
      this.emit("message", JSON.stringify({ event: "node_updated", data: {} }));
      this.emit("message", "this is not json");
      const schema = scenario === "old-schema" ? 11 : 12;
      this.emit("message", JSON.stringify({
        schema_version: schema, min_supported_schema_version: 11,
        sdk_version: "0.17.5", wifi_credentials_set: false,
        // The handshake value predates any sync in this process.
        thread_credentials_set: scenario === "pre-set",
        bluetooth_enabled: true,
      }));
    });
  }
  threadEntries() {
    const scenario = process.env.MOCK_SCENARIO || "ok";
    if (scenario === "missing-entry") return [];
    if (scenario === "empty-default") {
      // The always-present empty default summary (id omitted upstream).
      return [{ networkName: "", extPanId: "" }];
    }
    if (scenario === "named-only") {
      return [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" }];
    }
    if (scenario === "mismatch") {
      return [{ id: null, networkName: "OTHER-NET", extPanId: "9999999999999999" }];
    }
    // Default entry reported with a null id (upstream default semantics)
    // plus a legacy named entry. After a reserved-default removal the
    // server keeps an always-present EMPTY default summary.
    const entries = [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" }];
    if (defaultRemoved) {
      entries.push({ id: null, networkName: "", extPanId: "" });
    } else if (defaultConfigured || scenario === "pre-set" || scenario === "creds-not-set") {
      entries.push({ id: null, networkName: "LISA-HOME-01", extPanId: "1122334455667788" });
    }
    return entries;
  }
  send(raw) {
    if (process.env.WS_MSG_LOG) fs.appendFileSync(process.env.WS_MSG_LOG, raw + "\n");
    const msg = JSON.parse(raw);
    const scenario = process.env.MOCK_SCENARIO || "ok";
    setImmediate(() => {
      // Unrelated event and a foreign response interleaved with every call.
      this.emit("message", JSON.stringify({ event: "attribute_updated", data: {} }));
      this.emit("message", JSON.stringify({ message_id: "someone-else", result: null }));
      if (msg.command === "set_thread_dataset") {
        if (typeof msg.args.dataset !== "string") {
          this.emit("message", JSON.stringify({ message_id: msg.message_id, error_code: 1, details: "missing args" }));
          return;
        }
        if (scenario === "reject") {
          this.emit("message", JSON.stringify({
            message_id: msg.message_id, error_code: 9,
            details: "invalid dataset 0e080000000000010000000300000f0208112233445566778835060004001fffe0",
          }));
          return;
        }
        if (scenario === "disconnect") { this.emit("close"); return; }
        if (scenario === "timeout") return;
        if (msg.args.id === undefined) defaultConfigured = true;
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: null }));
      } else if (msg.command === "server_info") {
        if (scenario === "no-server-info-cmd") {
          this.emit("message", JSON.stringify({ message_id: msg.message_id, error_code: 2, details: "unknown command" }));
          return;
        }
        this.emit("message", JSON.stringify({
          message_id: msg.message_id,
          result: {
            schema_version: 12, min_supported_schema_version: 11,
            sdk_version: "0.17.5", wifi_credentials_set: false,
            thread_credentials_set: scenario === "creds-not-set"
              ? false : (defaultConfigured || scenario === "pre-set"),
            bluetooth_enabled: true,
          },
        }));
      } else if (msg.command === "get_all_credentials") {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: { wifi: [], thread: this.threadEntries() } }));
      } else if (msg.command === "get_fabric_label") {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: { fabric_label: "LISA Home" } }));
      } else if (msg.command === "get_nodes") {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: [{}, {}] }));
      } else if (msg.command === "remove_thread_dataset") {
        if (msg.args.id === undefined) { defaultConfigured = false; defaultRemoved = true; }
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: null }));
      }
    });
  }
  close() {}
}
module.exports = WebSocket;
module.exports.WebSocket = WebSocket;
EOF

DATASET="0e080000000000010000000300000f0208112233445566778835060004001fffe00510000102030405060708090a0b0c0d0e0f03084c4953412d545354"
MSG_LOG="$WORK_DIR/messages.log"

run_client() {
  local scenario="$1" command="$2" credential="${3:-}" dataset="${4:-}"
  : > "$MSG_LOG"
  NODE_PATH="$WORK_DIR/node_modules" MOCK_SCENARIO="$scenario" WS_MSG_LOG="$MSG_LOG" \
    MWS_COMMAND="$command" MWS_CREDENTIAL_ID="$credential" MWS_DATASET="$dataset" \
    MWS_CONNECT_TIMEOUT_MS=400 MWS_RESPONSE_TIMEOUT_MS=400 \
    node "$CLIENT" 2>&1
}

# --- successful default sync: no id on the wire ------------------------------
output="$(run_client ok sync default "$DATASET")" || fail "default sync must succeed: $output"
grep -q '^server.schema_version=12$' <<<"$output" || fail "server info must be printed"
grep -q '^sync.thread_credentials_set=true$' <<<"$output" ||
  fail "default sync must report the re-read thread_credentials_set"
grep -q '^stored.id=default$' <<<"$output" || fail "stored default credential must be verified"
grep -q '^stored.network_name=LISA-HOME-01$' <<<"$output" || fail "stored network name must be printed"
grep -q '^sync.result=ok$' <<<"$output" || fail "sync must report ok"
if grep -qi "$DATASET" <<<"$output"; then
  fail "the dataset must never appear in client output"
fi
set_frame="$(grep '"command":"set_thread_dataset"' "$MSG_LOG")" ||
  fail "set_thread_dataset must be sent"
if grep -q '"id"' <<<"$set_frame"; then
  fail "reserved-default sync must OMIT the id field, sent: $set_frame"
fi

# --- default sync fails verification when the server keeps creds unset -------
rc=0
output="$(run_client creds-not-set sync default "$DATASET")" || rc=$?
[ "$rc" -eq 7 ] || fail "thread_credentials_set=false after default sync must exit 7, got $rc"
grep -q 'thread_credentials_set' <<<"$output" || fail "the verification failure must name the flag"

# --- default sync fails verification when the default entry stays empty ------
rc=0
run_client empty-default sync default "$DATASET" >/dev/null || rc=$?
[ "$rc" -eq 7 ] || fail "empty default summary after sync must exit 7, got $rc"

# --- server_info command unavailable: falls back to the handshake value ------
rc=0
run_client no-server-info-cmd sync default "$DATASET" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 7 ] || fail "no server_info + handshake creds unset must fail verification, got $rc"

# --- named sync still works internally (id on the wire) ----------------------
output="$(run_client ok sync lisa-home-01 "$DATASET")" || fail "named sync must succeed: $output"
grep -q '^stored.id=lisa-home-01$' <<<"$output" || fail "named credential id must be verified"
grep '"command":"set_thread_dataset"' "$MSG_LOG" | grep -q '"id":"lisa-home-01"' ||
  fail "named sync must send the id field"

# --- API rejection: exit 4, details redacted ---------------------------------
rc=0
output="$(run_client reject sync default "$DATASET")" || rc=$?
[ "$rc" -eq 4 ] || fail "server rejection must exit 4, got $rc"
grep -q 'REDACTED' <<<"$output" || fail "long hex in server details must be redacted"
if grep -qi '112233445566778835060004' <<<"$output"; then
  fail "server-provided dataset material must be redacted"
fi

# --- unsupported schema: exit 6 ----------------------------------------------
rc=0
output="$(run_client old-schema server-info)" || rc=$?
[ "$rc" -eq 6 ] || fail "old schema must exit 6, got $rc"
grep -q 'schema_version 11' <<<"$output" || fail "schema failure must name the version"

# --- verification failure: exit 7 --------------------------------------------
rc=0
run_client missing-entry sync default "$DATASET" >/dev/null || rc=$?
[ "$rc" -eq 7 ] || fail "missing stored entry must exit 7, got $rc"

# --- mismatched summary is still reported (bash layer decides) ----------------
output="$(run_client mismatch sync default "$DATASET")" || fail "mismatch scenario should exit 0 at client level"
grep -q '^stored.network_name=OTHER-NET$' <<<"$output" || fail "client must report the stored summary verbatim"

# --- timeout: exit 5 -----------------------------------------------------------
rc=0
run_client timeout sync default "$DATASET" >/dev/null || rc=$?
[ "$rc" -eq 5 ] || fail "response timeout must exit 5, got $rc"
rc=0
run_client no-server-info credentials >/dev/null || rc=$?
[ "$rc" -eq 5 ] || fail "server-info timeout must exit 5, got $rc"

# --- socket problems: exit 3 ----------------------------------------------------
rc=0
run_client disconnect sync default "$DATASET" >/dev/null || rc=$?
[ "$rc" -eq 3 ] || fail "disconnect must exit 3, got $rc"
rc=0
run_client connect-fail credentials >/dev/null || rc=$?
[ "$rc" -eq 3 ] || fail "connect failure must exit 3, got $rc"

# --- usage validation: exit 2, no secrets --------------------------------------
rc=0
output="$(run_client ok sync default "not-hex")" || rc=$?
[ "$rc" -eq 2 ] || fail "invalid dataset must exit 2, got $rc"
rc=0
run_client ok sync "" "$DATASET" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "sync without credential id must exit 2, got $rc"
rc=0
run_client ok remove "" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "remove without credential id must exit 2, got $rc"
rc=0
run_client ok bogus-command >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "unknown command must exit 2, got $rc"

# --- credential listing: normalization + default summary -----------------------
output="$(run_client pre-set credentials)" || fail "credentials listing failed"
grep -q '^thread_credential_count=2$' <<<"$output" || fail "credential count must be printed"
grep -q '^thread_credential.1.id=default$' <<<"$output" ||
  fail "a null-id entry must be normalized to the reserved default"
grep -q '^default.present=true$' <<<"$output" || fail "default presence must be reported"
grep -q '^default.configured=true$' <<<"$output" || fail "configured default must be reported"
grep -q '^default.network_name=LISA-HOME-01$' <<<"$output" || fail "default summary must be printed"

# --- empty always-present default entry is NOT configured -----------------------
output="$(run_client empty-default credentials)" || fail "empty-default listing failed"
grep -q '^default.present=true$' <<<"$output" || fail "empty default must still be present"
grep -q '^default.configured=false$' <<<"$output" ||
  fail "an empty default summary must be reported as unconfigured"

# --- a named entry with an unconfigured default is NOT configured ----------------
output="$(run_client named-only credentials)" || fail "named-only listing failed"
grep -q '^default.present=false$' <<<"$output" || fail "named-only must report default absent"
grep -q '^default.configured=false$' <<<"$output" ||
  fail "a matching named credential must never make the default configured"

# --- default summary requires thread_credentials_set=true ------------------------
output="$(run_client creds-not-set credentials)" || fail "creds-not-set listing failed"
grep -q '^default.configured=false$' <<<"$output" ||
  fail "default.configured must be false while thread_credentials_set=false"

# --- status (fabric label + node count + default summary) ------------------------
output="$(run_client pre-set status)" || fail "status failed"
grep -q '^fabric_label=LISA Home$' <<<"$output" || fail "fabric label must be printed"
grep -q '^node_count=2$' <<<"$output" || fail "node count must be printed"
grep -q '^default.configured=true$' <<<"$output" || fail "status must include the default summary"

# --- remove: default omits id; empty leftover summary passes verification --------
output="$(run_client pre-set remove default)" || fail "default removal must succeed: $output"
grep -q '^remove.result=ok$' <<<"$output" || fail "remove must report ok"
remove_frame="$(grep '"command":"remove_thread_dataset"' "$MSG_LOG")" ||
  fail "remove_thread_dataset must be sent"
if grep -q '"id"' <<<"$remove_frame"; then
  fail "reserved-default removal must OMIT the id field, sent: $remove_frame"
fi

# The mock still returns lisa-home-01 after a named removal, so remove must
# fail verification.
rc=0
run_client pre-set remove lisa-home-01 >/dev/null || rc=$?
[ "$rc" -eq 7 ] || fail "named remove must verify absence via get_all_credentials, got $rc"
grep '"command":"remove_thread_dataset"' "$MSG_LOG" | grep -q '"id":"lisa-home-01"' ||
  fail "named removal must send the id field"
output="$(run_client missing-entry remove lisa-home-01)" || fail "verified removal must succeed"
grep -q '^remove.result=ok$' <<<"$output" || fail "remove must report ok"

echo "Matter WebSocket client tests passed."
