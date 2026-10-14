#!/usr/bin/env bash
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

TIMESTAMP="$(ts_file)"
VM_LIST_LOG="${EVIDENCE_DIR}/vm-list-${TIMESTAMP}.log"
VM_NAME_PATTERN="${1:-"*packer-*"}"

require_env VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD

export GOVC_URL="https://${VCENTER_HOST}"
export GOVC_USERNAME="${VCENTER_USERNAME}"
export GOVC_PASSWORD="${VCENTER_PASSWORD}"
export GOVC_INSECURE=true

ensure_evidence_dir
exec > >(tee -a "$VM_LIST_LOG") 2>&1

# Checked before the pattern is used or printed: an explicitly empty argument
# would otherwise match every VM in the inventory.
[[ -n "$VM_NAME_PATTERN" ]] ||
    fail "VM name pattern must not be empty."

# Workstation requirement: the CI runner image has no govc.
require_command govc

printf 'Checking VM-name availability: %s\n' "$VM_NAME_PATTERN"

# govc's stderr is kept: without it an authentication failure and a genuine
# empty result are indistinguishable.
if ! VM_LIST=$(govc find -type m -name "$VM_NAME_PATTERN"); then
    fail "Unable to query vCenter for VM names."
fi

if [ -n "$VM_LIST" ]; then
    printf '%s\n' "Found existing VM(s) matching pattern."
    printf '%s\n' "$VM_LIST"
else
    printf '%s\n' "No VMs found matching pattern."
fi

exit 0