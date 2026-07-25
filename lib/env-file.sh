#!/usr/bin/env bash

# Safe .env mutation helper. Sourced by services/lifecycle.sh (and other
# reviewed internal callers) to change LISA_COMPOSE_SERVICES and
# service-owned keys without rewriting the whole configuration.
#
# Guarantees:
#   - the current .env must source cleanly before any change
#   - a timestamped pre-change copy is created (mode 0600)
#   - the new content is written through a temporary file (mode 0600) and
#     moved into place atomically
#   - unrelated settings and comments are preserved (only the requested
#     keys are replaced in place; missing keys are appended)
#   - values are written as KEY='value' without eval; newlines and single
#     quotes are rejected
#   - the resulting file must source cleanly before it replaces .env
#
# After a successful update LISA_ENV_BACKUP_FILE holds the pre-change copy
# so callers can restore it (or point the operator at it) when a later step
# fails.

# True when the file sources cleanly under strict mode in a subshell.
lisa_env_file_is_valid() {
  local env_file="$1"
  [ -f "$env_file" ] || return 1
  (set -euo pipefail; set -a; . "$env_file"; set +a) >/dev/null 2>&1
}

# Reject values that cannot be represented on one KEY='value' line.
lisa_env_value_is_safe() {
  case "$1" in
    *$'\n'*|*"'"*) return 1 ;;
  esac
  return 0
}

# lisa_env_update_keys <env-file> KEY=VALUE [KEY=VALUE ...]
# Replaces (or appends) each KEY in <env-file>. Sets LISA_ENV_BACKUP_FILE.
lisa_env_update_keys() {
  local env_file="$1"
  shift
  [ "$#" -ge 1 ] || { echo "lisa_env_update_keys: no keys given" >&2; return 2; }

  if ! lisa_env_file_is_valid "$env_file"; then
    echo "ERROR: $env_file is missing or does not parse; refusing to modify it." >&2
    return 1
  fi

  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      echo "ERROR: invalid .env key name: $key" >&2
      return 1
    }
    lisa_env_value_is_safe "$value" || {
      echo "ERROR: value for $key contains an unsupported newline or single quote." >&2
      return 1
    }
  done

  LISA_ENV_BACKUP_FILE="$env_file.before-service-$(date +%Y%m%d-%H%M%S)"
  cp -- "$env_file" "$LISA_ENV_BACKUP_FILE"
  chmod 0600 "$LISA_ENV_BACKUP_FILE"

  local temp_file
  temp_file="$(mktemp "$env_file.tmp.XXXXXX")"
  chmod 0600 "$temp_file"
  cp -- "$env_file" "$temp_file"

  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    if grep -Eq "^${key}=" "$temp_file"; then
      # Replace the line in place; awk avoids sed escaping pitfalls in the
      # replacement value.
      awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 && !done { print key "=\x27" value "\x27"; done = 1; next }
        { print }
      ' "$temp_file" > "$temp_file.rewrite"
      chmod 0600 "$temp_file.rewrite"
      mv -- "$temp_file.rewrite" "$temp_file"
    else
      printf "%s='%s'\n" "$key" "$value" >> "$temp_file"
    fi
  done

  if ! lisa_env_file_is_valid "$temp_file"; then
    echo "ERROR: the updated configuration does not parse; .env was left unchanged." >&2
    rm -f -- "$temp_file"
    return 1
  fi

  mv -- "$temp_file" "$env_file"
  chmod 0600 "$env_file"
  return 0
}

# Restore the pre-change copy recorded by the last lisa_env_update_keys call.
lisa_env_restore_backup() {
  local env_file="$1"
  [ -n "${LISA_ENV_BACKUP_FILE:-}" ] && [ -f "$LISA_ENV_BACKUP_FILE" ] || return 1
  cp -- "$LISA_ENV_BACKUP_FILE" "$env_file"
  chmod 0600 "$env_file"
}
