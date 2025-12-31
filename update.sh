#!/bin/bash
#
# n8n-compose Update Script
# Checks GitHub for new releases and applies updates
#
# Usage: ./update.sh [--check|--apply|--force]
#   --check: Only check for updates (default)
#   --apply: Download and apply the latest update
#   --force: Apply update without confirmation
#
# Designed for home servers that pull updates rather than receive pushes
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_REPO="cognitivegears/n8n-compose"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
VERSION_FILE="${SCRIPT_DIR}/.version"
TEMP_DIR=""

# Colors for output (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Cleanup function with proper quoting
cleanup() {
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

trap cleanup EXIT INT TERM

# Check if jq is available
HAS_JQ=false
if command -v jq &> /dev/null; then
    HAS_JQ=true
fi

# Get current version
get_current_version() {
    if [[ -f "${VERSION_FILE}" ]]; then
        cat "${VERSION_FILE}"
    else
        echo "unknown"
    fi
}

# Get latest release from GitHub
get_latest_release() {
    local response
    response=$(curl -fsSL --proto '=https' "${GITHUB_API}" 2>/dev/null) || {
        log_error "Failed to fetch release info from GitHub"
        exit 1
    }

    if [[ -z "${response}" ]]; then
        log_error "Empty response from GitHub API"
        exit 1
    fi

    if echo "${response}" | grep -q "API rate limit exceeded"; then
        log_error "GitHub API rate limit exceeded. Try again later."
        exit 1
    fi

    if echo "${response}" | grep -q '"message": "Not Found"'; then
        log_error "Repository not found or no releases available: ${GITHUB_REPO}"
        exit 1
    fi

    echo "${response}"
}

# Parse version from release JSON (with jq if available, fallback to regex)
parse_version() {
    local json="$1"
    if [[ "${HAS_JQ}" == "true" ]]; then
        echo "${json}" | jq -r '.tag_name // empty'
    else
        echo "${json}" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"\([^"]*\)"/\1/' | head -1
    fi
}

# Parse tarball URL from release JSON
parse_tarball_url() {
    local json="$1"
    if [[ "${HAS_JQ}" == "true" ]]; then
        echo "${json}" | jq -r '.tarball_url // empty'
    else
        echo "${json}" | grep -o '"tarball_url": *"[^"]*"' | sed 's/"tarball_url": *"\([^"]*\)"/\1/' | head -1
    fi
}

# Parse release notes from release JSON
parse_release_notes() {
    local json="$1"
    if [[ "${HAS_JQ}" == "true" ]]; then
        echo "${json}" | jq -r '.body // "(No release notes)"' | head -20
    else
        echo "${json}" | grep -o '"body": *"[^"]*"' | sed 's/"body": *"\([^"]*\)"/\1/' | head -1 | sed 's/\\n/\n/g' | head -20
    fi
}

# Check for updates
check_update() {
    log_header "Checking for Updates"

    if [[ "${HAS_JQ}" != "true" ]]; then
        log_warn "jq not installed - using fallback JSON parsing (consider: brew install jq / apt install jq)"
    fi

    local current_version
    current_version=$(get_current_version)
    log_info "Current version: ${current_version}"

    log_info "Fetching latest release from GitHub..."
    local release_json
    release_json=$(get_latest_release)

    local latest_version
    latest_version=$(parse_version "${release_json}")

    if [[ -z "${latest_version}" ]]; then
        log_error "Could not parse latest version from GitHub"
        exit 1
    fi

    log_info "Latest version: ${latest_version}"

    if [[ "${current_version}" == "${latest_version}" ]]; then
        log_info "You are running the latest version!"
        return 1
    else
        log_warn "Update available: ${current_version} -> ${latest_version}"
        echo ""
        log_info "Release notes:"
        echo "----------------------------------------"
        parse_release_notes "${release_json}" || echo "(No release notes)"
        echo "----------------------------------------"
        echo ""
        return 0
    fi
}

