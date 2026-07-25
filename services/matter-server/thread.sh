#!/usr/bin/env bash
set -euo pipefail

# Matter Server Thread credential management (operator entry points:
# lisa-edge matter thread status|sync|remove). Talks to the Matter server
# through the shared WebSocket client; never restarts the server and never
# prints Thread credentials.
#
# LISA Edge's managed commissioning credential is the Matter server's
# RESERVED DEFAULT Thread credential (the entry default-API clients such as
# Home Assistant use). OTBR's active operational dataset stays authoritative;
# sync stores one copy of it in the default slot. Named credentials are an
# upstream advanced capability kept only for inspection and explicit cleanup
# of legacy entries (e.g. the pre-migration 'lisa-home-01').

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

usage() {
  cat <<'EOF'
Usage: lisa-edge matter thread <subcommand> [options]

Subcommands:
  status              Show the reserved default credential's state, the OTBR
                      network summary, any named (legacy) entries, and
                      whether Thread commissioning should work.
  sync [source]       Store a Thread dataset in the Matter server's reserved
                      default credential (the entry used for commissioning)
                      and verify the stored summary.
                      Sources (mutually exclusive):
                        --from-otbr        OTBR's active dataset (default)
                        --file <dataset>   read a dataset file
                        --stdin            read the dataset from stdin
  remove --id <id>    Remove a stored Thread credential entry. Use a named
                      ID to clean up legacy entries, or 'default' to clear
                      the reserved default credential.

Options:
  -h, --help  Show this help.
EOF
}

die_usage() {
  echo "ERROR: $*" >&2
  usage >&2
  exit 2
}

require_env() {
  if [ ! -f .env ]; then
    echo "ERROR: missing .env; run 'sudo ./lisa-edge configure' (or setup) first." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
}

load_libs() {
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/thread-dataset.sh"
  # shellcheck disable=SC1091
  . "$EDGE_REPO/lib/service-config.sh"
  # shellcheck disable=SC1091
  . "$EDGE_REPO/services/matter-server/lib/ws.sh"
  # shellcheck disable=SC1091
  . "$EDGE_REPO/services/otbr/dataset/lib.sh"
}

require_matter_running() {
  if ! matter_ws_container_running; then
    echo "ERROR: lisa-matter container is not running." >&2
    echo "Start it with: sudo ./lisa-edge deploy" >&2
    exit 1
  fi
}

# Map a nonzero matter_ws_run exit code to an actionable error. $1=rc.
report_ws_failure() {
  local rc="$1"
  case "$rc" in
    "$MATTER_WS_EXIT_CONNECT")
      echo "ERROR: could not reach the Matter server WebSocket (connect/disconnect)." >&2
      echo "Inspect next: docker logs --tail 30 lisa-matter; sudo ./lisa-edge matter status" >&2
      ;;
    "$MATTER_WS_EXIT_REJECTED")
      echo "ERROR: the Matter server rejected the command (see details above)." >&2
      ;;
    "$MATTER_WS_EXIT_TIMEOUT")
      echo "ERROR: timed out waiting for the Matter server response." >&2
      ;;
    "$MATTER_WS_EXIT_SCHEMA")
      echo "ERROR: the Matter server WebSocket schema is older than $MATTER_WS_MIN_SCHEMA." >&2
      echo "Thread credential management requires matterjs-server >= 1.2.0; check MATTER_SERVER_IMAGE." >&2
      ;;
    "$MATTER_WS_EXIT_VERIFY")
      echo "ERROR: post-command verification failed on the Matter server." >&2
      ;;
    *)
      echo "ERROR: Matter WebSocket client failed (exit $rc)." >&2
      ;;
  esac
  exit 1
}

read_dataset_from_otbr() {
  if ! otbr_container_is_running; then
    echo "ERROR: lisa-otbr container is not running and no --file/--stdin dataset was given." >&2
    exit 1
  fi
  DATASET_HEX="$(thread_otbr_active_dataset_hex_live)"
  if [ -z "$DATASET_HEX" ]; then
    echo "ERROR: OTBR has no readable active dataset (agent still starting, or no network formed)." >&2
    exit 1
  fi
}

