#!/bin/bash
set -euo pipefail

# === Coolify Volume Backup Agent ===
# Backs up a Docker volume to a compressed tar archive.

SCRIPT_NAME="Backup Agent"

# --- Colors & Helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[ $SCRIPT_NAME ]${NC} [ INFO ] $1"; }
success() { echo -e "${GREEN}[ $SCRIPT_NAME ]${NC} [ ✓ OK ] $1"; }
warn()    { echo -e "${YELLOW}[ $SCRIPT_NAME ]${NC} [ WARN ] $1"; }
error()   { echo -e "${RED}[ $SCRIPT_NAME ]${NC} [ ERROR ] $1"; }
prompt()  { echo -en "${CYAN}[ $SCRIPT_NAME ]${NC} [ INPUT ] $1"; }

die() { error "$1"; error "Backup failed!"; exit 1; }

# --- List Docker volumes for convenience ---
list_volumes() {
    echo ""
    info "Available Docker volumes:"
    echo "────────────────────────────────────────"
    docker volume ls --format "  {{.Name}}" 2>/dev/null || warn "Could not list volumes."
    echo "────────────────────────────────────────"
    echo ""
}

# --- Volume Name ---
list_volumes

while true; do
    prompt "Enter the Docker volume name to back up: "
    read -r VOLUME_NAME
    if [[ -z "$VOLUME_NAME" ]]; then
        warn "Volume name cannot be empty."
    elif docker volume ls --quiet | grep -qx "$VOLUME_NAME"; then
        break
    else
        warn "Volume '$VOLUME_NAME' does not exist. Try again."
    fi
done
info "Volume '$VOLUME_NAME' found."

# --- Backup Directory ---
prompt "Backup directory (default: ./volume-backup): "
read -r BACKUP_DIR
BACKUP_DIR=${BACKUP_DIR:-./volume-backup}

# Resolve to absolute path for Docker mount compatibility
if [[ "$BACKUP_DIR" = /* ]]; then
    ABS_BACKUP_DIR="$BACKUP_DIR"
else
    ABS_BACKUP_DIR="$(pwd)/$BACKUP_DIR"
fi

# --- Timestamped Backup Filename ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${VOLUME_NAME}-backup-${TIMESTAMP}.tar.gz"

info "Backup directory : $ABS_BACKUP_DIR"
info "Backup file      : $BACKUP_FILE"

# --- Create Directory ---
if [[ ! -d "$ABS_BACKUP_DIR" ]]; then
    info "Creating directory '$ABS_BACKUP_DIR'..."
    mkdir -p "$ABS_BACKUP_DIR" || die "Failed to create directory '$ABS_BACKUP_DIR'."
fi

# --- Perform Backup ---
info "Backing up volume '$VOLUME_NAME'..."

docker run --rm \
  -v "$VOLUME_NAME":/volume:ro \
  -v "$ABS_BACKUP_DIR":/backup \
  busybox \
  tar czf /backup/"$BACKUP_FILE" -C /volume . || die "Docker backup process failed."

# --- Report Size ---
BACKUP_SIZE=$(du -h "$ABS_BACKUP_DIR/$BACKUP_FILE" | cut -f1)
success "Backup complete! ($BACKUP_SIZE)"
info "File: $ABS_BACKUP_DIR/$BACKUP_FILE"
