# Coolify Migration Scripts

A set of bash scripts for migrating Docker volumes and application stacks between [Coolify](https://coolify.io) servers over a [Tailscale](https://tailscale.com) network.

## Quick Install

Download all scripts to the current directory:

```bash
curl -fsSL https://raw.githubusercontent.com/ejscheepers/coolify-scripts/main/install.sh | bash
```

Or pick only the scripts you need:

```bash
# Just backup + restore
curl -fsSL https://raw.githubusercontent.com/ejscheepers/coolify-scripts/main/install.sh | INSTALL=backup,restore bash

# Just the transfer script
curl -fsSL https://raw.githubusercontent.com/ejscheepers/coolify-scripts/main/install.sh | INSTALL=transfer bash

# Just the stack converter
curl -fsSL https://raw.githubusercontent.com/ejscheepers/coolify-scripts/main/install.sh | INSTALL=converter bash
```

Available names: `backup`, `transfer`, `restore`, `converter`, `cleanup`

## Scripts

### `backup.sh` — Volume Backup

Backs up a Docker volume to a timestamped `.tar.gz` archive.

```bash
./backup.sh
```

- Lists available Docker volumes for easy selection
- Saves to `./volume-backup/` by default (configurable)
- Timestamped filenames prevent accidental overwrites
- Reports backup size on completion

### `transfer.sh` — Tailscale SCP Transfer

Transfers backup files to a remote server over Tailscale SSH.

```bash
./transfer.sh
```

- Fully interactive — prompts for SSH user, Tailscale IP, and paths
- Lists available backups with file sizes for selection
- Transfer a single file or all backups at once
- Creates the remote directory automatically
- Supports env-var defaults: `TRANSFER_SSH_USER`, `TRANSFER_SSH_IP`, `TRANSFER_SOURCE_DIR`, `TRANSFER_DEST_DIR`

### `restore.sh` — Volume Restore

Restores a `.tar.gz` backup into a Docker volume.

```bash
./restore.sh
```

- Lists available volumes and backup files for selection
- Permission presets for PostgreSQL, MySQL/MariaDB, Redis, and MongoDB
- Optional safety backup of the target volume before overwriting
- Creates the target volume if it doesn't exist

### `coolify-stack-converter.sh` — Stack Converter

Migrates a standalone Docker Compose stack (with bind-mounted databases) into Coolify-managed dedicated database containers using Docker volumes.

```bash
sudo ./coolify-stack-converter.sh
```

> **Note:** Requires `sudo` because it directly accesses Docker volume paths on disk for Redis file-level migration.

- Handles PostgreSQL (pg_dump/psql) and Redis (physical file copy)
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
Source Server                          Target Server
─────────────                          ─────────────
1. ./backup.sh                         3. ./restore.sh
2. ./transfer.sh ──── Tailscale ────►
```

Or for full standalone-to-Coolify conversions, run `coolify-stack-converter.sh` directly on the server.

## Requirements

- Docker
- Tailscale (for `transfer.sh`)
- `bash` 4.0+
