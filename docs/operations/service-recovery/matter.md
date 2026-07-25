# Matter Data Recovery

Use this runbook when the Matter host or container is lost but a Matter data
backup archive is available. A full LISA Edge backup is preferred; this is
the data-only path.

Required state:

```text
latest.matter-data.tar.gz
```

Treat this archive as a secret. It contains the fabric credentials and the
commissioned-device state; whoever holds it can control the fabric.

## Fresh-host procedure

1. Install Linux and clone LISA Edge.
2. Configure without deploying; select the Matter service:

   ```bash
   sudo ./lisa-edge configure
   ```

3. Point the wizard at the saved archive. The Matter wizard's "Matter data
   detection" step accepts a custom path (for example a mounted USB or NAS
   directory), lists the `*.tar.gz` backups it finds, and stages the selected
   file for restore on the next deploy. Alternatively, copy the saved archive
   to the `MATTER_DATA_LATEST` path in `.env` manually. For the default
   layout:

   ```bash
   sudo install -D -m 0600 /path/to/latest.matter-data.tar.gz \
     /srv/lisa-edge/backups/matter/latest.matter-data.tar.gz
   ```

4. Bootstrap and deploy. Deploy detects the empty Matter store and restores
   the saved archive automatically before the container starts:

   ```bash
   sudo ./lisa-edge bootstrap
   ```

5. Verify:

   ```bash
   sudo ./lisa-edge health
   sudo ./lisa-edge matter status
   sudo ./lisa-edge matter thread status
   ```

   Then confirm in Home Assistant that the Matter integration reconnects and
   previously commissioned devices become available without re-commissioning.

Keep `MATTER_AUTO_RESTORE_DATA=1` in production. Without a data backup a new
fabric must be created and every Matter device re-commissioned.

## Reverting a python-matter-server migration

matterjs-server migrates a python-matter-server store in place on first
start, one-way. Deploy saves a `matter-data-*-pre-image-change.tar.gz`
archive before the image change. To return to python-matter-server, set
`MATTER_SERVER_IMAGE` back to the python-matter-server reference and restore
that archive:

```bash
sudo services/matter-server/data/restore.sh \
  /srv/lisa-edge/backups/matter/matter-data-<timestamp>-pre-image-change.tar.gz
sudo ./lisa-edge deploy
```

Devices commissioned only after the migration exist solely in the
matterjs-server store and are lost by the revert.

## Fabric reset

`sudo ./lisa-edge matter reset` wipes the store after typing `RESET`,
preserving it first as a `pre-reset` archive (with checksum and metadata
sidecars), recreates the empty store with safe ownership, restarts the
server, and verifies over the WebSocket API that it starts with an empty
fabric. Every device must be re-commissioned afterwards, and the Thread
credentials must be stored again in the reserved default credential with
`sudo ./lisa-edge matter thread sync`.
The wizard can also stage a reset for the next deploy. Reset is never part
of a normal deploy or update.

Implementation ownership:
[`services/matter-server/`](../../../services/matter-server/README.md).
