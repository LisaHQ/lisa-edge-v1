# Node-RED

Node-RED is an optional compact-host automation service. Its selection key is
`node-red`; the canonical owner is
[`services/node-red/`](../../services/node-red/README.md).

Configure `NODE_RED_BIND_ADDR` and `NODE_RED_PORT` through
`sudo ./lisa-edge setup`. The default bind is localhost-only on port 1880.
Persistent flows and configuration live at
`${DATA_ROOT}/docker/volumes/node-red/` and are included in full backups.

Add it with `sudo ./lisa-edge service add node-red` and verify with
`sudo ./lisa-edge health`. Large or business-critical automation flows normally
belong on LISA Brain or another automation host.
