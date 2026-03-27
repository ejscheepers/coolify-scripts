#!/bin/bash
set -euo pipefail

# === Coolify Volume Migrator ===
# End-to-end Docker volume migration: backup → transfer → restore.
# Runs on the SOURCE server, restores remotely via Tailscale SSH.
# Multiple source→target pairs in one run; GNU tar --numeric-owner preserves UID/GID across hosts.

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
BACKUP_DIR=""
cleanup() {
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        rm -rf "$BACKUP_DIR"
    fi
}
trap cleanup EXIT

# --- Defaults (override via env) ---
DEFAULT_SSH_USER="${MIGRATE_SSH_USER:-}"
DEFAULT_SSH_IP="${MIGRATE_SSH_IP:-}"
DEFAULT_REMOTE_DIR="${MIGRATE_REMOTE_DIR:-/tmp/volume-migrate}"
# bookworm-slim ships GNU tar; --numeric-owner keeps UID/GID when passwd differs between hosts
TAR_IMAGE="${MIGRATE_TAR_IMAGE:-debian:bookworm-slim}"

echo ""
echo "────────────────────────────────────────────────"
info "Coolify Volume Migrator (Backup → Transfer → Restore)"
echo "────────────────────────────────────────────────"
info "Archive image: $TAR_IMAGE (GNU tar, numeric UID/GID + permissions from source)"

