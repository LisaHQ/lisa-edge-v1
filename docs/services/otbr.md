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
`THREAD_RADIO_DEVICE`, `OTBR_BACKBONE_IF`, dataset storage and restore policy.
The wizard lists serial radios detected under `/dev/serial/by-id/` and active
host interfaces (defaulting to the default-route interface) as selectable
choices. When `OTBR_IMAGE` is left on a floating tag, the wizard also lists the
newest `openthread/border-router` release tags (`vYYYY.MM.N`) from Docker
Hub as a numbered menu, defaulting to the most recent release; if the host
is offline it keeps the configured reference. Host bootstrap prepares Avahi and IPv6 forwarding when OTBR is
selected.

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

Recommended production policy:

```env
OTBR_AUTO_RESTORE_DATASET=1
OTBR_AUTO_CREATE_NETWORK=0
```

Deploy automatically backs up an existing active dataset or restores
`OTBR_DATASET_LATEST` when the container has no dataset. It refuses to create a
new network unless explicitly allowed. Dataset snapshots live under
`OTBR_DATASET_BACKUP_DIR`, defaulting to
`/srv/lisa-edge/backups/otbr/`; the dataset timer is enabled automatically when
OTBR is selected.

## Dataset detection during provisioning

The OTBR wizard also detects existing dataset backups. It scans the configured
backup directory (or a custom path you enter, such as a mounted USB or NAS
directory) for `*.hex` dataset files, lists them newest first, and lets you
restore a selected backup, create a new Thread network, or keep the current
behavior. The choice is staged as a one-shot `pending.dataset.hex` or
`pending.new-network` marker inside `OTBR_DATASET_BACKUP_DIR` and applied
exactly once by the next deploy; delete the marker to cancel before deploying.

If OTBR is already running, the wizard backs up the active dataset before the
staged change is applied and offers to append a description to that backup's
filename (spaces become `-`, characters unsafe in filenames become `_`, and the
result is truncated to the filesystem name limit). Deploy backs the active
dataset up again before applying any staged change.

Keep an encrypted copy outside the edge host. See the
[OTBR recovery runbook](../operations/service-recovery/otbr.md) before hardware
migration or disaster recovery.

Related background: [Thread](../networking/thread.md) and
[Matter](../networking/matter.md).