cmd_sync() {
  local source="" dataset_file="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --from-otbr)
        [ -z "$source" ] || die_usage "--from-otbr conflicts with --$source"
        source="from-otbr"
        ;;
      --file)
        [ -z "$source" ] || die_usage "--file conflicts with --$source"
        [ "$#" -ge 2 ] || die_usage "--file requires a dataset file path"
        source="file"
        dataset_file="$2"
        shift
        ;;
      --stdin)
        [ -z "$source" ] || die_usage "--stdin conflicts with --$source"
        source="stdin"
        ;;
      --id)
        die_usage "sync always targets the reserved default credential; --id is not supported"
        ;;
      -h|--help) usage; exit 0 ;;
      -*) die_usage "unknown option: $arg" ;;
      *) die_usage "unexpected argument: $arg (datasets are never accepted as positional arguments)" ;;
    esac
    shift
  done
  [ -n "$source" ] || source="from-otbr"

  require_env
  load_libs

  DATASET_HEX=""
  case "$source" in
    from-otbr) read_dataset_from_otbr ;;
    file)
      if ! otbr_dataset_file_is_valid_hex "$dataset_file"; then
        echo "ERROR: dataset file is missing or not valid hex: $dataset_file" >&2
        exit 1
      fi
      if ! otbr_dataset_file_checksum_ok "$dataset_file"; then
        echo "ERROR: refusing to sync a dataset that fails its checksum." >&2
        exit 1
      fi
      DATASET_HEX="$(tr -d '[:space:]' < "$dataset_file")"
      ;;
    stdin)
      DATASET_HEX="$(tr -d '[:space:]')"
      ;;
  esac
  if ! thread_dataset_is_valid_hex "$DATASET_HEX"; then
    echo "ERROR: dataset is not a valid even-length hex string." >&2
    exit 1
  fi

  local expected_name expected_xpan
  expected_name="$(thread_dataset_network_name "$DATASET_HEX")"
  expected_xpan="$(thread_dataset_ext_pan_id "$DATASET_HEX")"

  require_matter_running

  echo "Storing the Thread dataset in the Matter server's reserved default credential..."
  local output rc=0
  output="$(matter_ws_run sync "$MATTER_WS_DEFAULT_ID" "$DATASET_HEX")" || rc=$?
  # The client never prints the dataset; its key=value output is safe.
  [ "$rc" -eq 0 ] || report_ws_failure "$rc"

  local stored_name stored_xpan creds_set
  stored_name="$(matter_ws_field "$output" stored.network_name)"
  stored_xpan="$(matter_ws_field "$output" stored.ext_pan_id)"
  creds_set="$(matter_ws_field "$output" sync.thread_credentials_set)"

  local drift=0
  if [ -n "$expected_name" ] && [ "$stored_name" != "$expected_name" ]; then
    echo "ERROR: stored network name '$stored_name' does not match the dataset's '$expected_name'." >&2
    drift=1
  fi
  if [ -n "$expected_xpan" ] && [ "${stored_xpan^^}" != "${expected_xpan^^}" ]; then
    echo "ERROR: stored extended PAN ID '$stored_xpan' does not match the dataset's '$expected_xpan'." >&2
    drift=1
  fi
  if [ "$drift" -ne 0 ]; then
    echo "The Matter server accepted the dataset but returned a different summary." >&2
    echo "Inspect next: sudo ./lisa-edge matter credentials list" >&2
    exit 1
  fi

  echo
  echo "Thread credentials stored in the reserved default credential and verified"
  echo "(WebSocket schema $(matter_ws_field "$output" server.schema_version))."
  echo "Verified:"
  echo "- Credential slot: reserved default (used for commissioning)"
  echo "- server.thread_credentials_set: ${creds_set:-true}"
  echo "- Network name: ${stored_name:-'(not reported)'}"
  echo "- Extended PAN ID: ${stored_xpan:-'(not reported)'}"
  echo "Not directly comparable (never returned by the API):"
  echo "- Network Key"
  echo "- PSKc"
  echo
  echo "Thread network identity fields match between the dataset and the Matter server."
  echo "The Matter server was NOT restarted; the stored credential takes effect for"
  echo "the next Thread commissioning immediately (already commissioned devices are"
  echo "not modified)."
}

cmd_remove() {
  local credential_id="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --id)
        [ "$#" -ge 2 ] || die_usage "--id requires a credential ID"
        credential_id="$2"
        shift
        ;;
      -h|--help) usage; exit 0 ;;
      -*) die_usage "unknown option: $arg" ;;
      *) die_usage "unexpected argument: $arg" ;;
    esac
    shift
  done
  [ -n "$credential_id" ] || die_usage "remove requires an explicit --id <credential-id>"

  require_env
  load_libs
  lisa_validate_matter_thread_credential_id "$credential_id" || exit 2
  require_matter_running

  if [ "$credential_id" = "$MATTER_WS_DEFAULT_ID" ]; then
    echo "WARNING: clearing the Matter server's RESERVED DEFAULT Thread credential."
    echo "This is the credential used for Thread commissioning: new commissioning"
    echo "will fail until you run 'sudo ./lisa-edge matter thread sync' again."
    echo "Existing devices keep working."
  else
    echo "WARNING: removing the named Thread credential '$credential_id' from the"
    echo "Matter server. Named entries are not used for commissioning; remove legacy"
    echo "entries only after 'matter thread status' verifies the default credential."
    echo "Existing devices keep working."
  fi
  read -r -p "Type REMOVE to continue: " answer
  if [ "$answer" != "REMOVE" ]; then
    echo "Aborted. No changes were made."
    exit 1
  fi

  local output rc=0
  output="$(matter_ws_run remove "$credential_id")" || rc=$?
  [ "$rc" -eq 0 ] || report_ws_failure "$rc"
  if [ "$credential_id" = "$MATTER_WS_DEFAULT_ID" ]; then
    echo "Reserved default Thread credential cleared and verified via get_all_credentials."
  else
    echo "Thread credential '$credential_id' removed and verified absent via get_all_credentials."
  fi
}

