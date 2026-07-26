# LISA Edge

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/Automated%20Setup-Ubuntu%20%7C%20Debian-blue)
![Runtime](https://img.shields.io/badge/Runtime-Docker%20Compose-blue)

LISA Edge is the lightweight local-infrastructure layer of the **[LISA Ecosystem](docs/architecture/01-lisa-ecosystem.md)**.
It provides connectivity, messaging, monitoring, secure remote access, backup,
and recovery services. (AI reasoning, large storage, and video processing belong
on other LISA systems)

The stable operator interface is the root command:

```bash
./lisa-edge help
```

You should not need to know where an implementation script lives.

## Start by task

| I need to… | Command |
| --- | --- |
| Set up a new or restored host | `sudo ./lisa-edge setup` |
| Edit `.env` only, without applying it | `sudo ./lisa-edge setup` → *Edit configuration only* |
| Apply the current configuration (no update) | `sudo ./lisa-edge setup` → *Refresh services* |
| Bootstrap or repair an already configured host | `sudo ./lisa-edge setup` → *Bootstrap or repair* |
| Get and activate a newer LISA Edge version | `sudo ./lisa-edge update` |
| Discard local changes and update | `sudo ./lisa-edge update clean` |
| See runtime state | `sudo ./lisa-edge status` |
| Run readiness checks (HEALTHY/DEGRADED/FAILED) | `sudo ./lisa-edge health` |
| Fail on degradations too (monitoring) | `sudo ./lisa-edge health --strict` |
| List selectable services with their status | `./lisa-edge service list` |
| Add, configure, start, and verify one service (interactive menu when the key is omitted) | `sudo ./lisa-edge service add [service-key]` |
| Remove one service and its active data safely (interactive menu when the key is omitted) | `sudo ./lisa-edge service remove [service-key]` |
| Start selected services that are not running (interactive menu when no key is given) | `sudo ./lisa-edge service start [service-key ...]` |
| Stop running selected services (interactive menu when no key is given) | `sudo ./lisa-edge service stop [service-key ...]` |
| Inspect security posture (read-only) | `sudo ./lisa-edge security audit` |
| Apply bounded, lockout-safe hardening | `sudo ./lisa-edge security harden` |
| See OTBR / Thread state | `sudo ./lisa-edge otbr status` |
| Show the Thread dataset (secrets redacted) | `sudo ./lisa-edge otbr dataset show` |
| Export the Thread dataset to a 0600 file | `sudo ./lisa-edge otbr dataset export --output <file>` |
| Back up the Thread dataset | `sudo ./lisa-edge otbr dataset backup` |
| Restore a Thread dataset (replaces the network) | `sudo ./lisa-edge otbr dataset restore <file>` |
| Create a NEW Thread network | `sudo ./lisa-edge otbr network create` |
| See Matter server state | `sudo ./lisa-edge matter status` |
| List stored Thread credentials on Matter | `sudo ./lisa-edge matter credentials list` |
| Sync Thread credentials into Matter | `sudo ./lisa-edge matter thread sync` |
| Check OTBR vs Matter credential drift | `sudo ./lisa-edge matter thread status` |
| Reset the Matter fabric (re-commission!) | `sudo ./lisa-edge matter reset` |
| Diagnose Matter-over-Thread end to end | `sudo ./lisa-edge doctor matter-thread` |
| Create a backup | `sudo ./lisa-edge backup` |
| Restore a backup | `sudo ./lisa-edge restore <archive>` |
| Recreate services from clean data (keeps `.env`) | `sudo ./lisa-edge reset data` |
| Return the host to first-boot provisioning | `sudo ./lisa-edge reset provisioning` |
| Reinstall the Production OS via the Rescue Layer | `sudo ./lisa-edge reset factory` |
| Preview any reset without changing anything | `sudo ./lisa-edge reset <mode> --dry-run` |
| Collect diagnostics | `sudo ./lisa-edge diagnostics` |
| List removable/USB disks | `./lisa-edge usb list` |
| Build a full installer USB | `sudo ./lisa-edge usb build <profile>` |
| Prepare a production USB | `sudo ./lisa-edge usb prepare production <mount-path>` |
| Prepare a rescue USB | `sudo ./lisa-edge usb prepare rescue <mount-path>` |
| Work from the Rescue OS | `sudo ./lisa-edge rescue <command>` |

Run `./lisa-edge help` for the complete command map. The three reset modes
(clean data / clean LISA / clean Ubuntu) are compared in
[ops/deploy/README.md](ops/deploy/README.md#reset-lifecycle); each supports
`--dry-run` and requires an exact confirmation phrase.

## Fastest fresh install

The automated host bootstrap supports Ubuntu Server and Debian. Other Linux
distributions may run the Compose services, but their host preparation is a
manual, unsupported path today.

```bash
sudo git clone https://github.com/LisaHQ/lisa-edge.git /opt/lisa-edge
cd /opt/lisa-edge
sudo ./lisa-edge setup
sudo ./lisa-edge health
```

`setup` is the single interactive entry point: fresh setup, restore, editing
the configuration, refreshing services from the current configuration, and
host bootstrap/repair all live in its menu. A fresh setup writes `.env`, asks
for service-specific settings, bootstraps the host, and starts the selected
services through the internal deployment engine. When both Matter and OTBR
are selected and running, setup checks the Thread credential relationship and
offers to copy OTBR's active dataset into the Matter server's default
credential only when they do not already match.

For a production USB install or an existing backup, choose the matching path:

- [USB Autoinstall Flow](docs/getting-started/03-autoinstall-flow.md)
- [First-Boot and Restore Provisioning](docs/getting-started/06-first-boot-provisioning.md)

### Preparing media from Windows

Before any LISA Edge server exists, `lisa-edge.cmd` provides the same
command style for day-0 tasks from a Windows workstation:

```bat
lisa-edge usb list
lisa-edge usb build production
lisa-edge usb prepare production --auto-detect
lisa-edge usb prepare rescue E:
lisa-edge config
```

`usb build` downloads and verifies the Ubuntu Server ISO, writes a bootable
UEFI USB (no Rufus or other imaging tool needed), and injects the autoinstall
profile in one pass. When no disk number is given it lists the USB disks and
asks which one to use; `usb list` shows them on demand.

Runtime commands (`setup`, `update`, `service`, `backup`, ...) still run on
the Linux host via `./lisa-edge`.

## Current capabilities

Selectable services:

- MQTT
- Uptime Kuma
- Home Assistant
- Matter Server
- OpenThread Border Router
- Zigbee2MQTT
- Node-RED
- Tailscale

Zigbee2MQTT automatically selects MQTT. Chrony time synchronization, host
bootstrap, health checks, backup/restore, systemd runtime units, and rescue
tooling are host-level capabilities rather than selectable Compose services.

Planned but not selectable today:

- NUT / UPS integration
- DNS helpers
- reverse proxy

See [Service Selection](docs/getting-started/02-service-selection.md) for when to
enable each implemented service.

## Deployment model

The reference deployment uses:

| Storage | Role |
| --- | --- |
| eMMC | Minimal independent Rescue OS |
| SSD | Production OS, Docker, and persistent service data |
| NAS or external storage | Backups and restore media |

The architecture remains hardware-independent. The current reference platform
is a ZimaBoard 2, but a suitable Ubuntu or Debian host, VM, Raspberry Pi, NUC,
or mini PC can be used when its CPU architecture supports the selected images.

## Repository map

| Path | Go here when… |
| --- | --- |
| [`install/usb/`](install/usb/README.md) | preparing production or rescue installation media |
| [`install/provisioning/`](install/provisioning/README.md) | changing first-boot and site-specific setup |
| [`install/bootstrap/`](install/bootstrap/README.md) | changing host packages, hardening, Docker, or storage preparation |
| [`services/`](services/README.md) | changing one service's Compose, config, provisioning, or preparation |
| `ops/deploy/` | changing the internal deployment engine, update, health, status, or runtime systemd behavior |
| `ops/backup-restore/` | changing full-stack backup, restore, archive validation, or timers |
| `ops/diagnostics/` | changing production diagnostic collection |
| `ops/security/` | changing the security audit or the bounded hardening |
| [`rescue/`](rescue/README.md) | maintaining the independent Rescue OS and disaster-recovery tools |
| [`docs/`](docs/README.md) | understanding architecture, security, networking, or detailed procedures |
| [`tools/`](tools/README.md) | building assets or validating the repository |
| [`tests/`](tests/README.md) | running unit, security, and integration tests |

A file-by-file reference lives in
[docs/reference/repository-map.md](docs/reference/repository-map.md).

Former layouts (`scripts/`, `bootstrap/`, `provisioning/`, `usb-installer/`,
`recovery/`, `compose/`, `config/`, `systemd/`) have been removed. All
automation goes through the root CLI and the canonical paths above.

## Safety rules

- Autoinstall can erase a disk. Match the target by serial or an explicitly
  reviewed model; never guess a device name.
- Keep `.env` and runtime secrets outside Git and mode them `0600`.
- Treat backup archives as sensitive because they may contain credentials.
- Require checksum sidecars and review restored image references before deploy.
- Keep administration VPN-first and avoid public dashboards.
- Test restore, not just backup creation.

## Documentation

Start with:

1. [Quick Start](docs/getting-started/01-quick-start.md)
2. [Service Selection](docs/getting-started/02-service-selection.md)
3. [Deployment Checklist](docs/getting-started/04-deployment-checklist.md)
4. [Deployment Validation](docs/getting-started/05-deployment-validation.md)

Architecture, networking, hardware, security, operations, roadmap, and archived
material are indexed in [docs/README.md](docs/README.md).

## License

Licensed under the [Apache License 2.0](LICENSE).

