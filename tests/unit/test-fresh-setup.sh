#!/usr/bin/env bash
set -euo pipefail

# Fresh setup semantics: existing .env values prefill wizard defaults but
# never suppress a step, skip a service section, bypass image discovery, or
# get accepted without a prompt. Runs the complete wizard against an
# isolated repository copy; remote tag discovery is disabled so the menus
# exercise the offline fallback. config-only editing stays covered by
# tests/unit/test-setup-menu.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "FRESH SETUP TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(TMPDIR=/tmp mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TREE="$WORK_DIR/tree"
mkdir -p "$TREE"
cp -a "$REPO_ROOT/lisa-edge" "$REPO_ROOT/lib" "$REPO_ROOT/services" "$REPO_ROOT/ops" \
  "$REPO_ROOT/install" "$REPO_ROOT/.env.template" "$TREE/"

WIZARD="$TREE/install/provisioning/lisa-first-boot.sh"

# An existing configuration with deliberately non-template values, including
# a TAGGED (pinned release) image for every interesting service.
write_existing_env() {
  cat > "$TREE/.env" <<'EOF'
LISA_EDGE_HOSTNAME=custom-host-01
TZ=Europe/Berlin
DATA_ROOT=/srv/custom-edge
BACKUP_DEST=/srv/custom-edge/backups
LISA_COMPOSE_SERVICES="mqtt matter otbr"
MQTT_USERNAME=customuser
MQTT_PASSWORD=custom-password-value
MQTT_PORT=2883
MQTT_IMAGE=eclipse-mosquitto:2.0.15
MATTER_SERVER_IMAGE=ghcr.io/matter-js/matterjs-server:1.2.0
OTBR_IMAGE=openthread/border-router:v2026.04.0
THREAD_NETWORK_NAME=CUSTOM-MESH-01
MATTER_AUTO_RESTORE_DATA=0
OTBR_AUTO_RESTORE_DATASET=1
OTBR_AUTO_CREATE_NETWORK=1
EOF
}

# Enough blank lines to accept every default the wizard offers; unread
# leftovers are harmless.
blanks() {
  local count="$1" i
  for ((i = 0; i < count; i++)); do echo; done
}

run_fresh() {
  RUN_RC=0
  RUN_OUTPUT="$(LISA_EDGE_TESTING=1 LISA_IMAGE_QUERY_DISABLE=1 \
    bash "$WIZARD" --mode fresh --dry-run 2>&1)" || RUN_RC=$?
}

# --- 1+2: fresh inherits .env values as defaults AND traverses every step ----
write_existing_env
run_fresh < <(blanks 60)
[ "$RUN_RC" -eq 0 ] || fail "fresh dry-run failed: $RUN_OUTPUT"

# Every applicable wizard section must be shown, whatever the current
# configuration looks like.
for section in \
  '--- Host and storage wizard ---' \
  '--- MQTT wizard ---' \
  '--- MQTT (Mosquitto) container image ---' \
  '--- Matter Server wizard ---' \
  '--- Matter data: one-shot action for the NEXT deploy ---' \
  '--- Future Matter recovery policy ---' \
  '--- Matter Server container image ---' \
  '--- OpenThread Border Router wizard ---' \
  '--- OTBR Thread dataset: one-shot action for the NEXT deploy ---' \
  '--- Future OTBR recovery policy ---' \
  '--- OpenThread Border Router container image ---' \
  '--- Selected container images ---' \
  ' Setup summary'
do
  grep -qF -- "$section" <<<"$RUN_OUTPUT" ||
    fail "fresh setup must always show: $section"
done

# Inherited values survive an all-defaults run (they prefill the prompts).
grep -q 'hostname: custom-host-01' <<<"$RUN_OUTPUT" ||
  fail "the existing hostname must be the accepted default"
grep -q 'data root: /srv/custom-edge' <<<"$RUN_OUTPUT" ||
  fail "the existing data root must be the accepted default"
grep -q 'services: mqtt matter otbr' <<<"$RUN_OUTPUT" ||
  fail "the existing service selection must be the accepted default"

# --- 3: tagged/pinned images do not suppress the numbered image menu ---------
grep -qE '[0-9]+\) eclipse-mosquitto:2.0.15 \[current\]' <<<"$RUN_OUTPUT" ||
  fail "a tagged current MQTT image must still be listed in a numbered menu"
