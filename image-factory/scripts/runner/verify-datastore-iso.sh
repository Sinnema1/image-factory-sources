#!/usr/bin/env bash
# Stage 2 of ISO qualification: verifies the copy on the vSphere datastore —
# the bytes a build actually boots — against its qualification record.
#
# TWO STAGES, AND WHY. The datastore is the authoritative ISO library (ADR 0004,
# Content Library being permission-blocked). An ISO arrives at an intake share,
# is hashed there, is published to the datastore by hand, and is verified again
# here. One recorded sha256; both copies checked against it.
#
#   stage 1  verify-iso.sh              the intake copy, at a filesystem path
#   stage 2  verify-datastore-iso.sh    the published copy, on the datastore
#
# Publishing is manual, so this does not prevent a bad publish — it catches one.
# That is the deliberate trade recorded in ADR 0004.
#
# WHERE IT RUNS. Needs govc, which the CI runner image does not have, so no
# pipeline job calls this yet. It exits 2 when govc is missing — "could not run"
# rather than "failed" — so it can be wired into CI unchanged once govc lands.
#
# COST. Always streams the whole ISO, roughly 8.5 GB, from the datastore through
# this machine. Expect minutes. A size pre-check could short-circuit an obvious
# mismatch, but govc's listing output format has not been confirmed here and an
# unverified shortcut on a verification tool is worse than a slow one.
#
# Usage:
#   verify-datastore-iso.sh [--metadata FILE] [--evidence-dir DIR]
#
# Needs bash, govc, jq and sha256sum, plus VCENTER_HOST, VCENTER_USERNAME and
# VCENTER_PASSWORD. A JSON evidence record is written on success and on failure.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

METADATA="${REPO_ROOT}/packer/sources/windows/windows-11.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --metadata)     METADATA="${2:-}"; shift 2 ;;
        --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
        -h|--help)      sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              printf 'Error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# Exit 2, not 1: a missing tool means the check could not run, which is a
# different condition from the check running and failing.
require_command govc jq sha256sum
require_env VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD

export GOVC_URL="https://${VCENTER_HOST}"
export GOVC_USERNAME="${VCENTER_USERNAME}"
export GOVC_PASSWORD="${VCENTER_PASSWORD}"
export GOVC_INSECURE=true

# A vCenter account is normally DOMAIN\user or user@domain. A bare name is the
# signature of a specific trap: sourcing an unquoted DOMAIN\user from .env lets
# bash eat the backslash, and vCenter then reports "incorrect user name or
# password" — which sends you looking at the password. Warn rather than fail,
# because a local (non-domain) vCenter account legitimately has neither form.
case "$VCENTER_USERNAME" in
    *[\\@]*) ;;
    *) printf 'Warning: VCENTER_USERNAME (%s) has no domain part. If it came from an\n' "$VCENTER_USERNAME" >&2
       printf '         unquoted .env, bash may have stripped a backslash. Quote it, or use user@domain.\n' >&2 ;;
esac

TIMESTAMP="$(ts_file)"
ensure_evidence_dir
# The record's name is part of the evidence filename, not just the timestamp.
# ts_file has second resolution, and CI validates every record in a loop that
# finishes well inside one second — so a bare timestamp made the second record
# silently overwrite the first's evidence. OBSERVED in CI, 2026-09-24.
RECORD_SLUG="$(basename -- "$METADATA" .json)"
RECORD_SLUG="${RECORD_SLUG//[^A-Za-z0-9._-]/-}"
EVIDENCE_FILE="${EVIDENCE_DIR}/iso-datastore-verify-${RECORD_SLUG}-${TIMESTAMP}.json"

# SHA-256 of zero bytes. If the download yields this, nothing was transferred,
# which is a different problem from the wrong bytes being transferred.
EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

error=""
datastore=""; datastore_path=""; origin_path=""
expected_filename=""; expected_size=""; expected_sha=""
actual_sha=""; elapsed_seconds=0

