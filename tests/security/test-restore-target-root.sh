#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESTORE="$REPO_ROOT/ops/backup-restore/restore.sh"
TEMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

FAKE_BIN="$TEMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
EOF
chmod +x "$FAKE_BIN/id"

# Parser and target-root guardrails reject these requests before reading the
# archive, so a regular placeholder file is sufficient.
ARCHIVE="$TEMP_ROOT/placeholder.tar.gz"
: > "$ARCHIVE"

if missing_output="$(PATH="$FAKE_BIN:$PATH" PYTHON_BIN=true bash "$RESTORE" --target-root 2>&1)"; then
  echo "Expected a missing --target-root value to fail." >&2
  exit 1
fi
grep -q -- '--target-root requires a path' <<<"$missing_output"

if unsafe_output="$(PATH="$FAKE_BIN:$PATH" PYTHON_BIN=true bash "$RESTORE" \
  --target-root "$TEMP_ROOT/target" "$ARCHIVE" 2>&1)"; then
  echo "Expected a target outside /mnt to fail." >&2
  exit 1
fi
grep -q -- '--target-root must be below /mnt' <<<"$unsafe_output"

if deploy_output="$(PATH="$FAKE_BIN:$PATH" PYTHON_BIN=true bash "$RESTORE" \
  --start-services --target-root /mnt/not-used "$ARCHIVE" 2>&1)"; then
  echo "Expected target-root restore with --start-services to fail." >&2
  exit 1
fi
grep -q 'target-root restore cannot start services' <<<"$deploy_output"

if missing_target_output="$(PATH="$FAKE_BIN:$PATH" PYTHON_BIN=true bash "$RESTORE" \
  --target-root /mnt/lisa-edge-test-target-does-not-exist "$ARCHIVE" 2>&1)"; then
  echo "Expected a missing mounted target to fail." >&2
  exit 1
fi
grep -q 'Restore target does not exist' <<<"$missing_target_output"

if facade_output="$(PATH="$FAKE_BIN:$PATH" PYTHON_BIN=true bash "$REPO_ROOT/lisa-edge" restore \
  --target-root "$TEMP_ROOT/target" "$ARCHIVE" 2>&1)"; then
  echo "Expected the facade to preserve target-root safety checks." >&2
  exit 1
fi
grep -q -- '--target-root must be below /mnt' <<<"$facade_output"

echo "Restore target-root parser and safety tests passed."
