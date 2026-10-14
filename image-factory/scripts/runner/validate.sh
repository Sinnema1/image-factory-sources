#!/usr/bin/env bash
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

TIMESTAMP="$(ts_file)"
VALIDATE_LOG="${EVIDENCE_DIR}/validate-${TIMESTAMP}.log"

# The template's package variables have no defaults on purpose, so packer
# validate needs the var file that stage-packages.sh emits.
PACKAGE_VERIFIER="${SCRIPT_DIR}/stage-packages.sh"

SOURCE_METADATA_VALIDATOR="${SCRIPT_DIR}/validate-iso-metadata.sh"
WINDOWS_ISO_VALIDATOR="${SCRIPT_DIR}/verify-iso.sh"
# There is no manifest-based package validation here any more. The PowerShell
# validator (software-source/) was deleted on 2026-09-29 once ADR 0003 was
# accepted: package integrity now belongs to download-packages on the runner and
# package-runner in the guest, both reading the pinned lock.

WINDOWS_ISO_PATH="${WINDOWS_ISO_PATH:-/mnt/fileshare-shared/image-factory/windows-11-enterprise-25h2-x64.iso}"

# fail, require_command and require_readable_file come from lib/common.sh.

# Function to write evidence
run_validation() {
    local step_name="$1"
    local description="$2"
    shift 2

    local step_log="${EVIDENCE_DIR}/${step_name}-${TIMESTAMP}.log"
    local command_rc

    printf '%s\n' "$description"
    printf 'Step log: %s\n' "$step_log"

    "$@" 2>&1 | tee "$step_log"
    command_rc=${PIPESTATUS[0]}

    if [[ "$command_rc" -ne 0 ]]; then
        printf 'Validation failed: %s\n' "$step_name" >&2
        printf 'Exit code: %s\n' "$command_rc" >&2
        printf 'Step log: %s\n' "$step_log" >&2
        return "$command_rc"
    fi
    printf 'Validation passed: %s\n' "$step_name"
    return 0
}

ensure_evidence_dir

# Log all output
exec > >(tee -a "$VALIDATE_LOG") 2>&1

printf '%s\n' "Starting configured repository validation checks..."
printf 'Repository root: %s\n' "$REPO_ROOT"
printf 'Validation log: %s\n' "$VALIDATE_LOG"

require_command packer tee

# Everything here is bash, so it needs no pwsh and could run on the CI runner
# image. What keeps this script off the runner is the mounted share that
# WINDOWS_ISO_PATH points at.
require_readable_file \
    "$PACKER_TEMPLATE" \
    "$PACKER_VARS" \
    "$PACKAGE_VERIFIER" \
    "$SOURCE_METADATA_VALIDATOR" \
    "$WINDOWS_ISO_VALIDATOR" \
    "$WINDOWS_ISO_PATH"

# --- Validate Windows source metadata ---
run_validation \
    "validate-metadata" \
    "Validating Windows source metadata..." \
    bash "$SOURCE_METADATA_VALIDATOR" --evidence-dir "$EVIDENCE_DIR"
validation_rc=$?

if [[ "$validation_rc" -ne 0 ]]; then
    exit "$validation_rc"
fi

# --- Validate Example Labs ISO ---
run_validation \
    "validate-iso" \
    "Validating Example Labs ISO..." \
    bash "$WINDOWS_ISO_VALIDATOR" \
        --source-path "$WINDOWS_ISO_PATH" \
        --evidence-dir "$EVIDENCE_DIR"
validation_rc=$?

if [[ "$validation_rc" -ne 0 ]]; then
    exit "$validation_rc"
fi

# --- Verify the install inputs and emit their Packer variables ---
# The template requires package_lock, package_artifact_root, package_runner and
# execution_id, none of which have defaults. Without this step
# packer validate below fails on the missing variables, not on the template.
ensure_build_dir

run_validation \
    "validate-package-vars" \
    "Verifying the lock, package-runner and the package files on the runner..." \
    bash "$PACKAGE_VERIFIER" --emit-var-file "$PACKAGE_VARS_FILE"
validation_rc=$?

if [[ "$validation_rc" -ne 0 ]]; then
    exit "$validation_rc"
fi

require_readable_file "$PACKAGE_VARS_FILE"

# --- Validate Packer template ---
printf '%s\n' "Validating Packer template..."

if ! packer validate \
    -var-file="$PACKER_VARS" \
    -var-file="$PACKAGE_VARS_FILE" \
    "$PACKER_TEMPLATE"; then
    printf 'Error: Packer template validation failed.\n' >&2
    exit 1
fi

printf '%s\n' "Packer template validation passed."
exit 0