# Apply update
apply_update() {
    local force="${1:-false}"

    log_header "Applying Update"

    if [[ "${HAS_JQ}" != "true" ]]; then
        log_warn "jq not installed - using fallback JSON parsing"
    fi

    # Get release info
    local release_json
    release_json=$(get_latest_release)

    local latest_version
    latest_version=$(parse_version "${release_json}")

    local tarball_url
    tarball_url=$(parse_tarball_url "${release_json}")

    if [[ -z "${tarball_url}" ]]; then
        log_error "Could not get download URL"
        exit 1
    fi

    # Confirmation
    if [[ "${force}" != "true" ]]; then
        echo ""
        log_warn "This will update to version ${latest_version}"
        log_warn "A backup will be created before updating"
        echo ""
        read -p "Continue? (yes/no): " CONFIRM

        if [[ "${CONFIRM}" != "yes" ]]; then
            log_info "Update cancelled"
            exit 0
        fi
    fi

    # Create backup before update
    log_info "Creating backup before update..."
    if [[ -x "${SCRIPT_DIR}/backup.sh" ]]; then
        if ! "${SCRIPT_DIR}/backup.sh"; then
            log_error "Backup failed - update aborted for safety"
            log_error "Fix backup issues before updating, or use --force to skip"
            if [[ "${force}" != "true" ]]; then
                exit 1
            fi
            log_warn "Continuing without backup due to --force flag"
        fi
    else
        log_warn "backup.sh not found or not executable, skipping backup"
    fi

    # Create temp directory
    TEMP_DIR=$(mktemp -d)

    # Download release with proper certificate validation
    log_info "Downloading ${latest_version}..."
    if ! curl -fsSL --proto '=https' "${tarball_url}" -o "${TEMP_DIR}/release.tar.gz"; then
        log_error "Download failed"
        exit 1
    fi

    if [[ ! -s "${TEMP_DIR}/release.tar.gz" ]]; then
        log_error "Download failed or file is empty"
        exit 1
    fi

    # Verify the tarball is valid
    log_info "Verifying download integrity..."
    if ! tar tzf "${TEMP_DIR}/release.tar.gz" > /dev/null 2>&1; then
        log_error "Downloaded file is corrupted"
        exit 1
    fi

    # Extract
    log_info "Extracting..."
    tar xzf "${TEMP_DIR}/release.tar.gz" -C "${TEMP_DIR}" --no-same-owner --no-same-permissions

    # Find extracted directory (GitHub tarballs have format: owner-repo-commitsha)
    local extracted_dir
    extracted_dir=$(find "${TEMP_DIR}" -maxdepth 1 -type d -name "*n8n-compose*" | head -1)

    if [[ -z "${extracted_dir}" ]]; then
        # Try to find any extracted directory
        extracted_dir=$(find "${TEMP_DIR}" -maxdepth 1 -type d ! -name "$(basename "${TEMP_DIR}")" | head -1)
    fi

    if [[ -z "${extracted_dir}" ]]; then
        log_error "Could not find extracted files"
        exit 1
    fi

    log_info "Extracted to: ${extracted_dir}"

    # Update files (preserve .env and local-files)
    log_info "Updating files..."

    # List of files to update
    local files_to_update=(
        "compose.yaml"
        "init-data.sh"
        "backup.sh"
        "restore.sh"
        "update.sh"
        "CLAUDE.md"
        "CLOUDFLARE_SETUP.md"
        ".env.example"
        ".gitignore"
    )

    for file in "${files_to_update[@]}"; do
        if [[ -f "${extracted_dir}/${file}" ]] && [[ ! -L "${extracted_dir}/${file}" ]]; then
            cp "${extracted_dir}/${file}" "${SCRIPT_DIR}/"
            log_info "Updated: ${file}"
        fi
    done

    # Update .github directory if it exists
    if [[ -d "${extracted_dir}/.github" ]]; then
        mkdir -p "${SCRIPT_DIR}/.github"
        # Copy files, not following symlinks
        find "${extracted_dir}/.github" -type f | while read -r file; do
            rel_path="${file#${extracted_dir}/}"
            mkdir -p "${SCRIPT_DIR}/$(dirname "${rel_path}")"
            cp "${file}" "${SCRIPT_DIR}/${rel_path}"
        done
        log_info "Updated: .github/"
    fi

    # Make scripts executable
    chmod +x "${SCRIPT_DIR}/backup.sh" 2>/dev/null || true
    chmod +x "${SCRIPT_DIR}/restore.sh" 2>/dev/null || true
    chmod +x "${SCRIPT_DIR}/update.sh" 2>/dev/null || true
    chmod +x "${SCRIPT_DIR}/init-data.sh" 2>/dev/null || true

    # Save version
    echo "${latest_version}" > "${VERSION_FILE}"
    log_info "Version file updated: ${latest_version}"

    # Stop services cleanly before updating
    log_info "Stopping services..."
    docker compose -f "${SCRIPT_DIR}/compose.yaml" down

    # Pull new images
    log_info "Pulling new Docker images..."
    docker compose -f "${SCRIPT_DIR}/compose.yaml" pull

    # Start services with new images
    log_info "Starting services with updated images..."
    docker compose -f "${SCRIPT_DIR}/compose.yaml" up -d

    # Wait for services to be healthy
    log_info "Waiting for services to become healthy..."
    local retries=30
    until docker compose -f "${SCRIPT_DIR}/compose.yaml" ps 2>/dev/null | grep -q "healthy"; do
        retries=$((retries - 1))
        if [[ ${retries} -le 0 ]]; then
            log_warn "Services may not be fully healthy yet - check with: docker compose ps"
            break
        fi
        sleep 5
    done

    echo ""
    log_info "Update to ${latest_version} completed successfully!"
    log_info "Check service status with: docker compose logs -f"
}

# Show help
show_help() {
    echo "n8n-compose Update Script"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --check, -c    Check for updates (default)"
    echo "  --apply, -a    Download and apply the latest update"
    echo "  --force, -f    Apply update without confirmation"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Check for updates"
    echo "  $0 --check      # Check for updates"
    echo "  $0 --apply      # Apply update with confirmation"
    echo "  $0 --force      # Apply update without confirmation"
    echo ""
    echo "Configuration:"
    echo "  GitHub Repo: ${GITHUB_REPO}"
    echo "  Version File: ${VERSION_FILE}"
    echo ""
    if [[ "${HAS_JQ}" == "true" ]]; then
        echo "  jq: installed (recommended)"
    else
        echo "  jq: not installed (install for better JSON parsing)"
    fi
}

# Main
case "${1:-check}" in
    --check|-c|check)
        check_update || true
        ;;
    --apply|-a|apply)
        if check_update; then
            apply_update
        else
            log_info "No update needed"
        fi
        ;;
    --force|-f|force)
        apply_update true
        ;;
    --help|-h|help)
        show_help
        ;;
    *)
        log_error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac
