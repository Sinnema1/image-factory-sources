#!/usr/bin/env bash
# Stage 1 of ISO qualification: verifies a copy of the ISO at a filesystem path
# — the intake copy — against its qualification record: filename, size and
# SHA-256.
#
# This is not the copy the build boots. The datastore is the authoritative
# library (ADR 0004), and verify-datastore-iso.sh is stage 2, checking the
# published copy there. Both stages check against the one sha256 in the record.
# Passing this alone says the intake copy is intact, nothing more.
#
# Bash rather than PowerShell so it can run on the CI runner, whose image has no
# pwsh.
#
# TWO PATHS, ON PURPOSE. The record's originPath is the intake location in its
# canonical form (\\fileshare\shared\...), but a Linux runner sees the same
# bytes at a mount point (/mnt/fileshare-shared/...). Those are one file in two
# locations, so --source-path overrides where to read from and the evidence
# records both: canonical_source_path is the recorded origin,
# validated_source_path is what was actually read. An override must still point
# at a file with the recorded name; the filename check runs against the record
# either way.
#
# originPath is optional in the schema, because the datastore fields are what a
# record must carry. Without it, this stage needs --source-path.
#
# COST. This hashes the whole ISO, roughly 8.5 GB, usually over a network share.
# Expect minutes, bound by the share rather than by CPU. The elapsed time is
# recorded in the evidence so a slow share is visible rather than mysterious.
#
# Usage:
#   verify-iso.sh [--metadata FILE] [--source-path PATH] [--evidence-dir DIR]
#
# Needs bash, jq, sha256sum and stat. A JSON evidence record is written on
# success and on failure.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

METADATA="${REPO_ROOT}/packer/sources/windows/windows-11.json"
SOURCE_PATH=""
SOURCE_PATH_GIVEN="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --metadata)     METADATA="${2:-}"; shift 2 ;;
        --source-path)  SOURCE_PATH="${2:-}"; SOURCE_PATH_GIVEN="true"; shift 2 ;;
        --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
        -h|--help)      sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              printf 'Error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

require_command jq sha256sum stat

TIMESTAMP="$(ts_file)"
ensure_evidence_dir
# The record's name is part of the evidence filename, not just the timestamp.
# ts_file has second resolution, and CI validates every record in a loop that
# finishes well inside one second — so a bare timestamp made the second record
# silently overwrite the first's evidence. OBSERVED in CI, 2026-09-24.
RECORD_SLUG="$(basename -- "$METADATA" .json)"
RECORD_SLUG="${RECORD_SLUG//[^A-Za-z0-9._-]/-}"
EVIDENCE_FILE="${EVIDENCE_DIR}/iso-verify-${RECORD_SLUG}-${TIMESTAMP}.json"

# Filled in as the checks progress, so a failure still records what was known.
error=""
canonical_path=""
validated_path=""
expected_filename=""; actual_filename=""
expected_size=""; actual_size=""
expected_sha=""; actual_sha=""
elapsed_seconds=0

write_evidence() {
    local result="$1"
    jq -n \
        --arg timestamp "$(ts_iso)" \
        --arg result "$result" \
        --arg error "$error" \
        --arg metadata "$METADATA" \
        --arg canonical "$canonical_path" \
        --arg validated "$validated_path" \
        --arg exp_name "$expected_filename" --arg act_name "$actual_filename" \
        --arg exp_size "$expected_size"     --arg act_size "$actual_size" \
        --arg exp_sha "$expected_sha"       --arg act_sha "$actual_sha" \
        --argjson elapsed "$elapsed_seconds" \
        '{
            schema_version: 1,
            timestamp: $timestamp,
            result: $result,
            error: (if $error == "" then null else $error end),
            metadata_path: $metadata,
            canonical_source_path: (if $canonical == "" then null else $canonical end),
            validated_source_path: (if $validated == "" then null else $validated end),
            hash_elapsed_seconds: $elapsed,
            iso: {
                expected_filename: $exp_name, actual_filename: $act_name,
                expected_size_bytes: $exp_size, actual_size_bytes: $act_size,
                expected_sha256: $exp_sha, actual_sha256: $act_sha
            }
        }' >"$EVIDENCE_FILE"
}

