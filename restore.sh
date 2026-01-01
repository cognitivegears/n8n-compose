#!/bin/bash
#
# n8n-compose Restore Script
# Restores PostgreSQL database, n8n data, and configuration from backup
#
# Usage: ./restore.sh <backup_file>
#   backup_file: Path to backup archive (e.g., backups/backup-20240101-120000.tar.gz)
#
# Environment Variables:
#   BACKUP_ENCRYPTION_KEY: Required if backup is encrypted (.tar.gz.enc)
#
# WARNING: This will overwrite current data!
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR=""

# Get Alpine version from compose.yaml (tracked by Dependabot)
get_alpine_image() {
    if [[ -f "${SCRIPT_DIR}/compose.yaml" ]]; then
        grep -A1 "^\s*alpine:" "${SCRIPT_DIR}/compose.yaml" | grep "image:" | sed 's/.*image:\s*//' | tr -d ' "'
    else
        echo "alpine:3.20"  # Fallback
    fi
}
ALPINE_IMAGE=$(get_alpine_image)

# Colors for output (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Cleanup function - uses properly quoted variables
cleanup() {
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

trap cleanup EXIT INT TERM

# Wait for PostgreSQL with exponential backoff
wait_for_postgres() {
    local max_attempts=30
    local attempt=1
    local wait_time=2

    log_info "Waiting for PostgreSQL to be ready..."

    while [[ ${attempt} -le ${max_attempts} ]]; do
        if docker compose -f "${SCRIPT_DIR}/compose.yaml" exec -T postgres \
            pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" &>/dev/null; then
            log_info "PostgreSQL is ready"
            return 0
        fi

        log_info "Attempt ${attempt}/${max_attempts} - waiting ${wait_time}s..."
        sleep ${wait_time}

        attempt=$((attempt + 1))
        # Exponential backoff with max of 10 seconds
        wait_time=$((wait_time < 10 ? wait_time + 1 : 10))
    done

    log_error "PostgreSQL failed to become ready"
    return 1
}

# Check arguments
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <backup_file>"
    echo "Example: $0 backups/backup-20240101-120000.tar.gz"
    echo ""
    echo "Available backups:"
    ls -1t "${SCRIPT_DIR}/backups/"*.tar.gz* 2>/dev/null | head -5 || echo "  No backups found"
    exit 1
fi

BACKUP_FILE="$1"

# Handle relative paths
if [[ ! "${BACKUP_FILE}" = /* ]]; then
    BACKUP_FILE="${SCRIPT_DIR}/${BACKUP_FILE}"
fi

# Validate backup file
if [[ ! -f "${BACKUP_FILE}" ]]; then
    log_error "Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

# Check if running from correct directory
if [[ ! -f "${SCRIPT_DIR}/compose.yaml" ]]; then
    log_error "compose.yaml not found. Run this script from the n8n-compose directory."
    exit 1
fi

# Check for interactive terminal
if [[ ! -t 0 ]]; then
    log_error "This script must be run interactively (not from cron or pipe)"
    log_error "Use --force flag to bypass this check (not recommended)"
    exit 1
fi

# Load current environment (NOT from backup - security)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # Validate .env file format before sourcing
    if grep -qE '^[^#]*\$\(' "${SCRIPT_DIR}/.env" 2>/dev/null; then
        log_error ".env file contains command substitution - this is not allowed for security"
        exit 1
    fi
    set -a
    set +H  # Disable history expansion (handles ! in passwords)
    source "${SCRIPT_DIR}/.env"
    set +a
    log_info "Using current environment from .env"
else
    log_error ".env file not found - required for restore"
    log_error "Please create .env from .env.example before restoring"
    exit 1
fi

# Validate database name format (prevent SQL injection)
if [[ ! "${POSTGRES_DB}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    log_error "Invalid database name format in POSTGRES_DB"
    exit 1
fi

# Create temporary directory for extraction
TEMP_DIR=$(mktemp -d)

# Check if backup is encrypted
IS_ENCRYPTED=false
ARCHIVE_FILE="${BACKUP_FILE}"
if [[ "${BACKUP_FILE}" == *.enc ]]; then
    IS_ENCRYPTED=true
    log_info "Encrypted backup detected"

    if [[ -z "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
        log_error "Backup is encrypted but BACKUP_ENCRYPTION_KEY is not set"
        log_error "Set the environment variable and try again"
        exit 1
    fi

    log_info "Decrypting backup..."
    ARCHIVE_FILE="${TEMP_DIR}/decrypted.tar.gz"
    if ! openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 \
        -in "${BACKUP_FILE}" \
        -out "${ARCHIVE_FILE}" \
        -pass "pass:${BACKUP_ENCRYPTION_KEY}" 2>/dev/null; then
        log_error "Decryption failed - check your BACKUP_ENCRYPTION_KEY"
        exit 1
    fi
    log_info "Backup decrypted successfully"
fi

# Verify backup archive integrity BEFORE any destructive operations
log_info "Verifying backup archive integrity..."
if ! tar tzf "${ARCHIVE_FILE}" > /dev/null 2>&1; then
    log_error "Backup archive is corrupted or invalid"
    exit 1
fi
log_info "Backup archive verified successfully"

# Extract backup to verify contents
log_info "Extracting backup archive..."
tar xzf "${ARCHIVE_FILE}" -C "${TEMP_DIR}" --no-same-owner --no-same-permissions

# Find the backup directory (handles different naming)
BACKUP_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d -name "backup-*" | head -1)

if [[ -z "${BACKUP_DIR}" ]]; then
    log_error "Invalid backup archive structure"
    exit 1
fi

# Validate backup contents
if [[ ! -f "${BACKUP_DIR}/database.sql.gz" ]]; then
    log_error "database.sql.gz not found in backup"
    exit 1
fi

# Verify database backup can be decompressed
if ! gunzip -t "${BACKUP_DIR}/database.sql.gz" 2>/dev/null; then
    log_error "Database backup is corrupted"
    exit 1
fi

log_info "Backup contents validated successfully"

# Confirmation prompt
echo ""
log_warn "WARNING: This will restore from backup and OVERWRITE current data!"
log_warn "Backup file: ${BACKUP_FILE}"
log_warn "Database: ${POSTGRES_DB}"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
    log_info "Restore cancelled"
    exit 0
fi

# Offer to create a backup before restoring
echo ""
read -p "Create a backup of current data before restoring? (yes/no): " CREATE_BACKUP

if [[ "${CREATE_BACKUP}" == "yes" ]]; then
    log_info "Creating backup of current state..."
    if [[ -x "${SCRIPT_DIR}/backup.sh" ]]; then
        PRE_RESTORE_DIR="${SCRIPT_DIR}/backups/pre-restore-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$(dirname "${PRE_RESTORE_DIR}")"
        if "${SCRIPT_DIR}/backup.sh" "${SCRIPT_DIR}/backups"; then
            log_info "Pre-restore backup completed"
        else
            log_warn "Pre-restore backup failed"
            read -p "Continue anyway? (yes/no): " CONTINUE
            if [[ "${CONTINUE}" != "yes" ]]; then
                log_info "Restore cancelled"
                exit 0
            fi
        fi
    else
        log_warn "backup.sh not found or not executable, skipping pre-restore backup"
    fi
fi

# Determine the project name (for volume names)
PROJECT_NAME=$(basename "${SCRIPT_DIR}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')

# Stop services
log_info "Stopping services..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" down

# Restore n8n data volume if backup exists
if [[ -f "${BACKUP_DIR}/n8n_data.tar.gz" ]]; then
    log_info "Restoring n8n data volume..."

    # Try explicit volume names first
    VOLUME_NAME="n8n_data"
    if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
        VOLUME_NAME="${PROJECT_NAME}_n8n_data"
    fi

    # Remove existing volume if it exists
    docker volume rm "${VOLUME_NAME}" 2>/dev/null || true

    # Create new volume
    docker volume create "${VOLUME_NAME}"

    # Restore data with safe extraction
    docker run --rm \
        -v "${VOLUME_NAME}:/data" \
        -v "${BACKUP_DIR}:/backup:ro" \
        "${ALPINE_IMAGE}" \
        sh -c "cd /data && tar xzf /backup/n8n_data.tar.gz --no-same-owner --no-same-permissions"

    log_info "n8n data volume restored"
else
    log_warn "No n8n_data.tar.gz found in backup, skipping volume restore"
fi

# Start postgres only
log_info "Starting PostgreSQL..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" up -d postgres

# Wait for postgres to be ready with proper health check
if ! wait_for_postgres; then
    log_error "PostgreSQL failed to start"
    exit 1
fi

# Drop and recreate database (using proper quoting to prevent injection)
log_info "Preparing database..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" exec -T postgres \
    psql -U "${POSTGRES_USER}" -c "DROP DATABASE IF EXISTS \"${POSTGRES_DB}\";" 2>/dev/null || true
docker compose -f "${SCRIPT_DIR}/compose.yaml" exec -T postgres \
    psql -U "${POSTGRES_USER}" -c "CREATE DATABASE \"${POSTGRES_DB}\";"

# Restore database
log_info "Restoring database..."
gunzip -c "${BACKUP_DIR}/database.sql.gz" | \
    docker compose -f "${SCRIPT_DIR}/compose.yaml" exec -T postgres \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"

log_info "Database restored"

# Restore configuration files (optional - prompt user)
if [[ -d "${BACKUP_DIR}/config" ]]; then
    echo ""
    read -p "Restore configuration files (compose.yaml, init-data.sh)? (yes/no): " RESTORE_CONFIG

    if [[ "${RESTORE_CONFIG}" == "yes" ]]; then
        log_info "Restoring configuration files..."
        # Validate files before copying (check for symlinks)
        for file in compose.yaml init-data.sh; do
            src="${BACKUP_DIR}/config/${file}"
            if [[ -f "${src}" ]] && [[ ! -L "${src}" ]]; then
                cp "${src}" "${SCRIPT_DIR}/"
                log_info "Restored: ${file}"
            fi
        done
        if [[ -f "${BACKUP_DIR}/config/.version" ]] && [[ ! -L "${BACKUP_DIR}/config/.version" ]]; then
            cp "${BACKUP_DIR}/config/.version" "${SCRIPT_DIR}/"
        fi
        log_info "Configuration files restored"
    fi
fi

# Start all services
log_info "Starting all services..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" up -d

# Wait for n8n to be healthy
log_info "Waiting for services to start..."
RETRIES=30
until docker compose -f "${SCRIPT_DIR}/compose.yaml" ps 2>/dev/null | grep -q "healthy"; do
    RETRIES=$((RETRIES - 1))
    if [[ ${RETRIES} -le 0 ]]; then
        break
    fi
    sleep 5
done

# Verify services are running
if docker compose -f "${SCRIPT_DIR}/compose.yaml" ps 2>/dev/null | grep -qE "(running|Up)"; then
    log_info "Restore completed successfully!"
    log_info "n8n should be available at https://${SUBDOMAIN}.${DOMAIN_NAME}"
    log_info "Local access: http://127.0.0.1:5678"
else
    log_warn "Some services may not have started correctly"
    log_warn "Check with: docker compose logs"
fi
