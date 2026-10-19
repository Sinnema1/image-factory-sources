#!/bin/bash

# Script: move_files.sh
# Description: Moves files from a source directory to a specified mount location.
# Usage: ./move_files.sh <source_dir> <target_mount>

set -euo pipefail

# Check if source and target arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Error: Invalid number of arguments."
    echo "Usage: $0 <source_dir> <target_mount>"
    exit 1
fi

SOURCE_DIR="$1"
TARGET_MOUNT="$2"

# Validate source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory '$SOURCE_DIR' does not exist."
    exit 1
fi

# Validate target mount exists and is writable
if [ ! -d "$TARGET_MOUNT" ]; then
    echo "Error: Target mount '$TARGET_MOUNT' does not exist."
    exit 1
fi

if [ ! -w "$TARGET_MOUNT" ]; then
    echo "Error: Target mount '$TARGET_MOUNT' is not writable."
    exit 1
fi

# Move files
echo "Moving files from '$SOURCE_DIR' to '$TARGET_MOUNT'..."
find "$SOURCE_DIR" -type f -exec mv -v {} "$TARGET_MOUNT" \;

echo "Files moved successfully."
exit 0