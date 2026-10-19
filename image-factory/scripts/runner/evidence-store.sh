#!/usr/bin/env bash
# The lasting copy of a published master's evidence (STORY-18, ADR 0005).
#
# Job artifacts expire after 30 days; a master lives longer, and the desktops
# made from it longer still. So each published master's evidence is copied
# once to a store outside CI, in a folder named by the image version:
#
#   <store root>/<version>/                 the evidence, written once
#   <store root>/<version>.retired.json     added if that master is retired
#
# The store is what makes a master "published" for masters.sh: a versioned VM
# whose record is not here is not a published master.
#
# This is the only script that knows where the store is. Today it is a folder
# on the share, which cannot enforce write-once, so the rule is kept here: a
# version that exists is never written again, and a copy becomes visible under
# its version only after it has been checked.
#
#   put           Checks an evidence folder against its own index and record,
#                 copies it to <version>.partial, checks the copy, then renames
#                 it. Refuses a version that is already in the store.
#   list          Prints a JSON array, one entry per version: the folder, the
#                 image-reference record and the retirement record if any.
#   mark-retired  Adds the retirement record beside a version. The evidence
#                 itself is left as it is: it outlives the master.
#
# Usage:
#   evidence-store.sh put --version V [--evidence-dir DIR]
#   evidence-store.sh list
#   evidence-store.sh mark-retired --version V --record FILE
#
# The store root is EVIDENCE_STORE_ROOT. Needs bash, jq, sha256sum, find, cp, mv.

set -uo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

STORE_ROOT="${EVIDENCE_STORE_ROOT:-/mnt/image-factory/artifactory/image-factory-group/image-factory/masters}"

MODE="${1:-}"
[[ $# -gt 0 ]] && shift

VERSION=""; RETIRED_RECORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      VERSION="${2:-}"; shift 2 ;;
        --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
        --record)       RETIRED_RECORD="${2:-}"; shift 2 ;;
        -h|--help)      sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              fail "unknown argument: $1" ;;
    esac
done

require_command jq sha256sum

# The same form image-reference.sh enforces. Checked before the version is
# used in a path.
require_version() {
    [[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+$ ]] ||
        fail "--version must be <date>-<build id>, for example 2026.10.12-4441"
}

sha_of() { sha256sum <"$1" | cut -d' ' -f1; }

