#!/usr/bin/env bash
# Collects the evidence for one build run into an index.
#
# Writes evidence/index.json (run metadata plus every evidence file with its
# role, size and SHA-256) and evidence/SHA256SUMS. Before indexing it scans
# every evidence file for the values of the secret variables; a file that
# contains one is deleted and reported by name only (the value is never
# printed), and the script exits 1.
#
# The scan is fail-closed. If the secret variables are not in the environment
# there is nothing to match on, and index.json records the scan as skipped
# rather than clean. index.json carries secret_scan.status for exactly this
# reason: a GitLab after_script's exit code does not fail the job, so the exit
# code alone cannot be relied on to surface an unverified artifact.
#
# Safe to run more than once, and from a CI after_script so it also runs when
# the build failed. Withheld filenames are appended to evidence/.withheld so a
# second run still reports what a first run removed.
#
# Usage:
#   collect-evidence.sh [--evidence-dir DIR] [--outcome success|failed|unknown]
#
# Needs bash, find, sha256sum, wc, grep, sed, sort, mktemp and jq.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

OUTCOME="${CI_JOB_STATUS:-unknown}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
        --outcome)      OUTCOME="${2:-}"; shift 2 ;;
        -h|--help)      sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              printf 'Error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

require_command jq sha256sum
ensure_evidence_dir

INDEX_FILE="${EVIDENCE_DIR}/index.json"
SUMS_FILE="${EVIDENCE_DIR}/SHA256SUMS"

# A published build's image-reference record carries the SHA-256 of index.json
# (ADR 0005). Once that record exists the index is FINAL: rewriting it, even
# with the same files, would give it a new generated_at and a new hash, and the
# record would point at an index that no longer exists. CI runs this script
# again from after_script, after the publish step has written the record, so
# this is the normal case for a published build and not an edge case.
#
# With a final index the secret scan still runs over every file, the record and
# the lookup results included, and the index is checked against the record
# instead of being rewritten.
RECORD_FILE="${EVIDENCE_DIR}/image-reference.json"
index_is_final=false
[[ -f "$RECORD_FILE" ]] && index_is_final=true

[[ "$index_is_final" == "true" ]] || rm -f "$INDEX_FILE" "$SUMS_FILE"

# --- Secret scan: delete any evidence file that contains a secret value. ---
# Fail-closed. A run that could not scan must not look like a run that scanned
# and found nothing, so the outcome is recorded in index.json as well as in the
# exit code: an after_script's exit code does not fail a GitLab job, which makes
# the recorded status the load-bearing half.
SECRET_VARS=(VCENTER_PASSWORD ADMIN_SERVICE_ACCOUNT_PASSWORD)

# The answer file carries an XML-escaped form of the password (see the
# admin_service_account_password_xml local in the Packer template), which a
# literal match on the raw value cannot find. Escape in the same order.
xml_escape() {
    printf '%s' "$1" |
        sed -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g' \
            -e 's/"/\&quot;/g' \
            -e "s/'/\&apos;/g"
}

patterns="$(mktemp)"
scan_err="$(mktemp)"
trap 'rm -f "$patterns" "$scan_err"' EXIT

