# Tailscale VPN

Tailscale provides private remote administration without publishing edge
dashboards to the internet. Its selection key is `vpn-tailscale`; `tailscale`
is accepted as an alias. The canonical owner is
[`services/tailscale/`](../../services/tailscale/README.md).

Select it through `sudo ./lisa-edge setup`. The wizard accepts `TS_AUTHKEY` and
`TS_EXTRA_ARGS`; the service uses host networking, `/dev/net/tun` and persists
state at `${DATA_ROOT}/docker/volumes/tailscale/`.

Add and verify:

```bash
sudo ./lisa-edge service add vpn-tailscale
sudo ./lisa-edge health
docker exec lisa-tailscale tailscale status --peers=false
```

Use reusable or ephemeral auth keys according to the tailnet policy and keep
them outside Git. If no auth key is supplied, interactive authentication may be
required. Access administrative services through VPN and firewall allowlists;
do not expose them directly to the public internet.
