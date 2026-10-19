#!/bin/bash

# Script: publish_cli.sh
# Description: Publishes build artifacts using absolute isolation to prevent filesystem collisions.
# Usage: ./publish_cli.sh <version> <source_dir> <target_mount>

set -euo pipefail

# Logging helper
log() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1"; }
error() { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1" >&2; exit 1; }

# Check if source and target arguments are provided
if [ "$#" -ne 3 ]; then
    error "Invalid number of arguments. Usage: $0 <version> <source_dir> <target_mount>"
fi

VERSION="$1"
SOURCE_DIR="$2"
BASE_MOUNT="$3"

APP_NAME="package-runner"
APP_ROOT="$BASE_MOUNT/$APP_NAME"
PUBLISH_DESTINATION="$APP_ROOT/$VERSION"

log "Starting publication for version: $VERSION"

# --- ISOLATION LAYER ---
# mktemp -d is the only guaranteed way in Linux to create a unique directory 
# that cannot conflict with other concurrent processes.
LOCAL_STAGING=$(mktemp -d -t package-runner-XXXXXX)
UNIQUE_ID=$(date +%s%N | cut -b1-13)
TMP_DESTINATION="${PUBLISH_DESTINATION}.${UNIQUE_ID}.tmp"

# --- CLEANUP HANDLER ---
cleanup() {
    local exit_code=$?
    log "Performing cleanup..."
    # Use a loop for remote cleanup because Windows shares are stubborn
    [ -d "$LOCAL_STAGING" ] && rm -rf "$LOCAL_STAGING"
    if [ -d "$TMP_DESTINATION" ]; then
        rm -rf "$TMP_DESTINATION" || log "Warning: Could not remove remote tmp folder"
    fi
    exit $exit_code
}
trap cleanup EXIT

# 1. Basic Validations
[ ! -d "$SOURCE_DIR" ] && error "Source directory '$SOURCE_DIR' does not exist."
[ ! -d "$BASE_MOUNT" ] && error "Base mount '$BASE_MOUNT' does not exist."
mkdir -p "$APP_ROOT"

# 2. Stage Locally (Isolated)
log "Staging artifacts to isolated local directory: $LOCAL_STAGING"

# Instead of cp -R, we use a more explicit method. 
# We copy the CONTENTS of source_dir into the staging dir.
# This avoids creating the 'dist' folder inside 'staging' and then 
# accidentally creating it again.
cp -R "$SOURCE_DIR"/. "$LOCAL_STAGING/"

# 3. Transfer to Network Share
log "Transferring from $LOCAL_STAGING to $TMP_DESTINATION..."
mkdir -p "$TMP_DESTINATION"

# Copy the contents of our isolated local folder to the unique remote tmp folder.
cp -R "$LOCAL_STAGING"/. "$TMP_DESTINATION/"

# 4. Force Filesystem Sync
sync

# 5. Atomic Final Move
log "Moving temporary directory to final destination..."
if [ -d "$PUBLISH_DESTINATION" ]; then
    log "Version $VERSION already exists. Overwriting..."
    # Windows Share Hack: Rename then delete
    BACKUP="${PUBLISH_DESTINATION}.old.$(date +%s)"
    mv "$PUBLISH_DESTINATION" "$BACKUP" || true
    rm -rf "$BACKUP" || true
    sleep 1 # Give the Windows server a moment to release locks
fi

if ! mv "$TMP_DESTINATION" "$PUBLISH_DESTINATION"; then
    error "Final move failed. Destination might be locked by a Windows process."
fi

# 6. Final Permissions
chmod -R 750 "$PUBLISH_DESTINATION" || log "Warning: chmod not supported by share"

log "Successfully published $VERSION to $PUBLISH_DESTINATION"
exit 0