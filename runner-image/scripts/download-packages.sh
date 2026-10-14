#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --lock <lock.yaml> --output <package-root-dir> [--mount-root <path>]

  --lock          Path to the package-runner lock file (yaml)
  --output        Directory to copy resolved package artifacts into
                   (default: packages)
  --mount-root    Local mount point for the package-content repository
                   (default: \${PACKAGE_CONTENT_MOUNT_ROOT:-/mnt/image-factory/package-content})

EOF
  exit 1
}

LOCK_FILE=""
OUTPUT_DIR="packages"
MOUNT_ROOT="${PACKAGE_CONTENT_MOUNT_ROOT:-/mnt/image-factory/package-content}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lock) LOCK_FILE="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --mount-root) MOUNT_ROOT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -z "$LOCK_FILE" ]] && usage
command -v yq >/dev/null 2>&1 || { echo "yq is required (install with: pip install yq or brew install yq)" >&2; exit 1; }
[[ -f "$LOCK_FILE" ]] || { echo "Lock file not found: $LOCK_FILE" >&2; exit 1; }
[[ -d "$MOUNT_ROOT" ]] || { echo "Mount root directory not found: $MOUNT_ROOT" >&2; exit 1; }

# Function to calculate SHA256
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

# Function to resolve repository root
resolve_repo_root() {
  local repo="$1"
  # For now, we only support the default package-content repository
  echo "$MOUNT_ROOT"
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo "Starting package download from lock file: $LOCK_FILE"
echo "Output directory: $OUTPUT_DIR"
echo "Mount root: $MOUNT_ROOT"
echo ""

# Get package count
package_count=$(yq eval '.packages | length' "$LOCK_FILE")
echo "Found $package_count packages to download"

failures=0
success=0

# Process each package
for i in $(seq 0 $((package_count - 1))); do
  # Extract package information from lock file
  name=$(yq eval ".packages[$i].name" "$LOCK_FILE")
  version=$(yq eval ".packages[$i].version" "$LOCK_FILE")

  # Check if artifact exists in lock file
  artifact_exists=$(yq eval ".packages[$i].artifact != null" "$LOCK_FILE")

  if [[ "$artifact_exists" != "true" ]]; then
    echo "⚠️  SKIP: $name $version - No artifact defined"
    continue
  fi

  # Extract artifact details
  repo=$(yq eval ".packages[$i].artifact.repository // \"package-content\"" "$LOCK_FILE")
  rel_path=$(yq eval ".packages[$i].artifact.path // \"\"" "$LOCK_FILE")
  filename=$(yq eval ".packages[$i].artifact.filename" "$LOCK_FILE")
  expected_sha256=$(yq eval ".packages[$i].artifact.sha256 // \"\"" "$LOCK_FILE")
  expected_size=$(yq eval ".packages[$i].artifact.sizeBytes // 0" "$LOCK_FILE")

  echo "==> Downloading: $name v$version"

  # Resolve source and destination paths
  repo_root=$(resolve_repo_root "$repo")
  src="$repo_root/$rel_path/$filename"
  dest_dir="$OUTPUT_DIR/$name/$version"
  dest="$dest_dir/$filename"

  # Validate source exists
  if [[ ! -f "$src" ]]; then
    echo "    ❌ FAIL: Source artifact not found: $src" >&2
    failures=$((failures + 1))
    continue
  fi

  # Create destination directory
  mkdir -p "$dest_dir"

  # Copy the file with progress indication
  echo "    Copying: $filename"
  cp -f "$src" "$dest"

  # Verify size
  actual_size=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || wc -c < "$dest" | tr -d ' ')
  if [[ "$expected_size" != "0" && "$actual_size" != "$expected_size" ]]; then
    echo "    ❌ FAIL: Size mismatch (expected $expected_size, got $actual_size)" >&2
    rm -f "$dest"
    failures=$((failures + 1))
    continue
  fi

  # Verify SHA256 if provided
  if [[ -n "$expected_sha256" ]]; then
    echo "    Verifying SHA256..."
    actual_sha256=$(sha256_of "$dest")
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
      echo "    ❌ FAIL: SHA256 mismatch (expected $expected_sha256, got $actual_sha256)" >&2
      rm -f "$dest"
      failures=$((failures + 1))
      continue
    fi
  fi

  echo "    ✅ SUCCESS: Downloaded to $dest"
  success=$((success + 1))
done

echo ""
echo "--- Download Summary ---"
echo "Successful: $success"
echo "Failed:     $failures"

if [[ "$failures" -gt 0 ]]; then
  echo "Completed with $failures failure(s)" >&2
  exit 1
fi

echo "✅ All $success packages downloaded and verified successfully."
exit 0