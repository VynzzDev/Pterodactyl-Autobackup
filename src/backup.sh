#!/bin/bash
##########################################################################################################################
#  Auto backup script by VynzDev                                                                                         #
#                                                                                                                        #
#                                                                                                                        #
#  Contributors:                                                                                                         #
#  VynzzDev                                                                                                              #
#                                                                                                                        #
#  Link: https://vynzzhost.com                                                                                           #
#                                                                                                                        #
##########################################################################################################################

set -euo pipefail

CONFIG_FILE="/etc/autobackup/config.env"
LOCK_FILE="/var/run/autobackup.lock"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found!"
    exit 1
fi

source "$CONFIG_FILE"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Backup already running."
    exit 1
fi

mkdir -p "$TEMP_PATH"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
    send_logs_webhook "$message"
}

send_status_webhook() {
    local type="$1"
    local db_name="${2:-}"
    local date_now
    date_now=$(date '+%m-%d-%Y %H:%M:%S')

    if [ -z "${status_webhook_url:-}" ]; then
        return
    fi

    case "$type" in
        start)
            curl -s -H "Content-Type: application/json" \
            -X POST \
            -d "{
              \"embeds\": [{
                \"title\": \"💾 Automatic Backup\",
                \"description\": \"[⏳] Starting backup process...\n\n• **Name:** $MACHINE_NODE_NAME\n• **Date:** $date_now\",
                \"color\": $status_webhook_start_color
              }]
            }" \
            "$status_webhook_url" >/dev/null 2>&1
        ;;

        success)
            curl -s -H "Content-Type: application/json" \
            -X POST \
            -d "{
              \"embeds\": [{
                \"title\": \"💾 Automatic Backup\",
                \"description\": \"[✅] Successfully created backup as well as uploaded backup to the backup storage!\n\n• **Name:** $MACHINE_NODE_NAME\n• **Size:** Successfully: $backup_successful and Failed: $backup_failed\n• **Date:** $date_now\",
               \"color\": $status_webhook_success_color
            }]
          }" \
          "$status_webhook_url" >/dev/null 2>&1
        ;;

        db_start)
            curl -s -H "Content-Type: application/json" \
            -X POST \
            -d "{
                \"embeds\": [{
                    \"title\": \"🗄️ Automatic Backup\",
                    \"description\": \"[⏳] Starting database backup...\n\n• **Database:** $db_name\n• **Date:** $date_now\",
                    \"color\": $status_webhook_db_start_color
                }]
            }" \
            "$status_webhook_url" >/dev/null 2>&1
        ;;

        db_success)
            curl -s -H "Content-Type: application/json" \
            -X POST \
            -d "{
                \"embeds\": [{
                    \"title\": \"🗄️ Automatic Backup\",
                    \"description\": \"[✅] Database backup completed!\n\n• **Database:** $db_name\n• **Status:** Successfully: $db_success and Failed: $db_failed\n• **Date:** $date_now\",
                    \"color\": $status_webhook_db_success_color
                }]
            }" \
            "$status_webhook_url" >/dev/null 2>&1
        ;;

        db_failed)
            curl -s -H "Content-Type: application/json" \
            -X POST \
            -d "{
                \"embeds\": [{
                    \"title\": \"🗄️ Automatic Backup\",
                    \"description\": \"[❌] Database backup failed!\n\n• **Database:** $db_name\n• **Status:** Successfully: $db_success and Failed: $db_failed\n• **Date:** $date_now\",
                    \"color\": 15158332
                }]
            }" \
            "$status_webhook_url" >/dev/null 2>&1
    esac
}

send_logs_webhook() {
    local message="$1"
    if [ "${logs_webhook_enabled:-false}" = "true" ] && [ -n "${logs_webhook_url:-}" ]; then
        curl -s -H "Content-Type: application/json" \
        -X POST \
        -d "{\"content\":\"$message\"}" \
        "$logs_webhook_url" >/dev/null 2>&1
    fi
}

log "===== BACKUP STARTED ====="

send_status_webhook "start"

DATE=$(date +"%Y-%m-%d_%H-%M")

WINGS_ARCHIVE="${TEMP_PATH}/wings-full-${DATE}.tar.gz"
DB_ARCHIVE="${TEMP_PATH}/database-${DATE}.tar.gz"
DB_TEMP_PATH="${TEMP_PATH}/db-${DATE}"

backup_successful=0
backup_failed=0
db_success=0
db_failed=0

EXCLUDE_PARAMS=()

for dir in "${EXCLUDE_DIRS[@]}"; do
    EXCLUDE_PARAMS+=(--exclude="*/${dir}")
done

