#!/bin/bash
set -euo pipefail

# === Coolify Volume Transfer Agent ===
# Transfers backup files to a remote server via Tailscale SSH / SCP.

SCRIPT_NAME="Transfer Agent"

# --- Colors & Helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[ $SCRIPT_NAME ]${NC} [ INFO ] $1"; }
success() { echo -e "${GREEN}[ $SCRIPT_NAME ]${NC} [ ✓ OK ] $1"; }
warn()    { echo -e "${YELLOW}[ $SCRIPT_NAME ]${NC} [ WARN ] $1"; }
error()   { echo -e "${RED}[ $SCRIPT_NAME ]${NC} [ ERROR ] $1"; }
prompt()  { echo -en "${CYAN}[ $SCRIPT_NAME ]${NC} [ INPUT ] $1"; }

die() { error "$1"; error "Transfer failed!"; exit 1; }

# --- Defaults (override via env or prompts) ---
DEFAULT_SSH_USER="${TRANSFER_SSH_USER:-}"
DEFAULT_SSH_IP="${TRANSFER_SSH_IP:-}"
DEFAULT_SOURCE_DIR="${TRANSFER_SOURCE_DIR:-./volume-backup}"
DEFAULT_DEST_DIR="${TRANSFER_DEST_DIR:-/srv/backups/volume-backup}"

echo ""
echo "────────────────────────────────────────"
info "Tailscale SCP Transfer"
echo "────────────────────────────────────────"

# --- Collect Connection Details ---
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

# --- Source Selection ---
while true; do
    prompt "Local backup directory (default: $DEFAULT_SOURCE_DIR): "
    read -r SOURCE_DIR
    SOURCE_DIR=${SOURCE_DIR:-$DEFAULT_SOURCE_DIR}

    if [[ ! -d "$SOURCE_DIR" ]]; then
        warn "Directory '$SOURCE_DIR' not found. Try again."
        continue
    fi

    BACKUPS=($(ls -1t "$SOURCE_DIR"/*.tar.gz 2>/dev/null))
    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        warn "No .tar.gz backup files found in '$SOURCE_DIR'. Try a different directory."
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
echo -e "  ${CYAN}[A]${NC} Transfer ALL files"
echo "────────────────────────────────────────"

while true; do
    prompt "Select file(s) to transfer [1]: "
    read -r SELECTION
    SELECTION=${SELECTION:-1}

    if [[ "${SELECTION^^}" == "A" ]]; then
        SELECTED_FILES=("${BACKUPS[@]}")
        info "Transferring all ${#BACKUPS[@]} backup(s)."
        break
    elif [[ "$SELECTION" =~ ^[0-9]+$ ]] && (( SELECTION >= 1 && SELECTION <= ${#BACKUPS[@]} )); then
        SELECTED_FILES=("${BACKUPS[$((SELECTION-1))]}")
        break
    fi
    warn "Invalid selection '$SELECTION'. Enter a number between 1 and ${#BACKUPS[@]}, or 'A' for all."
done

# --- Destination ---
prompt "Remote destination path (default: $DEFAULT_DEST_DIR): "
read -r DEST_DIR
DEST_DIR=${DEST_DIR:-$DEFAULT_DEST_DIR}

# --- Confirm ---
echo ""
info "Transfer summary:"
echo "────────────────────────────────────────"
info "  Target : $SSH_USER@$SSH_IP:$DEST_DIR"
for f in "${SELECTED_FILES[@]}"; do
    info "  File   : $(basename "$f")"
done
echo "────────────────────────────────────────"

prompt "Proceed? (Y/n): "
read -r CONFIRM
CONFIRM=${CONFIRM:-y}
[[ "${CONFIRM,,}" != "y" ]] && die "Cancelled by user."

# --- Ensure Remote Directory Exists ---
info "Ensuring remote directory exists..."
ssh "$SSH_USER@$SSH_IP" "mkdir -p '$DEST_DIR'" 2>/dev/null || warn "Could not verify remote directory (may already exist)."

# --- Transfer ---
info "Starting transfer via Tailscale SSH..."
for f in "${SELECTED_FILES[@]}"; do
    FNAME=$(basename "$f")
    info "Transferring $FNAME..."
    if scp -rpC "$f" "$SSH_USER@$SSH_IP:$DEST_DIR/$FNAME"; then
        success "$FNAME transferred."
    else
        error "$FNAME transfer failed."
        warn "Hint: Run 'sudo ufw allow in on tailscale0' on the target host if connections drop."
        exit 1
    fi
done

echo ""
success "All transfers complete!"
