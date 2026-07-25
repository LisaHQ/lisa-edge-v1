#!/usr/bin/env bash
set -euo pipefail

# Negative security tests for Thread credential handling: the dataset (and
# the network key inside it) must never reach stdout/stderr through the
# default show output, argument errors, export messages, or server-provided
# error details. Docker and the Matter server are mocked.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "DATASET SECRET SAFETY TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dataset-secret-test.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# Synthetic dataset with a recognizable fake network key (TLV 0510...).
KEY_MATERIAL="000102030405060708090a0b0c0d0e0f"
MOCK_DATASET="0e080000000000010000000300000f02081122334455667788030c4c4953412d484f4d452d30310510${KEY_MATERIAL}0102abcd"

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "ps --format {{.Names}}") printf 'lisa-otbr\n' ;;
  *"ot-ctl dataset active -x"*) printf '%s\r\nDone\r\n' "$MOCK_DATASET" ;;
  *"ot-ctl state"*) printf 'leader\r\nDone\r\n' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK_DIR/bin/docker"
export PATH="$WORK_DIR/bin:$PATH"

assert_no_secret() {
  local label="$1" text="$2"
  if grep -qi "$KEY_MATERIAL" <<<"$text"; then
    fail "$label leaked network key material"
  fi
  if grep -qi "$MOCK_DATASET" <<<"$text"; then
    fail "$label leaked the raw dataset"
  fi
}

SHOW="$REPO_ROOT/services/otbr/dataset/show.sh"
EXPORT="$REPO_ROOT/services/otbr/dataset/export.sh"

# 1. Default show output is redacted.
output="$(bash "$SHOW" 2>&1)" || fail "show failed"
assert_no_secret "default show output" "$output"
grep -q '\[REDACTED\]' <<<"$output" || fail "default show output must redact secrets"

# 2. Help and argument errors never trigger a dataset read or print.
for args in "--help" "--bogus" "unexpected" "--show-secret --bogus" "--show-secret extra"; do
  # shellcheck disable=SC2086
  output="$(bash "$SHOW" $args 2>&1 || true)"
  assert_no_secret "show $args output" "$output"
done
for args in "--help" "--bogus" "--output" ""; do
  # shellcheck disable=SC2086
  output="$(bash "$EXPORT" $args 2>&1 || true)"
  assert_no_secret "export $args output" "$output"
done

# 3. Export success message names the file but never the content, and the
#    file itself is 0600.
EXPORT_FILE="$WORK_DIR/out.hex"
output="$(bash "$EXPORT" --output "$EXPORT_FILE" 2>&1)" || fail "export failed"
assert_no_secret "export success output" "$output"
[ "$(stat -c %a "$EXPORT_FILE")" = "600" ] || fail "export file must be 0600"

# 4. Traversal, directory, and overwrite targets are refused before any write.
for target in "$WORK_DIR/../up.hex" "$WORK_DIR" "$EXPORT_FILE"; do
  rc=0
  output="$(bash "$EXPORT" --output "$target" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "export must refuse unsafe target: $target"
  assert_no_secret "export refusal output" "$output"
done

# 5. Server-provided error details are redacted by the WebSocket client.
if command -v node >/dev/null 2>&1; then
  mkdir -p "$WORK_DIR/node_modules/ws"
  cat > "$WORK_DIR/node_modules/ws/index.js" <<EOF
const { EventEmitter } = require("events");
class WebSocket extends EventEmitter {
  constructor() {
    super();
    setImmediate(() => {
      this.emit("open");
      this.emit("message", JSON.stringify({ schema_version: 12 }));
    });
  }
  send(raw) {
    const msg = JSON.parse(raw);
    setImmediate(() => this.emit("message", JSON.stringify({
      message_id: msg.message_id, error_code: 9,
      details: "server echoed dataset $MOCK_DATASET back",
    })));
  }
  close() {}
}
module.exports = WebSocket;
module.exports.WebSocket = WebSocket;
EOF
  rc=0
  output="$(NODE_PATH="$WORK_DIR/node_modules" MWS_COMMAND=sync \
    MWS_CREDENTIAL_ID=default MWS_DATASET="$MOCK_DATASET" \
    MWS_CONNECT_TIMEOUT_MS=400 MWS_RESPONSE_TIMEOUT_MS=400 \
    node "$REPO_ROOT/services/matter-server/lib/ws-client.js" 2>&1)" || rc=$?
  [ "$rc" -eq 4 ] || fail "server rejection must exit 4, got $rc"
  assert_no_secret "ws-client rejection output" "$output"
  grep -q 'REDACTED' <<<"$output" || fail "ws-client must redact hex in server details"
else
  echo "SKIP: node unavailable; ws-client redaction covered by unit tests."
fi

echo "Dataset secret-safety tests passed."
