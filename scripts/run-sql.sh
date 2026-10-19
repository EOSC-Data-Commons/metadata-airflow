#!/usr/bin/env bash
set -euo pipefail

SQL_FILE="${1:-index.sql}"

if [[ ! -f "$SQL_FILE" ]]; then
    echo "Error: File not found: $SQL_FILE" >&2
    exit 1
fi

docker compose exec -T postgres \
    psql -U airflow -d tooldb \
    -v ON_ERROR_STOP=1 < "$SQL_FILE"
