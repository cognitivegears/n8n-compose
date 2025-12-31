#!/bin/bash
#
# PostgreSQL initialization script for n8n
# Creates non-root user with appropriate privileges
#
# Security: Uses psql variables for safe SQL parameter handling
#

set -euo pipefail

# Validate environment variables
if [[ -z "${POSTGRES_NON_ROOT_USER:-}" ]] || [[ -z "${POSTGRES_NON_ROOT_PASSWORD:-}" ]]; then
    echo "SETUP INFO: POSTGRES_NON_ROOT_USER or POSTGRES_NON_ROOT_PASSWORD not set, skipping user creation"
    exit 0
fi

# Validate username format (alphanumeric and underscore only)
if [[ ! "${POSTGRES_NON_ROOT_USER}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: Invalid username format. Use only alphanumeric characters and underscores."
    exit 1
fi

# Create user idempotently using psql variables for safe interpolation
# This prevents SQL injection via environment variables
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v non_root_user="${POSTGRES_NON_ROOT_USER}" \
    -v non_root_pass="${POSTGRES_NON_ROOT_PASSWORD}" \
    -v target_db="${POSTGRES_DB}" <<-'EOSQL'
    -- Create user if not exists (idempotent)
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = :'non_root_user') THEN
            EXECUTE format('CREATE USER %I WITH PASSWORD %L', :'non_root_user', :'non_root_pass');
            RAISE NOTICE 'Created user: %', :'non_root_user';
        ELSE
            -- Update password if user already exists
            EXECUTE format('ALTER USER %I WITH PASSWORD %L', :'non_root_user', :'non_root_pass');
            RAISE NOTICE 'Updated password for existing user: %', :'non_root_user';
        END IF;
    END
    $$;

    -- Grant necessary privileges (minimum required for n8n)
    GRANT CONNECT ON DATABASE :"target_db" TO :"non_root_user";
    GRANT USAGE ON SCHEMA public TO :"non_root_user";
    GRANT CREATE ON SCHEMA public TO :"non_root_user";

    -- Grant privileges on existing tables
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"non_root_user";
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"non_root_user";

    -- Set default privileges for future tables
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"non_root_user";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"non_root_user";
EOSQL

echo "SETUP INFO: Non-root user '${POSTGRES_NON_ROOT_USER}' configured successfully"
