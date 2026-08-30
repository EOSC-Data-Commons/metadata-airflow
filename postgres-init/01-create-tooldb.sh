#!/bin/bash
set -e
# Create the database and user for the toolmeta-harvester application
psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER ${TOOLMETA_HARVESTER_DATABASE__USER} WITH PASSWORD '${TOOLMETA_HARVESTER_DATABASE__PASSWORD}';
    CREATE DATABASE ${TOOLMETA_HARVESTER_DATABASE__NAME} OWNER ${TOOLMETA_HARVESTER_DATABASE__USER};
EOSQL

# Add the vector extension to the database
psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname "$TOOLMETA_HARVESTER_DATABASE__NAME" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
EOSQL

# Create the harvest_source table in the database
psql -v ON_ERROR_STOP=1 \
    --username "$TOOLMETA_HARVESTER_DATABASE__USER" \
    --dbname "$TOOLMETA_HARVESTER_DATABASE__NAME" <<-EOSQL
    CREATE TABLE IF NOT EXISTS harvest_source (id UUID PRIMARY KEY, url TEXT NOT NULL UNIQUE, schedule VARCHAR(255), enabled BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),   updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());
EOSQL

