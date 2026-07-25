# Zigbee2MQTT

Zigbee2MQTT is an optional Zigbee bridge. Its selection key is `zigbee2mqtt`,
it requires `mqtt`, and its canonical owner is
[`services/zigbee2mqtt/`](../../services/zigbee2mqtt/README.md).

The wizard asks for `ZIGBEE_DONGLE`, `ZIGBEE2MQTT_BIND_ADDR` and
`ZIGBEE2MQTT_PORT`; it adds MQTT when required. Prefer a stable
`/dev/serial/by-id/...` coordinator path instead of a changing `/dev/ttyACM*`
name.

Persistent application data, including coordinator-related configuration, is
stored at `${DATA_ROOT}/docker/volumes/zigbee2mqtt/`. Back it up before hardware
migration. Add and verify with `sudo ./lisa-edge service add zigbee2mqtt`
followed by `sudo ./lisa-edge health`.
