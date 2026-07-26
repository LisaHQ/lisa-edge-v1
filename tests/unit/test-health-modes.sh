#!/usr/bin/env bash
set -euo pipefail

# Health outcome model: HEALTHY, DEGRADED (BLE off, default-credential
# drift/missing/unconfigured — including a matching named credential that
# must never count — timer gaps), FAILED (Matter WebSocket down),
# strict-mode exit codes, and the guarantee that a degraded run never prints
# a generic success message. Docker, systemd, and the Matter server are
# mocked; a local TCP listener stands in for the Matter port.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "HEALTH MODES TEST ERROR: $*" >&2
  exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required for the health-mode tests"

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
LISTENER_PID=""
cleanup() {
  [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" "$TREE/"

MATTER_PORT=$((45000 + RANDOM % 10000))
node -e "require('net').createServer(function(s){s.end();}).listen($MATTER_PORT,'127.0.0.1')" &
LISTENER_PID=$!

cat > "$TREE/.env" <<EOF
LISA_COMPOSE_SERVICES="matter otbr"
MATTER_SERVER_PORT=$MATTER_PORT
MATTER_LISTEN_ADDRESS=127.0.0.1
MATTER_THREAD_CREDENTIAL_ID=legacy-ignored-value
THREAD_NETWORK_NAME=LISA-HOME-01
LISA_HEALTH_WAIT_ATTEMPTS=2
LISA_HEALTH_WAIT_DELAY_SECONDS=0
LISA_HEALTH_ASSUME_SYSTEMD=1
EOF

# Matching OTBR dataset / stored credential: LISA-HOME-01 / 1122334455667788.
OTBR_DATASET="0e080000000000010000000300000f02081122334455667788030c4c4953412d484f4d452d30310510000102030405060708090a0b0c0d0e0f0102abcd"
export MOCK_OTBR_DATASET="$OTBR_DATASET"

mkdir -p "$WORK_DIR/node_modules/ws"
cat > "$WORK_DIR/node_modules/ws/index.js" <<'EOF'
const { EventEmitter } = require("events");
class WebSocket extends EventEmitter {
  constructor() {
    super();
    const scenario = process.env.MOCK_SCENARIO || "ok";
    setImmediate(() => {
      if (scenario === "connect-fail") { this.emit("error", new Error("ECONNREFUSED")); return; }
      this.emit("open");
      this.emit("message", JSON.stringify({
        schema_version: 12, min_supported_schema_version: 11,
        sdk_version: "0.17.5", wifi_credentials_set: false,
        thread_credentials_set: !["missing-credential", "named-only", "creds-unset"].includes(scenario),
        bluetooth_enabled: scenario !== "ble-off",
      }));
    });
  }
  send(raw) {
    const msg = JSON.parse(raw);
    const scenario = process.env.MOCK_SCENARIO || "ok";
    setImmediate(() => {
      if (msg.command === "get_all_credentials") {
        // The reserved default entry is reported with a null id (upstream
        // default semantics); a legacy named entry rides along in most
        // scenarios and must never influence readiness.
        const entries = scenario === "drift"
          ? [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" },
             { id: null, networkName: "OLD-NET", extPanId: "9999999999999999" }]
          : scenario === "missing-credential" ? []
          : scenario === "named-only"
            ? [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" }]
          : scenario === "empty-default"
            ? [{ id: null, networkName: "", extPanId: "" }]
          : [{ id: "lisa-home-01", networkName: "LISA-HOME-01", extPanId: "1122334455667788" },
             { id: null, networkName: "LISA-HOME-01", extPanId: "1122334455667788" }];
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: { wifi: [], thread: entries } }));
      } else {
        this.emit("message", JSON.stringify({ message_id: msg.message_id, result: null }));
      }
    });
  }
  close() {}
}
module.exports = WebSocket;
module.exports.WebSocket = WebSocket;
EOF

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$1" in
  compose) echo "NAME  STATUS"; exit 0 ;;
  ps) printf 'lisa-otbr\nlisa-matter\nlisa-mqtt\nlisa-uptime\n'; exit 0 ;;
  inspect)
    case "\$*" in
      *".State.Status"*) echo running ;;
      *".State.Health"*) echo healthy ;;
    esac
    exit 0 ;;
  exec) ;;
  *) exit 0 ;;
esac
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
      exit 0 ;;
    lisa-otbr)
      shift
      case "\$*" in
        *"dataset active -x"*) printf '%s\r\nDone\r\n' "\$MOCK_OTBR_DATASET" ;;
        *"rcp version"*) printf 'OPENTHREAD/thread-reference-20230119\r\nDone\r\n' ;;
        *"state"*) printf 'leader\r\nDone\r\n' ;;
      esac
      exit 0 ;;
    *) shift ;;
  esac
done
exit 0
EOF
cat > "$WORK_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "is-active" ]; then
  echo "${MOCK_TIMER_STATE:-active}"
  [ "${MOCK_TIMER_STATE:-active}" = "active" ] && exit 0 || exit 3
