# Repository Map

This is the maintainer's reference for every folder and file in the
repository: what it does, when to touch it, and which `lisa-edge` command
uses it. Operators normally never need this map — they use:

```bash
./lisa-edge help
```

For task-oriented guides, start at [docs/README.md](../README.md).

## CLI command → implementation

| Command | Implementation |
| --- | --- |
| `lisa-edge setup` (all menu actions) | `install/provisioning/lisa-first-boot.sh` |
| setup: bootstrap/repair (internal) | `install/bootstrap/bootstrap.sh` |
| `lisa-edge usb list` | `install/usb/scripts/build/build-ubuntu-usb.sh` (list mode) |
| `lisa-edge usb build <profile>` | `install/usb/scripts/build/build-ubuntu-usb.sh` |
| `lisa-edge usb prepare production` | `install/usb/scripts/prepare/prepare-production-usb.sh` |
| `lisa-edge usb prepare rescue` | `install/usb/scripts/prepare/prepare-rescue-usb.sh` |
| `lisa-edge update` / `health` / `status` | `ops/deploy/*.sh` |
| internal deployment engine (systemd ExecStart) | `ops/deploy/deploy.sh` |
| internal stack stop (systemd ExecStop) | `ops/deploy/stop.sh` |
| `lisa-edge reset data` / `provisioning` / `factory` | `ops/deploy/reset-node.sh` |
| `lisa-edge diagnostics` | `ops/diagnostics/collect-diag.sh` |
| `lisa-edge backup` / `restore` | `ops/backup-restore/*.sh` |
| `lisa-edge service list` | `services/list.sh` |
| `lisa-edge service add/remove/start/stop` | `services/lifecycle.sh` |
| `lisa-edge security audit` / `harden` | `ops/security/audit.sh`, `ops/security/harden.sh` |
| internal Thread check-and-sync | `services/matter-server/thread-sync-if-needed.sh` |
| `lisa-edge rescue <subcommand>` | `rescue/scripts/*.sh` |

## Root

| Path | Purpose |
| --- | --- |
| `lisa-edge` | The single operator CLI. Resolves the repo root (also through symlinks such as `/usr/local/sbin/lisa-edge-provision`, which first boot uses to run `setup`) and dispatches every command to its canonical script. No implementation logic lives here. |
| `lisa-edge.cmd` | Windows day-0 companion CLI: `usb list`, `usb build`, `usb prepare`, and `config` from a workstation before any server exists; dispatches to the canonical scripts under `install/usb/`. Runtime commands stay on the Linux host. |
| `README.md` | One-screen task map: command table, fastest install, capabilities, repository map, safety rules. |
| `.env.template` | Documented template for the runtime `.env`. The wizard writes `.env` from prompts; never put real secrets in the template. |
| `.editorconfig` | Editor defaults. LF for everything; CRLF only for `.bat`/`.cmd`/`.ps1`. Do not change the LF default — CRLF breaks scripts, YAML, and systemd units on Linux hosts. |
| `.gitattributes` | Enforces the same line-ending contract in Git (`* text=auto eol=lf` plus explicit per-type rules). |
| `.gitignore` | Ignores runtime `.env`, generated `user-data`, key material, `secrets/*` (except its README), and the local `_to_delete/` staging area. |
| `LICENSE` | Apache 2.0. |
| `.github/workflows/validate.yml` | CI: runs `tools/validate-repo.sh` on every push and pull request. |

## install/ — getting a host into existence

### install/usb/ — installation media