scanned_vars=0
for var_name in "${SECRET_VARS[@]}"; do
    value="${!var_name:-}"
    # Very short values would match unrelated text, so they are not scanned.
    [[ ${#value} -ge 6 ]] || continue
    scanned_vars=$((scanned_vars + 1))
    printf '%s\n' "$value" >>"$patterns"
    escaped="$(xml_escape "$value")"
    [[ "$escaped" != "$value" ]] && printf '%s\n' "$escaped" >>"$patterns"
done

# Files removed by this run or by an earlier one. build-diagnostic.sh runs this
# script from an EXIT trap and CI runs it again from after_script; without a
# ledger the second run finds nothing left to withhold and would rewrite
# index.json with an empty list, erasing the record of the leak it cleaned up.
WITHHELD_LEDGER="${EVIDENCE_DIR}/.withheld"

scan_status="skipped-no-secrets-in-env"
if [[ -s "$patterns" ]]; then
    hits="$(grep -r -I -l -F -f "$patterns" -- "$EVIDENCE_DIR" 2>"$scan_err")"
    case $? in
        0|1) scan_status="ran" ;;   # 1 is "no match", the clean case
        *)   scan_status="failed" ;;
    esac

    if [[ "$scan_status" == "ran" && -n "$hits" ]]; then
        while IFS= read -r hit; do
            [[ -z "$hit" ]] && continue
            basename -- "$hit" >>"$WITHHELD_LEDGER"
            rm -f -- "$hit"
        done <<<"$hits"
    fi

    if [[ "$scan_status" == "failed" ]]; then
        printf 'Error: the secret scan could not run; its result cannot be trusted.\n' >&2
        [[ -s "$scan_err" ]] && sed 's/^/  /' "$scan_err" >&2
    fi
fi

# Replay the ledger so a re-run reports everything withheld for this job.
withheld=()
if [[ -f "$WITHHELD_LEDGER" ]]; then
    while IFS= read -r name; do
        [[ -n "$name" ]] && withheld+=("$name")
    done < <(sort -u "$WITHHELD_LEDGER")
fi

# --- A final index is checked, not rewritten. ---
if [[ "$index_is_final" == "true" ]]; then
    rc=0
    # The scan above may have deleted the record itself, if a secret was in it.
    if [[ ! -f "$RECORD_FILE" ]]; then
        printf 'Error: the image-reference record was withheld by the secret scan. This build is not published.\n' >&2
        rc=1
    elif [[ ! -f "$INDEX_FILE" ]]; then
        printf 'Error: an image-reference record exists but index.json does not.\n' >&2
        rc=1
    else
        recorded_sha="$(jq -r '.evidence_index_sha256 // empty' "$RECORD_FILE" 2>/dev/null)"
        actual_sha="$(sha256sum "$INDEX_FILE" | cut -d' ' -f1)"
        if [[ "$recorded_sha" != "$actual_sha" ]]; then
            printf 'Error: index.json does not match the image-reference record (recorded %s, actual %s). The record no longer points at this evidence.\n' \
                "${recorded_sha:-none}" "$actual_sha" >&2
            rc=1
        else
            printf 'Evidence index is final: image-reference.json points at it (%s files). Not rewritten.\n' \
                "$(jq '.files | length' "$INDEX_FILE")"
        fi
    fi
    printf 'Secret scan: %s (%s variable(s) scanned), including the record and the lookup results\n' "$scan_status" "$scanned_vars"

    if [[ ${#withheld[@]} -gt 0 ]]; then
        printf 'Error: a secret value was found in evidence file(s) and they were deleted: %s\n' "${withheld[*]}" >&2
        rc=1
    fi
    if [[ "$scan_status" != "ran" ]]; then
        printf 'Error: the evidence was not scanned for secrets (%s). Treat this artifact as unverified.\n' \
            "$scan_status" >&2
        rc=1
    fi
    exit "$rc"
fi

# --- Role of each evidence file, by name. ---
role_of() {
    case "$1" in
        packer-console-*.log)       echo "build-log" ;;
        packer-build-*.log)         echo "debug-log" ;;
        packer-provenance-*.txt)    echo "provenance" ;;
        packer-validate-*.log)      echo "validation" ;;
        package-verify-*.json)      echo "validation" ;;
        package-stage-*.json)       echo "validation" ;;
        package-download-*.log)     echo "validation" ;;
        iso-metadata-*.json)        echo "validation" ;;
        iso-verify-*.json)          echo "validation" ;;
        iso-datastore-verify-*.json) echo "validation" ;;
        staging-result*.json)       echo "validation" ;;
        communicator-result*.json)  echo "communicator" ;;
        validate-*.log)             echo "validation" ;;
        install-result*.json)       echo "install" ;;
        cleanup-result*.json)       echo "cleanup" ;;
        seal-prepare-result*.json)  echo "seal" ;;
        seal-result-*.json)         echo "seal" ;;
        image-snapshot-*.json)      echo "publish" ;;
        evidence-store-put-*.json)  echo "retention" ;;
        masters-list-*.json)        echo "retention" ;;
        master-retired-*.json)      echo "retention" ;;
        enable-winrm-bootstrap*.log) echo "bootstrap-log" ;;
        preflight-*.log)            echo "preflight" ;;
        vm-list-*.log)              echo "inventory" ;;
        *)                          echo "other" ;;
    esac
}

