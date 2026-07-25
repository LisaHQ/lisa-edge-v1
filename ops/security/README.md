# Security Audit and Hardening

Operator entry points:

```bash
sudo ./lisa-edge security audit            # read-only inspection
sudo ./lisa-edge security audit --strict   # nonzero exit on DEGRADED too
sudo ./lisa-edge security harden           # bounded, lockout-safe remediation
```

`audit.sh` is read-only by contract (tests prove it), requires no Internet
access, never prints secret material, and reports HEALTHY/DEGRADED/FAILED
with the same exit-code model as `lisa-edge health` (0 HEALTHY or
non-strict DEGRADED, 1 FAILED, 2 usage, 3 DEGRADED with `--strict`).

`harden.sh` performs only provably safe remediation and fails closed with
the exact manual correction otherwise. Lockout rules: SSH password login is
disabled only after a usable non-root authorized key is verified (with
`sshd -t` validation before any reload), passwordless sudo removal reuses
`install/bootstrap/finalize-admin-access.sh` and requires a usable password,
and docker group membership is never changed automatically.

`lib.sh` holds the shared pure helpers so tests can exercise the checks
without touching a live host. Audit logic and remediation logic are kept in
separate scripts on purpose.

Security model and rationale: [docs/security/security-model.md](../../docs/security/security-model.md).
