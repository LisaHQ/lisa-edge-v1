# OpenThread Border Router

- Selection key: `otbr`
- Enabled by default: no
- Container: `lisa-otbr`
- Requires: Thread RCP, stable serial path, IPv6 and `/dev/net/tun`

Add it with `sudo ./lisa-edge service add otbr` (the wizard asks for the
radio, backbone interface and dataset policy, then starts and verifies the
service). Inspect it with:

```bash
sudo ./lisa-edge health
sudo ./lisa-edge otbr status
sudo ./lisa-edge otbr dataset show              # redacted summary
sudo ./lisa-edge otbr dataset show --show-secret # complete dataset (secret)
sudo ./lisa-edge otbr network create            # form a NEW network (replacement)
```

The Thread dataset is a secret and the identity of the network. Dataset tools
under `dataset/` back it up, restore it or initialize OTBR. The wizard detects
existing dataset backups (default directory or a custom path), and can stage a
selected backup or a new-network request as a one-shot pending marker that the
next deploy applies; a running dataset is backed up first, optionally with a
filename description (one prompt, Enter skips). The separate persistent
recovery policy (`OTBR_AUTO_RESTORE_DATASET`/`OTBR_AUTO_CREATE_NETWORK`,
offered as one wizard menu) governs later deploys that find no dataset and no
pending action; a new network is only ever created automatically when no
latest backup exists, and production should keep `1`/`0` (restore, never
create). The units in `systemd/` schedule dataset backups when OTBR is
selected.

Owned files: `compose.yml`, `provision.sh`, `status.sh`, `network-create.sh`, `dataset/` and `systemd/`. See the
[service reference](../../docs/services/otbr.md) and
[recovery runbook](../../docs/operations/service-recovery/otbr.md).
