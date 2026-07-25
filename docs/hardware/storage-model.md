# Storage Model

LISA Edge separates code, configuration, data, and backups.

Recommended layout:

```text
/opt/lisa-edge    Git repository
/srv/lisa-edge    Docker volumes, state, logs, backup cache
```

## Storage Guidance

Recommended:

- Keep the repository in `/opt/lisa-edge`
- Keep Docker volumes in `${DATA_ROOT}`
- Use SSD for active service data
- Store backups on NAS or external storage
- Avoid heavy writes to weak embedded storage

## Default Data Root

```env
DATA_ROOT=/srv/lisa-edge
```

## Backups

```env
BACKUP_DEST=/srv/lisa-edge/backups
```

For production, sync backups to another machine or NAS.

When `BACKUP_DEST` is a NAS or removable mount, enable mount enforcement so a
missing mount fails the backup instead of silently writing to the production
root filesystem. Configure this through `sudo ./lisa-edge setup` (a full pass, or the
`Edit configuration only` action).
