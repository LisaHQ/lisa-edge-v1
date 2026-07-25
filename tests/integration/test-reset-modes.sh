#!/usr/bin/env bash
set -euo pipefail

# Reset lifecycle behavior in an isolated fake repository: reset data
# (success and failed redeploy), reset provisioning, and reset factory on
# both the Production OS and the Rescue Layer. Docker, systemctl and
# findmnt are PATH shims; deploy and directory preparation are stub
# scripts. No live host state is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "RESET MODES TEST ERROR: $*" >&2
  exit 1
}

# shellcheck disable=SC1091
. "$REPO_ROOT/tests/lib/reset-harness.sh"

log_line_number() {
  grep -Fn -- "$1" "$LOG" | head -n 1 | cut -d: -f1
}

# ===========================================================================
# reset data: successful run
# ===========================================================================
reset_harness_init
reset_harness_seed_provisioned_host
touch "$STATE/leftover-container"   # one orphan survives compose down

run_reset --stdin 'RESET DATA' -- data
[ "$RC" -eq 0 ] || fail "reset data must succeed, got rc=$RC: $OUTPUT"

# 11 + 12. .env, wizard backups and local backups are preserved.
[ -f "$FAKE_REPO/.env" ] || fail "reset data must preserve .env"
[ -f "$FAKE_REPO/.env.before-wizard-20260101-000000" ] ||
  fail "reset data must preserve .env.before-wizard-*"
[ -f "$DATAROOT/backups/lisa-edge-backup-1.tar.gz" ] ||
  fail "reset data must preserve local backups"
[ -f "$DATAROOT/backups/otbr/latest.dataset.hex" ] ||
  fail "reset data must preserve dataset backups under BACKUP root"
[ -f "$EXTERNAL_BACKUPS/lisa-edge-backup-external.tar.gz" ] ||
  fail "reset data must preserve external backups"
[ -f "$STATE_DIR/provisioned" ] || fail "reset data must preserve the provision marker"

# 13. runtime data and generated secrets are gone.
[ ! -e "$DATAROOT/docker/volumes/matter-server/fabric.json" ] ||
  fail "reset data must remove the Matter fabric state"
[ ! -e "$DATAROOT/docker/volumes/otbr/settings.dat" ] ||
  fail "reset data must remove live OTBR state"
[ ! -e "$DATAROOT/docker/volumes/mosquitto/config/passwords" ] ||
  fail "reset data must remove the generated MQTT password file"
[ ! -e "$DATAROOT/data/tailscale/tailscaled.state" ] ||
  fail "reset data must remove Tailscale runtime state"
[ ! -e "$DATAROOT/secrets/generated.token" ] ||
  fail "reset data must remove generated secrets"
[ ! -e "$DATAROOT/logs/service.log" ] || fail "reset data must remove runtime logs"
[ ! -e "$DATAROOT/state/marker" ] || fail "reset data must remove generated state"

# 14. timers are stopped before deletion (and before compose down).
stop_line="$(log_line_number 'systemctl stop lisa-edge-backup.timer')"
down_line="$(log_line_number ' down --volumes --remove-orphans')"
[ -n "$stop_line" ] || fail "reset data must stop the backup timer"
[ -n "$down_line" ] || fail "reset data must run compose down --volumes --remove-orphans"
[ "$stop_line" -lt "$down_line" ] || fail "timers must stop before Docker teardown"
log_contains 'systemctl stop lisa-otbr-dataset-backup.timer' ||
  fail "reset data must stop the OTBR backup timer"
log_contains 'systemctl stop lisa-matter-data-backup.timer' ||
  fail "reset data must stop the Matter backup timer"
log_contains 'systemctl stop lisa-edge.service' ||
  fail "reset data must stop the production runtime service"

# redeploy went through the normal path.
log_contains '30-directories.sh' || fail "reset data must recreate the directory layout"
log_contains 'deploy.sh' || fail "reset data must redeploy services"
deploy_line="$(log_line_number 'deploy.sh')"

