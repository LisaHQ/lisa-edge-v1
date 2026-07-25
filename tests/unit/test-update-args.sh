#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Unknown arguments must be rejected before any git or deploy action runs.
set +e
OUTPUT="$(bash "$REPO_ROOT/ops/deploy/update.sh" bogus 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -ne 2 ]; then
  echo "Expected exit status 2 for an unknown update argument, got $STATUS." >&2
  exit 1
fi

case "$OUTPUT" in
  *"Usage: lisa-edge update [clean]"*) ;;
  *)
    echo "Expected a usage message for an unknown update argument." >&2
    echo "Got: $OUTPUT" >&2
    exit 1
    ;;
esac

# Update flow: repository update runs BEFORE the internal engine, and the
# engine is invoked with the selected-image refresh (--pull). Exercised in
# an isolated tree with git and the engine stubbed.
WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE/ops/deploy" "$TREE/.git" "$WORK_DIR/bin"
cp "$REPO_ROOT/ops/deploy/update.sh" "$TREE/ops/deploy/update.sh"
CALL_LOG="$WORK_DIR/calls.log"
export CALL_LOG
cat > "$TREE/ops/deploy/deploy.sh" <<'EOF'
#!/usr/bin/env bash
echo "deploy $*" >> "$CALL_LOG"
EOF
chmod +x "$TREE/ops/deploy/deploy.sh"
cat > "$WORK_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$CALL_LOG"
if [ "$1" = "rev-parse" ]; then echo "origin/main"; fi
exit 0
EOF
chmod +x "$WORK_DIR/bin/git"

PATH="$WORK_DIR/bin:$PATH" bash "$TREE/ops/deploy/update.sh" >/dev/null 2>&1 || {
  echo "update workflow failed against the stubbed tree" >&2
  exit 1
}
grep -q '^git pull --ff-only' "$CALL_LOG" || {
  echo "update must fast-forward the repository" >&2
  exit 1
}
grep -q -- '^deploy --pull' "$CALL_LOG" || {
  echo "update must invoke the internal engine with the image refresh (--pull)" >&2
  exit 1
}
git_line="$(grep -n '^git pull' "$CALL_LOG" | head -1 | cut -d: -f1)"
deploy_line="$(grep -n '^deploy' "$CALL_LOG" | head -1 | cut -d: -f1)"
if [ "$git_line" -ge "$deploy_line" ]; then
  echo "the repository update must happen before the engine runs" >&2
  exit 1
fi

# update clean resets to the upstream instead of merging local state.
: > "$CALL_LOG"
PATH="$WORK_DIR/bin:$PATH" bash "$TREE/ops/deploy/update.sh" clean >/dev/null 2>&1 || {
  echo "update clean failed against the stubbed tree" >&2
  exit 1
}
grep -q '^git fetch' "$CALL_LOG" || { echo "update clean must fetch" >&2; exit 1; }
grep -q '^git reset --hard' "$CALL_LOG" || { echo "update clean must hard-reset to upstream" >&2; exit 1; }
grep -q -- '^deploy --pull' "$CALL_LOG" || { echo "update clean must still refresh images" >&2; exit 1; }

echo "Update argument validation tests passed."
