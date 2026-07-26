# Matter Server

- Selection key: `matter`
- Accepted aliases: `matter-server`
- Enabled by default: no
- Container: `lisa-matter`

Matter Server (matterjs-server, the Matter.js-based drop-in replacement for
python-matter-server) is the local Matter controller server. Home Assistant
connects to it over WebSocket at `ws://<edge-host>:5580/ws`. Combined with
OTBR it supports Matter-over-Thread; Matter over Wi-Fi and Ethernet work
without OTBR.

It uses host networking because commissioning depends on mDNS multicast and
direct IPv6 reachability. The WebSocket API is unauthenticated and binds to
`MATTER_LISTEN_ADDRESS` (default `127.0.0.1`). Only set a trusted LAN
address for a remote Home Assistant, keep the port firewalled, and never
publish it through a reverse proxy. `MATTER_FABRIC_LABEL` pins the fabric
label shown on devices, and `MATTER_PRIMARY_INTERFACE` optionally pins the
mDNS interface on multi-homed hosts (its compose slice is only included when
set, so the upstream auto-detect default stays intact otherwise).

BLE commissioning (new Thread devices receive their network credentials over
Bluetooth) needs a Bluetooth adapter on the host, selected with
`MATTER_BLUETOOTH_ADAPTER` (validated by the wizard; `none` disables BLE).
Only the BLE compose slice (`compose.ble.yml`) runs the container as root
with `NET_RAW`/`NET_ADMIN`, because the kernel ignores HCI commands from
unprivileged users; with BLE disabled the container keeps the image's
unprivileged user. The image is pinned to a release tag because `:stable`
can move underneath a deployment and has served untested nightly server
builds (note that even release tags embed alpha builds of the matter.js
SDK). See the operator reference for the full BLE requirements and
troubleshooting.

Fabric credentials and commissioned-device state live at
`${DATA_ROOT}/docker/volumes/matter-server/`. This data is critical: losing
it requires re-commissioning every Matter device. matterjs-server migrates
existing python-matter-server storage found there in place; the migration is
one-way, and deploy backs the store up before the image change.

Data tools under `data/` back the store up, restore it, reset the fabric or
initialize it on deploy, mirroring the OTBR dataset protection. The wizard
detects existing Matter data backups (default directory or a custom path) and
can stage a selected backup or a fabric reset as a one-shot pending marker
that the next deploy applies; deploy backs up the active store first. The
separate persistent empty-store policy (`MATTER_AUTO_RESTORE_DATA`, offered
as its own wizard menu) governs later deploys with no pending action; a
staged reset removes the `latest` pointer first so the policy never
resurrects a reset fabric. Production should keep
`MATTER_AUTO_RESTORE_DATA=1`. The units in `systemd/`
schedule daily data backups when Matter is selected; a scheduled backup stops
`lisa-matter` for the few seconds the snapshot takes. The live store is also
included in the standard `sudo ./lisa-edge backup` archive.

Add, configure, start, and verify it with `sudo ./lisa-edge service add
matter`, then check `sudo ./lisa-edge health`. Operator commands: `matter status`,
`matter credentials list`, `matter thread status|sync|remove`, and
`matter reset` (backs up, wipes the fabric, and requires re-commissioning
every device). The Thread commissioning credential is the Matter
server's reserved default entry (populated by `matter thread sync` from
OTBR's authoritative active dataset). When OTBR is also selected, health
reports DEGRADED if the default credential is unconfigured or its identity
fields drift from OTBR's active dataset;
`sudo ./lisa-edge matter thread sync` re-syncs it without restarting the
server. Named credentials are an upstream advanced capability, listed but
never used for readiness.

Owned files: `compose.yml`, `compose.ble.yml`, `compose.primary-interface.yml`,
`provision.sh`, `status.sh`, `thread.sh`, `credentials.sh`, `lib/`, `data/`
and `systemd/`. See the
[operator reference](../../docs/services/matter-server.md) and
[recovery runbook](../../docs/operations/service-recovery/matter.md).
