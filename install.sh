#!/bin/bash
set -euo pipefail

# === Coolify Scripts Installer ===
# Downloads migration scripts from GitHub.
# Set INSTALL env var to pick specific scripts, or omit for all.
#
#   curl ... | bash                              # all scripts
#   curl ... | INSTALL=backup,restore bash       # just those two

REPO="ejscheepers/coolify-scripts"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

# --- Map short names to filenames ---
declare -A SCRIPT_MAP=(
    [backup]="backup.sh"
    [transfer]="transfer.sh"
    [restore]="restore.sh"
    [converter]="coolify-stack-converter.sh"
)

ALL_SCRIPTS=("backup.sh" "transfer.sh" "restore.sh" "coolify-stack-converter.sh")

# --- Resolve INSTALL env var ---
SCRIPTS=()

if [[ -z "${INSTALL:-}" ]]; then
    SCRIPTS=("${ALL_SCRIPTS[@]}")
else
    IFS=',' read -ra SELECTIONS <<< "$INSTALL"
    for SEL in "${SELECTIONS[@]}"; do
        SEL=$(echo "$SEL" | xargs) # trim whitespace
        if [[ -n "${SCRIPT_MAP[$SEL]+x}" ]]; then
            SCRIPTS+=("${SCRIPT_MAP[$SEL]}")
        else
            echo -e "${RED}Unknown script: '$SEL'${NC}"
            echo "Available: backup, transfer, restore, converter"
            exit 1
        fi
    done
fi

# Deduplicate
SCRIPTS=($(printf '%s\n' "${SCRIPTS[@]}" | sort -u))

echo ""
echo -e "${CYAN}Coolify Migration Scripts — Installer${NC}"
echo "────────────────────────────────────────"
echo -e "${DIM}Installing ${#SCRIPTS[@]} script(s)...${NC}"
echo ""

FAILED=0
for SCRIPT in "${SCRIPTS[@]}"; do
    if curl -fsSLO "$BASE_URL/$SCRIPT"; then
        chmod +x "$SCRIPT"
        echo -e "  ${GREEN}✓${NC} $SCRIPT"
    else
        echo -e "  ${RED}✗${NC} $SCRIPT (download failed)"
        FAILED=1
    fi
done

echo ""
if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${RED}Some scripts failed to download. Check your network or the repo URL.${NC}"
    exit 1
fi

echo ""
echo "Usage:"
for SCRIPT in "${SCRIPTS[@]}"; do
    case "$SCRIPT" in
        backup.sh)                    echo "  ./backup.sh                      # Back up a Docker volume" ;;
        transfer.sh)                  echo "  ./transfer.sh                    # Transfer backups via Tailscale" ;;
        restore.sh)                   echo "  ./restore.sh                     # Restore a backup into a volume" ;;
        coolify-stack-converter.sh)   echo "  sudo ./coolify-stack-converter.sh # Migrate standalone stack to Coolify" ;;
    esac
done
echo ""
