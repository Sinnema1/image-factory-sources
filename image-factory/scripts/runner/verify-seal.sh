#!/usr/bin/env bash
# Collects and checks the seal result of a sealed build (ADR 0002; the check
# is STORY-19's, AC4 and AC5).
#
# The seal removes WinRM, so its result cannot be downloaded the way every
# other guest result is. The final stage of
# packer/provisioners/Invoke-ImageSeal.ps1 sets it as a VMware Tools guestinfo
# value instead, base64-encoded, and this script reads that value from vCenter.
#
# A value the guest sets is visible from outside only while the VM is powered
# on (OBSERVED 2026-10-08: readable while on, gone after power-off). The seal
# therefore holds the machine on for a while after reporting, and this script
# has two modes:
#
#   watch   Started in the background before Packer. Polls the VM until the
#           result for THIS execution id appears, saves it as evidence, and
#           exits. It keeps whatever the seal reported, pass or fail.
#   check   Run after Packer returns. Fails unless a saved result exists for
#           this execution id and says the image is sealed. No result is a
#           failure: a seal that cannot be shown to have worked has not.
#
# Usage:
#   verify-seal.sh watch --vm NAME --execution-id ID [--evidence-dir DIR]
#                        [--timeout SECONDS] [--interval SECONDS]
#   verify-seal.sh check --execution-id ID [--evidence-dir DIR]
#
# watch needs govc, jq and base64, and VCENTER_HOST, VCENTER_USERNAME and
# VCENTER_PASSWORD. check needs jq.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

GUESTINFO_KEY="guestinfo.imagefactory.seal.result"

MODE="${1:-}"
[[ $# -gt 0 ]] && shift
VM_NAME=""
EXECUTION_ID=""
TIMEOUT_SECONDS=5400
INTERVAL_SECONDS=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)            VM_NAME="${2:-}"; shift 2 ;;
        --execution-id)  EXECUTION_ID="${2:-}"; shift 2 ;;
        --evidence-dir)  EVIDENCE_DIR="${2:-}"; shift 2 ;;
        --timeout)       TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        --interval)      INTERVAL_SECONDS="${2:-}"; shift 2 ;;
        -h|--help)       sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)               fail "unknown argument: $1" ;;
    esac
done

[[ "$EXECUTION_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--execution-id is required and may only contain letters, digits, '.', '_' and '-'"
RESULT_FILE="${EVIDENCE_DIR}/seal-result-${EXECUTION_ID}.json"

# Prints the decoded result if the VM currently carries one, and nothing
# otherwise. Every failure here is "not yet": the VM may not exist yet, may be
# off, or vCenter may be briefly unreachable, and the caller polls again.
read_result() {
    local encoded
    encoded="$(
        govc vm.info -json -e "$VM_NAME" 2>/dev/null |
            jq -r --arg key "$GUESTINFO_KEY" \
                'first(.. | objects | select((.key // .Key // "") == $key) | (.value // .Value)) // empty' 2>/dev/null
    )" || return 0
    [[ -n "$encoded" ]] || return 0
    printf '%s' "$encoded" | base64 -d 2>/dev/null || true
}

case "$MODE" in
    watch)
        require_command govc jq base64
        require_env VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD
        [[ -n "$VM_NAME" ]] || fail "--vm is required"
        [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
            fail "--timeout and --interval must be whole numbers of seconds"
        ensure_evidence_dir

        export GOVC_URL="https://${VCENTER_HOST}"
        export GOVC_USERNAME="${VCENTER_USERNAME}"
        export GOVC_PASSWORD="${VCENTER_PASSWORD}"
        export GOVC_INSECURE=true

        deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
        while [[ $(date +%s) -lt $deadline ]]; do
            result="$(read_result)"
            # A retained VM can still carry the result of an earlier run, so
            # only this execution's result counts.
            if [[ -n "$result" ]] &&
                [[ "$(jq -r '.execution_id // empty' <<<"$result" 2>/dev/null)" == "$EXECUTION_ID" ]]; then
                jq '.' <<<"$result" >"$RESULT_FILE" || fail "the seal result is not valid JSON"
                printf 'Seal result captured: %s (sealed: %s)\n' "$RESULT_FILE" "$(jq -r '.sealed' "$RESULT_FILE")"
                exit 0
            fi
            sleep "$INTERVAL_SECONDS"
        done
        fail "no seal result for execution ${EXECUTION_ID} appeared on ${VM_NAME} within ${TIMEOUT_SECONDS} seconds"
        ;;

    check)
        require_command jq
        [[ -f "$RESULT_FILE" ]] ||
            fail "no seal result was captured for execution ${EXECUTION_ID} (expected ${RESULT_FILE}). The image cannot be shown to be sealed"
        [[ "$(jq -r '.execution_id // empty' "$RESULT_FILE")" == "$EXECUTION_ID" ]] ||
            fail "the captured seal result is for another execution"
        if [[ "$(jq -r '.sealed' "$RESULT_FILE")" != "true" ]]; then
            fail "the image is NOT sealed: $(jq -r '.error // "no reason given"' "$RESULT_FILE")"
        fi
        printf 'Image seal verified: %s reports sealed, %s action(s), nothing left on the pre-seal list.\n' \
            "$(jq -r '.computer_name' "$RESULT_FILE")" "$(jq '.actions | length' "$RESULT_FILE")"
        printf 'Evidence: %s\n' "$RESULT_FILE"
        ;;

    *)
        fail "the first argument must be 'watch' or 'check'"
        ;;
esac
