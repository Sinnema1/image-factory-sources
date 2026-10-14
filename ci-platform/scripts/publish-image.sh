#!/usr/bin/env bash

set -Eeuo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
DEBUG=${DEBUG:-false}
LOG_LEVEL=${LOG_LEVEL:-INFO}  # DEBUG, INFO, WARN, ERROR

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Log messages with timestamps and severity levels
log() {
  local level=$1
  local message=$2
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  case "$level" in
    DEBUG)
      if [ "$DEBUG" = "true" ]; then
        echo "[${timestamp}] [DEBUG] ${message}"
      fi
      ;;
    INFO)
      echo "[${timestamp}] [INFO] ${message}"
      ;;
    WARN)
      echo "[${timestamp}] [WARN] ${message}" >&2
      ;;
    ERROR)
      echo "[${timestamp}] [ERROR] ${message}" >&2
      ;;
    *)
      echo "[${timestamp}] [${level}] ${message}"
      ;;
  esac
}

# Log entry and exit of functions (for debugging)
debug_enter() {
  if [ "$DEBUG" = "true" ]; then
    log "DEBUG" "Entering function: ${FUNCNAME[1]} with args: $*"
    log "DEBUG" "Caller: ${FUNCNAME[2]}"
  fi
}

debug_exit() {
  if [ "$DEBUG" = "true" ]; then
    log "DEBUG" "Exiting function: ${FUNCNAME[1]} with status: $?"
  fi
}

