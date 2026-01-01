#!/bin/bash
#
# n8n-compose Backup Script
# Backs up PostgreSQL database, n8n data volume, and configuration files
#
# Usage: ./backup.sh [backup_dir]
#   backup_dir: Optional. Defaults to ./backups
#
# Environment Variables:
#   BACKUP_ENCRYPTION_KEY: If set, backups will be encrypted with this passphrase
#
# Designed for cron scheduling:
#   0 2 * * * /path/to/n8n-compose/backup.sh >> /var/log/n8n-backup.log 2>&1
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${1:-${SCRIPT_DIR}/backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="backup-${TIMESTAMP}"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"
RETAIN_DAYS=30

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

# Cleanup function for failed backups
cleanup_on_failure() {
    if [[ -d "${BACKUP_PATH}" ]]; then
        log_warn "Cleaning up incomplete backup directory..."
        rm -rf "${BACKUP_PATH}"
    fi
    if [[ -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" ]]; then
        rm -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"
    fi
    if [[ -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz.enc" ]]; then
        rm -f "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz.enc"
    fi
}

trap cleanup_on_failure ERR

# Check if running from correct directory
if [[ ! -f "${SCRIPT_DIR}/compose.yaml" ]]; then
    log_error "compose.yaml not found. Run this script from the n8n-compose directory."
    exit 1
fi

# Load environment variables (safely - only for reading values, not executing)
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
else
    log_error ".env file not found"
    exit 1
fi

# Validate critical environment variables
if [[ -z "${POSTGRES_USER:-}" ]] || [[ -z "${POSTGRES_DB:-}" ]]; then
    log_error "Required environment variables POSTGRES_USER and POSTGRES_DB not set"
    exit 1
fi

# Check for placeholder passwords and keys
if [[ "${POSTGRES_PASSWORD:-}" == "generate-a-strong-password-here" ]] || \
   [[ "${POSTGRES_PASSWORD:-}" == "CHANGE_ME_generate_strong_password" ]] || \
   [[ "${POSTGRES_NON_ROOT_PASSWORD:-}" == "generate-another-strong-password-here" ]] || \
   [[ "${POSTGRES_NON_ROOT_PASSWORD:-}" == "CHANGE_ME_generate_another_password" ]] || \
   [[ "${N8N_ENCRYPTION_KEY:-}" == "CHANGE_ME_generate_hex_key" ]] || \
   [[ "${N8N_RUNNERS_AUTH_TOKEN:-}" == "CHANGE_ME_generate_runner_token" ]]; then
    log_error "Please set real passwords/keys in .env (not placeholder values)"
    log_error "Generate with: openssl rand -base64 32 (passwords) or openssl rand -hex 32 (keys/tokens)"
    exit 1
fi

# Set restrictive umask for backup files
umask 077

# Create backup directory with secure permissions
mkdir -p "${BACKUP_PATH}"
chmod 700 "${BACKUP_DIR}"
log_info "Starting backup to ${BACKUP_PATH}"

# Determine the project name (for volume names)
PROJECT_NAME=$(basename "${SCRIPT_DIR}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')

# Check if postgres container is running
if ! docker compose -f "${SCRIPT_DIR}/compose.yaml" ps postgres 2>/dev/null | grep -q "running"; then
    log_error "PostgreSQL container is not running"
    exit 1
fi

# Backup PostgreSQL database
log_info "Backing up PostgreSQL database..."
docker compose -f "${SCRIPT_DIR}/compose.yaml" exec -T postgres \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    --no-owner --no-acl \
    | gzip > "${BACKUP_PATH}/database.sql.gz"

# Capture PIPESTATUS immediately
DB_DUMP_STATUS=("${PIPESTATUS[@]}")

if [[ ${DB_DUMP_STATUS[0]} -eq 0 ]] && [[ ${DB_DUMP_STATUS[1]} -eq 0 ]]; then
    log_info "Database backup completed: database.sql.gz"
else
    log_error "Database backup failed (pg_dump: ${DB_DUMP_STATUS[0]}, gzip: ${DB_DUMP_STATUS[1]})"
    exit 1
fi

# Backup n8n data volume
log_info "Backing up n8n data volume..."

# Try explicit volume names first (from our updated compose.yaml)
VOLUME_NAME="n8n_data"
if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
    # Fall back to project-prefixed naming
    VOLUME_NAME="${PROJECT_NAME}_n8n_data"
    if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
        # Try alternative naming
        VOLUME_NAME="n8n-compose_n8n_data"
        if ! docker volume inspect "${VOLUME_NAME}" &>/dev/null; then
            log_warn "Could not find n8n_data volume, skipping volume backup"
            VOLUME_NAME=""
        fi
    fi
fi

if [[ -n "${VOLUME_NAME}" ]]; then
    docker run --rm \
        -v "${VOLUME_NAME}:/data:ro" \
        -v "${BACKUP_PATH}:/backup" \
        "${ALPINE_IMAGE}" \
        tar czf /backup/n8n_data.tar.gz -C /data .

    if [[ $? -eq 0 ]]; then
        log_info "n8n data backup completed: n8n_data.tar.gz"
    else
        log_error "n8n data backup failed"
        exit 1
    fi
fi

# Backup configuration files (excluding .env for security - credentials should be managed separately)
log_info "Backing up configuration files..."
mkdir -p "${BACKUP_PATH}/config"
cp "${SCRIPT_DIR}/compose.yaml" "${BACKUP_PATH}/config/"
cp "${SCRIPT_DIR}/init-data.sh" "${BACKUP_PATH}/config/"
cp "${SCRIPT_DIR}/.env.example" "${BACKUP_PATH}/config/" 2>/dev/null || true

# Save version info if available
if [[ -f "${SCRIPT_DIR}/.version" ]]; then
    cp "${SCRIPT_DIR}/.version" "${BACKUP_PATH}/config/"
fi

# Create a sanitized env reference (variable names only, no values)
log_info "Creating environment reference (without secrets)..."
grep -E '^[A-Z_]+=' "${SCRIPT_DIR}/.env" | cut -d= -f1 > "${BACKUP_PATH}/config/env-variables.txt" || true

# Create backup archive
log_info "Creating backup archive..."
cd "${BACKUP_DIR}"
tar czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"
rm -rf "${BACKUP_NAME}"

# Verify backup integrity
log_info "Verifying backup integrity..."
if ! tar tzf "${BACKUP_NAME}.tar.gz" > /dev/null 2>&1; then
    log_error "Backup verification failed - archive is corrupted"
    rm -f "${BACKUP_NAME}.tar.gz"
    exit 1
fi

# Encrypt backup if encryption key is set
FINAL_BACKUP="${BACKUP_NAME}.tar.gz"
if [[ -n "${BACKUP_ENCRYPTION_KEY:-}" ]]; then
    log_info "Encrypting backup..."
    if command -v openssl &> /dev/null; then
        openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
            -in "${BACKUP_NAME}.tar.gz" \
            -out "${BACKUP_NAME}.tar.gz.enc" \
            -pass "pass:${BACKUP_ENCRYPTION_KEY}"

        # Verify encrypted file exists and has content
        if [[ -s "${BACKUP_NAME}.tar.gz.enc" ]]; then
            rm -f "${BACKUP_NAME}.tar.gz"
            FINAL_BACKUP="${BACKUP_NAME}.tar.gz.enc"
            log_info "Backup encrypted successfully"
        else
            log_error "Encryption failed"
            rm -f "${BACKUP_NAME}.tar.gz.enc"
            exit 1
        fi
    else
        log_warn "openssl not found - backup will not be encrypted"
    fi
fi

# Set secure permissions on backup file
chmod 600 "${FINAL_BACKUP}"

BACKUP_SIZE=$(du -h "${FINAL_BACKUP}" | cut -f1)
log_info "Backup completed: ${BACKUP_DIR}/${FINAL_BACKUP} (${BACKUP_SIZE})"

# Clean up old backups
log_info "Cleaning up backups older than ${RETAIN_DAYS} days..."
find "${BACKUP_DIR}" -name "backup-*.tar.gz*" -mtime +${RETAIN_DAYS} -delete 2>/dev/null || true
REMAINING=$(ls -1 "${BACKUP_DIR}"/backup-*.tar.gz* 2>/dev/null | wc -l || echo "0")
log_info "Cleanup complete. ${REMAINING} backup(s) retained."

# Remove the ERR trap since we completed successfully
trap - ERR

log_info "Backup process finished successfully"