fi
exit 0
EOF
chmod +x "$WORK_DIR/bin/docker" "$WORK_DIR/bin/systemctl"
export PATH="$WORK_DIR/bin:$PATH"

HEALTH="$TREE/ops/deploy/healthcheck.sh"

# --- usage ---------------------------------------------------------------
rc=0
bash "$HEALTH" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown health option must exit 2, got $rc"
bash "$HEALTH" --help | grep -q 'DEGRADED' || fail "health help must document the outcome model"

# --- HEALTHY -----------------------------------------------------------------
rc=0
output="$(bash "$HEALTH" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "healthy stack must exit 0, got $rc: $output"
grep -q 'Overall status: HEALTHY' <<<"$output" || fail "healthy stack must report HEALTHY"
grep -q 'identity fields match' <<<"$output" || fail "healthy output must confirm identity-field match"

# --- DEGRADED: BLE unavailable --------------------------------------------------
rc=0
output="$(MOCK_SCENARIO=ble-off bash "$HEALTH" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "degraded (BLE) without --strict must exit 0, got $rc"
grep -q 'Overall status: DEGRADED' <<<"$output" || fail "BLE-off must report DEGRADED"
grep -q 'Bluetooth commissioning is unavailable' <<<"$output" || fail "BLE degradation must be named"
if grep -q 'Overall status: HEALTHY' <<<"$output"; then
  fail "a degraded run must never print the healthy summary"
fi
if grep -q 'passed readiness checks' <<<"$output"; then
  fail "a degraded run must never print a generic success message"
fi
rc=0
MOCK_SCENARIO=ble-off bash "$HEALTH" --strict >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "degraded with --strict must exit 3, got $rc"

# --- DEGRADED: credential drift ---------------------------------------------------
rc=0
output="$(MOCK_SCENARIO=drift bash "$HEALTH" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "drift without --strict must exit 0, got $rc"
grep -q 'Overall status: DEGRADED' <<<"$output" || fail "drift must report DEGRADED"
grep -q 'identity fields differ' <<<"$output" || fail "drift must be described"
grep -q 'matter thread sync' <<<"$output" || fail "drift must point at the sync command"

# --- DEGRADED: missing default credential --------------------------------------------
output="$(MOCK_SCENARIO=missing-credential bash "$HEALTH" 2>&1)" ||
  fail "missing default credential must not fail outright"
grep -q 'default Thread credential is not configured' <<<"$output" ||
  fail "the unconfigured default credential must be named"
grep -q 'Overall status: DEGRADED' <<<"$output" || fail "missing default must degrade"

# --- DEGRADED: a matching NAMED credential must never count as ready -----------------
output="$(MOCK_SCENARIO=named-only bash "$HEALTH" 2>&1)" ||
  fail "named-only must not fail outright"
grep -q 'default Thread credential is not configured' <<<"$output" ||
  fail "a matching named credential must not mask the unconfigured default"
grep -q 'Overall status: DEGRADED' <<<"$output" || fail "named-only must degrade"

# --- DEGRADED: empty always-present default summary with creds-set flag --------------
# thread_credentials_set=true but an empty default summary is still unconfigured.
output="$(MOCK_SCENARIO=empty-default bash "$HEALTH" 2>&1)" ||
  fail "empty-default must not fail outright"
grep -q 'default Thread credential is not configured' <<<"$output" ||
  fail "an empty default summary must be treated as unconfigured"
grep -q 'Overall status: DEGRADED' <<<"$output" || fail "empty-default must degrade"

# --- DEGRADED: inactive backup timer --------------------------------------------------
output="$(MOCK_TIMER_STATE=inactive bash "$HEALTH" 2>&1)" || fail "inactive timer must not fail outright"
grep -q 'Overall status: DEGRADED' <<<"$output" || fail "inactive timers must degrade"
grep -q 'backup timer' <<<"$output" || fail "inactive timers must be named"

# --- FAILED: Matter WebSocket down ------------------------------------------------------
rc=0
output="$(MOCK_SCENARIO=connect-fail bash "$HEALTH" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "unreachable Matter WebSocket must exit 1, got $rc"
grep -q 'Overall status: FAILED' <<<"$output" || fail "WebSocket failure must report FAILED"

# --- FAILED beats DEGRADED in strict exit codes too ---------------------------------------
rc=0
MOCK_SCENARIO=connect-fail bash "$HEALTH" --strict >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "FAILED must exit 1 even with --strict, got $rc"

# --- zero selected services: intentionally empty deployments are HEALTHY ------------------
cat > "$TREE/.env" <<'EOF'
LISA_COMPOSE_SERVICES=""
EOF
rc=0
output="$(bash "$HEALTH" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "an empty selection must be HEALTHY (exit 0), got $rc: $output"
grep -q 'No services selected' <<<"$output" || fail "the empty selection must be announced"
grep -q 'Overall status: HEALTHY' <<<"$output" || fail "the empty deployment must report HEALTHY"
rc=0
bash "$HEALTH" --strict >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "an empty selection must stay HEALTHY under --strict, got $rc"

echo "Health mode tests passed."