# Overrides lib/common.sh's fail: records evidence of the failure before exiting.
fail() {
    error="$1"
    write_evidence "failed"
    printf 'ISO verification FAILED: %s\n' "$error" >&2
    printf 'Evidence: %s\n' "$EVIDENCE_FILE" >&2
    exit 1
}

# An explicitly empty override is a mistake, not a request to fall back to the
# canonical path. Silently falling back would hash the wrong file, or none.
if [[ "$SOURCE_PATH_GIVEN" == "true" && -z "$SOURCE_PATH" ]]; then
    fail "--source-path was given but is empty"
fi

[[ -f "$METADATA" ]] || fail "metadata file not found: ${METADATA}"
jq -e . "$METADATA" >/dev/null 2>&1 || fail "metadata is not valid JSON: ${METADATA}"

expected_filename="$(jq -r '.filename // empty' "$METADATA")"
expected_size="$(jq -r '.sizeBytes // empty' "$METADATA")"
expected_sha="$(jq -r '.sha256 // empty' "$METADATA" | tr '[:upper:]' '[:lower:]')"
canonical_path="$(jq -r '.originPath // empty' "$METADATA")"

[[ -n "$expected_filename" ]] || fail "metadata has no 'filename'"
[[ -n "$expected_size" ]] || fail "metadata has no 'sizeBytes'"
[[ -n "$expected_sha" ]] || fail "metadata has no 'sha256'"

if [[ "$SOURCE_PATH_GIVEN" == "true" ]]; then
    validated_path="$SOURCE_PATH"
else
    [[ -n "$canonical_path" ]] ||
        fail "metadata has no 'originPath' and no --source-path was given; this stage verifies the intake copy, so it needs one or the other"
    validated_path="$canonical_path"
fi

[[ -f "$validated_path" ]] ||
    fail "source path does not exist or is not a file: ${validated_path}"

actual_filename="$(basename -- "$validated_path")"
[[ "$actual_filename" == "$expected_filename" ]] ||
    fail "filename mismatch: expected '${expected_filename}', found '${actual_filename}'"

actual_size="$(stat -c %s -- "$validated_path" 2>/dev/null)" ||
    fail "could not read the size of ${validated_path}"
[[ "$actual_size" == "$expected_size" ]] ||
    fail "size mismatch: expected ${expected_size} bytes, found ${actual_size}"

printf 'Hashing %s (%s bytes). This reads the whole file and may take minutes.\n' \
    "$actual_filename" "$actual_size"

hash_start="$(date -u +%s)"
# Hash from stdin, not by file name. When a path contains a backslash — the
# Windows form an originPath is written in — GNU sha256sum escapes the output
# line and prefixes it with "\", so the first field became "\<hash>" and a
# matching file was reported as a mismatch (OBSERVED 2026-09-30). From stdin
# there is no file name to escape. verify-datastore-iso.sh already hashes a
# stream, which is why stage 2 never hit this.
actual_sha="$(sha256sum < "$validated_path" 2>/dev/null | cut -d' ' -f1)" ||
    fail "could not compute the SHA-256 of ${validated_path}"
elapsed_seconds=$(( $(date -u +%s) - hash_start ))

[[ -n "$actual_sha" ]] || fail "SHA-256 computation produced no output"

[[ "$actual_sha" == "$expected_sha" ]] ||
    fail "SHA-256 mismatch: expected ${expected_sha}, computed ${actual_sha}"

write_evidence "passed"

printf 'ISO verification passed: %s (%s bytes, hashed in %ss)\n' \
    "$actual_filename" "$actual_size" "$elapsed_seconds"
printf 'Evidence: %s\n' "$EVIDENCE_FILE"
exit 0