# 15. only appropriate timers restart, and only after the deploy.
enable_line="$(log_line_number 'systemctl enable --now lisa-edge-backup.timer')"
[ -n "$enable_line" ] || fail "reset data must restore the backup timer after deploy"
[ "$deploy_line" -lt "$enable_line" ] || fail "timers must restart only after the deploy"
log_lacks 'systemctl enable --now lisa-otbr-dataset-backup.timer' ||
  fail "OTBR timer must not be enabled when OTBR is not selected"
log_lacks 'systemctl enable --now lisa-matter-data-backup.timer' ||
  fail "Matter timer must not be enabled when Matter is not selected"

# 23-25. Docker cleanup is project-scoped, spares images/build cache, never
# uses a global prune.
log_contains 'docker compose --env-file .env' || fail "compose teardown must use the env file"
log_contains '--filter label=com.docker.compose.project=lisa-edge' ||
  fail "leftover checks must be scoped to the effective Compose project"
log_contains 'docker rm -f cid123' || fail "project-owned leftover containers must be removed"
log_lacks ' prune' || fail "no docker prune command may ever run"
log_lacks 'docker rmi' || fail "docker images must not be deleted"
log_lacks 'docker image' || fail "docker images must not be touched"
log_lacks 'docker builder' || fail "docker build cache must not be touched"

# 26. Rescue Layer units stay untouched.
log_lacks 'lisa-rescue' || fail "reset data must never touch Rescue Layer units"
[ -f "$SYSTEMD_DIR/lisa-rescue-diagnostics.timer" ] ||
  fail "rescue timer unit file must survive reset data"

# unit files and symlinks survive reset data.
[ -f "$SYSTEMD_DIR/lisa-edge.service" ] || fail "reset data must keep installed units"
[ -L "$SBIN_DIR/lisa-edge" ] || fail "reset data must keep the lisa-edge symlink"
output_contains 'reset data completed' || fail "reset data must report success"

# ===========================================================================
# 16. reset data: failed redeploy leaves backup timers stopped
# ===========================================================================
reset_harness_init
reset_harness_seed_provisioned_host

run_reset --stdin 'RESET DATA' --env RESET_TEST_DEPLOY_RC=1 -- data
[ "$RC" -ne 0 ] || fail "reset data must fail when the redeploy fails"
log_contains 'deploy.sh' || fail "the redeploy must have been attempted"
log_lacks 'systemctl enable --now lisa-edge-backup.timer' ||
  fail "a failed redeploy must leave the backup timer stopped"
log_lacks 'systemctl start lisa-edge-backup.timer' ||
  fail "a failed redeploy must not start any backup timer"
output_contains 'redeploy FAILED' || fail "a failed redeploy must be reported clearly"
output_contains "sudo ./lisa-edge setup" || fail "the exact recovery command must be printed"
output_contains 'reset data completed' && fail "a failed redeploy must not claim success"

# ===========================================================================
# reset provisioning (external BACKUP_DEST)
# ===========================================================================
reset_harness_init
reset_harness_seed_provisioned_host "$EXTERNAL_BACKUPS"

run_reset --stdin 'RESET LISA' -- provisioning
[ "$RC" -eq 0 ] || fail "reset provisioning must succeed, got rc=$RC: $OUTPUT"

# 17. .env, .env.tmp and wizard backups are removed.
[ ! -e "$FAKE_REPO/.env" ] || fail "reset provisioning must remove .env"
[ ! -e "$FAKE_REPO/.env.tmp" ] || fail "reset provisioning must remove .env.tmp"
[ ! -e "$FAKE_REPO/.env.before-wizard-20260101-000000" ] ||
  fail "reset provisioning must remove .env.before-wizard-*"

# 18. local backups inside DATA_ROOT are removed; 10. external ones survive.
[ ! -e "$DATAROOT/backups" ] || fail "reset provisioning must remove local backups"
[ ! -e "$DATAROOT/secrets" ] || fail "reset provisioning must remove generated secrets"
[ ! -e "$DATAROOT/docker" ] || fail "reset provisioning must remove runtime data"
[ -f "$EXTERNAL_BACKUPS/lisa-edge-backup-external.tar.gz" ] ||
  fail "reset provisioning must preserve external backups"