| Path | Purpose |
| --- | --- |
| `config/ubuntu-releases.json` | Ubuntu series, mirror, and optional `iso`/`sha256` pin used by the build pipeline. |
| `config/production/user-data.template` | Ubuntu autoinstall seed for the production SSD install. Disk is matched by serial; placeholders are filled by `generate-user-data.ps1` or by hand into `user-data` (gitignored). Clones the repo to `/opt/lisa-edge` and installs the first-boot service. |
| `config/production/meta-data`, `grub.cfg` | Cloud-init NoCloud identity stub and USB boot menu. |
| `config/rescue/user-data.template` | Autoinstall seed for the eMMC Rescue OS: minimal Ubuntu, SSH keys only, clones the repo and runs `lisa-edge rescue bootstrap`. |
| `scripts/build/build-ubuntu-usb.sh` / `.cmd` | Full pipeline behind `lisa-edge usb build`: fetch + verify the Ubuntu ISO, write a bootable UEFI USB (replaces Rufus), inject the profile. |
| `scripts/build/platform/linux/`, `windows/` | Platform steps: `fetch-ubuntu-iso.*` (download, SHA256 verify, cache) and `create-usb-disk.*` (fail-closed USB erase + FAT32 + ISO copy). |
| `scripts/prepare/prepare-production-usb.sh` / `.cmd` | Inject the production autoinstall profile onto a mounted installer USB. Called by `lisa-edge usb prepare production`. |
| `scripts/prepare/prepare-rescue-usb.sh` / `.cmd` | Inject the rescue autoinstall profile. Called by `lisa-edge usb prepare rescue`. |
| `scripts/prepare/generate-user-data.ps1` | Windows helper that renders `user-data` from the template and your answers. |

### install/provisioning/ — first boot and reconfiguration

| Path | Purpose |
| --- | --- |
| `lisa-first-boot.sh` | The interactive wizard behind `setup` and `configure`. Fresh setup, restore-first setup, or `--mode config-only`; supports `--dry-run`. Writes `.env`, asks per-service questions via each `services/<service>/provision.sh`, then offers bootstrap + deploy. |
| `lib/ui.sh` | Prompt and validation helpers for the wizard (bind addresses, ports, persistent paths). |
| `notify-first-boot.sh` | Installs an MOTD notice telling the admin to run `sudo lisa-edge-provision` on an unprovisioned host. |
| `systemd/lisa-first-boot.service` | First-boot unit on autoinstalled hosts: runs `notify-first-boot.sh` to show the MOTD notice until the host is provisioned; the operator then runs `sudo lisa-edge-provision`. |

### install/bootstrap/ — host preparation

| Path | Purpose |
| --- | --- |
| `bootstrap.sh` | Idempotent internal host bootstrap (invoked by the setup workflows and first-boot provisioning): runs every phase, seeds `.env` if missing, installs systemd units, starts services through the internal deployment engine. |
| `phases/00-base-packages.sh` | Base OS packages (curl, git, and friends). |
| `phases/10-security.sh` | Host hardening (SSH policy, firewall baseline). |
| `phases/20-docker.sh` | Docker Engine and Compose installation. |
| `phases/30-directories.sh` | `${DATA_ROOT}` layout and permissions. |
| `phases/40-core-service-prep.sh` | Chrony time sync, plus Thread/OTBR host preparation (Avahi, IPv6/forwarding sysctl) when OTBR is selected. |
| `phases/50-backup-tools.sh` | Installs backup tooling (rsync, restic); the backup timer units are installed by `ops/deploy/install-systemd.sh`. |
| `finalize-admin-access.sh` | Final admin-access lockdown after provisioning is verified. |

## ops/ — running the node

### ops/deploy/

