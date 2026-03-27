#!/bin/bash
set -euo pipefail

# === Coolify Volume Migrator ===
# End-to-end Docker volume migration: backup → transfer → restore.
# Runs on the SOURCE server, restores remotely via Tailscale SSH.

SCRIPT_NAME="Volume Migrator"

# --- Colors & Helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[ $SCRIPT_NAME ]${NC} [ INFO ] $1"; }
success() { echo -e "${GREEN}[ $SCRIPT_NAME ]${NC} [ ✓ OK ] $1"; }
warn()    { echo -e "${YELLOW}[ $SCRIPT_NAME ]${NC} [ WARN ] $1"; }
error()   { echo -e "${RED}[ $SCRIPT_NAME ]${NC} [ ERROR ] $1"; }
prompt()  { echo -en "${CYAN}[ $SCRIPT_NAME ]${NC} [ INPUT ] $1"; }

die() { error "$1"; exit 1; }

# --- Cleanup Trap ---
LOCAL_BACKUP_FILE=""
cleanup() {
    if [[ -n "$LOCAL_BACKUP_FILE" && -f "$LOCAL_BACKUP_FILE" ]]; then
        rm -f "$LOCAL_BACKUP_FILE"
    fi
}
trap cleanup EXIT

# --- Defaults (override via env) ---
DEFAULT_SSH_USER="${MIGRATE_SSH_USER:-}"
DEFAULT_SSH_IP="${MIGRATE_SSH_IP:-}"
DEFAULT_REMOTE_DIR="${MIGRATE_REMOTE_DIR:-/tmp/volume-migrate}"

echo ""
echo "────────────────────────────────────────────────"
info "Coolify Volume Migrator (Backup → Transfer → Restore)"
echo "────────────────────────────────────────────────"

# ─── 1. Source Volume ─────────────────────────────

echo ""
info "--- Source Volume (this server) ---"
echo ""
info "Available Docker volumes:"
echo "────────────────────────────────────────"
docker volume ls --format "  {{.Name}}" 2>/dev/null || warn "Could not list volumes."
echo "────────────────────────────────────────"
echo ""

while true; do
    prompt "Docker volume to migrate: "
    read -r SOURCE_VOLUME
    if [[ -z "$SOURCE_VOLUME" ]]; then
        warn "Volume name cannot be empty."
    elif docker volume ls --quiet | grep -qx "$SOURCE_VOLUME"; then
        break
    else
        warn "Volume '$SOURCE_VOLUME' does not exist. Try again."
    fi
done
success "Volume '$SOURCE_VOLUME' found."

# ─── 2. Remote Connection (Tailscale) ────────────

echo ""
info "--- Remote Server (Tailscale) ---"

while true; do
    prompt "SSH username${DEFAULT_SSH_USER:+ (default: $DEFAULT_SSH_USER)}: "
    read -r SSH_USER
    SSH_USER=${SSH_USER:-$DEFAULT_SSH_USER}
    [[ -n "$SSH_USER" ]] && break
    warn "SSH username is required."
done

while true; do
    prompt "Tailscale IP${DEFAULT_SSH_IP:+ (default: $DEFAULT_SSH_IP)}: "
    read -r SSH_IP
    SSH_IP=${SSH_IP:-$DEFAULT_SSH_IP}
    [[ -n "$SSH_IP" ]] && break
    warn "Tailscale IP is required."
done

SSH_TARGET="$SSH_USER@$SSH_IP"

info "Testing SSH connection to $SSH_TARGET..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_TARGET" "echo ok" &>/dev/null; then
    die "Cannot reach $SSH_TARGET via SSH. Check Tailscale and SSH config."
fi
success "SSH connection OK."

# ─── 3. Target Volume ────────────────────────────

echo ""
info "--- Target Volume (remote server) ---"
echo ""
info "Docker volumes on $SSH_IP:"
echo "────────────────────────────────────────"
ssh "$SSH_TARGET" "docker volume ls --format '  {{.Name}}'" 2>/dev/null || warn "Could not list remote volumes."
echo "────────────────────────────────────────"
echo ""

while true; do
    prompt "Target volume name (default: $SOURCE_VOLUME): "
    read -r TARGET_VOLUME
    TARGET_VOLUME=${TARGET_VOLUME:-$SOURCE_VOLUME}
    if [[ -z "$TARGET_VOLUME" ]]; then
        warn "Volume name cannot be empty."
        continue
    fi

    if ssh "$SSH_TARGET" "docker volume ls --quiet | grep -qx '$TARGET_VOLUME'" 2>/dev/null; then
        break
    fi

    warn "Volume '$TARGET_VOLUME' does not exist on remote."
    prompt "Create it? (y/N): "
    read -r CREATE_VOL
    if [[ "${CREATE_VOL,,}" == "y" ]]; then
        if ssh "$SSH_TARGET" "docker volume create '$TARGET_VOLUME'" &>/dev/null; then
            success "Volume '$TARGET_VOLUME' created on remote."
            break
        fi
        warn "Failed to create volume. Try again."
    else
        warn "Try a different volume name."
    fi
done

# ─── 4. Permission Preset ────────────────────────

echo ""
info "Permission ownership presets (applied on remote after restore):"
echo -e "  ${CYAN}[1]${NC} PostgreSQL (UID 999:999)"
echo -e "  ${CYAN}[2]${NC} MySQL/MariaDB (UID 999:999)"
echo -e "  ${CYAN}[3]${NC} Redis (UID 999:1000)"
echo -e "  ${CYAN}[4]${NC} MongoDB (UID 999:999)"
echo -e "  ${CYAN}[5]${NC} None — skip permission fix"

