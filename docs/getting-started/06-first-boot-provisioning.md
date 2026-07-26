# First-Boot Provisioning

Production autoinstall creates this convenience command:

```bash
sudo lisa-edge-provision
```

With no arguments, the alias dispatches to the canonical setup workflow:

```bash
sudo /opt/lisa-edge/lisa-edge setup
```

From any repository checkout, use the root `lisa-edge` command directly for
mode-specific options.

## Provisioning modes

| Mode | Purpose |
| --- | --- |
| Fresh | Create configuration, then bootstrap and deploy after confirmation |
| Restore from USB | Discover a backup on `LISA_BACKUP` or common removable-media paths |
| Restore from path | Use a selected archive or mounted NAS/local directory |
| Configure only | Write `.env` without changing the host or starting services |

Interactive selection:

```bash
sudo ./lisa-edge setup
```

Explicit fresh mode:

```bash
sudo ./lisa-edge setup --mode fresh
```

Configuration only (applied later through the setup menu's
`Refresh services` or `Bootstrap or repair` actions):

```bash
sudo ./lisa-edge setup --mode config-only
```

## Restore from USB

Attach the backup volume, then run:

```bash
sudo ./lisa-edge setup --mode restore-usb
```

The wizard can mount a volume labeled `LISA_BACKUP` read-only or discover
archives beneath common removable-media mount locations. An archive is never
restored merely because it exists; the operator must select it.

## Restore from NAS or local path

Mount network storage first:

```bash
sudo mount -t nfs nas.example:/volume/lisa-edge /mnt/lisa-backup
sudo ./lisa-edge setup \
  --mode restore-path \
  --backup /mnt/lisa-backup
```

The backup path may be a directory or a specific archive.

## Restore safety

Before privileged extraction, provisioning:

1. requires and verifies the matching `.sha256` sidecar;
2. validates archive member types and paths;
3. restricts extraction to LISA Edge configuration and persistent-data roots;
4. restores without deploying;
5. reloads restored values as editable wizard defaults; and
6. requires review of restored container image references.

After review, setup writes a fresh `.env` and offers to bootstrap and deploy.

## What the wizard asks

Global settings include:

- hostname and timezone;
- `DATA_ROOT` and `BACKUP_DEST`;
- backup mount enforcement and retention;
- selected service list;
- bind addresses and ports;
- immutable-image policy;
- administrator account; and
- whether temporary passwordless sudo may remain.

Each selected service then runs its own configuration prompts. Zigbee2MQTT
automatically adds MQTT.

Review current keys with:

```bash
./lisa-edge service list
```

## Images and administrator access

The wizard labels selected images as floating or digest-pinned. Enabling
immutable-image enforcement rejects any selected image without an `@sha256`
digest.

Autoinstall creates `/etc/sudoers.d/90-lisa-admin` only to make unattended
first bootstrap possible. Bootstrap reconciles that grant with the configured
desired state: with `LISA_KEEP_PASSWORDLESS_SUDO=0` (default) it confirms that
the configured administrator has a usable local password and removes the
temporary grant; with the explicit emergency/lab override
(`LISA_KEEP_PASSWORDLESS_SUDO=1`) it creates or corrects the grant for the
configured admin user (visudo-validated, `root:root`, mode `0440`). The setup
menu's `Edit configuration only` action never touches host sudo state; apply
host-level changes with `Bootstrap or repair this host`.

## Re-running setup

```bash
sudo ./lisa-edge setup
```

Existing values become defaults. The current `.env` is backed up before
replacement. Deselected containers are removed as orphans, but their
bind-mounted persistent data is retained for deliberate cleanup or later reuse.

## Returning to the unprovisioned state

To wipe LISA state and configuration and run first-boot provisioning again
without reinstalling Ubuntu:

```bash
sudo ./lisa-edge reset provisioning --dry-run   # review the full plan first
sudo ./lisa-edge reset provisioning             # confirm with: RESET LISA
sudo lisa-edge-provision                        # provision again
```

This removes all service runtime data, generated secrets, local backups
inside `DATA_ROOT`, `.env` (with its wizard backups), the provision marker
and the production systemd units, then re-enables `lisa-first-boot.service`
and the `lisa-edge-provision` command. Ubuntu, Docker (including images),
SSH access and the host bootstrap configuration are retained; backups
stored outside `DATA_ROOT` are preserved. It does not deploy anything.

To recreate services from clean runtime data while keeping the current
configuration, use `sudo ./lisa-edge reset data` instead; for a clean
Ubuntu install through the Rescue Layer, use `sudo ./lisa-edge reset
factory`. The modes are compared in
[ops/deploy/README.md](../../ops/deploy/README.md#reset-lifecycle).
