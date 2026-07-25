# MQTT / Mosquitto

MQTT is the default local messaging backbone. Its selection key is `mqtt`; the
canonical owner is [`services/mqtt/`](../../services/mqtt/README.md).

Configure through the wizard:

```bash
sudo ./lisa-edge setup
```

Important `.env` values are `MQTT_USERNAME`, `MQTT_PASSWORD`,
`MQTT_BIND_ADDR`, `MQTT_PORT` and `MQTT_WS_PORT`. The wizard generates a random
password when the template value is unchanged. Bind to localhost or a trusted
service-network address; never expose MQTT directly to the public internet.

Add and verify:

```bash
sudo ./lisa-edge service add mqtt
sudo ./lisa-edge health
```

Persistent configuration, password database, retained data and logs live below
`${DATA_ROOT}/docker/volumes/mosquitto/`. Version-controlled source
configuration is at `services/mqtt/config/mosquitto.conf`; deployment copies it
into persistent storage before starting Mosquitto.

Full backups include the persistent MQTT tree. Back up before changing broker
credentials because clients must be updated to match.