while true; do
    prompt "Select permission preset [5]: "
    read -r PERM_SEL
    PERM_SEL=${PERM_SEL:-5}
    case "$PERM_SEL" in
        1) CHOWN_SPEC="999:999";  PERM_LABEL="PostgreSQL"; break ;;
        2) CHOWN_SPEC="999:999";  PERM_LABEL="MySQL/MariaDB"; break ;;
        3) CHOWN_SPEC="999:1000"; PERM_LABEL="Redis"; break ;;
        4) CHOWN_SPEC="999:999";  PERM_LABEL="MongoDB"; break ;;
        5) CHOWN_SPEC="";         PERM_LABEL="None"; break ;;
        *) warn "Invalid selection '$PERM_SEL'. Enter a number between 1 and 5." ;;
    esac
done

# ─── 5. Safety Backup Option ─────────────────────

echo ""
prompt "Create a safety backup of the REMOTE volume before overwriting? (y/N): "
read -r SAFETY_BACKUP

# ─── 6. Confirm ──────────────────────────────────

echo ""
echo "────────────────────────────────────────────────"
info "Migration Plan:"
info "  Source volume : $SOURCE_VOLUME (local)"
info "  Target volume : $TARGET_VOLUME ($SSH_IP)"
info "  Permissions   : $PERM_LABEL ${CHOWN_SPEC:+($CHOWN_SPEC)}"
info "  Safety backup : ${SAFETY_BACKUP,,:-n}"
echo "────────────────────────────────────────────────"
warn "This will OVERWRITE all data in the remote volume '$TARGET_VOLUME'!"
warn "Ensure containers using the remote volume are STOPPED."
prompt "Proceed? (y/N): "
read -r CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && die "Cancelled."

# ─── 7. Backup (local) ───────────────────────────

echo ""
info "--- Step 1/4: Backup ---"

BACKUP_DIR="$(mktemp -d)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="${SOURCE_VOLUME}-backup-${TIMESTAMP}.tar.gz"
LOCAL_BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"

info "Backing up volume '$SOURCE_VOLUME'..."
docker run --rm \
  -v "$SOURCE_VOLUME":/volume:ro \
  -v "$BACKUP_DIR":/backup \
  busybox \
  tar czf /backup/"$BACKUP_FILE" -C /volume . || die "Backup failed."

BACKUP_SIZE=$(du -h "$LOCAL_BACKUP_FILE" | cut -f1)
success "Backup complete ($BACKUP_SIZE)."

# ─── 8. Transfer ─────────────────────────────────

echo ""
info "--- Step 2/4: Transfer ---"

REMOTE_DIR="$DEFAULT_REMOTE_DIR"
info "Ensuring remote directory $REMOTE_DIR exists..."
ssh "$SSH_TARGET" "mkdir -p '$REMOTE_DIR'" || die "Could not create remote directory."

info "Transferring $BACKUP_FILE ($BACKUP_SIZE)..."
if ! scp -rpC "$LOCAL_BACKUP_FILE" "$SSH_TARGET:$REMOTE_DIR/$BACKUP_FILE"; then
    die "Transfer failed. Hint: run 'sudo ufw allow in on tailscale0' on the target host."
fi
success "Transfer complete."

# Clean up local temp file immediately
rm -f "$LOCAL_BACKUP_FILE"
LOCAL_BACKUP_FILE=""

# ─── 9. Remote Restore ───────────────────────────

echo ""
info "--- Step 3/4: Remote Restore ---"

if [[ "${SAFETY_BACKUP,,}" == "y" ]]; then
    info "Creating safety backup of '$TARGET_VOLUME' on remote..."
    SAFETY_FILE="${TARGET_VOLUME}-pre-migrate-${TIMESTAMP}.tar.gz"
    ssh "$SSH_TARGET" "docker run --rm \
      -v '$TARGET_VOLUME':/volume:ro \
      -v '$REMOTE_DIR':/backup \
      busybox \
      tar czf /backup/'$SAFETY_FILE' -C /volume ." \
      || warn "Safety backup failed — continuing anyway."
    success "Safety backup saved on remote: $REMOTE_DIR/$SAFETY_FILE"
fi

info "Restoring into remote volume '$TARGET_VOLUME'..."
ssh "$SSH_TARGET" "docker run --rm \
  -v '$TARGET_VOLUME':/volume \
  -v '$REMOTE_DIR':/backup \
  busybox \
  sh -c \"rm -rf /volume/* /volume/..?* /volume/.[!.]* 2>/dev/null; tar -xzf /backup/'$BACKUP_FILE' -C /volume\"" \
  || die "Remote restore failed."

success "Restore complete."

if [[ -n "$CHOWN_SPEC" ]]; then
    info "Applying $PERM_LABEL permissions ($CHOWN_SPEC) on remote..."
    ssh "$SSH_TARGET" "docker run --rm \
      -v '$TARGET_VOLUME':/volume \
      busybox \
      chown -R '$CHOWN_SPEC' /volume" \
      || warn "Permission fix may have partially failed."
    success "Permissions applied."
fi

# ─── 10. Cleanup ─────────────────────────────────

echo ""
info "--- Step 4/4: Cleanup ---"

info "Removing transferred backup from remote..."
ssh "$SSH_TARGET" "rm -f '$REMOTE_DIR/$BACKUP_FILE'" || warn "Could not remove remote backup file."
ssh "$SSH_TARGET" "rmdir '$REMOTE_DIR' 2>/dev/null" || true
success "Cleanup complete."

# ─── Done ─────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────────"
success "MIGRATION COMPLETE"
echo "────────────────────────────────────────────────"
info "Volume '$SOURCE_VOLUME' → '$TARGET_VOLUME' on $SSH_IP"
info "You can now start containers using the remote volume."
