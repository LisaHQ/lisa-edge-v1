#!/usr/bin/env bash

# Shared helpers for OTBR Thread dataset tooling. Sourced by dataset scripts
# and the OTBR provisioning wizard; keep this file free of side effects.

# One-shot markers staged by the provisioning wizard inside
# OTBR_DATASET_BACKUP_DIR and consumed by init-or-restore.sh on deploy.
# shellcheck disable=SC2034
OTBR_PENDING_DATASET_FILE_NAME="pending.dataset.hex"
# shellcheck disable=SC2034
OTBR_PENDING_NEW_NETWORK_FILE_NAME="pending.new-network"

# Maximum filename length on the supported filesystems (ext4 and friends).
OTBR_FILENAME_MAX_BYTES=255

# Sanitize a user-supplied backup description so it can be embedded in a
# filename: spaces become '-', any other byte outside [A-Za-z0-9._-] becomes
# '_', and the result is truncated to max_length bytes. The output is pure
# ASCII, so byte length equals character length.
otbr_sanitize_backup_description() {
  local description="${1-}"
  local max_length="${2:-64}"
  description="${description// /-}"
  description="$(printf '%s' "$description" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  printf '%s' "${description:0:max_length}"
}

# Print Thread dataset backup candidates under a directory, newest first, one
# path per line. Regular *.hex files only: the latest.dataset.hex symlink is
# skipped (its target is already listed) and pending markers are excluded.
otbr_list_dataset_backup_files() {
  local search_root="$1"
  find "$search_root" -maxdepth 3 -type f -name '*.hex' \
    ! -name "$OTBR_PENDING_DATASET_FILE_NAME" -printf '%T@\t%p\n' 2>/dev/null |
    sort -rn | cut -f2-
}

# True when the dataset file contains a single non-empty hex string.
otbr_dataset_file_is_valid_hex() {
  local dataset_file="$1"
  [ -f "$dataset_file" ] || return 1
  tr -d '[:space:]' < "$dataset_file" | grep -Eq '^[0-9a-fA-F]+$'
}

# Verify a backup file against its .sha256 sidecar when one exists. Returns
# 0 when the sidecar is absent (older or hand-copied file) or matches, 1 on
# mismatch. Prints the failure reason to stderr.
otbr_dataset_file_checksum_ok() {
  local dataset_file="$1"
  local sidecar="$dataset_file.sha256"
  local expected actual
  [ -f "$sidecar" ] || return 0
  expected="$(awk '{print $1; exit}' "$sidecar")"
  actual="$(sha256sum "$dataset_file" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    echo "Checksum mismatch for $dataset_file (sidecar $sidecar)." >&2
    return 1
  fi
  return 0
}

# Decide what deploy does when OTBR has NO active dataset and NO pending
# one-shot action, from the persistent recovery policy. Pure (unit-tested).
# Args: <auto_restore 0|1> <auto_create 0|1> <latest_backup_exists 0|1>
# Prints exactly one action token:
#   restore-latest                  restore the latest backup
#   create-network                  create a brand-new Thread network
#   fail-backup-restore-disabled    a latest backup exists but restoration is
#                                   disabled; NEVER silently create a
#                                   replacement network over it
#   fail-no-backup                  nothing to restore and creation is not
#                                   allowed by the policy
otbr_empty_dataset_action() {
  local auto_restore="$1" auto_create="$2" latest_exists="$3"
  if [ "$latest_exists" = "1" ]; then
    if [ "$auto_restore" = "1" ]; then
      printf 'restore-latest\n'
    else
      printf 'fail-backup-restore-disabled\n'
    fi
    return 0
  fi
  if [ "$auto_create" = "1" ]; then
    printf 'create-network\n'
  else
    printf 'fail-no-backup\n'
  fi
}

# True when the lisa-otbr container is currently running.
otbr_container_is_running() {
  command -v docker >/dev/null 2>&1 || return 1
  grep -qx lisa-otbr <<<"$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
}

# Wait until otbr-agent accepts ot-ctl commands. Args: [attempts] [sleep_s].
otbr_wait_for_agent() {
  local attempts="${1:-60}" delay="${2:-2}" i
  for ((i = 0; i < attempts; i++)); do
    if docker exec lisa-otbr ot-ctl state >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

# Classify OTBR's active dataset instead of trusting a single read. A
# transient ot-ctl failure must never be mistaken for "no dataset": that
# could replace a live Thread network and orphan its devices.
# Sets OTBR_ACTIVE_DATASET_HEX. Returns 0=present, 1=agent confirmed absent,
# 2=undetermined.
otbr_classify_active_dataset() {
  local output=""
  OTBR_ACTIVE_DATASET_HEX=""
  if output="$(docker exec lisa-otbr ot-ctl dataset active -x 2>&1)"; then
    # ot-ctl terminates lines with CRLF; strip \r or the hex line never matches.
    OTBR_ACTIVE_DATASET_HEX="$(printf '%s\n' "$output" | tr -d '\r' |
      awk '/^[0-9a-fA-F]+$/ {print $1; exit}')"
    [ -n "$OTBR_ACTIVE_DATASET_HEX" ] && return 0
  fi
  if printf '%s' "$output" | grep -qi 'NotFound'; then
    return 1
  fi
  return 2
}

# Classify with retries: repeatedly calls otbr_classify_active_dataset until
# it answers present/absent or attempts run out. Same return codes.
otbr_classify_active_dataset_retry() {
  local attempts="${1:-30}" delay="${2:-2}" i rc
  for ((i = 0; i < attempts; i++)); do
    rc=0
    otbr_classify_active_dataset || rc=$?
    [ "$rc" -ne 2 ] && return "$rc"
    sleep "$delay"
  done
  return 2
}

# Print OTBR's Thread role (leader/router/child/detached/disabled), or
# nothing when unavailable.
otbr_thread_state() {
  docker exec lisa-otbr ot-ctl state 2>/dev/null | head -n 1 | tr -d '\r' || true
}

# Wait until the node attaches (leader/router/child). Args: [attempts] [sleep].
otbr_wait_for_attach() {
  local attempts="${1:-60}" delay="${2:-2}" i state
  for ((i = 0; i < attempts; i++)); do
    state="$(otbr_thread_state)"
    case "$state" in
      leader|router|child) return 0 ;;
    esac
    sleep "$delay"
  done
  return 1
}
