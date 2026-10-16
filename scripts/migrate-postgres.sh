
#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL 16 -> 17 migration using Docker Compose.
#
# Requirements:
# - Both services belong to the same Compose project/network.
# - The target is a fresh PostgreSQL 17 cluster.
# - The target has a bootstrap superuser distinct from source roles.
# - Compatible PostgreSQL extensions are installed in the target.
# - All application writers have been stopped.
#
# Usage:
#   export SOURCE_PASSWORD="..."
#   export TARGET_PASSWORD="..."
#   ./migrate-postgres.sh

SOURCE_SERVICE="${SOURCE_SERVICE:-postgres}"
TARGET_SERVICE="${TARGET_SERVICE:-postgres17}"

SOURCE_USER="${SOURCE_USER:-postgres}"
TARGET_USER="${TARGET_USER:-upgrade_admin}"

SOURCE_HOST="${SOURCE_HOST:-$SOURCE_SERVICE}"

BACKUP_DIR="${BACKUP_DIR:-./pg-migration-backup}"
DATABASES="${DATABASES:-tooldb airflow}"

: "${SOURCE_PASSWORD:?Set SOURCE_PASSWORD}"
: "${TARGET_PASSWORD:?Set TARGET_PASSWORD}"

umask 077
mkdir -p "$BACKUP_DIR"

read -r -a DBS <<< "$DATABASES"

