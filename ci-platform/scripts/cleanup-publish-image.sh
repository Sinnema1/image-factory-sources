#!/bin/bash
#
# Script: cleanup-scripts.sh
# Purpose: Clean up old, untagged versions of scripts (older than 7 days)
#          Preserves versions with Git tags (e.g., v1.0.0, 1.0.0, 2.1.3).
# Usage: Run as a cron job (e.g., daily at 3 AM)
#        Use --dry-run to test without deleting

SHARED_SCRIPTS_DIR="/mnt/image-factory/artifactory/image-factory-group/ci-platform/scripts"
LOG_FILE="/var/log/scripts-cleanup.log"
DRY_RUN=false

# Parse command line arguments
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# Function to check if a directory name looks like a version tag
is_version_tag() {
  local dirname="$1"
  # Matches: v1.0.0, 1.0.0, v2.1, 2.1.3.4, etc.
  if [[ "$dirname" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
    return 0  # true
  fi
  return 1  # false
}

# Log function
log() {
  local message="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
  echo "$message"
}

# Main cleanup function
cleanup() {
  local dir
  local dirname
  local action

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would clean up ${SHARED_SCRIPTS_DIR}"
    action="[DRY RUN] Would remove"
  else
    log "Starting cleanup of ${SHARED_SCRIPTS_DIR}"
    action="Removing"
  fi

  # Use find with null-terminated output to handle special characters
  while IFS= read -r -d $'\0' dir; do
    dirname=$(basename "$dir")

    # Skip the "latest" directory (not a symlink, just a folder)
    if [[ "$dirname" == "latest" ]]; then
      continue
    fi

    # Skip version-tagged directories
    if is_version_tag "$dirname"; then
      log "Preserving tagged version: $dir"
      continue
    fi

    # Process the directory
    if [ "$DRY_RUN" = true ]; then
      log "${action} old untagged directory: $dir"
    else
      log "Removing old untagged directory: $dir"
      rm -rf "$dir"
    fi
  done < <(find "$SHARED_SCRIPTS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -print0)

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Cleanup test completed (no files were deleted)"
  else
    log "Cleanup completed"
  fi
}

# Run cleanup
cleanup