log "Scanning large folders inside each server (> ${MAX_FOLDER_SIZE_GB}GB)..."

VOLUMES_PATH="${DATA_PATH}/volumes"

if [ -d "$VOLUMES_PATH" ]; then
    while IFS= read -r -d '' server_dir; do
        server_name=$(basename "$server_dir")

        while IFS= read -r -d '' subfolder; do
            size_bytes=$(du -sb "$subfolder" | awk '{print $1}')
            size_gb=$((size_bytes / 1024 / 1024 / 1024))

            if [ "$size_gb" -ge "$MAX_FOLDER_SIZE_GB" ]; then
                relative_path="volumes/${server_name}/$(basename "$subfolder")"
                log "Excluding large folder: $relative_path (${size_gb}GB)"
                EXCLUDE_PARAMS+=(--exclude="$relative_path")
            fi
        done < <(find "$server_dir" -mindepth 1 -maxdepth 1 -type d -print0)

    done < <(find "$VOLUMES_PATH" -mindepth 1 -maxdepth 1 -type d -print0)
fi


if [ "${MARIADB_ENABLED:-false}" = "true" ]; then

    DUMP_CMD=$(command -v mariadb-dump || command -v mysqldump)
    mkdir -p "$DB_TEMP_PATH"

    for db in "${MARIADB_DATABASES[@]}"; do
        log "Dumping database: $db"
        send_status_webhook "db_start" "$db"

        if [ -z "${MARIADB_PASSWORD:-}" ]; then
            if "$DUMP_CMD" -u "$MARIADB_USER" "$db" | gzip > "${DB_TEMP_PATH}/${db}.sql.gz"; then
                db_success=$((db_success+1))
                send_status_webhook "db_success" "$db"
            else
                db_failed=$((db_failed+1))
                send_status_webhook "db_failed" "$db"
            fi
        else
            if "$DUMP_CMD" -u "$MARIADB_USER" -p"${MARIADB_PASSWORD}" "$db" | gzip > "${DB_TEMP_PATH}/${db}.sql.gz"; then
                db_success=$((db_success+1))
                send_status_webhook "db_success" "$db"
            else
                db_failed=$((db_failed+1))
                send_status_webhook "db_failed" "$db"
            fi
        fi
    done

    if [ "$db_success" -gt 0 ]; then
        tar -czpf "$DB_ARCHIVE" -C "$DB_TEMP_PATH" . || true
        log "Database archive created."
    fi
fi


log "Creating wings archive..."

TAR_EXIT=0

tar --warning=no-file-changed \
    --ignore-failed-read \
    -czpf "$WINGS_ARCHIVE" \
    "${EXCLUDE_PARAMS[@]}" \
    -C "$DATA_PATH" . || TAR_EXIT=$?

if [ "$TAR_EXIT" -eq 0 ] || [ "$TAR_EXIT" -eq 1 ]; then
    backup_successful=1
    log "Wings archive created successfully (exit code $TAR_EXIT)."
else
    backup_failed=1
    log "Wings archive failed with exit code $TAR_EXIT"
fi


if [ "$backup_successful" -eq 1 ]; then

    log "Uploading wings archive..."
    rclone mkdir "${RCLONE_REMOTE}:${CLOUD_PATH_WINGS}" || true
    rclone copy "$WINGS_ARCHIVE" "${RCLONE_REMOTE}:${CLOUD_PATH_WINGS}" || backup_failed=1

    if [ -f "$DB_ARCHIVE" ]; then
        log "Uploading database archive..."
        rclone mkdir "${RCLONE_REMOTE}:${CLOUD_PATH_DATABASE}" || true
        rclone copy "$DB_ARCHIVE" "${RCLONE_REMOTE}:${CLOUD_PATH_DATABASE}" || backup_failed=1
    fi
fi


if rclone lsf "${RCLONE_REMOTE}:${CLOUD_PATH_WINGS}" >/dev/null 2>&1; then
    rclone delete "${RCLONE_REMOTE}:${CLOUD_PATH_WINGS}" --min-age "${KEEP_DAYS}d" || true
fi

if rclone lsf "${RCLONE_REMOTE}:${CLOUD_PATH_DATABASE}" >/dev/null 2>&1; then
    rclone delete "${RCLONE_REMOTE}:${CLOUD_PATH_DATABASE}" --min-age "${KEEP_DAYS}d" || true
fi

rm -rf "$WINGS_ARCHIVE" "$DB_ARCHIVE" "$DB_TEMP_PATH"

send_status_webhook "success"

log "Database summary: success=$db_success failed=$db_failed"
log "===== BACKUP FINISHED ====="

exit 0