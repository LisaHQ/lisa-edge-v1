# NTP / Chrony

Chrony is a host capability installed by the host bootstrap (run through
`sudo ./lisa-edge setup`); it is
not a container and has no `LISA_COMPOSE_SERVICES` key.

Reliable time is required for logs, certificates, VPN and authentication. The
default configuration acts as an NTP client. If the edge host should also serve
trusted LAN clients, configure Chrony and firewall policy explicitly for the
site instead of exposing NTP broadly.

Verify host time with:

```bash
chronyc tracking
chronyc sources -v
systemctl status chrony --no-pager
```

Host preparation is owned by `install/bootstrap/`; service configuration is a
site responsibility and is not overwritten by Compose deployment.
