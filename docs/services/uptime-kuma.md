# Uptime Kuma

Uptime Kuma is the default lightweight monitoring UI. Its selection key is
`uptime-kuma`; the canonical owner is
[`services/uptime-kuma/`](../../services/uptime-kuma/README.md).

Add it with `sudo ./lisa-edge service add uptime-kuma` (the wizard asks for
`UPTIME_KUMA_BIND_ADDR` and `UPTIME_KUMA_PORT`). The default
bind is `127.0.0.1:3001`; use VPN or an explicitly trusted bind address for
remote access.

Application state is stored at
`${DATA_ROOT}/docker/volumes/uptime-kuma/` and is included in full backups.
Monitor definitions are configured in the Uptime Kuma UI; LISA Edge does not
pre-populate them.

Verify the container and port with:

```bash
sudo ./lisa-edge health
```
