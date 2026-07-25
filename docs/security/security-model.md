# Security Model

LISA Edge should be treated as infrastructure.

## Principles

- VPN-first administration
- No public admin dashboards
- SSH key authentication
- Disable SSH password login
- Minimal exposed ports
- Firewall allowlists
- Secrets outside Git
- Encrypted backups for sensitive data
- Temporary bootstrap-only passwordless sudo
- Immutable container image digests for production releases

The Ubuntu autoinstall account receives passwordless sudo only so unattended
bootstrap can start. Bootstrap removes `/etc/sudoers.d/90-lisa-admin` after a
usable local password is confirmed, unless the operator explicitly enables
the documented emergency override (`LISA_KEEP_PASSWORDLESS_SUDO=1`, default
`0`). Passwordless sudo is a lab/emergency exception, never the normal state.

## Security audit and hardening

```bash
sudo ./lisa-edge security audit            # read-only inspection
sudo ./lisa-edge security audit --strict   # also fail on DEGRADED (monitoring)
sudo ./lisa-edge security harden           # bounded, lockout-safe remediation
```

The audit is read-only, needs no Internet access, never prints secrets, and
reports HEALTHY/DEGRADED/FAILED with the same exit-code model as `health`
(nonzero only for FAILED; `--strict` also fails on DEGRADED). It checks: the
actual sudo state of `LISA_ADMIN_USER` against `LISA_KEEP_PASSWORDLESS_SUDO`;
the admin account and its administrative path; effective SSH settings via
`sshd -T` (`PermitRootLogin`, `PasswordAuthentication`,
`KbdInteractiveAuthentication`) and SSH syntax validity; usable authorized
keys and `.ssh` permissions; `.env` ownership/mode and Git tracking; unsafe
Docker TCP listeners (the local Unix socket is never flagged); docker group
membership (root-equivalent - reported, never changed automatically); the
Matter wildcard bind (`MATTER_LISTEN_ADDRESS=0.0.0.0`); and permissions on
the canonical OTBR/Matter backup directories. Firewall allowlists remain
deployment-specific and are not managed by the audit.

`security harden` performs only bounded, provably safe remediation: it fixes
LISA-owned file modes, fixes the admin account's SSH file ownership/modes,
removes the temporary passwordless sudo grant only after a usable password
is verified or interactively established, disables SSH password login only
after a usable non-root authorized key is verified (and validates the
configuration with `sshd -t` before any reload), and offers to replace a
Matter wildcard bind with an operator-selected address. It never removes
users from the docker group and fails closed with the exact manual
correction whenever safety cannot be proven.

## Sensitive Services

Protect:

- MQTT
- OTBR dataset backups and exports (`otbr dataset export` files are 0600 and
  contain the complete Thread credentials)
- Matter data backups (fabric credentials) and the Matter WebSocket API
- VPN state
- Home Assistant config
- Zigbee2MQTT keys
- NUT control access

## Matter WebSocket exposure

The Matter server's WebSocket API has no authentication and controls the
whole fabric. It binds to `MATTER_LISTEN_ADDRESS` (default `127.0.0.1`).
Rules:

- keep the default loopback bind unless a REMOTE Home Assistant needs it;
- when remote access is required, bind a specific trusted address and
  firewall `MATTER_SERVER_PORT` (default 5580) to the controller network;
- never bind `0.0.0.0` without an explicit firewall allowlist (deploy warns);
- never publish the port through a public reverse proxy.

CLI output is secret-safe by design: `otbr dataset show` redacts the network
key and PSKc, status/health/diagnostics never print credentials, and the
Thread dataset is never passed through process arguments or logs.

NUT is planned rather than currently selectable. Its control interface must be
treated as sensitive when the service is implemented.

## Network Segmentation

Use VLANs or separate subnets when available.

At minimum, separate:

- trusted users
- IoT devices
- cameras
- servers
- management
- guests

Use the [Deployment Checklist](../getting-started/04-deployment-checklist.md)
before exposing a new service and the
[Deployment Validation](../getting-started/05-deployment-validation.md) after
changes.
