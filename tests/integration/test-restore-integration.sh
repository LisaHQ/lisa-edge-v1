#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESTORE="$REPO_ROOT/ops/backup-restore/restore.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEMP_ROOT="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

REPO_MEMBER="${REPO_ROOT#/}"

write_checksum() {
  local archive="$1"
  "$PYTHON_BIN" - "$archive" <<'PY'
import hashlib
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_name(archive.name + ".sha256").write_text(
    f"{digest}  {archive.name}\n",
    encoding="ascii",
)
PY
}

restore_for_test() {
  local archive="$1"
  local target="$2"
  LISA_EDGE_TESTING=1 \
    LISA_RESTORE_TARGET_ROOT="$target" \
    PYTHON_BIN="$PYTHON_BIN" \
    bash "$RESTORE" --no-start-services "$archive"
}

echo "Testing legacy absolute-path backup format v2..."
V2_FIXTURE="$TEMP_ROOT/v2-fixture"
V2_TARGET="$TEMP_ROOT/v2-target"
mkdir -p \
  "$V2_FIXTURE/$REPO_MEMBER/compose" \
  "$V2_FIXTURE/$REPO_MEMBER/config" \
  "$V2_FIXTURE/srv/lisa-edge/data" \
  "$V2_FIXTURE/srv/lisa-edge/docker" \
  "$V2_FIXTURE/srv/lisa-edge/state" \
  "$V2_FIXTURE/srv/lisa-edge/secrets" \
  "$V2_FIXTURE/srv/lisa-edge/backups/otbr"
cp "$REPO_ROOT/.env.template" "$V2_FIXTURE/$REPO_MEMBER/.env"
printf 'must-not-overwrite-live-code\n' > "$V2_FIXTURE/$REPO_MEMBER/compose/blocked.txt"
printf 'v2-data\n' > "$V2_FIXTURE/srv/lisa-edge/data/integration.txt"
printf 'v2-docker\n' > "$V2_FIXTURE/srv/lisa-edge/docker/integration.txt"
printf 'v2-state\n' > "$V2_FIXTURE/srv/lisa-edge/state/integration.txt"
printf 'v2-secret\n' > "$V2_FIXTURE/srv/lisa-edge/secrets/integration.txt"
printf 'v2-dataset\n' > "$V2_FIXTURE/srv/lisa-edge/backups/otbr/latest.dataset.hex"

V2_ARCHIVE="$TEMP_ROOT/legacy-v2.tar.gz"
tar -czf "$V2_ARCHIVE" -C "$V2_FIXTURE" \
  "$REPO_MEMBER/.env" \
  "$REPO_MEMBER/compose/blocked.txt" \
  "srv/lisa-edge/data/integration.txt" \
  "srv/lisa-edge/docker/integration.txt" \
  "srv/lisa-edge/state/integration.txt" \
  "srv/lisa-edge/secrets/integration.txt" \
  "srv/lisa-edge/backups/otbr/latest.dataset.hex"
write_checksum "$V2_ARCHIVE"
v2_output="$(restore_for_test "$V2_ARCHIVE" "$V2_TARGET")"
grep -q 'Detected backup format v2' <<<"$v2_output"

test -f "$V2_TARGET/opt/lisa-edge/.env"
grep -q 'v2-data' "$V2_TARGET/srv/lisa-edge/data/integration.txt"
grep -q 'v2-docker' "$V2_TARGET/srv/lisa-edge/docker/integration.txt"
grep -q 'v2-state' "$V2_TARGET/srv/lisa-edge/state/integration.txt"
grep -q 'v2-secret' "$V2_TARGET/srv/lisa-edge/secrets/integration.txt"
grep -q 'v2-dataset' "$V2_TARGET/srv/lisa-edge/backups/otbr/latest.dataset.hex"
test ! -e "$V2_TARGET/$REPO_MEMBER/compose/blocked.txt"

echo "Testing logical backup format v3..."
V3_FIXTURE="$TEMP_ROOT/v3-fixture"
V3_TARGET="$TEMP_ROOT/v3-target"
mkdir -p \
  "$V3_FIXTURE/data" \
  "$V3_FIXTURE/docker" \
  "$V3_FIXTURE/state" \
  "$V3_FIXTURE/secrets" \
  "$V3_FIXTURE/otbr"
cp "$REPO_ROOT/.env.template" "$V3_FIXTURE/.env"
printf 'v3-data\n' > "$V3_FIXTURE/data/integration.txt"
printf 'v3-docker\n' > "$V3_FIXTURE/docker/integration.txt"
printf 'v3-state\n' > "$V3_FIXTURE/state/integration.txt"
printf 'v3-secret\n' > "$V3_FIXTURE/secrets/integration.txt"
printf 'v3-dataset\n' > "$V3_FIXTURE/otbr/latest.dataset.hex"

V3_ARCHIVE="$TEMP_ROOT/logical-v3.tar.gz"
tar -czf "$V3_ARCHIVE" -C "$V3_FIXTURE" \
  .env data docker state secrets otbr
write_checksum "$V3_ARCHIVE"
v3_output="$(restore_for_test "$V3_ARCHIVE" "$V3_TARGET")"
grep -q 'Detected backup format v3' <<<"$v3_output"

test -f "$V3_TARGET/opt/lisa-edge/.env"
grep -q 'v3-data' "$V3_TARGET/srv/lisa-edge/data/integration.txt"
grep -q 'v3-docker' "$V3_TARGET/srv/lisa-edge/docker/integration.txt"
grep -q 'v3-state' "$V3_TARGET/srv/lisa-edge/state/integration.txt"
grep -q 'v3-secret' "$V3_TARGET/srv/lisa-edge/secrets/integration.txt"
grep -q 'v3-dataset' "$V3_TARGET/srv/lisa-edge/backups/otbr/latest.dataset.hex"

echo "Restore integration tests passed for v2 and v3."
