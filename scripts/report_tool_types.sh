#!/usr/bin/env bash
set -euo pipefail

# Resolve project root relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found: $ENV_FILE" >&2
    exit 1
fi

# Load environment variables
set -a
source "$ENV_FILE"
set +a

# Database configuration
DB_HOST="${TOOLMETA_HARVESTER_DATABASE__HOST:?Missing database host}"
DB_PORT="${TOOLMETA_HARVESTER_DATABASE__PORT:-5432}"
DB_NAME="${TOOLMETA_HARVESTER_DATABASE__NAME:?Missing database name}"
DB_USER="${TOOLMETA_HARVESTER_DATABASE__USER:?Missing database user}"
DB_PASSWORD="${TOOLMETA_HARVESTER_DATABASE__PASSWORD:?Missing database password}"

cd "$PROJECT_ROOT"

echo "Database: $DB_NAME"
echo "Container service: $DB_HOST"
echo

docker compose exec -T \
    -e PGPASSWORD="$DB_PASSWORD" \
    "$DB_HOST" \
    psql \
        -h localhost \
        -p "$DB_PORT" \
        -U "$DB_USER" \
        -d "$DB_NAME" \
        -X \
        -v ON_ERROR_STOP=1 \
        -P pager=off <<'SQL'

\echo ''
\echo '=== TOOL TYPE COVERAGE ==='

SELECT
    COUNT(*) AS total_tools,
    COUNT(*) FILTER (
        WHERE cardinality(search_types) > 0
    ) AS typed_tools,
    COUNT(*) FILTER (
        WHERE cardinality(search_types) = 0
           OR search_types IS NULL
    ) AS untyped_tools
FROM public.tool_metadata;

\echo ''
\echo '=== DISTINCT TYPES ==='

SELECT COUNT(DISTINCT type) AS distinct_types
FROM public.tool_metadata
CROSS JOIN LATERAL unnest(search_types) AS type
WHERE NULLIF(trim(type), '') IS NOT NULL;

\echo ''
\echo '=== TOOLS PER TYPE ==='

SELECT
    type,
    COUNT(DISTINCT id) AS tool_count,
    ROUND(
        100.0 * COUNT(DISTINCT id) /
        NULLIF(
            (SELECT COUNT(*) FROM public.tool_metadata),
            0
        ),
        2
    ) AS pct_of_tools
FROM public.tool_metadata
CROSS JOIN LATERAL unnest(search_types) AS type
WHERE NULLIF(trim(type), '') IS NOT NULL
GROUP BY type
ORDER BY tool_count DESC, type;

\echo ''
\echo '=== NUMBER OF TYPES PER TOOL ==='

SELECT
    cardinality(search_types) AS types_per_tool,
    COUNT(*) AS tool_count
FROM public.tool_metadata
GROUP BY cardinality(search_types)
ORDER BY types_per_tool;

\echo ''
\echo '=== TYPES BY METADATA FORMAT ==='

SELECT
    metadata_format,
    COUNT(*) AS total_tools,
    COUNT(*) FILTER (
        WHERE cardinality(search_types) > 0
    ) AS typed_tools,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE cardinality(search_types) > 0
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS coverage_pct
FROM public.tool_metadata
GROUP BY metadata_format
ORDER BY total_tools DESC;

\echo ''
\echo '=== SELECTED TOOL COUNTS (EXACT MATCH) ==='

WITH selected AS (
    SELECT unnest(ARRAY[
        'galaxy',
        'scipion',
        'docker',
        'jupyter notebook',
        'jupyter',
        'notebook',
        'vip',
        'rrp',
        'nextflow',
        'cwl',
        'common workflow language',
        'dockerfile'

    ]) AS name
),
matches AS (
    SELECT DISTINCT
        s.name,
        t.id
    FROM selected s
    JOIN public.tool_metadata t
        ON lower(t.title) = s.name
        OR EXISTS (
            SELECT 1
            FROM unnest(t.search_types) AS st(type)
            WHERE lower(st.type) = s.name
        )
        OR EXISTS (
            SELECT 1
            FROM unnest(t.keywords) AS kw(keyword)
            WHERE lower(kw.keyword) = s.name
        )
),
counts AS (
    SELECT
        s.name,
        COUNT(m.id) AS tool_count
    FROM selected s
    LEFT JOIN matches m ON m.name = s.name
    GROUP BY s.name
)
SELECT name, tool_count
FROM (
    SELECT name, tool_count, 0 AS sort_order
    FROM counts

    UNION ALL

    SELECT 'TOTAL', COUNT(DISTINCT id), 1
    FROM matches
) results
ORDER BY sort_order, name;

-- SELECT
--     lower(trim(other_type)) AS related_type,
--     COUNT(DISTINCT t.id) AS tool_count
-- FROM public.tool_metadata t
-- CROSS JOIN LATERAL unnest(t.search_types) AS other_type
-- WHERE EXISTS (
--     SELECT 1
--     FROM unnest(t.search_types) AS st(type)
--     WHERE lower(trim(st.type)) = 'command-line tool'
-- )
-- AND lower(trim(other_type)) <> 'command-line tool'
-- AND trim(other_type) <> ''
-- GROUP BY lower(trim(other_type))
-- ORDER BY tool_count DESC, related_type;

SQL
