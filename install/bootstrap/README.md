# Bootstrap

This directory prepares a supported Linux host to run LISA Edge.

Bootstrap is an internal implementation, not a root command. It runs through
the setup workflows:

```bash
sudo ./lisa-edge setup     # fresh setup, restore with service start, or the
                           # "Bootstrap or repair this host" menu action
```

These workflows (and first-boot provisioning) invoke
`install/bootstrap/bootstrap.sh` directly. The bootstrap script loads `.env`,
executes every script in `phases/` in lexical order, installs the systemd
units, starts the selected Compose services through the internal deployment
engine (`ops/deploy/deploy.sh`), and finalizes administrator access.
Bootstrap and the deployment engine are different layers: bootstrap prepares
and hardens the host; the engine operates the already prepared service
stack.

## Phase convention

- Use a two-digit numeric prefix to make execution order explicit.
- Keep each phase focused on one host-level responsibility.
- Make phases safe to run again whenever practical.
- Put reusable runtime behavior in `lib/`, not in a bootstrap phase.

Bootstrap changes the host and therefore must be tested on a disposable machine
or VM before production rollout.
