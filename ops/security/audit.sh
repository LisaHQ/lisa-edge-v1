#!/usr/bin/env bash
set -euo pipefail

# LISA Edge security audit (operator entry point: lisa-edge security audit).
#
# READ-ONLY by contract: this script never changes files, permissions,
# accounts, services, or Docker state, requires no Internet access, and
# never prints secret material. Remediation lives in
# ops/security/harden.sh (lisa-edge security harden).
#
# Outcome model (mirrors lisa-edge health):
#   HEALTHY   no finding
#   DEGRADED  actionable warnings
#   FAILED    a critical condition, or a required check could not be
#             performed safely
# Exit codes: 0 HEALTHY (or DEGRADED without --strict), 1 FAILED,
# 2 usage error, 3 DEGRADED (--strict).

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

# shellcheck disable=SC1091
. "$EDGE_REPO/ops/security/lib.sh"

usage() {
  cat <<'EOF'
Usage: lisa-edge security audit [--strict]

Read-only security inspection: sudo state, admin account, effective SSH
configuration, SSH keys and permissions, .env protection, Docker exposure,
docker group membership, Matter API exposure, and LISA-owned backup
permissions.

Options:
  --strict    Exit nonzero (3) when the result is DEGRADED.
  -h, --help  Show this help.

Exit codes: 0 HEALTHY (or DEGRADED without --strict), 1 FAILED,
2 usage error, 3 DEGRADED (--strict).
EOF
}

STRICT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Test seams: honored only under LISA_EDGE_TESTING=1 and below /tmp
# (mirrors the reset-node.sh testing contract).
TESTING="${LISA_EDGE_TESTING:-0}"
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

SUDOERS_FILE="$(testing_path_or_default "${LISA_SECURITY_SUDOERS_FILE:-}" /etc/sudoers.d/90-lisa-admin)"

FAILURES=()
DEGRADATIONS=()
note_failed() { FAILURES+=("$1"); echo "[LISA] FAILED: $1" >&2; }
note_degraded() { DEGRADATIONS+=("$1"); echo "[LISA] DEGRADED: $1" >&2; }
note_ok() { echo "[LISA] OK: $1"; }
note_skip() { echo "[LISA] SKIPPED: $1"; }

# --- configuration ----------------------------------------------------------
ENV_FILE="$EDGE_REPO/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ENV_FILE"
  set +a
else
  note_failed ".env is missing; run 'sudo ./lisa-edge setup' first (most checks depend on it)."
fi
ADMIN_USER="${LISA_ADMIN_USER:-lisa}"
KEEP_NOPASSWD="${LISA_KEEP_PASSWORDLESS_SUDO:-0}"

echo "[LISA] Security audit (read-only). Admin account: $ADMIN_USER"

# --- 1. sudo state ----------------------------------------------------------
SUDOERS_PRESENT=0
if [ -e "$SUDOERS_FILE" ]; then
  SUDOERS_PRESENT=1
fi
NOPASSWD_EFFECTIVE=unknown
if [ "$SUDOERS_PRESENT" -eq 1 ] && security_sudoers_grants_nopasswd "$SUDOERS_FILE" "$ADMIN_USER"; then
  NOPASSWD_EFFECTIVE=yes
elif [ "$SUDOERS_PRESENT" -eq 0 ]; then
  NOPASSWD_EFFECTIVE=no
fi

if [ "$KEEP_NOPASSWD" = "1" ]; then
  if [ "$NOPASSWD_EFFECTIVE" = "yes" ]; then
    note_degraded "passwordless sudo is enabled for $ADMIN_USER by explicit configuration (LISA_KEEP_PASSWORDLESS_SUDO=1); this is a lab/emergency exception, not a normal state."
  else
    note_degraded "LISA_KEEP_PASSWORDLESS_SUDO=1 but no NOPASSWD grant was found ($SUDOERS_FILE); the configuration does not match the actual state. Apply it with 'sudo ./lisa-edge setup' (Bootstrap or repair this host), or set LISA_KEEP_PASSWORDLESS_SUDO=0."
  fi
else
  case "$NOPASSWD_EFFECTIVE" in
    yes)
      note_degraded "the temporary passwordless sudo grant still exists ($SUDOERS_FILE) although LISA_KEEP_PASSWORDLESS_SUDO=0; remove it with 'sudo ./lisa-edge security harden'." ;;
    no)
      note_ok "no passwordless sudo grant for $ADMIN_USER (matches LISA_KEEP_PASSWORDLESS_SUDO=0)." ;;
    *)
      note_degraded "$SUDOERS_FILE exists but grants nothing recognizable to $ADMIN_USER; review it manually." ;;
  esac
fi

# --- 2. admin account -------------------------------------------------------
ADMIN_HOME=""
if [ "$ADMIN_USER" = "root" ]; then
  note_failed "LISA_ADMIN_USER is root; a dedicated non-root admin account is required."
elif ! command -v getent >/dev/null 2>&1; then
  note_failed "getent is unavailable; the admin account cannot be verified."
