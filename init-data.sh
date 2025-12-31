#!/bin/bash
#
# PostgreSQL initialization script for n8n
# Creates non-root user with appropriate privileges
#

set -euo pipefail

# Validate environment variables
if [[ -z "${POSTGRES_NON_ROOT_USER:-}" ]] || [[ -z "${POSTGRES_NON_ROOT_PASSWORD:-}" ]]; then
    echo "SETUP INFO: POSTGRES_NON_ROOT_USER or POSTGRES_NON_ROOT_PASSWORD not set, skipping user creation"
    exit 0
fi

# Validate username format (alphanumeric and underscore only - prevents SQL injection)
if [[ ! "${POSTGRES_NON_ROOT_USER}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: Invalid username format. Use only alphanumeric characters and underscores."
    exit 1
fi

# Escape single quotes in password by doubling them (SQL standard escaping)
ESCAPED_PASSWORD="${POSTGRES_NON_ROOT_PASSWORD//\'/\'\'}"

# Create user idempotently
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
-- Create user if not exists (idempotent)
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${POSTGRES_NON_ROOT_USER}') THEN
        CREATE USER "${POSTGRES_NON_ROOT_USER}" WITH PASSWORD '${ESCAPED_PASSWORD}';
        RAISE NOTICE 'Created user: ${POSTGRES_NON_ROOT_USER}';
    ELSE
        ALTER USER "${POSTGRES_NON_ROOT_USER}" WITH PASSWORD '${ESCAPED_PASSWORD}';
        RAISE NOTICE 'Updated password for existing user: ${POSTGRES_NON_ROOT_USER}';
    END IF;
END
\$\$;

-- Grant necessary privileges (minimum required for n8n)
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO "${POSTGRES_NON_ROOT_USER}";
GRANT USAGE ON SCHEMA public TO "${POSTGRES_NON_ROOT_USER}";
GRANT CREATE ON SCHEMA public TO "${POSTGRES_NON_ROOT_USER}";

-- Grant privileges on existing tables
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${POSTGRES_NON_ROOT_USER}";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${POSTGRES_NON_ROOT_USER}";

-- Set default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${POSTGRES_NON_ROOT_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "${POSTGRES_NON_ROOT_USER}";
EOSQL

echo "SETUP INFO: Non-root user '${POSTGRES_NON_ROOT_USER}' configured successfully"
