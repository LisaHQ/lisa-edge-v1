# Zigbee2MQTT

- Selection key: `zigbee2mqtt`
- Enabled by default: no
- Dependency: `mqtt`
- Container: `lisa-zigbee2mqtt`

Add it with `sudo ./lisa-edge service add zigbee2mqtt` (the wizard asks for
the coordinator path, bind address and UI port, and adds MQTT when
required). Prefer `/dev/serial/by-id/...` over a changing tty name.

```bash
sudo ./lisa-edge service add zigbee2mqtt
sudo ./lisa-edge health
```

Persistent application and coordinator state lives at
`${DATA_ROOT}/docker/volumes/zigbee2mqtt/` and is included in full backups.

Owned files: `compose.yml` and `provision.sh`. See
[operator reference](../../docs/services/zigbee2mqtt.md).
