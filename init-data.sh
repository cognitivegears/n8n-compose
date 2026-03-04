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

# Create user and extensions idempotently
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
-- Create extensions required by n8n (must be done as superuser)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

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

-- Create eva_memory_meta table for RAG memory system
CREATE TABLE IF NOT EXISTS eva_memory_meta (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  qdrant_point_id TEXT NOT NULL,
  content         TEXT NOT NULL,
  category        TEXT NOT NULL DEFAULT 'general',
  source          TEXT NOT NULL DEFAULT 'chat',
  importance      INTEGER NOT NULL DEFAULT 5 CHECK (importance BETWEEN 1 AND 10),
  tags            TEXT[] DEFAULT '{}',
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_eva_memory_meta_category ON eva_memory_meta(category);
CREATE INDEX IF NOT EXISTS idx_eva_memory_meta_source ON eva_memory_meta(source);
CREATE INDEX IF NOT EXISTS idx_eva_memory_meta_expires_at ON eva_memory_meta(expires_at);
CREATE INDEX IF NOT EXISTS idx_eva_memory_meta_created_at ON eva_memory_meta(created_at);
CREATE INDEX IF NOT EXISTS idx_eva_memory_meta_importance ON eva_memory_meta(importance);
CREATE UNIQUE INDEX IF NOT EXISTS idx_eva_memory_meta_qdrant_point_id ON eva_memory_meta(qdrant_point_id);

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
