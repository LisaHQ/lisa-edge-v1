#!/usr/bin/env bash

# Shared helpers for the security audit and hardening commands. Sourced by
# ops/security/audit.sh and ops/security/harden.sh; keep this file free of
# side effects so tests can prove the audit path is read-only.

# Print the octal permission bits of a path (e.g. 600), or nothing when the
# path cannot be inspected.
security_file_mode() {
  stat -c '%a' -- "$1" 2>/dev/null || true
}

# Print "uid gid" of a path, or nothing.
security_file_owner() {
  stat -c '%u %g' -- "$1" 2>/dev/null || true
}

# True when the octal mode grants any group permission bit.
security_mode_group_accessible() {
  local mode="$1"
  [ -n "$mode" ] || return 1
  local group=$(( 8#$mode / 8 % 8 ))
  [ "$group" -ne 0 ]
}

# True when the octal mode grants any world (other) permission bit.
security_mode_world_accessible() {
  local mode="$1"
  [ -n "$mode" ] || return 1
  local other=$(( 8#$mode % 8 ))
  [ "$other" -ne 0 ]
}

# True when a file contains at least one plausible SSH public key line.
security_file_has_authorized_key() {
  local key_file="$1"
  [ -f "$key_file" ] || return 1
  grep -Eq '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$key_file" 2>/dev/null
}

# Extract one lowercase effective sshd setting from `sshd -T` output on
# stdin (sshd -T prints lowercase keys and values).
security_sshd_effective() {
  local key="$1"
  awk -v key="$key" 'tolower($1) == key { print tolower($2); exit }'
}

# True when a sudoers fragment grants NOPASSWD to the given user.
security_sudoers_grants_nopasswd() {
  local sudoers_file="$1"
  local user="$2"
  [ -f "$sudoers_file" ] || return 1
  grep -Eq "^[[:space:]]*${user}[[:space:]].*NOPASSWD" "$sudoers_file" 2>/dev/null
}

# Print the docker group's member list (comma-separated, possibly empty), or
# nothing when the group does not exist.
security_docker_group_members() {
  getent group docker 2>/dev/null | cut -d: -f4
}

# True when a TCP listener exists on the given port (uses ss). Returns 2
# when ss is unavailable, so callers can distinguish "cannot check".
security_tcp_listener_on_port() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 2
  ss -Hltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|^)${port}\$"
}