# --- List and hash the files. ---
rows="$(mktemp)"
trap 'rm -f "$patterns" "$scan_err" "$rows"' EXIT

while IFS= read -r path; do
    file_name="$(basename -- "$path")"
    printf '%s\t%s\t%s\t%s\n' \
        "$file_name" \
        "$(role_of "$file_name")" \
        "$(wc -c <"$path" | tr -d ' ')" \
        "$(sha256sum "$path" | cut -d' ' -f1)" >>"$rows"
done < <(find "$EVIDENCE_DIR" -maxdepth 1 -type f \
            ! -name index.json ! -name SHA256SUMS ! -name .gitkeep \
            ! -name .withheld \
            ! -name image-reference.json ! -name 'image-lookup-*.json' | sort)
# The record and the lookup results are left out on purpose. The record carries
# this index's hash, so it cannot be inside it, and the lookups are made from
# the record. They are the only evidence files the index does not cover.

files_json="$(
    jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
        | {name: .[0], role: .[1], size_bytes: (.[2] | tonumber), sha256: .[3]})' <"$rows"
)"

( cd "$EVIDENCE_DIR" && while IFS=$'\t' read -r file_name _ _ file_sha; do
      printf '%s  %s\n' "$file_sha" "$file_name"
  done <"$rows" >"$SUMS_FILE" )

withheld_json="$(printf '%s\n' "${withheld[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"

commit="${CI_COMMIT_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
ref="${CI_COMMIT_REF_NAME:-$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)}"

jq -n \
    --arg generated_at "$(ts_iso)" \
    --arg outcome "$OUTCOME" \
    --arg commit "$commit" \
    --arg ref "$ref" \
    --arg pipeline_id "${CI_PIPELINE_ID:-}" \
    --arg job_id "${CI_JOB_ID:-}" \
    --argjson files "$files_json" \
    --argjson withheld "$withheld_json" \
    --arg scan_status "$scan_status" \
    --argjson scanned_vars "$scanned_vars" \
    '{
        schema_version: 1,
        generated_at: $generated_at,
        outcome: $outcome,
        run: {
            commit: $commit,
            ref: (if $ref == "" then null else $ref end),
            pipeline_id: (if $pipeline_id == "" then null else $pipeline_id end),
            job_id: (if $job_id == "" then null else $job_id end)
        },
        secret_scan: {
            status: $scan_status,
            variables_scanned: $scanned_vars
        },
        files: $files,
        withheld: $withheld
    }' >"$INDEX_FILE"

printf 'Evidence index: %s (%s files)\n' "$INDEX_FILE" "$(printf '%s' "$files_json" | jq 'length')"
printf 'Secret scan: %s (%s variable(s) scanned)\n' "$scan_status" "$scanned_vars"

rc=0

if [[ ${#withheld[@]} -gt 0 ]]; then
    printf 'Error: a secret value was found in evidence file(s) and they were deleted: %s\n' "${withheld[*]}" >&2
    rc=1
fi

# A scan that did not run is not a pass. The status is in index.json above,
# which is what survives into the artifact; this exit code is the local signal.
if [[ "$scan_status" != "ran" ]]; then
    printf 'Error: the evidence was not scanned for secrets (%s). Treat this artifact as unverified.\n' \
        "$scan_status" >&2
    rc=1
fi

exit "$rc"
