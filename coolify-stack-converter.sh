#!/bin/bash
set -euo pipefail

# === Coolify Stack Converter ===
# Migrates Docker Compose stacks between environments (standalone <-> Coolify).
# Supports Redis data in Docker volumes or bind-mount directories.
# Handles: PostgreSQL (pg_dump/psql) + Redis (physical file copy).

SCRIPT_NAME="Stack Converter"

# --- Colors & Helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[ $SCRIPT_NAME ]${NC} [ INFO ] $1"; }
success() { echo -e "${GREEN}[ $SCRIPT_NAME ]${NC} [ ✓ OK ] $1"; }
warn()    { echo -e "${YELLOW}[ $SCRIPT_NAME ]${NC} [ WARN ] $1"; }
error()   { echo -e "${RED}[ $SCRIPT_NAME ]${NC} [ ERROR ] $1"; }
prompt()  { echo -en "${CYAN}[ $SCRIPT_NAME ]${NC} [ INPUT ] $1"; }

die() { error "$1"; exit 1; }

# --- Cleanup Trap ---
TEMP_DUMP=""
cleanup() {
    if [[ -n "$TEMP_DUMP" && -f "$TEMP_DUMP" ]]; then
        rm -f "$TEMP_DUMP"
    fi
}
trap cleanup EXIT

# --- Validation Helpers ---
require_container() {
    local name="$1"
    docker inspect "$name" &>/dev/null
}

prompt_container() {
    local label="$1" var_name="$2"
    while true; do
        prompt "$label: "
        read -r _val
        if [[ -z "$_val" ]]; then
            warn "Value cannot be empty."
        elif require_container "$_val"; then
            eval "$var_name=\$_val"
            return
        else
            warn "Container '$_val' not found. Try again."
        fi
    done
}

require_running() {
    local name="$1"
    [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]
}

echo ""
echo "────────────────────────────────────────────────"
info "Coolify Stack Converter (Standalone -> Coolify)"
echo "────────────────────────────────────────────────"

# --- 1. Collect Source (Old) Container Info ---
echo ""
info "--- Source Stack (Old) ---"
prompt_container "OLD App Container ID/Name" OLD_APP
prompt_container "OLD Postgres Container ID/Name" OLD_PG
prompt_container "OLD Redis Container ID/Name" OLD_REDIS

while true; do
    prompt "OLD Redis storage type — (v)olume or (d)irectory? [v/d]: "
    read -r REDIS_OLD_TYPE
    REDIS_OLD_TYPE="${REDIS_OLD_TYPE,,}"
    if [[ "$REDIS_OLD_TYPE" == "v" ]]; then
        prompt "OLD Redis Volume Name: "
        read -r REDIS_OLD_VOL
        REDIS_OLD_PATH="/var/lib/docker/volumes/$REDIS_OLD_VOL/_data"
        [[ -d "$REDIS_OLD_PATH" ]] && break
        warn "Volume path '$REDIS_OLD_PATH' not found. Check the volume name."
    elif [[ "$REDIS_OLD_TYPE" == "d" ]]; then
        prompt "OLD Redis Data Path (e.g. /data/stack/redis/): "
        read -r REDIS_OLD_PATH
        [[ -d "$REDIS_OLD_PATH" ]] && break
        warn "Directory '$REDIS_OLD_PATH' not found. Try again."
    else
        warn "Invalid choice — enter 'v' for volume or 'd' for directory."
    fi
done

# --- 2. Collect Target (New / Coolify) Container Info ---
echo ""
info "--- Target Stack (Coolify) ---"
prompt_container "NEW Postgres Container ID/Name" NEW_PG
prompt_container "NEW Redis Container ID/Name" NEW_REDIS
prompt_container "NEW App Container ID/Name" NEW_APP

while true; do
    prompt "NEW Redis storage type — (v)olume or (d)irectory? [v/d]: "
    read -r REDIS_NEW_TYPE
    REDIS_NEW_TYPE="${REDIS_NEW_TYPE,,}"
    if [[ "$REDIS_NEW_TYPE" == "v" ]]; then
        prompt "NEW Redis Volume Name (e.g. redis-data-xyz): "
        read -r REDIS_VOL_NAME
        REDIS_NEW_PATH="/var/lib/docker/volumes/$REDIS_VOL_NAME/_data"
        [[ -d "$REDIS_NEW_PATH" ]] && break
        warn "Volume path '$REDIS_NEW_PATH' not found. Check the volume name."
    elif [[ "$REDIS_NEW_TYPE" == "d" ]]; then
        prompt "NEW Redis Data Path (e.g. /data/coolify/redis/): "
        read -r REDIS_NEW_PATH
        [[ -d "$REDIS_NEW_PATH" ]] && break
        warn "Directory '$REDIS_NEW_PATH' not found. Try again."
    else
        warn "Invalid choice — enter 'v' for volume or 'd' for directory."
    fi
done

# --- 3. Database Credentials ---
echo ""
info "--- Database Credentials ---"

