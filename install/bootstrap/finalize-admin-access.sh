#!/usr/bin/env bash
set -euo pipefail

# Idempotent reconciler for the passwordless-sudo grant
# (/etc/sudoers.d/90-lisa-admin). Desired state comes from .env:
#
#   LISA_KEEP_PASSWORDLESS_SUDO=1  the grant must EXIST with exactly the
#                                  configured admin user (lab/emergency
#                                  exception). A missing or stale file is
#                                  created/corrected through a visudo-
#                                  validated temporary file (root:root,
#                                  mode 0440), installed atomically.
#   LISA_KEEP_PASSWORDLESS_SUDO=0  the grant must be ABSENT. Removal stays
#                                  lockout-safe: it happens only after the
#                                  admin account has (or interactively
#                                  sets) a usable password; an already
#                                  absent file is a successful no-op.
#
# Callers: install/bootstrap/bootstrap.sh (fresh setup, restore apply, and
# the setup menu's bootstrap/repair action) and ops/security/harden.sh
# (removal path only). The setup menu's config-only action never runs this
# script: it must not mutate host sudo state.
#
# Test seams (mirror ops/security/audit.sh): honored only under
# LISA_EDGE_TESTING=1, and path overrides must resolve below /tmp. Tests
# never touch the real /etc/sudoers.d.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$EDGE_REPO/.env"

TESTING="${LISA_EDGE_TESTING:-0}"

if [ "$(id -u)" -ne 0 ] && [ "$TESTING" != "1" ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

testing_path_or_default() {
  local override="$1" default_value="$2" resolved
  if [ "$TESTING" = "1" ] && [ -n "$override" ]; then
    resolved="$(readlink -m -- "$override")"
    case "$resolved" in
      /tmp/*) printf '%s\n' "$resolved"; return 0 ;;
      *) echo "ERROR: testing override must resolve below /tmp: $override" >&2; exit 1 ;;
    esac
  fi
  printf '%s\n' "$default_value"
}

ADMIN_USER="${LISA_ADMIN_USER:-lisa}"
SUDOERS_FILE="$(testing_path_or_default "${LISA_SECURITY_SUDOERS_FILE:-}" /etc/sudoers.d/90-lisa-admin)"
DESIRED_CONTENT="$ADMIN_USER ALL=(ALL) NOPASSWD:ALL"

require_admin_account() {
  [ "$ADMIN_USER" != "root" ] || {
    echo "LISA_ADMIN_USER is root; a dedicated non-root admin account is required." >&2
    exit 1
  }
  id "$ADMIN_USER" >/dev/null 2>&1 || {
    echo "Configured admin account does not exist: $ADMIN_USER" >&2
    exit 1
  }
}

# Validate a candidate sudoers fragment. Fail closed: an invalid candidate
# is never installed, and a missing visudo refuses installation of NEW
# content (an unvalidated fragment could break sudo entirely).
validate_sudoers_candidate() {
  local candidate="$1"
  if ! command -v visudo >/dev/null 2>&1; then
    echo "ERROR: visudo is unavailable; refusing to install an unvalidated sudoers file." >&2
    return 1
  fi
  visudo -cf "$candidate" >/dev/null
}

reconcile_present() {
  require_admin_account

  local current="" state mode owner_ok=1
  if [ -e "$SUDOERS_FILE" ]; then
    current="$(cat "$SUDOERS_FILE" 2>/dev/null || true)"
    state=corrected
  else
    state=created
  fi

  if [ "$current" = "$DESIRED_CONTENT" ]; then
    mode="$(stat -c '%a' "$SUDOERS_FILE" 2>/dev/null || echo '')"
    if [ "$TESTING" != "1" ]; then
      [ "$(stat -c '%u:%g' "$SUDOERS_FILE" 2>/dev/null || echo '')" = "0:0" ] || owner_ok=0
    fi
    if [ "$mode" = "440" ] && [ "$owner_ok" -eq 1 ]; then
      echo "[LISA] Passwordless sudo grant for $ADMIN_USER is already valid ($SUDOERS_FILE)."
      echo "[LISA] WARNING: passwordless sudo remains enabled for $ADMIN_USER by explicit configuration (LISA_KEEP_PASSWORDLESS_SUDO=1)." >&2
      return 0
    fi
  fi

  local sudoers_dir temp_file
  sudoers_dir="$(dirname "$SUDOERS_FILE")"
  [ -d "$sudoers_dir" ] || {
    echo "ERROR: sudoers directory does not exist: $sudoers_dir" >&2
    exit 1
  }
  temp_file="$(mktemp "$sudoers_dir/.90-lisa-admin.XXXXXX")"
  printf '%s\n' "$DESIRED_CONTENT" > "$temp_file"
  if ! chown root:root "$temp_file" 2>/dev/null; then
    if [ "$TESTING" != "1" ]; then
      rm -f "$temp_file"
      echo "ERROR: could not set root:root ownership on the sudoers candidate." >&2
      exit 1
    fi
  fi
  chmod 0440 "$temp_file"
  if ! validate_sudoers_candidate "$temp_file"; then
    rm -f "$temp_file"
    echo "ERROR: the sudoers candidate failed visudo validation; nothing was installed." >&2
    exit 1
  fi
  mv -- "$temp_file" "$SUDOERS_FILE"
  if [ "$state" = "created" ]; then
    echo "[LISA] Passwordless sudo grant created for $ADMIN_USER ($SUDOERS_FILE)."
  else
    echo "[LISA] Passwordless sudo grant corrected for $ADMIN_USER ($SUDOERS_FILE)."
  fi
  echo "[LISA] WARNING: passwordless sudo remains enabled for $ADMIN_USER by explicit configuration (LISA_KEEP_PASSWORDLESS_SUDO=1)." >&2
}

reconcile_absent() {
  if [ ! -e "$SUDOERS_FILE" ]; then
    echo "[LISA] No passwordless sudo grant is present ($SUDOERS_FILE); nothing to remove."
    return 0
  fi
  require_admin_account

  local password_status
  password_status="$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')"
  if [ "$password_status" != "P" ]; then
    [ -t 0 ] && [ -t 1 ] || {
      echo "Cannot remove passwordless sudo: $ADMIN_USER has no usable password and this run is non-interactive." >&2
      echo "Run sudo passwd $ADMIN_USER, then rerun this script." >&2
      exit 1
    }
    echo "[LISA] Set a local password for $ADMIN_USER before passwordless sudo is removed."
    passwd "$ADMIN_USER"
    password_status="$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')"
    [ "$password_status" = "P" ] || {
      echo "Password for $ADMIN_USER is still unavailable; passwordless sudo was preserved." >&2
      exit 1
    }
  fi

  if command -v visudo >/dev/null 2>&1; then
    visudo -cf /etc/sudoers >/dev/null
  fi
  rm -f "$SUDOERS_FILE"
  echo "[LISA] Temporary passwordless sudo grant removed for $ADMIN_USER."
}

case "${LISA_KEEP_PASSWORDLESS_SUDO:-0}" in
  1) reconcile_present ;;
  0) reconcile_absent ;;
  *) echo "LISA_KEEP_PASSWORDLESS_SUDO must be 0 or 1." >&2; exit 1 ;;
esac
