# Services

This directory owns every deployable service as a vertical slice. A service
keeps its Compose fragment, provisioning questions, source configuration and
service-specific recovery helpers together.

`registry.sh` is the canonical list of implemented selection keys,
dependencies and human-readable names. Run the public command instead of
reading internal files:

```bash
./lisa-edge service list
```

Only implemented services belong here. Planned services are documented under
`docs/planned/` until runnable code exists.

`image-advisories.tsv` is the Git-managed image advisory catalog: one
`service-key<TAB>image<TAB>status<TAB>note` record per image with a recorded
problem (`known-issue` requires explicit confirmation in the image menu,
`blocked` is refused). It is static and reviewed with code changes - there
are no runtime commands to edit it - and it never lists "tested" or
"recommended" images: recommended versions stay documented in
`.env.template` and the service documentation.

| Owner | Selection key | Default | Notes |
|---|---|:---:|---|
| [mqtt/](mqtt/README.md) | `mqtt` | Yes | Mosquitto messaging |
| [uptime-kuma/](uptime-kuma/README.md) | `uptime-kuma` | Yes | Lightweight monitoring |
| [home-assistant/](home-assistant/README.md) | `ha` | No | Compact-host option |
| [matter-server/](matter-server/README.md) | `matter` | No | Matter controller server; `matter-server` alias accepted |
| [otbr/](otbr/README.md) | `otbr` | No | Thread RCP required |
| [zigbee2mqtt/](zigbee2mqtt/README.md) | `zigbee2mqtt` | No | Requires `mqtt` |
| [node-red/](node-red/README.md) | `node-red` | No | Compact-host option |
| [tailscale/](tailscale/README.md) | `vpn-tailscale` | No | `tailscale` alias accepted |
