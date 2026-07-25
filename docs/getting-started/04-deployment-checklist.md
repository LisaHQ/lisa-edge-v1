# Deployment Checklist

Use this checklist before a fresh setup, restore, major service change, or host
replacement.

## Choose exactly one workflow

- [ ] Manual fresh setup on an existing Ubuntu or Debian host
- [ ] Production USB autoinstall to the reviewed SSD
- [ ] Restore from a verified LISA Edge backup
- [ ] Rescue OS install to explicitly identified eMMC

Do not mix manual bootstrap steps into a full `setup` run. The setup wizard
offers to bootstrap and deploy after it writes configuration.

## Host and access

- [ ] Ubuntu Server or Debian is installed for the automated bootstrap path
- [ ] hostname and timezone are decided
- [ ] SSH public-key access works
- [ ] the administrator has a usable local password before temporary
      passwordless sudo is removed
- [ ] the intended Git tag or commit has been reviewed
- [ ] no public admin dashboard is required

Architecture may support other Linux hosts, but their host setup is currently a
manual, unsupported workflow.

## Disk and storage safety

- [ ] installation target is identified by serial or an explicitly reviewed model
- [ ] unrelated disks are disconnected when practical
- [ ] production OS and active data are on SSD or suitable persistent storage
- [ ] Rescue OS targets eMMC explicitly and never uses `size: largest`
- [ ] `DATA_ROOT` is an absolute, dedicated persistent path
- [ ] `BACKUP_DEST` is outside the failure domain of the production SSD
- [ ] a required NAS/removable destination is mounted before setup

Inspect disks:

```bash
lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TYPE,TRAN,MOUNTPOINTS
```

## Network and security

- [ ] static address or DHCP reservation is ready
- [ ] DNS and time synchronization can work
- [ ] firewall rules expose only selected service ports
- [ ] VPN-first administration is planned when remote access is needed
- [ ] management, IoT, camera, guest, and sensitive networks remain isolated
- [ ] `.env`, auth keys, passwords, datasets, and private keys remain outside Git

## Service selection

Review the current service keys:

```bash
./lisa-edge service list
```

- [ ] every selected service has an operational purpose
- [ ] Zigbee2MQTT includes its MQTT dependency
- [ ] serial devices use stable `/dev/serial/by-id/...` paths when available
- [ ] bind addresses and ports do not conflict
- [ ] container images support the host architecture
- [ ] production image pinning policy has been decided
- [ ] planned services such as NUT, DNS helpers, and reverse proxy are not placed
      in `LISA_COMPOSE_SERVICES`

## Backup or restore readiness

- [ ] backup destination and retention are defined
- [ ] mount enforcement is enabled when local fallback would be unsafe
- [ ] restore archive has its matching `.sha256` sidecar
- [ ] backup storage is trusted because archives may contain secrets
- [ ] restored image references will be reviewed before deployment
- [ ] OTBR dataset recovery is planned when Thread is selected

## Preview configuration

Run a non-writing wizard pass:

```bash
./lisa-edge setup --mode config-only --dry-run
```

Resolve unsafe paths, endpoint conflicts, missing dependencies, or image-policy
errors before changing the host.

## Apply

Fresh or interactive restore:

```bash
sudo ./lisa-edge setup
```

Configuration only, applied later:

```bash
sudo ./lisa-edge setup    # choose "Edit configuration only", then later
                          # "Bootstrap or repair this host"
```

After setup, continue with the
[Deployment Validation](05-deployment-validation.md).
