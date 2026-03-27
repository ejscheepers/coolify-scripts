# Coolify Migration Scripts

A set of bash scripts for migrating Docker volumes and application stacks between [Coolify](https://coolify.io) servers over a [Tailscale](https://tailscale.com) network.

## Quick Install

Download all scripts to the current directory:

```bash
curl -fsSL https://raw.githubusercontent.com/ejscheepers/coolify-scripts/main/install.sh | bash
```

Or pick only the scripts you need:

```bash
# Just the volume migrator
curl -fsSL https://raw.githubusercontent.com/ejscheepers/coolify-scripts/main/install.sh | INSTALL=migrate bash

# Just the stack converter
curl -fsSL https://raw.githubusercontent.com/ejscheepers/coolify-scripts/main/install.sh | INSTALL=converter bash
```

Available names: `migrate`, `converter`, `cleanup`

## Scripts

### `migrate-volume.sh` — Volume Migration

End-to-end volume migration that combines backup, transfer, and restore into a single command. Runs on the source server and restores remotely via Tailscale SSH.

```bash
./migrate-volume.sh
```

- Single command: backup → SCP transfer → remote restore
- **Multiple volume pairs** in one run: choose how many mappings (e.g. three locals → three remotes) in order
- Lists local and remote Docker volumes for selection
- Tests SSH connectivity before starting
- **Permissions match the source** (tar preserves mode and ownership)
- Optional safety backup of each remote volume before overwriting
- Automatic cleanup of temp files on both servers
- Supports env-var defaults: `MIGRATE_SSH_USER`, `MIGRATE_SSH_IP`, `MIGRATE_REMOTE_DIR`

### `coolify-stack-converter.sh` — Stack Converter

Migrates Docker Compose stacks between environments (standalone ↔ Coolify). Supports Redis data stored in Docker volumes or bind-mount directories.

```bash
sudo ./coolify-stack-converter.sh
```

> **Note:** Requires `sudo` because it directly accesses Docker volume paths on disk for Redis file-level migration.

- Handles PostgreSQL (pg_dump/psql) and Redis (physical file copy)
- Redis source/target can be a Docker volume or a host directory
- Validates all containers exist before starting
- Aborts if pg_dump produces an empty file
- Auto-detects Coolify-assigned Redis passwords
- Cleans up temp files on failure

### `cleanup.sh` — Uninstall & Clean Up

Removes all installed scripts and optionally deletes backup files.

```bash
./cleanup.sh
```

- Shows what will be removed before prompting
- Separately confirms script deletion and backup deletion
- Reports backup directory size and file count
- Optionally removes itself when done

## Typical Migration Workflow

```
Source Server ─── ./migrate-volume.sh ── Tailscale ──► Target Server
```

For full standalone-to-Coolify stack conversions (PostgreSQL + Redis), run `coolify-stack-converter.sh` directly on the server.

## Requirements

- Docker
- Tailscale (for `migrate-volume.sh`)
- `bash` 4.0+