| Path | Purpose |
| --- | --- |
| `compose.yml` | Base Docker Compose file. Service fragments from `services/<service>/compose.yml` are layered on top per the selection in `.env`. |
| `deploy.sh` | Start or reconcile the selected stack (`--pull`, `--offline`). |
| `stop.sh` | Stop the stack. |
| `update.sh` | Fast-forward the repo and refresh pinned images. |
| `healthcheck.sh` | Readiness checks for host and selected services. |
| `status.sh` | Show selection and runtime state. |
| `install-systemd.sh` | Install/refresh the runtime unit below. |
| `systemd/lisa-edge.service` | Boot-time unit that brings the stack up. |
| `reset-node.sh` | The canonical reset lifecycle behind `lisa-edge reset` (modes: `data`, `provisioning`, `factory`): mode-specific plans, exact confirmation phrases, `--dry-run`, project-scoped Docker cleanup, mount/path fail-closed guards. See [ops/deploy/README.md](../../ops/deploy/README.md#reset-lifecycle). |

### ops/backup-restore/

| Path | Purpose |
| --- | --- |
| `backup.sh` | Creates format-v3 archives (`.env` + `${DATA_ROOT}` members + OTBR datasets), stops/restarts the stack around the tar, writes `.sha256` and `.manifest.json` sidecars, applies retention. |
| `restore.sh` | Validates and restores an archive. Detects v3 and legacy v2. `--deploy` for live hosts, `--target-root` for Rescue OS restores into a mounted production root. |
| `lib/backup.sh` | Checksum verification and validated-env read helpers. |
| `lib/validate_backup.py` | Archive inspector: member allowlist, path-traversal defense, `.env` schema check against `.env.template`. |
| `systemd/lisa-edge-backup.service` / `.timer` | Scheduled backups. |

### ops/diagnostics/

| Path | Purpose |
| --- | --- |
| `collect-diag.sh` | Builds a diagnostics bundle (host facts, service state, logs) for troubleshooting. |

## services/ — one vertical slice per deployable service

| Path | Purpose |
| --- | --- |
| `registry.sh` | The single service catalog: selection keys, aliases, directory mapping, dependencies (for example zigbee2mqtt → mqtt), image variables/repositories/release-tag filters. Add a service here first. |
| `list.sh` | Implements `lisa-edge service list`. |
| `image-advisories.tsv` | Git-managed image advisory catalog (`known-issue`/`blocked` records shown by the image-selection menu). |
| `<service>/compose.yml` | The service's Compose fragment, layered onto `ops/deploy/compose.yml` when selected. |
| `<service>/provision.sh` | The service's section of the setup wizard (its `.env` questions and defaults). |
| `<service>/prepare.sh` | Host-side preparation when needed (for example MQTT password file). |
| `<service>/config/` | Static configuration shipped to the host (for example `mqtt/config/mosquitto.conf`). |
| `<service>/README.md` | Service-specific operational notes. |

Current slices: `mqtt`, `uptime-kuma`, `home-assistant`, `matter-server`, `otbr`,
`zigbee2mqtt`, `node-red`, `tailscale`.

`otbr/dataset/` protects the Thread network dataset: `show.sh` (redacted
summary / `--show-secret`), `export.sh` (0600 secret export), `backup.sh`
(checksum + metadata sidecars), `restore.sh` (validated, confirmed network
replacement), `init-or-restore.sh` (deploy-time decisions), and a systemd
service/timer pair that snapshots the dataset alongside regular backups.
`otbr/status.sh` implements `lisa-edge otbr status` and
`otbr/network-create.sh` implements `lisa-edge otbr network create`.

`matter-server/` additionally owns `status.sh`, `credentials.sh`,
`thread.sh` (`matter thread status|sync|remove`), `lib/ws.sh` +
`lib/ws-client.js` (the shared Matter WebSocket client), the optional
compose slices `compose.ble.yml` / `compose.primary-interface.yml`, and
`data/` (backup/restore/reset with checksum sidecars).
`ops/diagnostics/doctor-matter-thread.sh` implements
`lisa-edge doctor matter-thread`, and `lib/service-config.sh` validates the
Matter/Thread configuration before deploy.

## rescue/ — the independent eMMC Rescue OS

| Path | Purpose |
| --- | --- |
| `scripts/bootstrap.sh` | Installs rescue tooling to `/opt/lisa-rescue` (`rescue bootstrap`). |
| `scripts/detect-disks.sh` | Inspect disks and installation candidates (`rescue disks`). |
| `scripts/diagnostics.sh` | Rescue-host diagnostics (`rescue doctor`). |
| `scripts/install-diagnostics-timer.sh` | Enables the periodic rescue diagnostics timer. |
| `scripts/mount-production.sh` | Safely mounts the production filesystem below `/mnt` (`rescue mount`). |
| `scripts/recovery-safety.sh` | Shared guard library: exact-mountpoint checks, path validation, overlap refusal. Sourced by the restore scripts. |
| `scripts/restore-edge-backup.sh` | `rescue restore-backup`: validates the mount, then delegates to `lisa-edge restore --target-root`. Use this for normal archives. |
| `scripts/restore-filesystem-snapshot.sh` | `rescue restore-snapshot`: rsync a raw filesystem snapshot. Only for separately maintained snapshots, never for `.tar.gz` archives. |
| `scripts/reinstall-guide.sh` | Non-destructive, human-guided production reinstall procedure (`rescue reinstall`). |
| `scripts/update-rescue-scripts.sh` | Refreshes `/opt/lisa-rescue` from Git (`rescue update`). |
| `systemd/lisa-rescue-diagnostics.service` / `.timer` | Periodic rescue diagnostics. |

## lib/ — shared shell libraries

| Path | Purpose |
| --- | --- |
| `compose.sh` | Service selection resolution (`LISA_COMPOSE_SERVICES`), dependency validation, Compose file-list construction. |
| `images.sh` | Image pinning/policy helpers, the Git-managed image advisory catalog (`services/image-advisories.tsv`), remote release-tag discovery (Docker Hub/GHCR, bounded), and the shared interactive image-selection menu. |
| `paths.sh` | Persistent-path safety: traversal/symlink validation, mounted-destination verification. |

## tools/ — developer and build utilities

| Path | Purpose |
| --- | --- |
| `validate-repo.sh` | CI entrypoint: layout contract, Bash syntax, stale references, Compose rendering, all test suites. Run before every commit. |
| `validate-compose.sh` | Renders the base Compose file with every service fragment (requires Docker). |
| `build-usb.sh` | Copies production or rescue autoinstall assets from `install/usb/config/` into a build directory. |
| `disaster-recovery-check.sh` | Audits that recovery prerequisites (scripts, docs, timers) exist. |
| `generate-secrets.sh` | Prints candidate secret values to stdout; move them straight into secure storage. |
| `detect-disks.sh` | Developer disk-detection helper (host-side twin of the rescue script). |

## tests/ — the test suite (run via `tools/validate-repo.sh`)

| Path | Purpose |
| --- | --- |
| `structure/test-layout.sh` | Layout contract: canonical paths exist, service slices are complete, the CLI maps commands correctly, legacy paths never reappear. |
| `structure/test-repo-root-resolution.sh` | Every script resolves the repo root from its own location. |
| `unit/test-service-selection.sh` | Selection keys, aliases, dependency injection. |
| `unit/test-image-policy.sh` | Image pinning policy. |
| `unit/test-provisioning-wizard.sh` | Wizard flows in `--dry-run` (dependency auto-select, port-conflict rejection, input validation). |
| `security/test-backup-validation.py` | Archive validator: traversal, allowlist, env schema. |
| `security/test-backup-checksum.sh` | Checksum sidecar enforcement. |
| `security/test-backup-mount-guard.sh` | `BACKUP_REQUIRE_MOUNT` guard. |
| `security/test-path-safety.sh` | `lib/paths.sh` traversal and symlink defenses. |
| `security/test-restore-target-root.sh` | `--target-root` argument hardening. |
| `security/test-recovery-safety.sh` | Rescue mount/overlap guards. |
| `security/test-reset-safety.sh` | Reset guardrails: unsafe `DATA_ROOT`, traversal/symlink attacks, nested-mount fail-closed behavior, no global Docker prune, no disk tooling. |
| `unit/test-reset-cli.sh` | Reset CLI contract: help/usage, dispatch, unknown modes, `--dry-run` zero-mutation, exact confirmation phrases. |
| `lib/reset-harness.sh` | Shared fake-repo/stub harness for the reset tests. |
| `integration/test-restore-integration.sh` | Full backup→restore round-trips for v2 and v3 archives in temporary trees. |
| `integration/test-reset-modes.sh` | Full reset data/provisioning/factory flows against a stubbed fake repository. |

## docs/ — documentation

| Path | Purpose |
| --- | --- |
| `README.md` | Documentation index; start here. |
| `getting-started/01…06` | The linear path from empty hardware to a validated deployment (quick start, service selection, autoinstall, checklist, validation, first-boot provisioning). |
| `architecture/` | LISA ecosystem role, service boundaries, deployment patterns, reference deployment. |
| `hardware/` | Reference hardware and the eMMC/SSD storage model. |
| `networking/` | Network/VLAN model, UniFi firewall notes, Thread, Matter. |
| `security/` | Security model and secrets policy. |
| `services/` | Per-service operational documentation. |
| `operations/` | Diagnostics, backup/restore, disaster recovery, service-specific recovery. |
| `reference/` | This map and future reference material. |
| `planned/` | Designs for services that are not implemented (NUT, DNS, reverse proxy). Never deployment instructions. |
| `archive/` | Historical documents kept for context only. |
| `roadmap.md` | Direction and open work. |

## secrets/ — policy placeholder only

Documentation-only directory (`secrets/README.md`). Everything else under it
is gitignored and must never contain real credentials; production secrets
live outside the checkout or under `${DATA_ROOT}/secrets`.