# Export logging functions immediately
export -f log
export -f debug_enter
export -f debug_exit

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Check if required variables are set
validate_required_vars() {
  debug_enter
  local missing=()

  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing+=("$var")
    fi
  done

  if [ ${#missing[@]} -ne 0 ]; then
    log "ERROR" "The following required environment variables are not set:"
    for var in "${missing[@]}"; do
      log "ERROR" "  - ${var}"
    done
    log "ERROR" "Set them before running this script."
    return 1
  fi
}

# Validate podman image exists
validate_image_exists() {
  debug_enter
  local image_reference=$1
  log "INFO" "Checking if image exists: ${image_reference}"

  if ! podman image exists "${image_reference}"; then
    log "ERROR" "Image not found: ${image_reference}"
    return 1
  fi
  log "INFO" "Image exists: ${image_reference}"
}

# =============================================================================
# CORE FUNCTIONS
# =============================================================================

# Cleanup temporary files
cleanup() {
  debug_enter
  if [ -n "${LOCAL_STAGE:-}" ] && [ -d "${LOCAL_STAGE}" ]; then
    log "INFO" "Cleaning up temporary directory: ${LOCAL_STAGE}"
    rm -rf "${LOCAL_STAGE}"
  fi
}

# Generate metadata file
generate_metadata() {
  debug_enter
  local local_metadata=$1
  local image_name=$2
  local image_version=$3
  local image_reference=$4
  local image_id=$5
  local image_digest=$6
  local archive_name=$7
  local archive_sha256=$8
  local archive_size_bytes=$9
  local source_repository=${10}
  local source_commit=${11}
  local pipeline_id=${12}
  local job_id=${13}
  local git_tag=${14}
  local published_at_utc=${15}

  log "INFO" "Generating metadata file: ${local_metadata}"

  cat > "${local_metadata}" <<EOF
schema_version: "1"
name: "${image_name}"
version: "${image_version}"
image_reference: "${image_reference}"
image_id: "${image_id}"
image_digest: "${image_digest}"
archive: "${archive_name}"
archive_sha256: "${archive_sha256}"
archive_size_bytes: "${archive_size_bytes}"
source_repository: "${source_repository}"
source_commit: "${source_commit}"
pipeline_id: "${pipeline_id}"
job_id: "${job_id}"
git_tag: "${git_tag}"
published_at_utc: "${published_at_utc}"
EOF

  log "DEBUG" "Metadata file created: ${local_metadata}"
}

# Save image to archive
save_image() {
  debug_enter
  local image_reference=$1
  local local_archive=$2

  log "INFO" "Saving image ${image_reference} to ${local_archive}"

  if ! podman save \
    --format docker-archive \
    --output "${local_archive}" \
    "${image_reference}"; then
    log "ERROR" "Failed to save image: ${image_reference}"
    return 1
  fi

  log "INFO" "Image saved successfully: ${local_archive}"
}

# Generate checksum
generate_checksum() {
  debug_enter
  local local_stage=$1
  local archive_name=$2
  local checksum_name=$3

  log "INFO" "Generating checksum for ${archive_name} in ${local_stage}"

  (
    cd "${local_stage}"
    if ! sha256sum "${archive_name}" > "${checksum_name}"; then
      log "ERROR" "Failed to generate checksum for ${archive_name}"
      return 1
    fi

    if ! sha256sum --check "${checksum_name}"; then
      log "ERROR" "Checksum verification failed for ${archive_name}"
      return 1
    fi
  )

  log "INFO" "Checksum generated and verified: ${checksum_name}"
}

# Publish locked (atomic publication)
publish_locked() {
  debug_enter
  local image_root="${PUBLISH_ROOT}/${IMAGE_NAME}"  # <-- FIX: Added missing '/'
  local final_directory="${image_root}/${IMAGE_VERSION}"
  local temporary_directory="${image_root}/.${IMAGE_VERSION}.publishing.${CI_PIPELINE_ID}.${CI_JOB_ID}"

  log "INFO" "Publishing to: ${final_directory}"

  # Create image root directory
  mkdir -p "${image_root}"

  # Check if version already exists
  if [[ -e "${final_directory}" ]]; then
    log "ERROR" "Published version already exists: ${final_directory}"
    log "ERROR" "Published versions are immutable. Create a new version."
    return 1
  fi

  # Check if temporary directory already exists
  if [[ -e "${temporary_directory}" ]]; then
    log "ERROR" "Temporary publication directory already exists: ${temporary_directory}"
    return 1
  fi

  # Create temporary directory
  mkdir -p "${temporary_directory}"  # <-- FIX: Added '-p' to create parent dirs
  trap 'rm -rf "${temporary_directory}"' ERR INT TERM

  # Copy files to temporary directory
  log "INFO" "Copying files to temporary directory: ${temporary_directory}"
  # Use cp instead of install for mounted filesystems (no permission setting)
  cp "${LOCAL_ARCHIVE}" "${temporary_directory}/${ARCHIVE_NAME}"
  cp "${LOCAL_CHECKSUM}" "${temporary_directory}/${CHECKSUM_NAME}"
  cp "${LOCAL_METADATA}" "${temporary_directory}/${METADATA_NAME}"

  # Verify checksum in temporary directory
  (
    cd "${temporary_directory}" || return 1
    if ! sha256sum --check "${CHECKSUM_NAME}"; then
      log "ERROR" "Checksum verification failed in temporary directory"
      return 1
    fi
  )

  # Atomically move to final directory
  mv "${temporary_directory}" "${final_directory}"
  trap - ERR INT TERM

  log "INFO" "Published successfully to ${final_directory}"

  # List published files
  if [[ -d "${final_directory}" ]]; then
    find "${final_directory}" -maxdepth 1 -type f -printf '%f\n' | sort | while read -r file; do
      log "INFO" "Published file: ${file}"
    done
  fi
}

# Export ALL functions required by publish_locked
export -f log
export -f debug_enter
export -f debug_exit
export -f publish_locked

# =============================================================================
# MAIN SCRIPT
# =============================================================================

# Validate required environment variables
validate_required_vars \
  IMAGE_NAME \
  IMAGE_VERSION \
  IMAGE_REFERENCE \
  PUBLISH_ROOT || exit 1

# Set optional variables with defaults
LOCAL_STAGE_ROOT="${LOCAL_STAGE_ROOT:-/var/tmp/image-publisher}"
LOCK_FILE="${LOCK_FILE:-/var/lock/image-publisher/publish.lock}"
SOURCE_REPOSITORY="${CI_PROJECT_PATH:-unknown}"
SOURCE_COMMIT="${CI_COMMIT_SHA:-unknown}"
PIPELINE_ID="${CI_PIPELINE_ID:-unknown}"
JOB_ID="${CI_JOB_ID:-unknown}"
GIT_TAG="${CI_COMMIT_TAG:-}"

# Derived variables
ARCHIVE_NAME="${IMAGE_NAME}-${IMAGE_VERSION}.tar"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"
METADATA_NAME="${IMAGE_NAME}-${IMAGE_VERSION}.yml"

# Create temporary directory
LOCAL_STAGE=$(mktemp -d "${LOCAL_STAGE_ROOT}/${IMAGE_NAME}.${PIPELINE_ID}.${JOB_ID}.XXXXXX")
LOCAL_ARCHIVE="${LOCAL_STAGE}/${ARCHIVE_NAME}"
LOCAL_CHECKSUM="${LOCAL_STAGE}/${CHECKSUM_NAME}"
LOCAL_METADATA="${LOCAL_STAGE}/${METADATA_NAME}"

log "INFO" "Starting image publishing process"
log "INFO" "Local staging directory: ${LOCAL_STAGE}"
log "INFO" "Image: ${IMAGE_REFERENCE}"
log "INFO" "Version: ${IMAGE_VERSION}"
log "INFO" "Publish root: ${PUBLISH_ROOT}"

# Register cleanup trap
trap cleanup EXIT

# Validate image exists
validate_image_exists "${IMAGE_REFERENCE}" || exit 1

# Get image metadata
log "INFO" "Getting image metadata for: ${IMAGE_REFERENCE}"

if ! IMAGE_ID=$(podman image inspect --format '{{.Id}}' "${IMAGE_REFERENCE}" 2>/dev/null); then
  log "ERROR" "Failed to inspect image ID for: ${IMAGE_REFERENCE}"
  exit 1
fi

if ! IMAGE_DIGEST=$(podman image inspect --format '{{if .Digest}}{{.Digest}}{{end}}' "${IMAGE_REFERENCE}" 2>/dev/null); then
  log "ERROR" "Failed to inspect image digest for: ${IMAGE_REFERENCE}"
  exit 1
fi

log "DEBUG" "Image ID: ${IMAGE_ID}"
log "DEBUG" "Image Digest: ${IMAGE_DIGEST}"

# Save image to archive
save_image "${IMAGE_REFERENCE}" "${LOCAL_ARCHIVE}" || exit 1

# Verify archive was created
if [ ! -s "${LOCAL_ARCHIVE}" ]; then
  log "ERROR" "Archive file is empty or missing: ${LOCAL_ARCHIVE}"
  exit 1
fi
log "INFO" "Archive created: ${LOCAL_ARCHIVE}"

# Generate checksum
generate_checksum "${LOCAL_STAGE}" "${ARCHIVE_NAME}" "${CHECKSUM_NAME}" || exit 1

# Get archive metadata
ARCHIVE_SHA256=$(awk '{print $1}' "${LOCAL_CHECKSUM}")
ARCHIVE_SIZE_BYTES=$(stat -c '%s' "${LOCAL_ARCHIVE}")
PUBLISHED_AT_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

log "DEBUG" "Archive SHA256: ${ARCHIVE_SHA256}"
log "DEBUG" "Archive Size: ${ARCHIVE_SIZE_BYTES} bytes"

# Generate metadata file
if ! generate_metadata \
  "${LOCAL_METADATA}" \
  "${IMAGE_NAME}" \
  "${IMAGE_VERSION}" \
  "${IMAGE_REFERENCE}" \
  "${IMAGE_ID}" \
  "${IMAGE_DIGEST}" \
  "${ARCHIVE_NAME}" \
  "${ARCHIVE_SHA256}" \
  "${ARCHIVE_SIZE_BYTES}" \
  "${SOURCE_REPOSITORY}" \
  "${SOURCE_COMMIT}" \
  "${PIPELINE_ID}" \
  "${JOB_ID}" \
  "${GIT_TAG}" \
  "${PUBLISHED_AT_UTC}"; then
  log "ERROR" "Failed to generate metadata file"
  exit 1
fi

# Export ALL variables required by publish_locked
export IMAGE_NAME
export IMAGE_VERSION
export IMAGE_REFERENCE
export PUBLISH_ROOT
export CI_PIPELINE_ID
export CI_JOB_ID
export LOCAL_ARCHIVE
export LOCAL_CHECKSUM
export LOCAL_METADATA

# Publish with flock for mutual exclusion
log "INFO" "Acquiring lock for publishing: ${LOCK_FILE}"

(
  export -f log debug_enter debug_exit publish_locked
  export IMAGE_NAME IMAGE_VERSION IMAGE_REFERENCE PUBLISH_ROOT CI_PIPELINE_ID CI_JOB_ID LOCAL_ARCHIVE LOCAL_CHECKSUM LOCAL_METADATA

  # Ensure lock directory exists
  LOCK_DIR=$(dirname "${LOCK_FILE}")
  mkdir -p "${LOCK_DIR}"

  # Use file descriptor approach - doesn't require lock file to exist
  exec 200>"${LOCK_FILE}"
  if ! flock --exclusive --nonblock 200; then
    log "ERROR" "Another publish operation currently holds lock: ${LOCK_FILE}"
    exit 1
  fi

  publish_locked

  # Clean up file descriptor
  flock --unlock 200
  exec 200>&-
) || {
  log "ERROR" "Failed to acquire lock or execute publish_locked"
  exit 1
}

log "INFO" "Image publishing completed successfully"