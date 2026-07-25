# Provisioning

Provisioning collects site-specific settings and writes the local `.env` file
before bootstrap or deployment.

The main entrypoint is:

```bash
sudo ./lisa-edge setup
```

The implementation lives at `install/provisioning/lisa-first-boot.sh`.

`setup` is the single human-facing entry point for setup, configuration,
restore, service refresh, bootstrap, and host repair. Its menu offers: fresh
setup, restore from removable storage, restore from a mounted local/NAS path,
editing the configuration only, refreshing services using the current
configuration (internal deployment engine + health, no Git update and no
intentional image refresh), and bootstrapping/repairing the host (idempotent
bootstrap phases + systemd units + engine + health). Shared prompts and
validation helpers live in `lib/`; service-specific questions live in each
service's `provision.sh`. After a fresh setup or restore starts services with
both Matter and OTBR selected, the shared internal Thread check-and-sync path
(`services/matter-server/thread-sync-if-needed.sh`) checks the actual
relationship and prompts (default Yes) only when the Matter server's default
credential is missing or differs from OTBR.

The systemd unit in `systemd/` only notifies an unprovisioned host. The installer
creates the `lisa-edge-provision` command as a link to the main entrypoint.
`sudo ./lisa-edge reset provisioning` returns a provisioned host to this
unprovisioned first-boot state (see
[ops/deploy/README.md](../../ops/deploy/README.md#reset-lifecycle)).

Do not store production credentials in this directory. Generated values belong
in the ignored `.env` file or an external secret manager.
