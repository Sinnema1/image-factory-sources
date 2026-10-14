#!/usr/bin/env bash
# Checks that the Windows ISO qualification record parses and carries the fields
# the schema marks required.
#
# This is NOT JSON Schema validation, despite reading a JSON Schema file. It uses
# the schema for one thing: the `required` list. For each name in that list it
# checks the property is present, non-null and non-empty, then applies two format
# rules of its own (SHA-256 shape, positive size).
#
# Everything else in the schema is ignored: type, pattern, properties,
# additionalProperties. A record with a correctly named field holding a
# wrong-typed value passes here.
#
# Bash rather than PowerShell so it runs on the CI runner, whose image has no
# pwsh. It reads only files in this
# repository, so unlike verify-iso.sh it needs no mounted share and can run in
# any job.
#
# Usage:
#   validate-iso-metadata.sh [--metadata FILE] [--schema FILE] [--evidence-dir DIR]
#
# Needs bash and jq. A JSON evidence record is written on success and on failure.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

METADATA="${REPO_ROOT}/packer/sources/windows/windows-11.json"
SCHEMA="${REPO_ROOT}/packer/schemas/iso-metadata.schema.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --metadata)     METADATA="${2:-}"; shift 2 ;;
        --schema)       SCHEMA="${2:-}"; shift 2 ;;
        --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
        -h|--help)      sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              printf 'Error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

require_command jq

TIMESTAMP="$(ts_file)"
ensure_evidence_dir
# The record's name is part of the evidence filename, not just the timestamp.
# ts_file has second resolution, and CI validates every record in a loop that
# finishes well inside one second — so a bare timestamp made the second record
# silently overwrite the first's evidence. OBSERVED in CI, 2026-09-24.
RECORD_SLUG="$(basename -- "$METADATA" .json)"
RECORD_SLUG="${RECORD_SLUG//[^A-Za-z0-9._-]/-}"
EVIDENCE_FILE="${EVIDENCE_DIR}/iso-metadata-${RECORD_SLUG}-${TIMESTAMP}.json"

# Filled in as the checks progress, so a failure still records what was known.
error=""
required_fields='[]'
checked_fields='[]'

write_evidence() {
    local result="$1"
    jq -n \
        --arg timestamp "$(ts_iso)" \
        --arg result "$result" \
        --arg error "$error" \
        --arg metadata "$METADATA" \
        --arg schema "$SCHEMA" \
        --argjson required "$required_fields" \
        --argjson checked "$checked_fields" \
        '{
            schema_version: 1,
            timestamp: $timestamp,
            result: $result,
            error: (if $error == "" then null else $error end),
            metadata_path: $metadata,
            schema_path: $schema,
            required_fields: $required,
            fields_checked: $checked
        }' >"$EVIDENCE_FILE"
}

# Overrides lib/common.sh's fail: records evidence of the failure before exiting,
# so a failed validation is as auditable as a passing one.
fail() {
    error="$1"
    write_evidence "failed"
    printf 'ISO metadata validation FAILED: %s\n' "$error" >&2
    printf 'Evidence: %s\n' "$EVIDENCE_FILE" >&2
    exit 1
}

[[ -f "$METADATA" ]] || fail "metadata file not found: ${METADATA}"
[[ -f "$SCHEMA" ]] || fail "schema file not found: ${SCHEMA}"

jq -e . "$METADATA" >/dev/null 2>&1 || fail "metadata is not valid JSON: ${METADATA}"
jq -e . "$SCHEMA" >/dev/null 2>&1 || fail "schema is not valid JSON: ${SCHEMA}"

# The schema's `required` list is the source of truth for which fields matter.
required_fields="$(jq -c '.required // []' "$SCHEMA")"

# Fail-closed rather than a no-op: a schema that has lost its `required` list
# would otherwise make every record pass, including an empty one.
[[ "$(printf '%s' "$required_fields" | jq 'length')" -gt 0 ]] ||
    fail "no required fields are declared in ${SCHEMA}"

while IFS= read -r field; do
    # A jq build on Windows terminates lines with CRLF, so the trailing CR would
    # otherwise become part of the field name and every lookup would miss. Costs
    # nothing on Linux, where there is no CR to strip.
    field="${field%$'\r'}"
    [[ -n "$field" ]] || continue

    jq -e --arg f "$field" 'has($f)' "$METADATA" >/dev/null 2>&1 ||
        fail "missing required field: ${field}"

    jq -e --arg f "$field" '.[$f] != null' "$METADATA" >/dev/null 2>&1 ||
        fail "required field is null: ${field}"

    # Only strings can be blank; a number or object passes this check.
    jq -e --arg f "$field" '
        (.[$f] | type) != "string" or ((.[$f] | gsub("^\\s+|\\s+$"; "")) != "")
    ' "$METADATA" >/dev/null 2>&1 ||
        fail "required field is empty: ${field}"

    checked_fields="$(printf '%s' "$checked_fields" | jq -c --arg f "$field" '. + [$f]')"
done < <(printf '%s' "$required_fields" | jq -r '.[]')

# The two rules below are enforced here and ALSO expressed in the schema file,
# which nothing reads for anything except `required`. They can drift, and only
# this copy has any effect. Treat the schema's equivalents as documentation.
jq -e '.sha256 | test("^[a-fA-F0-9]{64}$")' "$METADATA" >/dev/null 2>&1 ||
    fail "'sha256' is not a valid 64-character hexadecimal string"

jq -e '(.sizeBytes | type) == "number" and .sizeBytes > 0' "$METADATA" >/dev/null 2>&1 ||
    fail "'sizeBytes' must be a number greater than zero"

write_evidence "passed"

printf 'ISO metadata validation passed: %s (%s required field(s))\n' \
    "$(basename -- "$METADATA")" \
    "$(printf '%s' "$required_fields" | jq 'length')"
printf 'Evidence: %s\n' "$EVIDENCE_FILE"
exit 0
