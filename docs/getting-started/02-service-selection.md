# Service Selection

Deploy only the services this node needs.

List the current selection keys:

```bash
./lisa-edge service list
```

Add or remove one service at a time with the service lifecycle:

```bash
sudo ./lisa-edge service add <service-key>
sudo ./lisa-edge service remove <service-key>
```

Re-running `sudo ./lisa-edge setup` reselects everything at once. Choose the
setup menu's `Edit configuration only` action when you only want to update
`.env` without applying it yet; apply it later with the `Refresh services`
action.

## Selectable services

| Key | Service | Enable when… |
| --- | --- | --- |
| `mqtt` | Eclipse Mosquitto | clients need a local message bus |
| `uptime-kuma` | Uptime Kuma | you need lightweight availability monitoring |
| `ha` | Home Assistant | this Edge host is intentionally hosting a small HA deployment |
| `matter` | Matter Server | your Matter controller (for example Home Assistant without add-ons) needs a local Matter controller server |
| `otbr` | OpenThread Border Router | you have Matter-over-Thread devices and an RCP radio |
| `zigbee2mqtt` | Zigbee2MQTT | you have a supported Zigbee coordinator |
| `node-red` | Node-RED | you need a lightweight local flow engine |
| `vpn-tailscale` | Tailscale | you need VPN-first remote administration |

Selecting Zigbee2MQTT automatically selects MQTT. Hand-written configurations
that omit this dependency are rejected during deployment validation.

Chrony, host hardening, systemd runtime, backup/restore, diagnostics, and rescue
tooling are host-level capabilities. They do not appear in the selectable
Compose list.

## Common profiles

### Minimal messaging node

```text
mqtt
```

### Matter-over-Thread infrastructure

```text
uptime-kuma ha matter otbr
```

Add `matter` when Home Assistant on another host needs a local Matter
controller server next to OTBR.

### Remotely administered edge node

```text
mqtt uptime-kuma vpn-tailscale
```

### Local automation bridge

```text
mqtt zigbee2mqtt node-red
```

Home Assistant is optional. Keep it on its existing controller or dedicated
host unless co-location clearly reduces operational complexity.

## Planned, not selectable

These services fit the Edge boundary but are not implemented Compose choices:

- NUT / UPS integration
- DNS helpers
- reverse proxy

Do not put their names in `LISA_COMPOSE_SERVICES`. Follow the current output of
`./lisa-edge service list`, not an architecture diagram or roadmap entry.

## Before enabling a service

Confirm:

- the selected image supports the host CPU architecture;
- bind addresses and firewall rules expose only intended clients;
- device paths use stable `/dev/serial/by-id/...` names where possible;
- persistent data is on suitable storage;
- backup and restore requirements are understood; and
- any required credential is stored outside Git.

Start small. You can re-run setup later without reinstalling the host.