elif ! getent passwd "$ADMIN_USER" >/dev/null 2>&1; then
  note_failed "the configured admin account does not exist: $ADMIN_USER"
else
  ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  ADMIN_GROUPS="$(id -Gn "$ADMIN_USER" 2>/dev/null || true)"
  case " $ADMIN_GROUPS " in
    *" sudo "*|*" wheel "*|*" admin "*)
      note_ok "admin account $ADMIN_USER exists, is non-root, and has an administrative group." ;;
    *)
      if [ "$SUDOERS_PRESENT" -eq 1 ]; then
        note_degraded "admin account $ADMIN_USER relies only on the temporary sudoers grant; add it to the sudo group before that grant is removed."
      else
        note_failed "admin account $ADMIN_USER has no administrative path (no sudo/wheel/admin group and no sudoers grant)."
      fi
      ;;
  esac
fi

# --- 3+4. effective SSH configuration and syntax ---------------------------
SSHD_EFFECTIVE=""
PASSWORD_AUTH=unknown
if command -v sshd >/dev/null 2>&1; then
  if sshd -t >/dev/null 2>&1; then
    note_ok "sshd configuration syntax is valid."
  else
    note_failed "sshd configuration syntax is INVALID (sshd -t failed); fix it before any SSH reload."
  fi
  if SSHD_EFFECTIVE="$(sshd -T 2>/dev/null)"; then
    root_login="$(printf '%s\n' "$SSHD_EFFECTIVE" | security_sshd_effective permitrootlogin)"
    PASSWORD_AUTH="$(printf '%s\n' "$SSHD_EFFECTIVE" | security_sshd_effective passwordauthentication)"
    kbd_auth="$(printf '%s\n' "$SSHD_EFFECTIVE" | security_sshd_effective kbdinteractiveauthentication)"
    case "$root_login" in
      no) note_ok "PermitRootLogin is 'no'." ;;
      yes) note_failed "PermitRootLogin is 'yes'; direct root SSH login must be disabled." ;;
      *) note_degraded "PermitRootLogin is '${root_login:-unknown}' (expected 'no')." ;;
    esac
    if [ "$PASSWORD_AUTH" = "no" ]; then
      note_ok "PasswordAuthentication is 'no' (key-only login)."
    else
      note_degraded "PasswordAuthentication is '${PASSWORD_AUTH:-unknown}'; prefer key-only login once an admin key is installed."
    fi
    if [ "$kbd_auth" = "no" ]; then
      note_ok "KbdInteractiveAuthentication is 'no'."
    else
      note_degraded "KbdInteractiveAuthentication is '${kbd_auth:-unknown}'; prefer 'no'."
    fi
  else
    note_degraded "sshd -T failed; effective SSH settings could not be read."
  fi
else
  note_skip "sshd is not installed; SSH checks do not apply."
fi

# --- 5+6. admin authorized keys and SSH file permissions --------------------
if [ -n "$ADMIN_HOME" ]; then
  AUTH_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
  if security_file_has_authorized_key "$AUTH_KEYS"; then
    note_ok "$ADMIN_USER has at least one usable authorized SSH key."
  elif [ "$PASSWORD_AUTH" = "no" ]; then
    note_failed "$ADMIN_USER has no usable authorized key while PasswordAuthentication is 'no'; remote lockout risk."
  else
    note_degraded "$ADMIN_USER has no usable authorized key ($AUTH_KEYS); install one before disabling password authentication."
  fi

  ADMIN_UID="$(id -u "$ADMIN_USER" 2>/dev/null || true)"
  if [ -d "$ADMIN_HOME/.ssh" ]; then
    mode="$(security_file_mode "$ADMIN_HOME/.ssh")"
    owner="$(security_file_owner "$ADMIN_HOME/.ssh")"
    if [ "${owner%% *}" != "$ADMIN_UID" ]; then
      note_degraded "$ADMIN_HOME/.ssh is not owned by $ADMIN_USER."
    elif security_mode_group_accessible "$mode" || security_mode_world_accessible "$mode"; then
      note_degraded "$ADMIN_HOME/.ssh mode is $mode; it should be 0700."
    else
      note_ok "$ADMIN_HOME/.ssh ownership and mode look correct ($mode)."
    fi
  fi
  if [ -f "$AUTH_KEYS" ]; then
    mode="$(security_file_mode "$AUTH_KEYS")"
    owner="$(security_file_owner "$AUTH_KEYS")"
    if [ "${owner%% *}" != "$ADMIN_UID" ]; then
      note_degraded "$AUTH_KEYS is not owned by $ADMIN_USER."
    elif security_mode_world_accessible "$mode" && [ $(( 8#$mode % 8 & 2 )) -ne 0 ]; then
      note_failed "$AUTH_KEYS is world-writable (mode $mode)."
    elif security_mode_group_accessible "$mode" || security_mode_world_accessible "$mode"; then
      note_degraded "$AUTH_KEYS mode is $mode; it should be 0600."
    else
      note_ok "$AUTH_KEYS ownership and mode look correct ($mode)."
    fi
  fi
fi

# --- 7. .env ownership and permissions -------------------------------------
if [ -f "$ENV_FILE" ]; then
  mode="$(security_file_mode "$ENV_FILE")"
  if security_mode_world_accessible "$mode"; then
    note_failed ".env is world-accessible (mode $mode); it holds secrets and must be 0600."
  elif security_mode_group_accessible "$mode"; then
    note_degraded ".env is group-accessible (mode $mode); it should be 0600."
  else
    note_ok ".env permissions look correct ($mode)."
  fi
fi

# --- 8. .env must not be tracked by Git -------------------------------------
if command -v git >/dev/null 2>&1 && [ -d "$EDGE_REPO/.git" ]; then
  if git -C "$EDGE_REPO" ls-files --error-unmatch .env >/dev/null 2>&1; then
    note_failed ".env is tracked by Git; secrets must never live in version control (git rm --cached .env)."
  else
    note_ok ".env is not tracked by Git."
  fi
else
  note_skip "no Git checkout detected; the .env tracking check does not apply."
fi

# --- 9. Docker TCP exposure -------------------------------------------------
# The local Unix socket is the normal, safe configuration and is never
# flagged. An unauthenticated TCP listener is root-equivalent remote access.
rc=0
security_tcp_listener_on_port 2375 || rc=$?
case "$rc" in
  0) note_failed "an unauthenticated Docker TCP listener appears active on port 2375 (root-equivalent remote access)." ;;
  1) note_ok "no Docker TCP listener on port 2375 (local Unix socket only is the safe default)." ;;
  *) note_skip "ss is unavailable; Docker TCP exposure could not be checked." ;;
