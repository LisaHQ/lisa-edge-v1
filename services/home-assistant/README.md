# Home Assistant

- Selection key: `ha`
- Accepted aliases: `home-assistant`, `homeassistant`
- Enabled by default: no
- Container: `lisa-ha`

Home Assistant uses host networking and stores configuration at
`${DATA_ROOT}/docker/volumes/homeassistant/`. Add it with
`sudo ./lisa-edge service add ha`, then verify with
`sudo ./lisa-edge health`.

This is a compact-host option. Move larger automation workloads to LISA Brain
or a dedicated host so they do not compete with edge infrastructure.

Owned files: `compose.yml` and `provision.sh`. See
[operator reference](../../docs/services/home-assistant.md).
