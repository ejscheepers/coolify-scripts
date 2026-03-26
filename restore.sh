#!/bin/bash
set -euo pipefail

# === Coolify Volume Restore Agent ===
# Restores a compressed tar backup into a Docker volume.

SCRIPT_NAME="Restore Agent"

# --- Colors & Helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[ $SCRIPT_NAME ]${NC} [ INFO ] $1"; }
success() { echo -e "${GREEN}[ $SCRIPT_NAME ]${NC} [ ✓ OK ] $1"; }
warn()    { echo -e "${YELLOW}[ $SCRIPT_NAME ]${NC} [ WARN ] $1"; }
error()   { echo -e "${RED}[ $SCRIPT_NAME ]${NC} [ ERROR ] $1"; }
prompt()  { echo -en "${CYAN}[ $SCRIPT_NAME ]${NC} [ INPUT ] $1"; }

die() { error "$1"; error "Restore failed!"; exit 1; }

# --- List Docker volumes ---
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
    prompt "Target Docker volume name to restore into: "
    read -r TARGET_VOLUME
    if [[ -z "$TARGET_VOLUME" ]]; then
        warn "Volume name cannot be empty."
        continue
    fi
    if docker volume ls --quiet | grep -qx "$TARGET_VOLUME"; then
        break
    fi
    warn "Volume '$TARGET_VOLUME' does not exist."
    prompt "Create it? (y/N): "
    read -r CREATE_VOL
    if [[ "${CREATE_VOL,,}" == "y" ]]; then
        docker volume create "$TARGET_VOLUME" || { warn "Failed to create volume. Try again."; continue; }
        success "Volume '$TARGET_VOLUME' created."
        break
    fi
    warn "Try a different volume name."
done

# --- Backup Directory ---
while true; do
    prompt "Backup directory (default: ./volume-backup): "
    read -r BACKUP_DIR
    BACKUP_DIR=${BACKUP_DIR:-./volume-backup}

    if [[ "$BACKUP_DIR" = /* ]]; then
        ABS_BACKUP_DIR="$BACKUP_DIR"
    else
        ABS_BACKUP_DIR="$(pwd)/$BACKUP_DIR"
    fi

    if [[ ! -d "$ABS_BACKUP_DIR" ]]; then
        warn "Directory not found: $ABS_BACKUP_DIR — try again."
        continue
    fi

    BACKUPS=($(ls -1t "$ABS_BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        warn "No .tar.gz files found in '$ABS_BACKUP_DIR'. Try a different directory."
        continue
    fi
    break
done

echo ""
info "Available backups (newest first):"
echo "────────────────────────────────────────"
for i in "${!BACKUPS[@]}"; do
    FILE_SIZE=$(du -h "${BACKUPS[$i]}" | cut -f1)
    echo -e "  ${CYAN}[$((i+1))]${NC} $(basename "${BACKUPS[$i]}") (${FILE_SIZE})"
done
echo "────────────────────────────────────────"

while true; do
    prompt "Select backup file [1]: "
    read -r FILE_SEL
    FILE_SEL=${FILE_SEL:-1}
    if [[ "$FILE_SEL" =~ ^[0-9]+$ ]] && (( FILE_SEL >= 1 && FILE_SEL <= ${#BACKUPS[@]} )); then
        BACKUP_FILE=$(basename "${BACKUPS[$((FILE_SEL-1))]}")
        break
    fi
    warn "Invalid selection '$FILE_SEL'. Enter a number between 1 and ${#BACKUPS[@]}."
done

FULL_BACKUP_PATH="$ABS_BACKUP_DIR/$BACKUP_FILE"

# --- Database Type (for permission fixing) ---
echo ""
info "Permission ownership presets:"
echo -e "  ${CYAN}[1]${NC} PostgreSQL (UID 999:999)"
echo -e "  ${CYAN}[2]${NC} MySQL/MariaDB (UID 999:999)"
echo -e "  ${CYAN}[3]${NC} Redis (UID 999:1000)"
echo -e "  ${CYAN}[4]${NC} MongoDB (UID 999:999)"
echo -e "  ${CYAN}[5]${NC} None — skip permission fix"

while true; do
    prompt "Select permission preset [5]: "
    read -r DB_TYPE
    DB_TYPE=${DB_TYPE:-5}
    case "$DB_TYPE" in
        1) CHOWN_SPEC="999:999"; DB_LABEL="PostgreSQL"; break ;;
        2) CHOWN_SPEC="999:999"; DB_LABEL="MySQL/MariaDB"; break ;;
        3) CHOWN_SPEC="999:1000"; DB_LABEL="Redis"; break ;;
        4) CHOWN_SPEC="999:999"; DB_LABEL="MongoDB"; break ;;
        5) CHOWN_SPEC=""; DB_LABEL="None"; break ;;
        *) warn "Invalid selection '$DB_TYPE'. Enter a number between 1 and 5." ;;
    esac
done

# --- Safety Confirmation ---
echo ""
echo "────────────────────────────────────────"
info "Restore summary:"
info "  Volume      : $TARGET_VOLUME"
info "  Backup file : $BACKUP_FILE"
info "  Permissions : $DB_LABEL ${CHOWN_SPEC:+($CHOWN_SPEC)}"
echo "────────────────────────────────────────"
warn "This will OVERWRITE all data in '$TARGET_VOLUME'!"
warn "Ensure containers using this volume are STOPPED."
prompt "Proceed with restore? (y/N): "
read -r CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && die "Cancelled by user."

# --- Optional Pre-Restore Safety Backup ---
prompt "Create a safety backup of the volume before overwriting? (y/N): "
read -r SAFETY_BACKUP
if [[ "${SAFETY_BACKUP,,}" == "y" ]]; then
    SAFETY_FILE="${TARGET_VOLUME}-pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
    info "Creating safety backup: $ABS_BACKUP_DIR/$SAFETY_FILE ..."
    docker run --rm \
      -v "$TARGET_VOLUME":/volume:ro \
      -v "$ABS_BACKUP_DIR":/backup \
      busybox \
      tar czf /backup/"$SAFETY_FILE" -C /volume . || warn "Safety backup failed — continuing anyway."
    success "Safety backup saved."
fi

# --- Restore ---
info "Restoring volume from '$BACKUP_FILE'..."
docker run --rm \
  -v "$TARGET_VOLUME":/volume \
  -v "$ABS_BACKUP_DIR":/backup \
  busybox \
  sh -c "rm -rf /volume/* /volume/..?* /volume/.[!.]* 2>/dev/null; tar -xzf /backup/$BACKUP_FILE -C /volume" \
  || die "Extraction failed."

success "Extraction complete."

# --- Permission Fix ---
if [[ -n "$CHOWN_SPEC" ]]; then
    info "Applying $DB_LABEL permissions ($CHOWN_SPEC)..."
    docker run --rm -v "$TARGET_VOLUME":/volume busybox chown -R "$CHOWN_SPEC" /volume \
      || warn "Permission fix may have partially failed."
    success "Permissions applied."
fi

echo ""
success "Restore complete! You can now start your containers."