while true; do
    prompt "PostgreSQL Database Name (the DB to migrate): "
    read -r DB_NAME
    [[ -n "$DB_NAME" ]] && break
    warn "Database name cannot be empty."
done

while true; do
    prompt "PostgreSQL Username (used for both old & new): "
    read -r PG_USER
    [[ -n "$PG_USER" ]] && break
    warn "Username cannot be empty."
done

prompt "OLD Redis Password (leave blank if none): "
read -r REDIS_OLD_PASS

# --- 4. Confirm ---
echo ""
echo "────────────────────────────────────────────────"
info "Migration Plan:"
info "  PostgreSQL : $OLD_PG -> $NEW_PG (db: $DB_NAME)"
if [[ "$REDIS_NEW_TYPE" == "v" ]]; then
    info "  Redis      : $OLD_REDIS -> $NEW_REDIS (vol: $REDIS_VOL_NAME)"
else
    info "  Redis      : $OLD_REDIS -> $NEW_REDIS (dir: $REDIS_NEW_PATH)"
fi
info "  App        : $OLD_APP -> $NEW_APP"
echo "────────────────────────────────────────────────"
warn "This will STOP the old app and overwrite data in new containers."
prompt "Proceed? (y/N): "
read -r CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && die "Cancelled."

# --- 5. Pre-Flight: Ensure New Services Are Running ---
echo ""
info "Pre-flight checks..."
for CID in "$NEW_PG" "$NEW_REDIS"; do
    if ! require_running "$CID"; then
        info "Starting container $CID..."
        docker start "$CID"
        sleep 3
        if ! require_running "$CID"; then
            die "Failed to start container '$CID'."
        fi
    fi
    success "$CID is running."
done

# --- 6. Freeze Old App ---
info "Stopping OLD app ($OLD_APP) to freeze data..."
docker stop "$OLD_APP" || warn "Old app may already be stopped."

# --- 7. PostgreSQL Migration ---
echo ""
info "--- PostgreSQL Migration ---"

info "Ensuring target database '$DB_NAME' exists..."
docker exec "$NEW_PG" psql -U "$PG_USER" -d postgres \
    -c "CREATE DATABASE \"$DB_NAME\";" 2>/dev/null || info "Database '$DB_NAME' may already exist (OK)."

TEMP_DUMP="$(pwd)/migrate_pg_$(date +%s).sql"
info "Dumping from $OLD_PG..."
docker exec -t "$OLD_PG" pg_dump -U "$PG_USER" -d "$DB_NAME" \
    --clean --if-exists --no-owner --no-acl > "$TEMP_DUMP"

DUMP_SIZE=$(du -h "$TEMP_DUMP" | cut -f1)
if [[ ! -s "$TEMP_DUMP" ]]; then
    die "pg_dump produced an empty file — aborting to prevent data loss."
fi
info "Dump size: $DUMP_SIZE"

info "Importing into $NEW_PG..."
docker exec -i "$NEW_PG" psql -U "$PG_USER" -d "$DB_NAME" < "$TEMP_DUMP"
success "PostgreSQL migration complete."

rm -f "$TEMP_DUMP"
TEMP_DUMP=""

# --- 8. Redis Migration ---
echo ""
info "--- Redis Migration ---"

info "Forcing SAVE on OLD Redis ($OLD_REDIS)..."
if [[ -z "$REDIS_OLD_PASS" ]]; then
    docker exec "$OLD_REDIS" redis-cli SAVE
else
    docker exec "$OLD_REDIS" redis-cli -a "$REDIS_OLD_PASS" SAVE
fi

info "Stopping Redis containers for physical file sync..."
docker stop "$OLD_REDIS" "$NEW_REDIS"

info "Cleaning target Redis data..."
rm -rf "${REDIS_NEW_PATH:?}"/*

info "Copying Redis data files..."
cp -rp "${REDIS_OLD_PATH%/}/." "$REDIS_NEW_PATH/"

info "Fixing permissions (UID 999)..."
chown -R 999:999 "$REDIS_NEW_PATH/"

success "Redis file sync complete."

# --- 9. Final Startup & Verification ---
echo ""
info "--- Finalizing Cutover ---"

docker start "$NEW_REDIS"
sleep 3

info "Verifying Redis key count..."
NEW_PASS=$(docker inspect "$NEW_REDIS" \
    --format='{{range .Config.Env}}{{println .}}{{end}}' \
    | grep '^REDIS_PASSWORD=' | cut -d'=' -f2- || true)

if [[ -z "$NEW_PASS" ]]; then
    docker exec "$NEW_REDIS" redis-cli DBSIZE
else
    info "Using detected Coolify Redis password."
    docker exec "$NEW_REDIS" redis-cli -a "$NEW_PASS" DBSIZE
fi

info "Starting NEW app ($NEW_APP)..."
docker start "$NEW_APP"

echo ""
echo "────────────────────────────────────────────────"
success "MIGRATION COMPLETE"
echo "────────────────────────────────────────────────"
info "Verify: docker logs -f $NEW_APP"
