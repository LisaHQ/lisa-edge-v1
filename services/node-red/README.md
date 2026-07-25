# Node-RED

- Selection key: `node-red`
- Enabled by default: no
- Container: `lisa-node-red`
- UI: `NODE_RED_BIND_ADDR:NODE_RED_PORT`, default `127.0.0.1:1880`

Add, configure, start, and verify it with:

```bash
sudo ./lisa-edge service add node-red
sudo ./lisa-edge health
```

Flows and configuration persist at `${DATA_ROOT}/docker/volumes/node-red/` and
are included in full backups. Keep large automation workloads on LISA Brain or
a dedicated automation host.

Owned files: `compose.yml` and `provision.sh`. See
[operator reference](../../docs/services/node-red.md).