esac
rc=0
security_tcp_listener_on_port 2376 || rc=$?
if [ "$rc" -eq 0 ]; then
  note_degraded "a Docker TLS TCP listener appears active on port 2376; verify certificates and firewalling."
fi

# --- 10. docker group membership --------------------------------------------
if command -v getent >/dev/null 2>&1 && getent group docker >/dev/null 2>&1; then
  members="$(security_docker_group_members)"
  if [ -z "$members" ]; then
    note_ok "the docker group has no members (Docker socket access is root-equivalent)."
  else
    note_degraded "docker group members have root-equivalent access; review them: $members (membership is never changed automatically)."
  fi
else
  note_skip "no docker group found; the membership check does not apply."
fi

# --- 11. Matter API exposure -------------------------------------------------
case " ${LISA_COMPOSE_SERVICES:-} " in
  *" matter "*|*" matter-server "*)
    if [ "${MATTER_LISTEN_ADDRESS:-127.0.0.1}" = "0.0.0.0" ]; then
      note_degraded "MATTER_LISTEN_ADDRESS=0.0.0.0 exposes the UNAUTHENTICATED Matter WebSocket API on every interface; bind a trusted address and firewall TCP ${MATTER_SERVER_PORT:-5580} ('sudo ./lisa-edge security harden' can fix the bind)."
    else
      note_ok "Matter WebSocket API is bound to ${MATTER_LISTEN_ADDRESS:-127.0.0.1} (not a wildcard)."
    fi
    ;;
esac

# --- 12. LISA-owned exported datasets / backup metadata ----------------------
# Only the canonical dedicated backup directories are inspected, one level
# deep; unrelated storage is never scanned.
check_backup_dir() {
  local label="$1" dir="$2" mode entry
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  mode="$(security_file_mode "$dir")"
  if security_mode_group_accessible "$mode" || security_mode_world_accessible "$mode"; then
    note_degraded "$label directory $dir mode is $mode; it should be 0700."
  fi
  while IFS= read -r entry; do
    mode="$(security_file_mode "$entry")"
    if security_mode_world_accessible "$mode"; then
      note_degraded "$label file is world-accessible (mode $mode): $entry"
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
}
check_backup_dir "OTBR dataset backup" "${OTBR_DATASET_BACKUP_DIR:-}"
check_backup_dir "Matter data backup" "${MATTER_DATA_BACKUP_DIR:-}"

# --- summary -----------------------------------------------------------------
echo
if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "[LISA] Failed checks:"
  printf '[LISA]   - %s\n' "${FAILURES[@]}"
fi
if [ "${#DEGRADATIONS[@]}" -gt 0 ]; then
  echo "[LISA] Warnings:"
  printf '[LISA]   - %s\n' "${DEGRADATIONS[@]}"
fi
echo "[LISA] Note: firewall allowlists remain deployment-specific (VLANs, UniFi"
echo "[LISA] rules); this audit does not manage a firewall."

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "[LISA] Security audit result: FAILED"
  exit 1
fi
if [ "${#DEGRADATIONS[@]}" -gt 0 ]; then
  echo "[LISA] Security audit result: DEGRADED"
  echo "[LISA] Bounded remediation is available: sudo ./lisa-edge security harden"
  if [ "$STRICT" -eq 1 ]; then
    exit 3
  fi
  exit 0
fi
echo "[LISA] Security audit result: HEALTHY"
