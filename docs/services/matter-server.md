# Matter Server

Matter Server (matterjs-server) is the local Matter controller server for the
Matter fabric, a Matter.js-based drop-in replacement for python-matter-server
with the same WebSocket API. It is an optional service with selection key
`matter` (`matter-server` is accepted as an alias); the canonical owner is
[`services/matter-server/`](../../services/matter-server/README.md).

Home Assistant's Matter integration connects to it over WebSocket:

```text
ws://<edge-host>:5580/ws
```

The server also serves a web dashboard on the same port. With OTBR on the
same or another reachable host it enables Matter-over-Thread. Matter over
Wi-Fi and Ethernet work without OTBR.

## Requirements

- Host networking (mDNS multicast and direct IPv6 reachability to devices)
- IPv6 enabled on the host
- A Bluetooth adapter on the host for BLE commissioning (see
  [BLE commissioning](#ble-commissioning))

Use `sudo ./lisa-edge setup` to select it. The wizard asks for
`MATTER_SERVER_PORT` (passed to the server as its listen port and used by
health checks), `MATTER_LISTEN_ADDRESS`, an optional
`MATTER_PRIMARY_INTERFACE`, the Bluetooth adapter (detected from
`/sys/class/bluetooth/`), the fabric label, the
Matter data backup directory and restore policy, and can stage a data
restore or fabric reset for the next service refresh. Add and verify:

```bash
sudo ./lisa-edge service add matter
sudo ./lisa-edge health
sudo ./lisa-edge matter status
```

## Naming model

Three independent names, three different things:

| Setting | Default | Names |
| --- | --- | --- |
| `LISA_EDGE_HOSTNAME` | `lisa-edge-01` | the infrastructure host |
| `THREAD_NETWORK_NAME` | `LISA-HOME-01` | the Thread mesh (the logical site network) |
| `MATTER_FABRIC_LABEL` | `LISA Home` | the Matter fabric label shown on devices |

The Thread network and the Matter fabric outlive any specific host or border
router, so none of them are named after hardware. The Matter server's
reserved `default` Thread credential slot is an implementation detail, not a
user-facing identity: it holds a copy of the Thread dataset, it is not the
Thread network name, and it is never configured by name.

## Thread credential management

The server stores a copy of OTBR's Thread credentials and hands it to new
devices during commissioning; OTBR's active operational dataset stays the
authoritative network configuration. LISA Edge stores that copy in the
Matter server's RESERVED DEFAULT Thread credential — the entry the API uses
when no credential ID is supplied, which is exactly what Home Assistant and
other default-API clients read and write when they commission devices:

```bash
sudo ./lisa-edge matter thread sync            # from OTBR (default)
sudo ./lisa-edge matter thread sync --file <f> # from an exported dataset file
sudo ./lisa-edge matter thread sync --stdin    # from stdin
sudo ./lisa-edge matter credentials list       # non-secret summaries
sudo ./lisa-edge matter thread status          # relationship with OTBR
sudo ./lisa-edge matter thread remove --id <id>
```

Interactive workflows check and offer this sync automatically: setup
(fresh/restore), `service add matter`/`service add otbr`, an interactive
`otbr dataset restore` or `otbr network create`, and a live restore with
`--start-services` all run one shared internal check
(`services/matter-server/thread-sync-if-needed.sh`). When the default
credential already matches OTBR they report the match and ask nothing; when
it is missing or differs they ask `Copy OTBR's active Thread dataset to
Matter Server's default credential? [Y/n]` (default Yes). Non-interactive
paths — systemd boot, the internal deployment engine, `update`, timers, and
`service start` — never prompt: they leave services running, let `health`
report DEGRADED, and print the manual `matter thread sync` command. The
synchronization direction is only ever OTBR → Matter default credential;
only the identity fields the API returns (network name, extended PAN ID)
are compared, and the raw dataset, Network Key, and PSKc are never printed.

Sync validates the dataset, sends `set_thread_dataset` without an `id`
field (upstream reserved-default semantics) over one WebSocket connection,
verifies that the server reports `thread_credentials_set=true` and that the
default entry's summary is present through `server_info` and
`get_all_credentials`, and does NOT restart the server. The verification is
honest about its limits: the API returns the network name and extended PAN
ID, so those identity fields are compared; the network key and PSKc are
never returned and therefore never claimed as verified or compared. The raw
dataset is never accepted as a command-line argument and never appears in
process listings, logs, or error messages. Changing the stored credential
affects FUTURE commissioning only; already commissioned devices are not
modified.

Named Thread credentials (WebSocket schema 12) remain an upstream advanced
capability. LISA Edge does not use them for commissioning:
`matter credentials list` shows them, and `matter thread remove --id <id>`
removes them explicitly. Readiness (health, doctor, status) is always
decided by the reserved default credential — a named entry that matches
OTBR never makes commissioning ready on its own.

### Migrating from the named credential (`lisa-home-01`)

Deployments provisioned before this model stored the dataset as the named
credential `lisa-home-01` (configured via the now-legacy
`MATTER_THREAD_CREDENTIAL_ID` variable) and left the reserved default entry
unconfigured. Migration is one command, safe and idempotent:

```bash
sudo ./lisa-edge matter thread sync
sudo ./lisa-edge matter thread status
```

Sync populates and verifies the default credential from OTBR's active
dataset; nothing is deleted automatically. The leftover `lisa-home-01`
entry is harmless — status and `matter credentials list` mark it as a
legacy duplicate and it is ignored for readiness. Remove it ONLY after
`matter thread status` confirms the default credential is configured and
matches OTBR:

```bash
sudo ./lisa-edge matter thread remove --id lisa-home-01
```

A leftover `MATTER_THREAD_CREDENTIAL_ID` line in `.env` is ignored and does
not break deploy, configure, update, or health; remove it at leisure.

## BLE commissioning

New Thread (and Wi-Fi) Matter devices hand over their network credentials
during commissioning via Bluetooth LE, so the dashboard's "Commission node"
needs working BLE on the edge host. Three configuration points make it work,
all encoded in `compose.yml`:

- `MATTER_BLUETOOTH_ADAPTER` selects the hci adapter (default `0`; the
  wizard lists detected adapters and validates the value; `none` disables
  BLE and is a valid mode — network-based Matter control keeps working and
  health reports DEGRADED only for the commissioning capability).
- With BLE enabled, the `compose.ble.yml` slice runs the container as
  **root** (`user: "0:0"`) with `cap_add: NET_RAW, NET_ADMIN`. The kernel
  only honors HCI commands from a process with effective
  `NET_RAW`/`NET_ADMIN`; the image's default unprivileged user never gets
  effective capabilities, so BLE discovery silently finds nothing (the
  server still logs `BLE is enabled`). Upstream documents no unprivileged
  alternative. With `MATTER_BLUETOOTH_ADAPTER=none` the slice is omitted and
  the container runs unprivileged.
- The image is pinned to a **release tag**. Release tags are fixed, tested
  server snapshots; `:stable` can move underneath a deployment and has
  served untested nightly server builds (a 2026-07-22 nightly shipped a BLE
  regression that hung commissioning right after the ATT MTU exchange).
  Note that even release-tagged servers embed alpha builds of the matter.js
  SDK (1.3.1 ships a 0.17.7 alpha), so a "stable release" refers to the
  server build, not the SDK version string inside it. Evaluate upgrades
  explicitly against the upstream changelog and re-validate BLE on hardware
  before repinning.

  Version policy status: `1.3.1` (2026-07-23) was evaluated and NOT adopted.
  Per the upstream changelog it only adds dashboard features and updates the
  embedded matter.js SDK to a newer 0.17.7 alpha; schema 12, named Thread
  credentials, `DEFAULT_FABRIC_LABEL`, and `LISTEN_ADDRESS` already exist in
  the pinned `1.3.0` (they landed in 1.2.0), and the SDK bump's BLE behavior
  cannot be verified without physical commissioning hardware. Re-evaluate
  when a hardware BLE validation pass (see
  [Deployment Validation](../getting-started/05-deployment-validation.md))
  can accompany the repin.

Troubleshooting, in the order that localizes the fault fastest:

1. Confirm the device is advertising: `sudo btmon` on the host must show
   `Service Data: Matter Profile ID (0xfff6)` advertisements. The
   discriminator is in bytes 1–2 of that payload (12-bit little-endian);
   its upper 4 bits must match the short discriminator the server logs. No
   0xfff6 adverts means the device is not in pairing mode or is already
   commissioned into another fabric (factory-reset it, or open a
   commissioning window from the existing controller).
2. Do not run `bluetoothctl scan` or leave the adapter discoverable during
   commissioning; a passive `sudo btmon` is safe and shows whether the
   container actually issues `LE Set Extended Scan` commands.
3. `Commission failed ... started attempt(s) failed` after a successful BLE
   session means the device joined BLE fine and the failure moved to the
   Thread/IP layer (see below).

**"Operative reconnection with device failed"** after the BLE phase almost
always means the Thread dataset the server hands to devices has drifted from
OTBR's active dataset (for example after an OTBR dataset restore or
regeneration). Symptom: the device never appears in
`sudo docker exec lisa-otbr ot-ctl child table` and SRP stays empty.
`lisa-edge health` (deploy runs it too) compares the identity fields of
OTBR's active dataset with the server's stored credential and reports
DEGRADED on drift. Fix it with:

```bash
sudo ./lisa-edge matter thread sync
```

which stores OTBR's active dataset over the WebSocket API in the reserved
default credential and verifies it without restarting the server
(`sudo ./lisa-edge otbr dataset export --output <file>` produces the same
dataset for manual use elsewhere). Then factory-reset the device — failed
attempts leave stale state on it — and commission again.

## Migration from python-matter-server

matterjs-server reads an existing python-matter-server store at
`${DATA_ROOT}/docker/volumes/matter-server/` and migrates it to its native
format on first start, so commissioned devices carry over without
re-commissioning. The migration is ONE-WAY: after matterjs-server has run,
the store can no longer be used by python-matter-server. Deploy detects the
image change and backs the store up first; that `pre-image-change` archive is
the only way back to the old server.

## Security

The WebSocket API has no authentication. The container uses host
networking, but the server binds only to `MATTER_LISTEN_ADDRESS` (default
`127.0.0.1`, which keeps it host-local and still works for a co-located
Home Assistant). For a REMOTE Home Assistant, set the address to the
specific trusted host address it should connect through — never `0.0.0.0`
unless firewall policy explicitly protects the port — and restrict
`MATTER_SERVER_PORT` with firewall or VLAN rules so only trusted controllers
can reach it. Never expose it beyond the local network and never publish it
through a public reverse proxy. Deploy refuses invalid values and warns
loudly about `0.0.0.0`.

## Fabric data safety

`${DATA_ROOT}/docker/volumes/matter-server/` holds the fabric credentials
and commissioned-device state. Treat it like the OTBR Thread dataset: losing
it requires re-commissioning every Matter device.

The compose file runs the container as root for BLE commissioning (see
[BLE commissioning](#ble-commissioning)), so store ownership no longer
affects startup. The data scripts still normalize ownership to uid/gid
`1000:1000`, the image's default unprivileged user, after creating the
directory and after every archive extraction; that keeps the store usable if
the root override is ever removed — under the image's default user, a
root-owned store crash-loops at startup with
`EACCES: permission denied, mkdir '/data/config'`.

Protection mirrors the OTBR dataset tooling:

- On every deploy, `services/matter-server/data/init-or-restore.sh` runs
  before the containers start: it applies a staged wizard selection, backs
  the store up before a container image change, and restores
  `MATTER_DATA_LATEST` into an empty store when
  `MATTER_AUTO_RESTORE_DATA=1`.
- `lisa-matter-data-backup.timer` snapshots the store daily to
  `MATTER_DATA_BACKUP_DIR` (default `/srv/lisa-edge/backups/matter/`); the
  timer is enabled automatically when Matter is selected. The snapshot stops
  `lisa-matter` for a few seconds so the archive is consistent.
- `services/matter-server/data/backup.sh [--label <label>]` and
  `restore.sh [archive]` are the manual data entry points, and
  `sudo ./lisa-edge matter reset` is the operator-facing fabric reset.
  Every archive gets a `.sha256` checksum and a non-secret `.meta` sidecar;
  restore refuses archives whose checksum does not match. Restore and reset
  always preserve the current store as a `pre-restore` / `pre-reset`
  archive first; reset requires typing `RESET`, recreates the empty store
  with safe ownership, restarts the server, and verifies over the WebSocket
  API that it starts with an empty fabric (0 nodes, 0 stored credentials).
  Reset is never part of a normal deploy or update.

The live store is also included in the standard full-stack backup
(`sudo ./lisa-edge backup`); keep a copy outside the edge host.

## Data detection during provisioning

The Matter wizard detects existing data backups. It scans the configured
backup directory (or a custom path you enter, such as a mounted USB or NAS
directory) for `*.tar.gz` archives, lists them newest first, and lets you
restore a selected backup, reset the fabric, or keep the current behavior.
The choice is staged as a one-shot `pending.matter-data.tar.gz` or
`pending.reset` marker inside `MATTER_DATA_BACKUP_DIR` and applied exactly
once by the next deploy; delete the marker to cancel before deploying. Deploy
backs up the active store before applying any staged change.

See the [Matter recovery runbook](../operations/service-recovery/matter.md)
before hardware migration or disaster recovery.

Related background: [Matter](../networking/matter.md),
[Thread](../networking/thread.md) and [OTBR](otbr.md).