# Resolve user input to a volume name: index N from list, or exact name if it exists on host.
# Usage: resolve_volume_pick INPUT HOST_CMD
# HOST_CMD: empty = local docker; non-empty = ssh target for "docker volume inspect"
resolve_volume_pick() {
    local input="$1"
    local ssh_target="${2:-}"
    local -a names=("${@:3}")

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$((10#$input))
        if (( idx >= 1 && idx <= ${#names[@]} )); then
            echo "${names[idx - 1]}"
            return 0
        fi
        return 1
    fi
    if [[ -z "$ssh_target" ]]; then
        docker volume inspect "$input" &>/dev/null || return 1
    else
        ssh "$ssh_target" "docker volume inspect '$input'" &>/dev/null || return 1
    fi
    echo "$input"
    return 0
}

# --- 1. How many volume pairs ---

echo ""
info "--- Volume pairs ---"
info "Map each local volume to a destination volume on the remote host (same order: 1st→1st, 2nd→2nd, …)."

while true; do
    prompt "How many volume pairs to migrate? [1]: "
    read -r NUM_PAIRS
    NUM_PAIRS=${NUM_PAIRS:-1}
    if [[ "$NUM_PAIRS" =~ ^[1-9][0-9]*$ ]]; then
        break
    fi
    warn "Enter a positive integer (e.g. 1, 3)."
done

declare -a SOURCE_VOLUMES
declare -a TARGET_VOLUMES

# --- 2. Remote connection (Tailscale) — before picks so lists are meaningful ---

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

# --- 3. Source volumes (this server) — number or name ---

echo ""
info "--- Source volumes (this server) ---"
mapfile -t LOCAL_VOL_NAMES < <(docker volume ls -q 2>/dev/null || true)
if ((${#LOCAL_VOL_NAMES[@]} == 0)); then
    warn "No local Docker volumes listed (is Docker running?)."
else
    info "Pick by number or type the exact volume name:"
    echo "────────────────────────────────────────"
    for j in "${!LOCAL_VOL_NAMES[@]}"; do
        printf '  %2d) %s\n' $((j + 1)) "${LOCAL_VOL_NAMES[j]}"
    done
    echo "────────────────────────────────────────"
fi

for ((i = 1; i <= NUM_PAIRS; i++)); do
    echo ""
    info "Pair $i / $NUM_PAIRS — source (local):"
    while true; do
        prompt "  Number from list or volume name: "
        read -r raw_pick
        if picked=$(resolve_volume_pick "$raw_pick" "" "${LOCAL_VOL_NAMES[@]}"); then
            duplicate=0
            for prev in "${SOURCE_VOLUMES[@]}"; do
                if [[ "$prev" == "$picked" ]]; then
                    duplicate=1
                    break
                fi
            done
            if ((duplicate)); then
                warn "Volume '$picked' is already selected for another pair. Choose a different one."
                continue
            fi
            SOURCE_VOLUMES+=("$picked")
            success "  Source: '$picked'"
            break
        fi
        warn "Invalid choice. Use a list number (1–${#LOCAL_VOL_NAMES[@]}) or an existing volume name."
    done
done

# --- 4. Target volumes (remote) — number or name; auto-create if missing ---

echo ""
info "--- Target volumes (remote server) ---"

refresh_remote_volumes() {
    readarray -t REMOTE_VOL_NAMES < <(ssh "$SSH_TARGET" "docker volume ls -q" 2>/dev/null || true)
}

refresh_remote_volumes
if ((${#REMOTE_VOL_NAMES[@]} == 0)); then
    warn "Could not list remote volumes (empty or SSH issue). You can still type a name to create."
fi

for ((i = 0; i < NUM_PAIRS; i++)); do
    src="${SOURCE_VOLUMES[i]}"
    pair_num=$((i + 1))
    echo ""
    info "Pair $pair_num / $NUM_PAIRS — target for local '$src':"
    if ((${#REMOTE_VOL_NAMES[@]} > 0)); then
        info "Remote volumes (number or name; default name = same as source '$src'):"
        echo "────────────────────────────────────────"
        for j in "${!REMOTE_VOL_NAMES[@]}"; do
            printf '  %2d) %s\n' $((j + 1)) "${REMOTE_VOL_NAMES[j]}"
        done
        echo "────────────────────────────────────────"
    fi

    while true; do
        prompt "  Target (number, name, or Enter = '$src'): "
        read -r raw_pick
        raw_pick=${raw_pick:-$src}

        if picked=$(resolve_volume_pick "$raw_pick" "$SSH_TARGET" "${REMOTE_VOL_NAMES[@]}"); then
            TARGET_VOLUMES+=("$picked")
            success "  Remote target: '$picked'"
            refresh_remote_volumes
            break
        fi

        # Typed name not in list: offer create (same as before)
        TARGET_VOLUME="$raw_pick"
        if [[ -z "$TARGET_VOLUME" ]]; then
            warn "Volume name cannot be empty."
            continue
        fi

        if ssh "$SSH_TARGET" "docker volume ls --quiet | grep -qx '$TARGET_VOLUME'" 2>/dev/null; then
            TARGET_VOLUMES+=("$TARGET_VOLUME")
            success "  Remote volume '$TARGET_VOLUME' exists."
            refresh_remote_volumes
            break
        fi

        warn "Volume '$TARGET_VOLUME' does not exist on remote."
        prompt "  Create it? (y/N): "
        read -r CREATE_VOL
        if [[ "${CREATE_VOL,,}" == "y" ]]; then
            if ssh "$SSH_TARGET" "docker volume create '$TARGET_VOLUME'" &>/dev/null; then
                success "  Volume '$TARGET_VOLUME' created on remote."
                TARGET_VOLUMES+=("$TARGET_VOLUME")
                refresh_remote_volumes
                break
            fi
            warn "Failed to create volume. Try again."
        else
            warn "Try a list number, existing name, or create a new one."
        fi
    done
done

# --- 5. Safety backup option ---

echo ""
prompt "Create a safety backup of each REMOTE volume before overwriting? (y/N): "
read -r SAFETY_BACKUP

# --- 6. Confirm ---

echo ""
echo "────────────────────────────────────────────────"
info "Migration plan ($NUM_PAIRS pair(s)):"
for ((i = 0; i < NUM_PAIRS; i++)); do
    info "  $((i + 1)). ${SOURCE_VOLUMES[i]}  →  ${TARGET_VOLUMES[i]}  ($SSH_IP)"
done
info "  Safety backup : ${SAFETY_BACKUP,,:-n}"
echo "────────────────────────────────────────────────"
warn "This will OVERWRITE all data in each listed remote volume!"
warn "Ensure containers using those remote volumes are STOPPED."
prompt "Proceed? (y/N): "
read -r CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && die "Cancelled."

# --- 7. Prepare local temp dir ---

BACKUP_DIR="$(mktemp -d)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REMOTE_DIR="$DEFAULT_REMOTE_DIR"

info "Ensuring remote directory $REMOTE_DIR exists..."
ssh "$SSH_TARGET" "mkdir -p '$REMOTE_DIR'" || die "Could not create remote directory."

# --- 8. Migrate each pair ---

for ((i = 0; i < NUM_PAIRS; i++)); do
    SOURCE_VOLUME="${SOURCE_VOLUMES[i]}"
    TARGET_VOLUME="${TARGET_VOLUMES[i]}"
    pair_num=$((i + 1))

    SAFE_SRC="${SOURCE_VOLUME//[^a-zA-Z0-9._-]/_}"
    BACKUP_FILE="${SAFE_SRC}-backup-${TIMESTAMP}-p${pair_num}.tar.gz"
    LOCAL_BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"

    echo ""
    echo "════════════════════════════════════════════════"
    info "Pair $pair_num / $NUM_PAIRS: '$SOURCE_VOLUME' → '$TARGET_VOLUME'"
    echo "════════════════════════════════════════════════"

    echo ""
    info "--- Step 1/4: Backup (local) ---"
    info "Archiving '$SOURCE_VOLUME' (GNU tar: numeric UID/GID + permissions)..."
    docker run --rm \
      -v "$SOURCE_VOLUME":/volume:ro \
      -v "$BACKUP_DIR":/backup \
      "$TAR_IMAGE" \
      tar --numeric-owner --warning=no-timestamp -czpf "/backup/$BACKUP_FILE" -C /volume . \
      || die "Backup failed for '$SOURCE_VOLUME'."

    BACKUP_SIZE=$(du -h "$LOCAL_BACKUP_FILE" | cut -f1)
    success "Backup complete ($BACKUP_SIZE)."

    echo ""
    info "--- Step 2/4: Transfer ---"
    info "Transferring $BACKUP_FILE ($BACKUP_SIZE)..."
    if ! scp -rpC "$LOCAL_BACKUP_FILE" "$SSH_TARGET:$REMOTE_DIR/$BACKUP_FILE"; then
        die "Transfer failed for '$SOURCE_VOLUME'. Hint: run 'sudo ufw allow in on tailscale0' on the target host."
    fi
    success "Transfer complete."

    rm -f "$LOCAL_BACKUP_FILE"

    echo ""
    info "--- Step 3/4: Remote restore ---"

    if [[ "${SAFETY_BACKUP,,}" == "y" ]]; then
        info "Creating safety backup of '$TARGET_VOLUME' on remote..."
        SAFETY_FILE="${SAFE_SRC}-pre-migrate-${TIMESTAMP}-p${pair_num}.tar.gz"
        ssh "$SSH_TARGET" "docker run --rm \
          -v '$TARGET_VOLUME':/volume:ro \
          -v '$REMOTE_DIR':/backup \
          '$TAR_IMAGE' \
          tar --numeric-owner --warning=no-timestamp -czpf /backup/$SAFETY_FILE -C /volume ." \
          || warn "Safety backup failed for '$TARGET_VOLUME' — continuing anyway."
        success "Safety backup on remote: $REMOTE_DIR/$SAFETY_FILE"
    fi

    info "Restoring into remote volume '$TARGET_VOLUME' (same UID/GID and modes as source)..."
    ssh "$SSH_TARGET" "docker run --rm \
      -v '$TARGET_VOLUME':/volume \
      -v '$REMOTE_DIR':/backup \
      '$TAR_IMAGE' \
      sh -c \"rm -rf /volume/* /volume/..?* /volume/.[!.]* 2>/dev/null; tar --numeric-owner --preserve-permissions --warning=no-timestamp -xzpf /backup/$BACKUP_FILE -C /volume\"" \
      || die "Remote restore failed for '$TARGET_VOLUME'."

    success "Restore complete."

    echo ""
    info "--- Step 4/4: Cleanup (this pair) ---"
    info "Removing transferred backup from remote..."
    ssh "$SSH_TARGET" "rm -f '$REMOTE_DIR/$BACKUP_FILE'" || warn "Could not remove remote backup file."
    success "Pair $pair_num done."
done

echo ""
info "Removing empty remote migrate directory if possible..."
ssh "$SSH_TARGET" "rmdir '$REMOTE_DIR' 2>/dev/null" || true

# --- Done ---

echo ""
echo "────────────────────────────────────────────────"
success "MIGRATION COMPLETE ($NUM_PAIRS volume pair(s))"
echo "────────────────────────────────────────────────"
for ((i = 0; i < NUM_PAIRS; i++)); do
    info "${SOURCE_VOLUMES[i]} → ${TARGET_VOLUMES[i]} on $SSH_IP"
done
info "You can now start containers using the remote volumes."
