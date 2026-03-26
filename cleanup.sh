#!/bin/bash
set -euo pipefail

# === Coolify Scripts Cleanup ===
# Removes installed scripts and optionally backup files.

SCRIPT_NAME="Cleanup"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[ $SCRIPT_NAME ]${NC} [ INFO ] $1"; }
success() { echo -e "${GREEN}[ $SCRIPT_NAME ]${NC} [ ✓ OK ] $1"; }
warn()    { echo -e "${YELLOW}[ $SCRIPT_NAME ]${NC} [ WARN ] $1"; }
prompt()  { echo -en "${CYAN}[ $SCRIPT_NAME ]${NC} [ INPUT ] $1"; }

SCRIPTS=(
    "backup.sh"
    "transfer.sh"
    "restore.sh"
    "coolify-stack-converter.sh"
    "install.sh"
)

BACKUP_DIR="./volume-backup"

echo ""
echo "────────────────────────────────────────"
info "Coolify Scripts Cleanup"
echo "────────────────────────────────────────"
echo ""

# --- Show what will be removed ---
FOUND_SCRIPTS=()
for S in "${SCRIPTS[@]}"; do
    [[ -f "$S" ]] && FOUND_SCRIPTS+=("$S")
done

HAS_BACKUPS=false
if [[ -d "$BACKUP_DIR" ]]; then
    BACKUP_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l | xargs)
    BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    HAS_BACKUPS=true
fi

if [[ ${#FOUND_SCRIPTS[@]} -eq 0 ]] && [[ "$HAS_BACKUPS" == false ]]; then
    info "Nothing to clean up."
    exit 0
fi

if [[ ${#FOUND_SCRIPTS[@]} -gt 0 ]]; then
    info "Scripts found:"
    for S in "${FOUND_SCRIPTS[@]}"; do
        echo -e "  ${CYAN}•${NC} $S"
    done
fi

if [[ "$HAS_BACKUPS" == true ]]; then
    echo ""
    info "Backup directory: $BACKUP_DIR ($BACKUP_SIZE, $BACKUP_COUNT archive(s))"
fi

echo ""

# --- Confirm script removal ---
if [[ ${#FOUND_SCRIPTS[@]} -gt 0 ]]; then
    prompt "Delete scripts? (y/N): "
    read -r DEL_SCRIPTS
    if [[ "${DEL_SCRIPTS,,}" == "y" ]]; then
        for S in "${FOUND_SCRIPTS[@]}"; do
            rm -f "$S"
            success "Removed $S"
        done
    else
        info "Keeping scripts."
    fi
fi

# --- Confirm backup removal ---
if [[ "$HAS_BACKUPS" == true ]]; then
    echo ""
    warn "Backup directory contains $BACKUP_COUNT archive(s) ($BACKUP_SIZE)."
    prompt "Delete $BACKUP_DIR and all backups? (y/N): "
    read -r DEL_BACKUPS
    if [[ "${DEL_BACKUPS,,}" == "y" ]]; then
        rm -rf "$BACKUP_DIR"
        success "Removed $BACKUP_DIR"
    else
        info "Keeping backups."
    fi
fi

# --- Self-destruct ---
echo ""
if [[ -f "cleanup.sh" ]]; then
    prompt "Remove this cleanup script too? (y/N): "
    read -r DEL_SELF
    if [[ "${DEL_SELF,,}" == "y" ]]; then
        success "All clean. Goodbye!"
        rm -f "cleanup.sh"
        exit 0
    fi
fi

echo ""
success "Cleanup complete."
