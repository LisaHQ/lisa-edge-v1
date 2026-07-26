#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
PYTHON_BIN="${PYTHON_BIN:-python3}"

FIX_EXEC_BITS=0
for arg in "$@"; do
  case "$arg" in
    --fix)
      FIX_EXEC_BITS=1
      ;;
    *)
      echo "Usage: tools/validate-repo.sh [--fix]" >&2
      echo "  --fix  set the executable bit in the git index for tracked scripts" >&2
      exit 2
      ;;
  esac
done

echo "Checking executable bits in git index..."
# The repo is authored on Windows (core.fileMode=false), so scripts staged
# without an explicit +x end up as 100644 in the index. On deployed hosts
# bootstrap.sh chmods everything +x, producing permanent mode-only diffs that
# make `lisa-edge update` (git pull --ff-only) abort.
missing_exec=()
while IFS=$'\t' read -r meta path; do
  [[ "${meta%% *}" == "100755" ]] || missing_exec+=("$path")
done < <(git ls-files -s -- lisa-edge '*.sh')
if (( ${#missing_exec[@]} > 0 )); then
  if (( FIX_EXEC_BITS )); then
    for path in "${missing_exec[@]}"; do
      git update-index --chmod=+x -- "$path"
      echo "  set +x: $path"
    done
    echo "Executable bit set on ${#missing_exec[@]} file(s) in the index; commit the mode change."
  else
    printf '  missing +x in index: %s\n' "${missing_exec[@]}" >&2
    echo "Tracked scripts must carry the executable bit in the git index," >&2
    echo "or 'lisa-edge update' breaks on deployed hosts." >&2
    echo "Fix with: tools/validate-repo.sh --fix   (or: git add --chmod=+x <file>)" >&2
    exit 1
  fi
fi

echo "Checking canonical layout and compatibility contracts..."
bash "$REPO_ROOT/tests/structure/test-layout.sh"
bash "$REPO_ROOT/tests/structure/test-repo-root-resolution.sh"

echo "Checking Bash syntax..."
bash -n "$REPO_ROOT/lisa-edge"
syntax_roots=(
  install ops rescue services lib tools tests
)
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "${syntax_roots[@]}" -type f -name '*.sh' -print0)

echo "Checking stale file references..."
if grep -RInE --exclude='validate-repo.sh' --exclude='test-layout.sh' \
  '\.env\.example|40-mosquitto-defaults\.sh|docs/getting-started/deployment-validation\.md|sync-thread-dataset\.sh|matter sync-dataset' \
  README.md docs install ops rescue services lib tools tests
then
  echo "Stale file reference found." >&2
  exit 1
fi

echo "Checking removed operator commands stay removed..."
# configure, bootstrap, deploy, and stop are no longer root commands; no
# documentation, hint, or example may recommend them (internal paths such
# as ops/deploy/deploy.sh are different strings and stay valid).
if grep -RInE --exclude='validate-repo.sh' --exclude='test-root-cli.sh' \
  --exclude='test-restore-args.sh' --exclude-dir=archive \
  'lisa-edge (configure|bootstrap|deploy)\b|lisa-edge stop($|[^a-z-])|lisa-edge-provision (configure|bootstrap|deploy)\b' \
  README.md CLAUDE.md docs install ops rescue services lib tools tests
then
  echo "A removed root command is still referenced." >&2
  exit 1
fi
if grep -RInE --exclude='validate-repo.sh' --exclude='test-root-cli.sh' \
  --exclude='test-restore-args.sh' --exclude-dir=archive \
  'restore (--deploy|--no-deploy)|--no-deploy' \
  README.md CLAUDE.md docs install ops rescue services lib tools tests
then
  echo "The obsolete restore deploy options are still referenced." >&2
  exit 1
fi
if grep -RInE 'MATTER_THREAD_CREDENTIAL_ID=' .env.template install ops; then
  echo "MATTER_THREAD_CREDENTIAL_ID must not return as a configuration concept." >&2
  exit 1
fi
if grep -RInE \
  '(\$REPO_ROOT/|bash[[:space:]]+)test/(unit|security|integration)/' \
  tools .github
then
  echo "CI or tools still invoke the deprecated test/ tree." >&2
  exit 1
fi

echo "Checking Docker Compose configurations..."
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env.template}" \
  bash "$REPO_ROOT/tools/validate-compose.sh"

echo "Checking Thread dataset helpers..."
bash "$REPO_ROOT/tests/unit/test-thread-dataset-lib.sh"

echo "Checking service-specific configuration validation..."
bash "$REPO_ROOT/tests/unit/test-service-config.sh"

echo "Checking OTBR CLI..."
bash "$REPO_ROOT/tests/unit/test-otbr-cli.sh"

echo "Checking OTBR network creation flow..."
bash "$REPO_ROOT/tests/unit/test-otbr-network-create.sh"

echo "Checking OTBR image resolver..."
bash "$REPO_ROOT/tests/unit/test-otbr-image-resolver.sh"

echo "Checking Matter WebSocket client..."
bash "$REPO_ROOT/tests/unit/test-matter-ws-client.sh"

echo "Checking Matter CLI..."
bash "$REPO_ROOT/tests/unit/test-matter-cli.sh"

echo "Checking health outcome modes..."
bash "$REPO_ROOT/tests/unit/test-health-modes.sh"

echo "Checking service selection and image policy..."
bash "$REPO_ROOT/tests/unit/test-service-selection.sh"
bash "$REPO_ROOT/tests/unit/test-image-policy.sh"

echo "Checking the service list statuses..."
bash "$REPO_ROOT/tests/unit/test-service-list.sh"

echo "Checking zero-service runtime behavior..."
bash "$REPO_ROOT/tests/unit/test-zero-services.sh"

echo "Checking root CLI command model..."
bash "$REPO_ROOT/tests/unit/test-root-cli.sh"

echo "Checking the shared Thread check-and-sync path..."
bash "$REPO_ROOT/tests/unit/test-thread-sync.sh"

echo "Checking the setup menu actions..."
bash "$REPO_ROOT/tests/unit/test-setup-menu.sh"

echo "Checking the service lifecycle..."
bash "$REPO_ROOT/tests/unit/test-service-lifecycle.sh"

echo "Checking restore argument validation..."
bash "$REPO_ROOT/tests/unit/test-restore-args.sh"

echo "Checking update argument validation..."
bash "$REPO_ROOT/tests/unit/test-update-args.sh"

echo "Checking reset CLI contract..."
bash "$REPO_ROOT/tests/unit/test-reset-cli.sh"

echo "Checking provisioning wizard..."
bash "$REPO_ROOT/tests/unit/test-provisioning-wizard.sh"

echo "Checking OTBR dataset selection helpers..."
bash "$REPO_ROOT/tests/unit/test-otbr-dataset-selection.sh"

echo "Checking Matter data selection helpers..."
bash "$REPO_ROOT/tests/unit/test-matter-data-selection.sh"

echo "Checking USB release config..."
bash "$REPO_ROOT/tests/unit/test-usb-release-config.sh"

echo "Checking backup archive validation..."
"$PYTHON_BIN" "$REPO_ROOT/tests/security/test-backup-validation.py"
bash "$REPO_ROOT/tests/security/test-backup-checksum.sh"
bash "$REPO_ROOT/tests/security/test-backup-mount-guard.sh"
bash "$REPO_ROOT/tests/security/test-path-safety.sh"
bash "$REPO_ROOT/tests/security/test-restore-target-root.sh"
bash "$REPO_ROOT/tests/security/test-usb-device-guard.sh"
bash "$REPO_ROOT/tests/security/test-dataset-secret-safety.sh"

echo "Checking security audit and hardening..."
bash "$REPO_ROOT/tests/security/test-security-audit.sh"

echo "Checking passwordless sudo reconciliation..."
bash "$REPO_ROOT/tests/security/test-sudo-reconcile.sh"

echo "Checking Rescue OS path guardrails..."
bash "$REPO_ROOT/tests/security/test-recovery-safety.sh"

echo "Checking reset safety guardrails..."
bash "$REPO_ROOT/tests/security/test-reset-safety.sh"

echo "Checking v2 and v3 restore integration..."
PYTHON_BIN="$PYTHON_BIN" \
  bash "$REPO_ROOT/tests/integration/test-restore-integration.sh"

echo "Checking reset mode integration..."
bash "$REPO_ROOT/tests/integration/test-reset-modes.sh"

echo "Repository validation passed."
