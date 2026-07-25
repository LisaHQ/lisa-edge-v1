# Home Assistant

Home Assistant is an optional compact-host service. Its selection key is `ha`
and `home-assistant` is accepted as a command alias. The canonical owner is
[`services/home-assistant/`](../../services/home-assistant/README.md).

It uses host networking and persists configuration at
`${DATA_ROOT}/docker/volumes/homeassistant/`. Add it with
`sudo ./lisa-edge service add ha`, then verify with
`sudo ./lisa-edge health`.

Home Assistant can grow into a high-I/O automation workload. Prefer LISA Brain
or a dedicated automation host when the deployment is large, while keeping
LISA Edge focused on infrastructure services.