grep -qE '[0-9]+\) ghcr.io/matter-js/matterjs-server:1.2.0 \[current\]' <<<"$RUN_OUTPUT" ||
  fail "a tagged current Matter image must still be listed in a numbered menu"
grep -qE '[0-9]+\) openthread/border-router:v2026.04.0 \[current\]' <<<"$RUN_OUTPUT" ||
  fail "a tagged current OTBR image must still be listed in a numbered menu"
# Matter must have a real version menu including the advisory-annotated
# candidate from the Git-managed catalog.
grep -qE '[0-9]+\) ghcr.io/matter-js/matterjs-server:1.3.1 \[known-issue\]' <<<"$RUN_OUTPUT" ||
  fail "the Matter menu must include and annotate the cataloged known-issue image"
grep -q 'BLE commissioning regression observed by LISA Edge' <<<"$RUN_OUTPUT" ||
  fail "the advisory note must be shown in the Matter menu"
# All-defaults keeps the tagged images.
grep -q 'Selected MQTT (Mosquitto) image: eclipse-mosquitto:2.0.15' <<<"$RUN_OUTPUT" ||
  fail "Enter must keep the current tagged MQTT image"
grep -q 'Selected Matter Server image: ghcr.io/matter-js/matterjs-server:1.2.0' <<<"$RUN_OUTPUT" ||
  fail "Enter must keep the current tagged Matter image"

# One-shot actions and persistent policies are reported separately.
grep -q 'Next Matter deploy action:  none' <<<"$RUN_OUTPUT" ||
  fail "the summary must report the Matter one-shot action"
grep -q 'Future empty-store policy:  never restore automatically' <<<"$RUN_OUTPUT" ||
  fail "the summary must report the inherited Matter recovery policy"
grep -q 'Next OTBR deploy action:    none' <<<"$RUN_OUTPUT" ||
  fail "the summary must report the OTBR one-shot action"
grep -q 'Future empty-dataset policy: restore latest backup; create a new network only when no backup exists' <<<"$RUN_OUTPUT" ||
  fail "the summary must report the inherited OTBR recovery policy"

# --- 4: every inherited default can be replaced ------------------------------
# Selecting only mqtt and answering the prompts explicitly. Input order:
# hostname, TZ, data root, backup dest, require-mount, retention,
# healthcheck, pinned, admin user, sudo, service selection, mqtt wizard
# (user, password[secret], bind, port, ws port), mqtt image (custom).
write_existing_env
RUN_RC=0
RUN_OUTPUT="$(LISA_EDGE_TESTING=1 LISA_IMAGE_QUERY_DISABLE=1 \
  bash "$WIZARD" --mode fresh --dry-run 2>&1 <<'EOF'
replacement-host
America/Chicago
/srv/replacement-edge
/srv/replacement-edge/backups
no
7
auto
no
lisa
no
mqtt
newuser
new-password-value
127.0.0.1
3883
9001
eclipse-mosquitto:2.0.22
EOF
)" || RUN_RC=$?
[ "$RUN_RC" -eq 0 ] || fail "fresh dry-run with replacements failed: $RUN_OUTPUT"
grep -q 'hostname: replacement-host' <<<"$RUN_OUTPUT" ||
  fail "the operator must be able to replace the inherited hostname"
grep -q 'data root: /srv/replacement-edge' <<<"$RUN_OUTPUT" ||
  fail "the operator must be able to replace the inherited data root"
grep -q 'services: mqtt$' <<<"$RUN_OUTPUT" ||
  fail "the operator must be able to replace the inherited service selection"
grep -q 'Selected MQTT (Mosquitto) image: eclipse-mosquitto:2.0.22' <<<"$RUN_OUTPUT" ||
  fail "the operator must be able to replace the inherited image"

# --- fresh with no existing .env falls back to template defaults -------------
rm -f "$TREE/.env"
run_fresh < <(blanks 30)
[ "$RUN_RC" -eq 0 ] || fail "fresh dry-run without .env failed: $RUN_OUTPUT"
grep -q 'hostname: lisa-edge-01' <<<"$RUN_OUTPUT" ||
  fail "without .env the template hostname must be the default"
grep -q 'services: (none)' <<<"$RUN_OUTPUT" ||
  fail "without .env the template's empty service selection must be preserved"

echo "Fresh setup tests passed."
