# OpenThread Border Router

OTBR connects a Thread mesh to the IP network for Matter-over-Thread. It is an
optional service with selection key `otbr`; the canonical owner is
[`services/otbr/`](../../services/otbr/README.md).

## Requirements

- A Thread radio running RCP firmware
- A stable `/dev/serial/by-id/...` device path
- IPv6 and `/dev/net/tun` on the host
- The correct service-facing backbone interface

Use `sudo ./lisa-edge setup` to select OTBR and configure
`THREAD_RADIO_DEVICE`, `OTBR_BACKBONE_IF`, dataset storage and recovery policy.
The wizard lists serial radios detected under `/dev/serial/by-id/` and active
host interfaces (defaulting to the default-route interface) as selectable
choices. The shared image-selection menu always lists the newest
`openthread/border-router` release tags (`vYYYY.MM.N`) discovered from Docker
Hub next to the current value and the template default - whatever the current
tag looks like (floating, release tag, or digest). Offline, the menu still
renders from those local choices; see
[image version selection](../getting-started/06-first-boot-provisioning.md#image-version-selection).
Host bootstrap prepares Avahi and IPv6 forwarding when OTBR is selected.

Add and verify:

```bash
sudo ./lisa-edge service add otbr
sudo ./lisa-edge health
sudo ./lisa-edge otbr status
sudo ./lisa-edge otbr dataset show
```

An attached network normally reports `child`, `router` or `leader`.
`otbr dataset show` prints a decoded summary with the network key and PSKc
redacted. The complete dataset is only available explicitly:
`otbr dataset show --show-secret` prints it after a warning, and
`otbr dataset export --output <file>` writes it atomically to a new file
with mode `0600` for use in other commissioners.
`sudo ./lisa-edge matter thread sync` stores it in the Matter server's
reserved default Thread credential (the entry Home Assistant and other
default-API clients use for commissioning), and `lisa-edge health`
degrades when the identity fields of the two sides have drifted apart.
After an interactive `otbr dataset restore` or `otbr network create`, the
shared check-and-sync path asks (default Yes) to copy the new dataset into
the Matter server's default credential when they differ; automatic
(engine-driven) restores never prompt and leave the drift to `health` plus
the manual `matter thread sync` command.

## Creating a Thread network

`sudo ./lisa-edge otbr network create` forms a completely new Thread network
named `THREAD_NETWORK_NAME` (default `LISA-HOME-01`, max 16 bytes). The name
identifies the logical site mesh — never the host, the border router, the
ZimaBoard, or the RCP dongle — so it survives hardware replacement. There is
no rename of an established network: creating a network with a different
name is a network REPLACEMENT. When a network is already active the command
shows its summary, requires typing `CREATE`, and backs the old dataset up
first. After forming, it verifies the committed dataset, stores a new
backup, and (when Matter is selected) syncs the credentials to the Matter
server. Every previously paired Thread device must be re-commissioned.

## Thread dataset safety

The Active Operational Dataset contains the Thread network key, PSKc, channel,
PAN identifiers and mesh prefix. Treat it as a secret. Losing it can require
factory-resetting or re-pairing Thread devices.

The wizard separates two concepts explicitly:

- **One-shot action for the NEXT deploy** - restore a selected backup or
  create a new network, staged as a pending marker and applied exactly once.
- **Persistent recovery policy** - what LATER deploys do when they find no
  active dataset and no pending action, offered as one numbered menu:

  1. Restore the latest dataset backup; fail when none exists
     (`OTBR_AUTO_RESTORE_DATASET=1`, `OTBR_AUTO_CREATE_NETWORK=0`).
     Recommended production default.
  2. Restore the latest backup; create a NEW network only when no backup
     exists (`1`/`1`).
  3. Never restore; create a NEW network only when no backup exists
     (`0`/`1`).
  4. Never restore or create automatically; deploy fails with guidance
     (`0`/`0`).

A new network is only ever created automatically when NO latest backup
exists. When a backup exists but restoration is disabled, deploy fails
closed and explains that a backup exists instead of silently replacing the
Thread network (which would orphan every device paired to it). Deploy
automatically backs up an existing active dataset. Dataset snapshots live
under `OTBR_DATASET_BACKUP_DIR`, defaulting to
`/srv/lisa-edge/backups/otbr/`; the dataset timer is enabled automatically when
OTBR is selected.

## Dataset detection during provisioning

The OTBR wizard also detects existing dataset backups. It scans the configured
backup directory (or a custom path you enter, such as a mounted USB or NAS
directory) for `*.hex` dataset files, lists them newest first, and lets you
restore a selected backup, create a new Thread network, or stage no one-shot
action. The choice is staged as a one-shot `pending.dataset.hex` or
`pending.new-network` marker inside `OTBR_DATASET_BACKUP_DIR` and applied
exactly once by the next deploy; delete the marker to cancel before
deploying. A staged one-shot action always takes precedence over the
persistent recovery policy.

If OTBR is already running, the wizard backs up the active dataset before the
staged change is applied and asks for one optional backup description
(Enter skips it; spaces become `-`, characters unsafe in filenames become
`_`, and the result is truncated to the filesystem name limit). Deploy backs
the active dataset up again before applying any staged change.

Keep an encrypted copy outside the edge host. See the
[OTBR recovery runbook](../operations/service-recovery/otbr.md) before hardware
migration or disaster recovery.

Related background: [Thread](../networking/thread.md) and
[Matter](../networking/matter.md).