if (( ${#DBS[@]} == 0 )); then
    echo "No databases specified" >&2
    exit 1
fi

# Run PostgreSQL client tools from the PG17 container.
source_pg() {
    docker compose exec -T \
        -e PGPASSWORD="$SOURCE_PASSWORD" \
        "$TARGET_SERVICE" \
        "$@" -h "$SOURCE_HOST" -U "$SOURCE_USER"
}

target_pg() {
    docker compose exec -T \
        -e PGPASSWORD="$TARGET_PASSWORD" \
        "$TARGET_SERVICE" \
        "$@" -h 127.0.0.1 -U "$TARGET_USER"
}

echo "Checking PostgreSQL versions..."

SOURCE_VERSION=$(
    source_pg psql -d postgres -AtX \
        -c "SHOW server_version_num"
)

TARGET_VERSION=$(
    target_pg psql -d postgres -AtX \
        -c "SHOW server_version_num"
)

if [[ "$SOURCE_VERSION" != 16* ]]; then
    echo "Source is not PostgreSQL 16: $SOURCE_VERSION" >&2
    exit 1
fi

if [[ "$TARGET_VERSION" != 17* ]]; then
    echo "Target is not PostgreSQL 17: $TARGET_VERSION" >&2
    exit 1
fi

echo "Source: PostgreSQL $SOURCE_VERSION"
echo "Target: PostgreSQL $TARGET_VERSION"

# The target must be a new cluster. Existing user databases
# and conflicting roles must not be overwritten.
echo "Checking target cluster..."

for db in "${DBS[@]}"; do
    exists=$(
        printf "SELECT 1 FROM pg_database WHERE datname = :'db';\n" |
            target_pg psql -d postgres -AtX -v db="$db"
    )
    # exists=$(
    #     target_pg psql -d postgres -AtX \
    #         -v db="$db" \
    #         -c "SELECT 1 FROM pg_database WHERE datname = :'db'"
    # )

    if [[ "$exists" == "1" ]]; then
        echo "Target database '$db' already exists." >&2
        echo "Use a fresh PostgreSQL 17 volume." >&2
        exit 1
    fi
done

# Abort on unsupported TimescaleDB logical restore.
# pgvectorscale alone is fine; the timescaledb extension
# has additional backup/restore requirements.
echo "Checking source extensions..."

for db in "${DBS[@]}"; do
    has_timescaledb=$(
        source_pg psql -d "$db" -AtX \
            -c "SELECT count(*) FROM pg_extension WHERE extname = 'timescaledb'"
    )

    if [[ "$has_timescaledb" != "0" ]]; then
        echo "Database '$db' uses TimescaleDB." >&2
        echo "Use the TimescaleDB-specific restore procedure." >&2
        exit 1
    fi

    extensions=$(
        source_pg psql -d "$db" -AtX \
            -c "SELECT extname FROM pg_extension WHERE extname <> 'plpgsql'"
    )

    while IFS= read -r ext; do
        [[ -z "$ext" ]] && continue

        available=$(
            target_pg psql -d postgres -AtX \
                -c "SELECT count(*)
                    FROM pg_available_extensions
                    WHERE name = '$ext'"
        )

        if [[ "$available" == "0" ]]; then
            echo "Missing target extension: $ext" >&2
            exit 1
        fi
    done <<< "$extensions"
done

echo "Backing up cluster roles and global objects..."

source_pg pg_dumpall --globals-only \
    > "$BACKUP_DIR/globals.sql"

echo "Backing up databases..."

for db in "${DBS[@]}"; do
    echo "  Dumping $db"
    source_pg pg_dump \
        -d "$db" \
        --format=custom \
        > "$BACKUP_DIR/$db.dump"

    # source_pg pg_dump \
    #     -d "$db" \
    #     --format=custom \
    #     --verbose \
    #     --file=- \
    #     > "$BACKUP_DIR/$db.dump"
done

echo "Validating backup archives..."

for db in "${DBS[@]}"; do
    docker compose exec -T "$TARGET_SERVICE" \
        pg_restore --list \
        < "$BACKUP_DIR/$db.dump" \
        > /dev/null
done

# Check for role-name collisions before restoring globals.
# This expects a dedicated target bootstrap role (upgrade_admin)
# whose name does not exist on the source.
echo "Checking role compatibility..."

source_roles=$(
    source_pg psql -d postgres -AtX \
        -c "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_'"
)

target_roles=$(
    target_pg psql -d postgres -AtX \
        -c "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_'"
)

while IFS= read -r role; do
    [[ -z "$role" ]] && continue

    if grep -Fxq "$role" <<< "$target_roles"; then
        echo "Conflicting role on target: $role" >&2
        echo "Use a fresh target with a distinct bootstrap role." >&2
        exit 1
    fi
done <<< "$source_roles"

if grep -Fxq "$TARGET_USER" <<< "$source_roles"; then
    echo "Target bootstrap role exists on source." >&2
    exit 1
fi

echo "Restoring roles and globals..."

target_pg psql \
    -d postgres \
    -X \
    -v ON_ERROR_STOP=1 \
    < "$BACKUP_DIR/globals.sql"

echo "Restoring databases..."

for db in "${DBS[@]}"; do
    echo "  Restoring $db"

    target_pg pg_restore \
        --dbname=postgres \
        --create \
        --exit-on-error \
        --verbose \
        < "$BACKUP_DIR/$db.dump"

    echo "  Updating statistics for $db"

    target_pg vacuumdb \
        --dbname="$db" \
        --analyze-in-stages
done

echo "Comparing table row counts..."

for db in "${DBS[@]}"; do
    echo "Database: $db"

    source_counts=$(
        source_pg psql -d "$db" -AtX -c "
            SELECT count(*)
            FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_type = 'BASE TABLE';
        "
    )

    target_counts=$(
        target_pg psql -d "$db" -AtX -c "
            SELECT count(*)
            FROM information_schema.tables
            WHERE table_schema = 'public'
              AND table_type = 'BASE TABLE';
        "
    )

    echo "  Source public tables: $source_counts"
    echo "  Target public tables: $target_counts"

    if [[ "$source_counts" != "$target_counts" ]]; then
        echo "  WARNING: Table count mismatch!" >&2
    fi
done

echo
echo "Migration completed."
echo "Backups saved in: $BACKUP_DIR"
echo
echo "Next steps:"
echo "1. Verify roles, extensions, row counts and indexes."
echo "2. Test Tool Registry and Airflow against postgres17."
echo "3. Switch application database hostnames."
echo "4. Keep the PostgreSQL 16 volume for rollback."