# A folder is a complete evidence set when its record is valid and is for this
# version, the index is the one the record names, and every file the index
# lists is present with the hash the index gives. Run on the source before the
# copy and on the copy before it is renamed.
verify_set() {
    local dir="$1" what="$2" record index name expected
    record="${dir}/image-reference.json"
    index="${dir}/index.json"
    [[ -f "$record" ]] || fail "${what}: no image-reference.json. Only a published build's evidence is stored."
    [[ -f "$index" ]] || fail "${what}: no index.json"
    bash "${SCRIPT_DIR}/image-reference.sh" check --record "$record" >/dev/null ||
        fail "${what}: the image-reference record is not valid"
    [[ "$(jq -r '.version' <"$record")" == "$VERSION" ]] ||
        fail "${what}: the record is for version $(jq -r '.version' <"$record"), not ${VERSION}"
    [[ "$(sha_of "$index")" == "$(jq -r '.evidence_index_sha256' <"$record")" ]] ||
        fail "${what}: index.json is not the index the record names"
    while IFS=$'\t' read -r name expected; do
        [[ "$name" != */* && "$name" != .* ]] || fail "${what}: unexpected file name in the index: ${name}"
        [[ -f "${dir}/${name}" ]] || fail "${what}: ${name} is in the index but not in the folder"
        [[ "$(sha_of "${dir}/${name}")" == "$expected" ]] || fail "${what}: ${name} does not match the index"
    done < <(jq -r '.files[] | [.name, .sha256] | @tsv' <"$index" | tr -d '\r')
}

case "$MODE" in
    put)
        require_version
        [[ -d "$EVIDENCE_DIR" ]] || fail "evidence folder not found: ${EVIDENCE_DIR}"
        target="${STORE_ROOT}/${VERSION}"
        partial="${target}.partial"

        mkdir -p -- "$STORE_ROOT" || fail "the evidence store could not be created or reached: ${STORE_ROOT}"
        [[ ! -e "$target" ]] ||
            fail "version ${VERSION} is already in the evidence store. A version is written once: ${target}"
        [[ ! -e "$partial" ]] ||
            fail "an unfinished copy of ${VERSION} is in the store: ${partial}. Look at it, remove it by hand, then run this again."

        verify_set "$EVIDENCE_DIR" "the evidence folder"

        # Named files only: what the index covers, the index and its sums, the
        # record, and the lookups made from the record. Nothing else in the
        # folder is evidence of this master.
        mkdir -- "$partial" || fail "could not create ${partial}"
        {
            jq -r '.files[].name' <"${EVIDENCE_DIR}/index.json" | tr -d '\r'
            printf '%s\n' index.json image-reference.json
            [[ -f "${EVIDENCE_DIR}/SHA256SUMS" ]] && printf 'SHA256SUMS\n'
            find "$EVIDENCE_DIR" -maxdepth 1 -type f -name 'image-lookup-*.json' -printf '%f\n' | sort
        } | while IFS= read -r name; do
            cp -- "${EVIDENCE_DIR}/${name}" "${partial}/${name}" || exit 1
        done || fail "the copy to ${partial} failed. Remove it by hand before running this again."

        verify_set "$partial" "the copy in the store"

        # Best effort: a share may ignore modes, and the rule that a version is
        # written once is kept by the check above either way.
        chmod -R a-w -- "$partial" 2>/dev/null || true
        chmod u+w -- "$partial" 2>/dev/null || true

        [[ ! -e "$target" ]] || fail "version ${VERSION} appeared in the store during the copy; ${partial} is left for inspection"
        mv -T -- "$partial" "$target" || fail "the checked copy could not be renamed to ${target}"
        chmod a-w -- "$target" 2>/dev/null || true

        file_count="$(find "$target" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
        ensure_evidence_dir
        jq -n \
            --arg timestamp "$(ts_iso)" --arg version "$VERSION" --arg location "$target" \
            --arg index_sha "$(sha_of "${target}/index.json")" --argjson files "$file_count" \
            '{schema_version: 1, timestamp: $timestamp, version: $version, location: $location,
              files: $files, evidence_index_sha256: $index_sha, verified_after_copy: true}' \
            >"${EVIDENCE_DIR}/evidence-store-put-${VERSION}.json" ||
            fail "the evidence was stored, but the record of storing it could not be written"
        printf 'Evidence stored: %s (%s files, checked against the index after the copy)\n' "$target" "$file_count"
        ;;

    list)
        [[ -d "$STORE_ROOT" ]] || { printf '[]\n'; exit 0; }
        entries="[]"
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            version="$(basename -- "$dir")"
            [[ "$version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+$ ]] || continue
            record="${dir}/image-reference.json"
            # A folder without a readable record is reported, not hidden: it is
            # either damage or something that does not belong here.
            if [[ -f "$record" ]] && jq -e . <"$record" >/dev/null 2>&1; then
                record_json="$(jq -c . <"$record")"
            else
                record_json="null"
            fi
            retired_json="null"
            if [[ -f "${dir}.retired.json" ]]; then
                retired_json="$(jq -c . <"${dir}.retired.json" 2>/dev/null)" || retired_json='{"unreadable":true}'
            fi
            entries="$(jq -c --arg version "$version" --arg path "$dir" \
                --argjson record "$record_json" --argjson retired "$retired_json" \
                '. + [{version: $version, path: $path, record: $record, retired: $retired}]' <<<"$entries")"
        done < <(find "$STORE_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
        jq . <<<"$entries"
        ;;

    mark-retired)
        require_version
        [[ -f "$RETIRED_RECORD" ]] || fail "mark-retired needs --record FILE"
        jq -e . <"$RETIRED_RECORD" >/dev/null 2>&1 || fail "the retirement record is not valid JSON: ${RETIRED_RECORD}"
        target="${STORE_ROOT}/${VERSION}"
        [[ -d "$target" ]] || fail "version ${VERSION} is not in the evidence store"
        [[ ! -e "${target}.retired.json" ]] || fail "version ${VERSION} is already marked retired in the store"
        cp -- "$RETIRED_RECORD" "${target}.retired.json" || fail "the retirement record could not be written to the store"
        chmod a-w -- "${target}.retired.json" 2>/dev/null || true
        printf 'Marked retired in the store: %s (its evidence is kept)\n' "${target}.retired.json"
        ;;

    *)
        fail "the first argument must be 'put', 'list' or 'mark-retired'"
        ;;
esac