output_contains "External backups preserved at: $EXTERNAL_BACKUPS" ||
  fail "reset provisioning must print the preserved external backup path"

# 19. provision marker removed; 20. production unit files and timers gone.
[ ! -e "$STATE_DIR/provisioned" ] || fail "reset provisioning must remove the provision marker"
for unit in lisa-edge.service lisa-edge-backup.service lisa-edge-backup.timer \
  lisa-otbr-dataset-backup.service lisa-otbr-dataset-backup.timer \
  lisa-matter-data-backup.service lisa-matter-data-backup.timer; do
  [ ! -e "$SYSTEMD_DIR/$unit" ] || fail "reset provisioning must remove $unit"
  log_contains "systemctl disable --now $unit" || fail "$unit must be disabled and stopped"
done

# 21. first-boot provisioning is restored with repo-local paths.
[ -f "$SYSTEMD_DIR/lisa-first-boot.service" ] ||
  fail "reset provisioning must install lisa-first-boot.service"
grep -Fq "$FAKE_REPO/install/provisioning/notify-first-boot.sh" \
  "$SYSTEMD_DIR/lisa-first-boot.service" ||
  fail "the first-boot unit must point at this checkout, not /opt/lisa-edge"
grep -Fq '/opt/lisa-edge' "$SYSTEMD_DIR/lisa-first-boot.service" &&
  fail "the installed first-boot unit must not keep /opt/lisa-edge literals"
log_contains 'systemctl daemon-reload' || fail "systemd must be reloaded"
log_contains 'systemctl enable lisa-first-boot.service' ||
  fail "lisa-first-boot.service must be enabled"
log_contains 'notify-first-boot.sh' || fail "the first-boot notice must be installed"
[ -L "$SBIN_DIR/lisa-edge-provision" ] || fail "lisa-edge-provision must exist"
[ "$(readlink -f "$SBIN_DIR/lisa-edge-provision")" = "$FAKE_REPO/lisa-edge" ] ||
  fail "lisa-edge-provision must point at this checkout's CLI"
[ ! -e "$SBIN_DIR/lisa-edge" ] ||
  fail "the provisioned-runtime lisa-edge symlink must be removed"

# 22. no deployment, no bootstrap, no new .env, timers stay gone.
log_lacks 'deploy.sh' || fail "reset provisioning must not deploy"
log_lacks '30-directories.sh' || fail "reset provisioning must not run bootstrap phases"
[ ! -e "$FAKE_REPO/.env" ] || fail "reset provisioning must not recreate .env"
log_lacks 'systemctl enable --now lisa-edge-backup.timer' ||
  fail "reset provisioning must not restart production timers"

# Docker cleanup remains project-scoped with no prune.
log_contains '--filter label=com.docker.compose.project=lisa-edge' ||
  fail "provisioning docker cleanup must be project-scoped"
log_lacks ' prune' || fail "no docker prune command may ever run"

# 26. Rescue Layer units stay untouched.
log_lacks 'lisa-rescue' || fail "reset provisioning must never touch Rescue Layer units"
[ -f "$SYSTEMD_DIR/lisa-rescue-diagnostics.service" ] ||
  fail "rescue service unit file must survive reset provisioning"

# required operator hand-back message.
output_contains 'LISA Edge has been reset to the unprovisioned state.' ||
  fail "reset provisioning must print the unprovisioned-state message"
output_contains 'Run: sudo lisa-edge-provision' ||
  fail "reset provisioning must tell the operator to run lisa-edge-provision"

# ===========================================================================
# reset provisioning works without .env (canonical/explicit fallback only)
# ===========================================================================
reset_harness_init
reset_harness_seed_provisioned_host
rm -f "$FAKE_REPO/.env"

