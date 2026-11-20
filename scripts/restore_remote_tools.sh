
#!/usr/bin/env bash
set -euo pipefail

# Restore tool_metadata and tool_embeddings to a remote PostgreSQL database.
#
# Usage:
# PGHOST=your-remote-host \
# PGPORT=5432 \
# PGUSER=your-remote-user \
# PGDATABASE=tooldb \
# ./scripts/restore_remote_tools.sh ./backups/backup.dump
#
# Connection:
#   PGHOST, PGPORT, PGUSER, PGDATABASE
#   Authentication: PGPASSWORD or ~/.pgpass
#
# WARNING: Existing remote tables will be replaced.

DUMP_FILE="${1:?Usage: $0 <dump-file>}"

: "${PGHOST:?Set PGHOST}"
: "${PGUSER:?Set PGUSER}"

PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-tooldb}"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: Dump file not found: $DUMP_FILE" >&2
    exit 1
fi

echo "Validating dump..."

pg_restore --list "$DUMP_FILE" > /dev/null

for table in tool_metadata tool_embeddings tool_metadata_enrichment harvest_source toolmeta_schema_version; do
    if ! pg_restore --list "$DUMP_FILE" |
        grep -Eq " TABLE public ${table} "; then
        echo "ERROR: Missing table $table in dump" >&2
        exit 1
    fi
done

# Do not accidentally restore unrelated tables.
# extra_tables=$(
#     pg_restore --list "$DUMP_FILE" |
#         awk '$4 == "TABLE" && $5 == "public" {print $6}' |
#         grep -Ev '^(tool_metadata|tool_embeddings)$' || true
# )
#
# if [[ -n "$extra_tables" ]]; then
#     echo "ERROR: Dump contains other tables:" >&2
#     echo "$extra_tables" >&2
#     exit 1
# fi

echo "Checking remote connection..."

psql -X -v ON_ERROR_STOP=1 -Atc \
    "SELECT current_database(), current_user, version();" \
    >/dev/null

echo "Remote database:"
echo "  Host:     $PGHOST:$PGPORT"
echo "  Database: $PGDATABASE"
echo "  User:     $PGUSER"
echo

# Ensure essential extensions are installed.
echo "Checking extensions..."

psql -X -v ON_ERROR_STOP=1 -Atc "
DO \$\$
DECLARE
    missing text[];
BEGIN
    SELECT array_agg(required.name)
    INTO missing
    FROM (
        VALUES
            ('vector'),
            ('pg_textsearch'),
            ('pg_trgm')
    ) AS required(name)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_extension e
        WHERE e.extname = required.name
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'Missing extensions: %', missing;
    END IF;
END
\$\$;
"

# Back up remote tables before replacement.
BACKUP_FILE="$BACKUP_DIR/remote-tools-$TIMESTAMP.dump"

echo "Backing up existing remote tables..."

pg_dump \
    --format=custom \
    --table=public.tool_metadata \
    --table=public.tool_embeddings \
    --table=public.tool_metadata_enrichment \
    --table=public.harvest_source \
    --table=public.toolmeta_schema_version \
    --file="$BACKUP_FILE"

echo "Backup saved: $BACKUP_FILE"

echo
echo "WARNING: Remote tool_metadata and tool_embeddings"
echo "         will be dropped and restored."
read -r -p "Type RESTORE to continue: " confirmation

if [[ "$confirmation" != "RESTORE" ]]; then
    echo "Cancelled."
    exit 0
fi

echo "Restoring database tables..."

pg_restore \
    --dbname="$PGDATABASE" \
    --table=tool_metadata \
    --table=tool_embeddings \
    --table=tool_metadata_enrichment \
    --table=harvest_source \
    --table=toolmeta_schema_version \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --single-transaction \
    --exit-on-error \
    --verbose \
    "$DUMP_FILE"

echo "Updating database statistics..."

vacuumdb \
    --dbname="$PGDATABASE" \
    --analyze \
    --table=public.tool_metadata \
    --table=public.tool_embeddings \
    --table=public.tool_metadata_enrichment \
    --table=public.harvest_source \
    --table=public.toolmeta_schema_version \

echo "Verifying restored tables..."

psql -X -v ON_ERROR_STOP=1 -c "
    SELECT 'tool_metadata' AS table_name, count(*) AS rows
    FROM public.tool_metadata
    UNION ALL
    SELECT 'tool_embeddings', count(*)
    FROM public.tool_embeddings
    UNION ALL
    SELECT 'tool_metadata_enrichment', count(*)
    FROM public.tool_metadata_enrichment
    UNION ALL
    SELECT 'harvest_source', count(*)
    FROM public.harvest_source
    UNION ALL
    SELECT 'toolmeta_schema_version', count(*)
    FROM public.toolmeta_schema_version;
"

echo
echo "Restore completed successfully."
echo "Previous remote data backed up to: $BACKUP_FILE"

