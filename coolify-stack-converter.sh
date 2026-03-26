#!/bin/bash
set -euo pipefail

# === Coolify Stack Converter ===
# Migrates a standalone Docker Compose stack (bind-mount DBs) into
# Coolify-managed dedicated database containers with Docker volumes.
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
    local name="$1" label="$2"
    if ! docker inspect "$name" &>/dev/null; then
        die "$label container '$name' not found. Check the name/ID."
    fi
}

require_running() {
    local name="$1" label="$2"
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then
        return 1
    fi
    return 0
}

echo ""
echo "────────────────────────────────────────────────"
info "Coolify Stack Converter (Standalone -> Coolify)"
echo "────────────────────────────────────────────────"

# --- 1. Collect Source (Old) Container Info ---
echo ""
info "--- Source Stack (Old) ---"
prompt "OLD App Container ID/Name: "
read -r OLD_APP
prompt "OLD Postgres Container ID/Name: "
read -r OLD_PG
prompt "OLD Redis Container ID/Name: "
read -r OLD_REDIS
prompt "OLD Redis Data Path (e.g. /data/stack/redis/): "
read -r REDIS_OLD_PATH

# --- 2. Collect Target (New / Coolify) Container Info ---
echo ""
info "--- Target Stack (Coolify) ---"
prompt "NEW Postgres Container ID/Name: "
read -r NEW_PG
prompt "NEW Redis Container ID/Name: "
read -r NEW_REDIS
prompt "NEW App Container ID/Name: "
read -r NEW_APP
prompt "NEW Redis Volume Name (e.g. redis-data-xyz): "
read -r REDIS_VOL_NAME

# --- 3. Database Credentials ---
echo ""
info "--- Database Credentials ---"
prompt "Database Name: "
read -r DB_NAME
prompt "Postgres Username: "
read -r PG_USER
prompt "OLD Redis Password (leave blank if none): "
read -r REDIS_OLD_PASS

# --- 4. Validate All Containers Exist ---
echo ""
info "Validating containers..."
for pair in "OLD_APP:$OLD_APP" "OLD_PG:$OLD_PG" "OLD_REDIS:$OLD_REDIS" \
            "NEW_PG:$NEW_PG" "NEW_REDIS:$NEW_REDIS" "NEW_APP:$NEW_APP"; do
    LABEL="${pair%%:*}"
    CID="${pair#*:}"
    require_container "$CID" "$LABEL"
done
success "All containers found."

# --- 5. Validate Redis Source Path ---
if [[ ! -d "$REDIS_OLD_PATH" ]]; then
    die "Redis data path '$REDIS_OLD_PATH' not found."
fi

# --- 6. Confirm Before Proceeding ---
echo ""
echo "────────────────────────────────────────────────"
info "Migration Plan:"
info "  PostgreSQL : $OLD_PG -> $NEW_PG (db: $DB_NAME)"
info "  Redis      : $OLD_REDIS -> $NEW_REDIS (vol: $REDIS_VOL_NAME)"
info "  App        : $OLD_APP -> $NEW_APP"
echo "────────────────────────────────────────────────"
warn "This will STOP the old app and overwrite data in new containers."
prompt "Proceed? (y/N): "
read -r CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && die "Cancelled."

# --- 7. Pre-Flight: Ensure New Services Are Running ---
echo ""
info "Pre-flight checks..."
for CID in "$NEW_PG" "$NEW_REDIS"; do
    if ! require_running "$CID" "target"; then
        info "Starting container $CID..."
        docker start "$CID"
        sleep 3
        if ! require_running "$CID" "target"; then
            die "Failed to start container '$CID'."
        fi
    fi
    success "$CID is running."
done

# --- 8. Freeze Old App ---
info "Stopping OLD app ($OLD_APP) to freeze data..."
docker stop "$OLD_APP" || warn "Old app may already be stopped."

# --- 9. PostgreSQL Migration ---
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

# --- 10. Redis Migration ---
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

VOL_PATH="/var/lib/docker/volumes/$REDIS_VOL_NAME/_data"
if [[ ! -d "$VOL_PATH" ]]; then
    die "Volume path '$VOL_PATH' not found. Verify the volume name."
fi

info "Cleaning target volume..."
rm -rf "${VOL_PATH:?}"/*

info "Copying Redis data files..."
cp -rp "${REDIS_OLD_PATH%/}/." "$VOL_PATH/"

info "Fixing permissions (UID 999)..."
chown -R 999:999 "$VOL_PATH/"

success "Redis file sync complete."

# --- 11. Final Startup & Verification ---
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
