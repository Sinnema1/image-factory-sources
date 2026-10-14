#!/usr/bin/env bash
set -uo pipefail
umask 077

# --- Setup ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

TIMESTAMP="$(ts_file)"
PREFLIGHT_LOG="${EVIDENCE_DIR}/preflight-${TIMESTAMP}.log"

# --- Validations ---
ensure_evidence_dir
exec > >(tee -a "$PREFLIGHT_LOG") 2>&1

printf '%s\n' "Starting preflight checks..."

# govc is a workstation requirement: the CI runner image does not have it, which
# is why no CI job calls this script. See the Makefile help.
require_command packer govc

require_env VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD

require_readable_file \
    "$PACKER_TEMPLATE" \
    "$PACKER_VARS" \
    "$UNATTEND_TEMPLATE" \
    "$WINRM_SCRIPT"

printf '%s\n' "Local runner Preflight checks passed."
exit 0