cmd_status() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) die_usage "unexpected argument: $1" ;;
    esac
  done

  require_env
  load_libs

  local otbr_name="" otbr_xpan="" otbr_readable=0
  if otbr_container_is_running; then
    local otbr_hex
    otbr_hex="$(thread_otbr_active_dataset_hex_live)"
    if [ -n "$otbr_hex" ]; then
      otbr_readable=1
      otbr_name="$(thread_dataset_network_name "$otbr_hex")"
      otbr_xpan="$(thread_dataset_ext_pan_id "$otbr_hex")"
      printf '%-28s%s\n' "OTBR network:" "${otbr_name:-?} (extended PAN ID ${otbr_xpan:-?})"
    else
      printf '%-28s%s\n' "OTBR network:" "no readable active dataset"
    fi
  else
    printf '%-28s%s\n' "OTBR network:" "lisa-otbr not running"
  fi

  if ! matter_ws_container_running; then
    printf '%-28s%s\n' "Matter server:" "lisa-matter not running"
    echo "Thread commissioning readiness: UNKNOWN (Matter server unavailable)."
    exit 1
  fi

  local output rc=0
  output="$(matter_ws_run credentials)" || rc=$?
  [ "$rc" -eq 0 ] || report_ws_failure "$rc"

  # The commissioning credential is the reserved default entry; named
  # entries are listed for awareness but never decide readiness.
  local default_name default_xpan default_configured=0
  default_name="$(matter_ws_field "$output" default.network_name)"
  default_xpan="$(matter_ws_field "$output" default.ext_pan_id)"
  matter_ws_default_configured "$output" && default_configured=1

  if [ "$default_configured" -eq 1 ]; then
    printf '%-28s%s\n' "Default credential:" "configured -> ${default_name:-?} (extended PAN ID ${default_xpan:-?})"
  elif matter_ws_default_present "$output"; then
    printf '%-28s%s\n' "Default credential:" "NOT CONFIGURED (empty summary or thread_credentials_set=false)"
  else
    printf '%-28s%s\n' "Default credential:" "NOT CONFIGURED (no reserved default entry)"
  fi

  # Named entries (upstream advanced capability / legacy duplicates).
  local id name xpan
  while IFS=$'\t' read -r id name xpan; do
    [ "$id" = "$MATTER_WS_DEFAULT_ID" ] && continue
    if [ "$default_configured" -eq 1 ] &&
       [ "$name" = "$default_name" ] && [ "${xpan^^}" = "${default_xpan^^}" ]; then
      printf '%-28s%s\n' "Named credential:" "'$id' -> ${name:-?} (legacy duplicate of the default; not used for commissioning)"
    else
      printf '%-28s%s\n' "Named credential:" "'$id' -> ${name:-?} (not used for commissioning)"
    fi
  done < <(matter_ws_thread_entries "$output")

  if [ "$default_configured" -ne 1 ]; then
    echo
    echo "The reserved default credential is what commissioning uses; named entries"
    echo "do not make commissioning ready."
    echo "New Thread commissioning is expected to FAIL until you run:"
    echo "  sudo ./lisa-edge matter thread sync"
    exit 1
  fi

  if [ "$otbr_readable" -eq 1 ]; then
    if [ "${default_name}" = "${otbr_name}" ] && [ "${default_xpan^^}" = "${otbr_xpan^^}" ]; then
      echo
      echo "Thread network identity fields match between OTBR and the Matter server's"
      echo "default credential (network name, extended PAN ID). No detectable Thread"
      echo "credential drift. New Thread commissioning is expected to WORK."
    else
      echo
      echo "DRIFT: the default credential does not match OTBR's active network:"
      [ "${default_name}" != "${otbr_name}" ] &&
        echo "- network name: OTBR='$otbr_name' matter='$default_name'"
      [ "${default_xpan^^}" != "${otbr_xpan^^}" ] &&
        echo "- extended PAN ID: OTBR='$otbr_xpan' matter='$default_xpan'"
      echo "New Thread commissioning is expected to FAIL; re-sync with:"
      echo "  sudo ./lisa-edge matter thread sync"
      exit 1
    fi
  else
    echo
    echo "OTBR's dataset is not readable, so the relationship cannot be verified."
    echo "Commissioning readiness: UNKNOWN."
  fi
}

[ "$#" -ge 1 ] || die_usage "matter thread requires a subcommand (status, sync, remove)"
SUBCOMMAND="$1"
shift
case "$SUBCOMMAND" in
  status) cmd_status "$@" ;;
  sync) cmd_sync "$@" ;;
  remove) cmd_remove "$@" ;;
  -h|--help) usage ;;
  *) die_usage "unknown matter thread subcommand: $SUBCOMMAND" ;;
esac