run_reset --stdin 'RESET LISA' --env "DATA_ROOT=$DATAROOT" -- provisioning
[ "$RC" -eq 0 ] || fail "reset provisioning must work without .env, got rc=$RC: $OUTPUT"
[ ! -e "$DATAROOT/secrets" ] || fail "no-.env provisioning reset must still clean DATA_ROOT"
[ ! -e "$STATE_DIR/provisioned" ] || fail "no-.env provisioning reset must remove the marker"
output_contains 'LISA Edge has been reset to the unprovisioned state.' ||
  fail "no-.env provisioning reset must reach the unprovisioned state"

# ===========================================================================
# 27. reset factory from the Production OS never erases the running root
# ===========================================================================
reset_harness_init
reset_harness_seed_provisioned_host   # provision marker present => Production

run_reset --stdin 'RESET UBUNTU' -- factory
[ "$RC" -eq 0 ] || fail "factory handoff on Production must exit cleanly, got rc=$RC"
output_contains 'NO factory reset was performed.' ||
  fail "factory reset on Production must state that nothing happened"
output_contains 'Rescue Layer boot entry' ||
  fail "factory reset on Production must print the boot-into-rescue steps"
output_contains 'sudo ./lisa-edge reset factory' ||
  fail "factory reset on Production must tell the operator to rerun from Rescue"
[ -f "$FAKE_REPO/.env" ] || fail "factory reset on Production must not delete .env"
[ -f "$DATAROOT/secrets/generated.token" ] ||
  fail "factory reset on Production must not delete data"
log_lacks 'docker rm' || fail "factory reset on Production must not remove containers"
log_lacks ' down ' || fail "factory reset on Production must not stop the stack"
log_lacks 'systemctl stop' || fail "factory reset on Production must not stop units"
output_contains 'factory reset completed' &&
  fail "factory reset must never claim completion"

# ===========================================================================
# reset factory from the Rescue Layer: guarded handoff to the canonical
# reinstall procedure, with the exact confirmation phrase
# ===========================================================================
reset_harness_init
mkdir -p "$RESCUE_ROOT/scripts"
cat > "$RESCUE_ROOT/scripts/reinstall-guide.sh" <<'STUB'
#!/usr/bin/env bash
echo "rescue-reinstall-guide.sh" >> "$RESET_TEST_LOG"
echo "LISA Edge Production Reinstall Guide (rescue copy)"
STUB
chmod +x "$RESCUE_ROOT/scripts/reinstall-guide.sh"
# no provision marker: this host looks like the Rescue OS

run_reset --stdin 'wrong phrase' -- factory
[ "$RC" -ne 0 ] || fail "factory reset on Rescue must abort on a wrong phrase"
output_contains 'Aborted. No changes were made.' || fail "wrong phrase must abort cleanly"
log_lacks 'rescue-reinstall-guide.sh' || fail "an aborted factory reset must not run the guide"

run_reset --stdin 'RESET UBUNTU' -- factory
[ "$RC" -eq 0 ] || fail "factory handoff on Rescue must succeed, got rc=$RC: $OUTPUT"
log_contains 'rescue-reinstall-guide.sh' ||
  fail "factory reset on Rescue must run the canonical reinstall guide"
output_contains 'did NOT erase any disk' ||
  fail "factory reset must state that no disk was erased"
output_contains 'factory reset is complete only' ||
  fail "factory reset must explain when the reset is actually complete"

# 28. no disk is ever selected or wiped by the reset implementation itself:
# ambiguous/unsafe target selection is structurally impossible because the
# wipe is delegated to the serial-matched autoinstall workflow.
log_lacks 'dd ' || fail "factory reset must never invoke dd"
for tool in 'dd if=' mkfs wipefs sgdisk 'parted '; do
  grep -Fq -- "$tool" "$REPO_ROOT/ops/deploy/reset-node.sh" &&
    fail "reset-node.sh must not contain disk-wipe tooling: $tool"
done

echo "Reset mode integration tests passed."
