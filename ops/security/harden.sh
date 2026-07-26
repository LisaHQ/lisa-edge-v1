#!/usr/bin/env bash
set -euo pipefail

# LISA Edge bounded security hardening (operator entry point:
# lisa-edge security harden).
#
# Only provably safe remediation is performed; anything that cannot be
# proven safe fails closed with the exact manual correction. Lockout rules:
#   - SSH password authentication is disabled only after a usable NON-ROOT
#     authorized key is verified
#   - passwordless sudo is removed only when the admin account has (or
#     interactively sets) a usable password
#     (install/bootstrap/finalize-admin-access.sh enforces this)
#   - docker group membership is never changed
#   - SSH is never reloaded after an invalid configuration (sshd -t first)
#
# Audit logic stays in ops/security/audit.sh, which is read-only.

EDGE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$EDGE_REPO"

# shellcheck disable=SC1091
. "$EDGE_REPO/ops/security/lib.sh"

usage() {
  cat <<'EOF'
Usage: lisa-edge security harden

Bounded, lockout-safe remediation:
  - fix ownership/modes of .env and LISA-owned backup directories
  - fix ownership/modes of the admin account's SSH files
  - remove the temporary passwordless sudo grant (a usable password is
    required or established first)
  - optionally disable SSH password login (only with a verified non-root
    authorized key; sshd -t validates before any reload)
  - optionally replace an unsafe Matter wildcard bind address

Options:
  -h, --help  Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

TESTING="${LISA_EDGE_TESTING:-0}"
if [ "$(id -u)" -ne 0 ] && [ "$TESTING" != "1" ]; then
  echo "Run as root: sudo ./lisa-edge security harden" >&2
  exit 1
fi

# Test seams: honored only under LISA_EDGE_TESTING=1 and below /tmp
# (mirrors the reset-node.sh testing contract).
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

info() { echo "[LISA] $*"; }
warn() { echo "[LISA] WARNING: $*" >&2; }

interactive() { [ -t 0 ] && [ -t 1 ]; }

ask_yes_no_default_no() {
  local answer
  interactive || return 1
  read -r -p "$1 [y/N] " answer
  case "${answer,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

ENV_FILE="$EDGE_REPO/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env is missing; run 'sudo ./lisa-edge setup' first." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. "$ENV_FILE"
set +a
ADMIN_USER="${LISA_ADMIN_USER:-lisa}"

CHANGED=0
SKIPPED=0
note_changed() { CHANGED=$((CHANGED + 1)); info "FIXED: $*"; }
note_skipped() { SKIPPED=$((SKIPPED + 1)); info "SKIPPED (not provably safe here): $*"; }

# --- 1. LISA-owned sensitive file modes (always safe) ------------------------
mode="$(security_file_mode "$ENV_FILE")"
if [ "$mode" != "600" ]; then
  chmod 0600 "$ENV_FILE"
  note_changed ".env mode $mode -> 0600."
else
  info ".env mode is already 0600."
fi

fix_backup_dir() {
  local label="$1" dir="$2" mode entry
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  mode="$(security_file_mode "$dir")"
  if [ "$mode" != "700" ]; then
    chmod 0700 "$dir"
    note_changed "$label directory mode $mode -> 0700 ($dir)."
  fi
  while IFS= read -r entry; do
    mode="$(security_file_mode "$entry")"
    if security_mode_group_accessible "$mode" || security_mode_world_accessible "$mode"; then
      chmod 0600 "$entry"
      note_changed "$label file mode $mode -> 0600 ($entry)."
    fi
  done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
}
fix_backup_dir "OTBR dataset backup" "${OTBR_DATASET_BACKUP_DIR:-}"
fix_backup_dir "Matter data backup" "${MATTER_DATA_BACKUP_DIR:-}"

# --- 2. admin SSH file ownership/modes ---------------------------------------
if command -v getent >/dev/null 2>&1 && getent passwd "$ADMIN_USER" >/dev/null 2>&1 &&
   [ "$ADMIN_USER" != "root" ]; then
  ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  if [ -d "$ADMIN_HOME/.ssh" ]; then
    chown "$ADMIN_USER" "$ADMIN_HOME/.ssh" 2>/dev/null ||
      warn "could not change ownership of $ADMIN_HOME/.ssh"
    if [ "$(security_file_mode "$ADMIN_HOME/.ssh")" != "700" ]; then
      chmod 0700 "$ADMIN_HOME/.ssh"
      note_changed "$ADMIN_HOME/.ssh mode -> 0700."
    fi
  fi
  if [ -f "$ADMIN_HOME/.ssh/authorized_keys" ]; then
    chown "$ADMIN_USER" "$ADMIN_HOME/.ssh/authorized_keys" 2>/dev/null ||
      warn "could not change ownership of $ADMIN_HOME/.ssh/authorized_keys"
    if [ "$(security_file_mode "$ADMIN_HOME/.ssh/authorized_keys")" != "600" ]; then
      chmod 0600 "$ADMIN_HOME/.ssh/authorized_keys"
      note_changed "$ADMIN_HOME/.ssh/authorized_keys mode -> 0600."
    fi
  fi
else
  note_skipped "admin SSH files: the account $ADMIN_USER could not be verified."
fi

# --- 3. passwordless sudo removal --------------------------------------------
# finalize-admin-access.sh contains the lockout guards: it refuses when the
# account has no usable password and no terminal is available to set one.
SUDOERS_FILE="/etc/sudoers.d/90-lisa-admin"
if [ -e "$SUDOERS_FILE" ]; then
  if [ "${LISA_KEEP_PASSWORDLESS_SUDO:-0}" = "1" ]; then
    note_skipped "passwordless sudo: kept by explicit configuration (LISA_KEEP_PASSWORDLESS_SUDO=1). Set it to 0 and rerun to remove the grant."
  elif bash "$EDGE_REPO/install/bootstrap/finalize-admin-access.sh"; then
    note_changed "temporary passwordless sudo grant removed for $ADMIN_USER."
  else
    note_skipped "passwordless sudo: removal refused (no usable password could be verified or established). Run 'sudo passwd $ADMIN_USER', then rerun."
  fi
elif [ "${LISA_KEEP_PASSWORDLESS_SUDO:-0}" = "1" ]; then
  note_skipped "passwordless sudo: the configured exception (LISA_KEEP_PASSWORDLESS_SUDO=1) expects a grant, but none exists. Hardening never creates sudo grants; apply the configuration with 'sudo ./lisa-edge setup' (Bootstrap or repair this host), or set LISA_KEEP_PASSWORDLESS_SUDO=0."
else
  info "no temporary passwordless sudo grant is present."
fi

# --- 4. SSH password authentication ------------------------------------------
SSHD_CONFIG="$(testing_path_or_default "${LISA_SECURITY_SSHD_CONFIG:-}" /etc/ssh/sshd_config)"
SSHD_DROP_IN_DIR="$(testing_path_or_default "${LISA_SECURITY_SSHD_DROP_IN_DIR:-}" /etc/ssh/sshd_config.d)"
SSHD_DROP_IN="$SSHD_DROP_IN_DIR/99-lisa-edge-hardening.conf"
if command -v sshd >/dev/null 2>&1 && [ -f "$SSHD_CONFIG" ]; then
  password_auth="$(sshd -T 2>/dev/null | security_sshd_effective passwordauthentication || true)"
  if [ "$password_auth" = "no" ]; then
    info "SSH password authentication is already disabled."
  else
    # A usable NON-ROOT key is mandatory before password login goes away.
    has_key=0
    if [ "$ADMIN_USER" != "root" ] && command -v getent >/dev/null 2>&1; then
      admin_home="$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6 || true)"
      if [ -n "$admin_home" ] && security_file_has_authorized_key "$admin_home/.ssh/authorized_keys"; then
        has_key=1
      fi
    fi
    if [ "$has_key" -ne 1 ]; then
      note_skipped "SSH password login: $ADMIN_USER has no usable authorized key; disabling passwords now would risk remote lockout. Install a key, then rerun."
    elif ask_yes_no_default_no "Disable SSH password login (a usable key for $ADMIN_USER was verified)?"; then
      mkdir -p "$SSHD_DROP_IN_DIR"
      {
        echo "PermitRootLogin no"
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
      } > "$SSHD_DROP_IN"
      install -d -m 0755 /run/sshd
      if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        note_changed "SSH hardened: PermitRootLogin no, PasswordAuthentication no ($SSHD_DROP_IN)."
      else
        rm -f "$SSHD_DROP_IN"
        warn "sshd -t rejected the hardened configuration; the drop-in was removed and SSH was NOT reloaded."
        note_skipped "SSH password login: configuration validation failed."
      fi
    else
      note_skipped "SSH password login: left unchanged (no interactive confirmation)."
    fi
  fi
fi

# --- 5. Matter wildcard bind --------------------------------------------------
case " ${LISA_COMPOSE_SERVICES:-} " in
  *" matter "*|*" matter-server "*)
    if [ "${MATTER_LISTEN_ADDRESS:-127.0.0.1}" = "0.0.0.0" ]; then
      if interactive; then
        echo
        echo "[LISA] MATTER_LISTEN_ADDRESS=0.0.0.0 exposes the unauthenticated Matter"
        echo "[LISA] WebSocket API on every interface."
        read -r -p "Replacement bind address [127.0.0.1, empty keeps 0.0.0.0]: " new_bind
        if [ -z "$new_bind" ]; then
          note_skipped "Matter bind: kept 0.0.0.0 by operator choice; firewall TCP ${MATTER_SERVER_PORT:-5580}."
        elif [[ "$new_bind" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          # shellcheck disable=SC1091
          . "$EDGE_REPO/lib/env-file.sh"
          if lisa_env_update_keys "$ENV_FILE" "MATTER_LISTEN_ADDRESS=$new_bind"; then
            note_changed "MATTER_LISTEN_ADDRESS -> $new_bind. Apply it with: sudo ./lisa-edge setup (Refresh services)."
          else
            note_skipped "Matter bind: .env could not be updated safely."
          fi
        else
          note_skipped "Matter bind: '$new_bind' is not a valid IPv4 address; nothing was changed."
        fi
      else
        note_skipped "Matter bind: 0.0.0.0 needs an operator-selected replacement; rerun interactively."
      fi
    fi
    ;;
esac

echo
info "Hardening finished: $CHANGED change(s), $SKIPPED skipped item(s)."
info "Verify with: sudo ./lisa-edge security audit"
