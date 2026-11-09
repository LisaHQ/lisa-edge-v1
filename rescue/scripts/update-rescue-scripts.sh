#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

REPO_URL="${REPO_URL:-https://github.com/LisaHQ/lisa-edge-v1.git}"
BRANCH="${BRANCH:-main}"
RESCUE_ROOT="${LISA_RESCUE_ROOT:-/opt/lisa-rescue}"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[INFO] Updating rescue tools from $REPO_URL branch $BRANCH"

git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR/lisa-edge"
SOURCE_ROOT="$TMP_DIR/lisa-edge/rescue"

if [[ ! -d "$SOURCE_ROOT/scripts" || ! -d "$SOURCE_ROOT/systemd" ]]; then
    echo "ERROR: canonical rescue assets not found in repo."
    exit 1
fi

install -d -m 0755 "$RESCUE_ROOT/scripts"
install -d -m 0755 "$RESCUE_ROOT/systemd"

while IFS= read -r -d '' script; do
    install -m 0755 "$script" "$RESCUE_ROOT/scripts/$(basename "$script")"
done < <(find "$SOURCE_ROOT/scripts" -maxdepth 1 -type f -name '*.sh' -print0)

install -m 0644 "$SOURCE_ROOT/systemd/lisa-rescue-diagnostics.service" \
    "$RESCUE_ROOT/systemd/lisa-rescue-diagnostics.service"
install -m 0644 "$SOURCE_ROOT/systemd/lisa-rescue-diagnostics.timer" \
    "$RESCUE_ROOT/systemd/lisa-rescue-diagnostics.timer"

if [[ -f /etc/systemd/system/lisa-rescue-diagnostics.service ]]; then
    install -m 0644 "$SOURCE_ROOT/systemd/lisa-rescue-diagnostics.service" \
        /etc/systemd/system/lisa-rescue-diagnostics.service
    install -m 0644 "$SOURCE_ROOT/systemd/lisa-rescue-diagnostics.timer" \
        /etc/systemd/system/lisa-rescue-diagnostics.timer
    systemctl daemon-reload
fi

echo "[INFO] Rescue tools updated from canonical rescue/."
