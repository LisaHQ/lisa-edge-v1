#!/usr/bin/env bash

# Shared shell wrapper around the Matter Server WebSocket client
# (services/matter-server/lib/ws-client.js). Sourced by the Matter CLI
# scripts, status, health checks and diagnostics; keep this file free of
# side effects.
#
# The client runs inside the lisa-matter container (which ships Node.js and
# the ws module). Secrets are never passed through process arguments: an
# optional dataset is prepended to the script on stdin, which only travels
# through a pipe.

MATTER_WS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATTER_WS_CLIENT_JS="$MATTER_WS_LIB_DIR/ws-client.js"

# The WebSocket schema generation required for get_all_credentials and
# fabric-label reads (matterjs-server >= 1.2.0).
MATTER_WS_MIN_SCHEMA=12

# The Matter server's reserved default Thread credential slot: LISA Edge's
# single managed commissioning credential. The ws-client normalizes this ID
# to the upstream default semantics (API calls without an `id` field), which
# is the entry Home Assistant and other default-API clients use.
# shellcheck disable=SC2034
MATTER_WS_DEFAULT_ID="default"

# Stable ws-client.js exit codes (keep in sync with the JS client).
# shellcheck disable=SC2034
MATTER_WS_EXIT_OK=0
# shellcheck disable=SC2034
MATTER_WS_EXIT_USAGE=2
# shellcheck disable=SC2034
MATTER_WS_EXIT_CONNECT=3
# shellcheck disable=SC2034
MATTER_WS_EXIT_REJECTED=4
# shellcheck disable=SC2034
MATTER_WS_EXIT_TIMEOUT=5
# shellcheck disable=SC2034
MATTER_WS_EXIT_SCHEMA=6
# shellcheck disable=SC2034
MATTER_WS_EXIT_VERIFY=7

# Print the address the WebSocket client should connect to. With host
# networking, 127.0.0.1 inside the container is the host loopback, so it
# works for the default and for 0.0.0.0 binds; only a specific non-loopback
# IPv4 bind must be dialed directly.
matter_ws_host() {
  local listen="${MATTER_LISTEN_ADDRESS:-127.0.0.1}"
  case "$listen" in
    ""|0.0.0.0) printf '127.0.0.1\n' ;;
    *)
      if [[ "$listen" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s\n' "$listen"
      else
        # Interface-name binds expand to that interface's addresses, which
        # include nothing we can guess portably; loopback is not among them,
        # but the dashboard/WebSocket is still reachable via the interface
        # IP. Default to loopback and let the caller report the failure.
        printf '127.0.0.1\n'
      fi
      ;;
  esac
}

# Run the WebSocket client inside the lisa-matter container.
#   matter_ws_run <mws-command> [credential-id] [dataset-hex]
# Prints key=value lines on stdout; returns the client's exit code.
# The dataset (if any) must already be validated as pure hex by the caller;
# it is injected through stdin, never through argv or docker -e.
matter_ws_run() {
  local command="$1"
  local credential_id="${2:-}"
  local dataset_hex="${3:-}"

  if [ -n "$dataset_hex" ] && ! [[ "$dataset_hex" =~ ^[0-9A-Fa-f]+$ ]]; then
    echo "matter_ws_run: dataset must be validated hex before the call" >&2
    return 2
  fi

  {
    if [ -n "$dataset_hex" ]; then
      printf 'process.env.MWS_DATASET = "%s";\n' "$dataset_hex"
    fi
    cat "$MATTER_WS_CLIENT_JS"
  } | docker exec -i \
    -e MWS_COMMAND="$command" \
    -e MWS_HOST="$(matter_ws_host)" \
    -e MWS_PORT="${MATTER_SERVER_PORT:-5580}" \
    -e MWS_CREDENTIAL_ID="$credential_id" \
    -e MWS_MIN_SCHEMA="$MATTER_WS_MIN_SCHEMA" \
    -e MWS_CONNECT_TIMEOUT_MS="${MATTER_WS_CONNECT_TIMEOUT_MS:-10000}" \
    -e MWS_RESPONSE_TIMEOUT_MS="${MATTER_WS_RESPONSE_TIMEOUT_MS:-15000}" \
    lisa-matter node -
}

# Extract one key=value field from matter_ws_run output.
#   matter_ws_field "$output" server.schema_version
matter_ws_field() {
  printf '%s\n' "$1" |
    awk -v key="$2" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }'
}

# Print the stored thread credential summary (id, network name, ext PAN ID,
# one tab-separated entry per line) from matter_ws_run output.
matter_ws_thread_entries() {
  local output="$1"
  local count index id name xpan
  count="$(matter_ws_field "$output" thread_credential_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || return 0
  for ((index = 0; index < count; index++)); do
    id="$(matter_ws_field "$output" "thread_credential.$index.id")"
    name="$(matter_ws_field "$output" "thread_credential.$index.network_name")"
    xpan="$(matter_ws_field "$output" "thread_credential.$index.ext_pan_id")"
    printf '%s\t%s\t%s\n' "$id" "$name" "$xpan"
  done
}

# Reserved-default credential summary helpers, reading the default.* fields
# printed by the ws-client for the `credentials` and `status` commands.
# "Configured" requires a non-empty identity summary AND the server
# reporting thread_credentials_set=true; the always-present empty default
# summary alone never counts.
matter_ws_default_configured() {
  [ "$(matter_ws_field "$1" default.configured)" = "true" ]
}

matter_ws_default_present() {
  [ "$(matter_ws_field "$1" default.present)" = "true" ]
}

# True when the lisa-matter container is running.
matter_ws_container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  grep -qx lisa-matter <<<"$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
}