write_evidence() {
    local result="$1"
    jq -n \
        --arg timestamp "$(ts_iso)" \
        --arg result "$result" \
        --arg error "$error" \
        --arg metadata "$METADATA" \
        --arg datastore "$datastore" \
        --arg datastore_path "$datastore_path" \
        --arg origin_path "$origin_path" \
        --arg exp_name "$expected_filename" \
        --arg exp_size "$expected_size" \
        --arg exp_sha "$expected_sha" \
        --arg act_sha "$actual_sha" \
        --argjson elapsed "$elapsed_seconds" \
        '{
            schema_version: 1,
            timestamp: $timestamp,
            result: $result,
            error: (if $error == "" then null else $error end),
            metadata_path: $metadata,
            stage: "datastore",
            datastore: $datastore,
            datastore_path: $datastore_path,
            origin_path: (if $origin_path == "" then null else $origin_path end),
            download_elapsed_seconds: $elapsed,
            iso: {
                filename: $exp_name,
                expected_size_bytes: $exp_size,
                expected_sha256: $exp_sha,
                actual_sha256: (if $act_sha == "" then null else $act_sha end)
            }
        }' >"$EVIDENCE_FILE"
}

# Overrides lib/common.sh's fail: records evidence of the failure before exiting.
fail() {
    error="$1"
    write_evidence "failed"
    printf 'Datastore ISO verification FAILED: %s\n' "$error" >&2
    printf 'Evidence: %s\n' "$EVIDENCE_FILE" >&2
    exit 1
}

[[ -f "$METADATA" ]] || fail "metadata file not found: ${METADATA}"
jq -e . "$METADATA" >/dev/null 2>&1 || fail "metadata is not valid JSON: ${METADATA}"

datastore="$(jq -r '.datastore // empty' "$METADATA")"
datastore_path="$(jq -r '.datastorePath // empty' "$METADATA")"
origin_path="$(jq -r '.originPath // empty' "$METADATA")"
expected_filename="$(jq -r '.filename // empty' "$METADATA")"
expected_size="$(jq -r '.sizeBytes // empty' "$METADATA")"
expected_sha="$(jq -r '.sha256 // empty' "$METADATA" | tr '[:upper:]' '[:lower:]')"

[[ -n "$datastore" ]] || fail "metadata has no 'datastore'"
[[ -n "$datastore_path" ]] || fail "metadata has no 'datastorePath'"
[[ -n "$expected_filename" ]] || fail "metadata has no 'filename'"
[[ -n "$expected_sha" ]] || fail "metadata has no 'sha256'"

# The record's path must name the file the record claims to describe, or the
# hash below would be checked against the wrong thing entirely.
[[ "$(basename -- "$datastore_path")" == "$expected_filename" ]] ||
    fail "datastorePath ends in '$(basename -- "$datastore_path")' but filename is '${expected_filename}'"

printf 'Verifying [%s] %s\n' "$datastore" "$datastore_path"
printf 'This streams the whole ISO (%s bytes) and may take minutes.\n' "${expected_size:-unknown}"

# govc's stderr is deliberately not suppressed: an authentication failure and an
# empty result are otherwise indistinguishable (same reasoning as
# check-vm-name.sh). PIPESTATUS is what surfaces a govc failure through the pipe,
# since sha256sum will happily hash nothing and exit 0.
download_start="$(date -u +%s)"
actual_sha="$(govc datastore.download -ds "$datastore" "$datastore_path" - | sha256sum | cut -d' ' -f1)"
govc_rc="${PIPESTATUS[0]}"
elapsed_seconds=$(( $(date -u +%s) - download_start ))

[[ "$govc_rc" -eq 0 ]] ||
    fail "govc datastore.download failed with exit ${govc_rc}; see its output above"

[[ -n "$actual_sha" ]] || fail "the download produced no hash"

# Distinguish "transferred nothing" from "transferred the wrong bytes". If govc
# in this build does not treat '-' as stdout, this is the symptom.
[[ "$actual_sha" != "$EMPTY_SHA256" ]] ||
    fail "the download produced zero bytes. If govc here does not stream to stdout with '-', download to a file and hash that instead"

[[ "$actual_sha" == "$expected_sha" ]] ||
    fail "SHA-256 mismatch on the datastore copy: expected ${expected_sha}, computed ${actual_sha}"

write_evidence "passed"

printf 'Datastore ISO verification passed: %s (streamed in %ss)\n' \
    "$expected_filename" "$elapsed_seconds"
printf 'Evidence: %s\n' "$EVIDENCE_FILE"
exit 0
