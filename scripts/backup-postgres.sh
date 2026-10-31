
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -z "${BACKUP_DIR:-}" ]]; then
    echo "ERROR: BACKUP_DIR environment variable is not defined or is empty." >&2
    exit 1
fi

cd "$(dirname "$0")/.."

SERVICE="${POSTGRES_SERVICE:-postgres}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DAY_OF_WEEK="$(date +%u)"
DAY_OF_MONTH="$(date +%d)"

# All backups are retained for 7 days.
# On Sundays, additionally keep weekly backups for 28 days.
# On the first of each month, keep monthly backups for 180 days.
mkdir -p "$BACKUP_DIR"/{daily,weekly,monthly}

backup_database() {
    local label="$1"
    local db_user="$2"
    local db_name="$3"

    local tmp="$BACKUP_DIR/daily/${label}-${TIMESTAMP}.dump.tmp"
    local dest="${tmp%.tmp}"

    echo "Backing up ${db_name}..."

    if ! docker compose exec -T "$SERVICE" \
        pg_dump -U "$db_user" -d "$db_name" -Fc > "$tmp"; then
        rm -f "$tmp"
        echo "Backup failed: ${db_name}" >&2
        return 1
    fi

    if ! docker compose exec -T "$SERVICE" \
        pg_restore -l < "$tmp" > /dev/null; then
        rm -f "$tmp"
        echo "Archive verification failed: ${db_name}" >&2
        return 1
    fi

    mv "$tmp" "$dest"

    if [[ "$DAY_OF_WEEK" == 7 ]]; then
        cp "$dest" "$BACKUP_DIR/weekly/"
    fi

    if [[ "$DAY_OF_MONTH" == 01 ]]; then
        cp "$dest" "$BACKUP_DIR/monthly/"
    fi

    echo "Created: $dest"
}

backup_database airflow \
    "$AIRFLOW_DATABASE_USER" \
    "$AIRFLOW_DATABASE_NAME"

backup_database toolmeta \
    "$TOOLMETA_HARVESTER_DATABASE__USER" \
    "$TOOLMETA_HARVESTER_DATABASE__NAME"

# Rotate only after all backups succeed.
find "$BACKUP_DIR/daily" -type f -name '*.dump' -mtime +6 -delete
find "$BACKUP_DIR/weekly" -type f -name '*.dump' -mtime +27 -delete
find "$BACKUP_DIR/monthly" -type f -name '*.dump' -mtime +179 -delete

echo "PostgreSQL backup completed."

