# Quick Start

LISA Edge has one stable operator interface:

```bash
./lisa-edge help
```

Choose one installation path. Do not combine the steps from different paths.

| Starting point | Use |
| --- | --- |
| Ubuntu or Debian is already installed | Manual fresh setup below |
| You need an unattended Ubuntu install | [USB Autoinstall Flow](03-autoinstall-flow.md) |
| You are rebuilding from a backup | [First-Boot Provisioning](06-first-boot-provisioning.md) |

## Manual fresh setup

Automated host bootstrap currently supports Ubuntu Server and Debian.

### 1. Clone the repository

```bash
sudo git clone https://github.com/LisaHQ/lisa-edge.git /opt/lisa-edge
cd /opt/lisa-edge
```

For production, check out a reviewed release tag or commit rather than an
unreviewed development branch.

### 2. Run setup

```bash
sudo ./lisa-edge setup
```

Choose **Fresh setup**, review storage and backup paths, select services,
and complete each selected service's wizard. When prompted, allow setup to
bootstrap the host and start the selected services.

Setup performs the full path:

```text
configuration → host bootstrap → systemd install → internal deployment engine → health
```

When both Matter and OTBR are selected, setup then checks whether the Matter
server's default Thread credential matches OTBR's active dataset and offers
to copy it (default Yes) only when it is missing or differs.

### 3. Verify

```bash
sudo ./lisa-edge status
sudo ./lisa-edge health
```

Then complete the [Deployment Validation](05-deployment-validation.md).

## Configure now, apply later

To write or update `.env` without changing the host or starting services,
run `sudo ./lisa-edge setup` and choose **Edit configuration only**.

Review the result, then apply it later through the same menu:

- **Refresh services using the current configuration** starts/refreshes the
  selected services through the internal deployment engine and verifies
  health (no Git update, no intentional image refresh).
- **Bootstrap or repair this host** additionally reruns the idempotent host
  bootstrap phases and systemd unit installation first.

Do not hand-copy `.env.template` for a normal installation. The wizard validates
paths, service dependencies, ports, image policy, backup mounts, and admin
access that a manual copy would bypass.

## Add or remove services later

```bash
sudo ./lisa-edge service add <service-key>
sudo ./lisa-edge service remove <service-key>
```

`service add` configures only the new service (plus required dependencies),
updates `.env` atomically with a pre-change copy, refreshes the stack through
the internal deployment engine, and verifies health. `service remove` prints
a complete plan, requires an exact typed confirmation, creates a fresh
dedicated backup for Matter/OTBR first, and preserves backups and images by
default. Re-running the full `setup` wizard also works and preserves
existing values as defaults.

## Next steps

- [Choose services](02-service-selection.md)
- [Review the deployment checklist](04-deployment-checklist.md)
- [Understand first-boot and restore modes](06-first-boot-provisioning.md)
