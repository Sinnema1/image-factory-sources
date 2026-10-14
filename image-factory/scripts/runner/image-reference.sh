#!/usr/bin/env bash
# Writes, checks and looks up the image-reference record of a published master
# (STORY-11, ADR 0005).
#
# The record is the contract between building an image and consuming it: which
# VM and snapshot the image is, which build made it, and which evidence shows
# how. Its shape is packer/schemas/image-reference.schema.json.
#
#   write   Builds the record from a finished, sealed, snapshotted build. It
#           carries the SHA-256 of the build's FINAL evidence index, so it must
#           run after the last evidence collection, and the record is never
#           listed in that index (collect-evidence.sh leaves it out and stops
#           rewriting the index once the record exists).
#   check   Fails unless a record has every required field in the right form.
#   lookup  Finds the VM by the recorded instance UUID and the snapshot by the
#           recorded id, and fails unless what vCenter returns is what the
#           record says. Run twice, it is the continuity evidence: the same
#           identity resolves to the same thing each time.
#
# Usage:
#   image-reference.sh write --version V --vm-path PATH --snapshot-name NAME
#                            --snapshot-id ID --instance-uuid UUID
#                            --seal-result FILE [--snapshot-evidence FILE]
#                            [--evidence-dir DIR] [--out FILE]
#   image-reference.sh check [--record FILE] [--schema FILE]
#   image-reference.sh lookup --out FILE [--record FILE]
#
# write and check need jq and sha256sum. lookup needs govc and jq, and
# VCENTER_HOST, VCENTER_USERNAME and VCENTER_PASSWORD.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODE="${1:-}"
[[ $# -gt 0 ]] && shift

SCHEMA="${REPO_ROOT}/packer/schemas/image-reference.schema.json"
ISO_RECORD_DIR="${REPO_ROOT}/packer/sources/windows"
RECORD=""
OUT=""
VERSION=""; VM_PATH=""; SNAPSHOT_NAME=""; SNAPSHOT_ID=""; INSTANCE_UUID=""
SEAL_RESULT=""; SNAPSHOT_EVIDENCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)           VERSION="${2:-}"; shift 2 ;;
        --vm-path)           VM_PATH="${2:-}"; shift 2 ;;
        --snapshot-name)     SNAPSHOT_NAME="${2:-}"; shift 2 ;;
        --snapshot-id)       SNAPSHOT_ID="${2:-}"; shift 2 ;;
        --instance-uuid)     INSTANCE_UUID="${2:-}"; shift 2 ;;
        --seal-result)       SEAL_RESULT="${2:-}"; shift 2 ;;
        --snapshot-evidence) SNAPSHOT_EVIDENCE="${2:-}"; shift 2 ;;
        --evidence-dir)      EVIDENCE_DIR="${2:-}"; shift 2 ;;
        --iso-record-dir)    ISO_RECORD_DIR="${2:-}"; shift 2 ;;
        --record)            RECORD="${2:-}"; shift 2 ;;
        --schema)            SCHEMA="${2:-}"; shift 2 ;;
        --out)               OUT="${2:-}"; shift 2 ;;
        -h|--help)           sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)                   fail "unknown argument: $1" ;;
    esac
done

[[ -n "$RECORD" ]] || RECORD="${EVIDENCE_DIR}/image-reference.json"

# The rules a record must satisfy. The top-level required list comes from the
# schema file; the forms are enforced here, because nothing on the runner
# evaluates a JSON Schema (the same arrangement as validate-iso-metadata.sh).
check_record() {
    local record="$1" required problems
    [[ -f "$SCHEMA" ]] || fail "schema file not found: ${SCHEMA}"
    jq -e . "$record" >/dev/null 2>&1 || fail "the record is not valid JSON: ${record}"
    required="$(jq -c '.required // []' "$SCHEMA")"
    [[ "$(jq 'length' <<<"$required")" -gt 0 ]] || fail "no required fields are declared in ${SCHEMA}"

    problems="$(
        jq -r --argjson required "$required" '
            def hex64: type == "string" and test("^[a-f0-9]{64}$");
            . as $r
            | [ $required[] | select($r[.] == null) | "missing field: \(.)" ]
            + [ if .schema_version != 1 then "schema_version must be 1" else empty end,
                if (.version // "" | test("^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-[A-Za-z0-9]+$") | not) then "version is not <date>-<build id>" else empty end,
                if (.vm.instance_uuid // "" | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") | not) then "vm.instance_uuid is not a UUID" else empty end,
                if ((.vm.name // "") | endswith($r.version // "?") | not) then "vm.name does not carry the version" else empty end,
                if ((.vm.datacenter // "") == "" or (.vm.folder // "") == "") then "vm.datacenter and vm.folder are required" else empty end,
                if ((.snapshot.name // "") | endswith($r.version // "?") | not) then "snapshot.name does not carry the version" else empty end,
                if (.snapshot.id // "" | test("^snapshot-[0-9]+$") | not) then "snapshot.id is not a snapshot id" else empty end,
                if ((.build.commit // "") == "" or (.build.timestamp // "") == "") then "build.commit and build.timestamp are required" else empty end,
                if ((.source.isos // []) | length) == 0 then "source.isos is empty" else empty end,
                ( (.source.isos // [])[]
                  | select((.sha256 | hex64 | not) or ((.stage2_evidence // "") == "") or ((.filename // "") == ""))
                  | "source.isos entry for \(.record // "?") is incomplete" ),
                if .seal.sealed != true or ((.seal.evidence // "") == "") then "seal.sealed must be true, with its evidence file" else empty end,
                if (.evidence_index_sha256 | hex64 | not) then "evidence_index_sha256 is not a SHA-256" else empty end,
                if ((.evidence.index // "") == "") then "evidence.index is required" else empty end
              ]
            | .[]' "$record"
    )" || fail "the record could not be checked: ${record}"

    if [[ -n "$problems" ]]; then
        printf 'Error: the image-reference record is not valid:\n' >&2
        sed 's/^/  - /' <<<"$problems" >&2
        return 1
    fi
}

case "$MODE" in
    write)
        require_command jq sha256sum
        [[ -n "$OUT" ]] || OUT="${EVIDENCE_DIR}/image-reference.json"
        for required_arg in VERSION VM_PATH SNAPSHOT_NAME SNAPSHOT_ID INSTANCE_UUID SEAL_RESULT; do
            [[ -n "${!required_arg}" ]] || fail "write needs --$(tr 'A-Z_' 'a-z-' <<<"$required_arg")"
        done
        index_file="${EVIDENCE_DIR}/index.json"
        [[ -f "$index_file" ]] || fail "no index.json in ${EVIDENCE_DIR}: the record is written after the last evidence collection"
        [[ -f "$SEAL_RESULT" ]] || fail "seal result not found: ${SEAL_RESULT}"
        [[ "$(jq -r '.sealed' "$SEAL_RESULT")" == "true" ]] || fail "the seal result does not say sealed: no record is written"

        # Every ISO record the build could have used must have a passing
        # datastore check among this build's evidence, and the check must be for
        # the hash the record carries now. This is the publish gate, checked a
        # second time at the point the record is written.
        isos="[]"
        shopt -s nullglob
        for iso_record in "$ISO_RECORD_DIR"/*.json; do
            slug="$(basename -- "$iso_record" .json)"
            expected_sha="$(jq -r '.sha256' "$iso_record")"
            stage2=""
            for candidate in "$EVIDENCE_DIR"/iso-datastore-verify-"${slug}"-*.json; do
                if [[ "$(jq -r '.result' "$candidate")" == "passed" &&
                      "$(jq -r '.iso.actual_sha256' "$candidate")" == "$expected_sha" ]]; then
                    stage2="$(basename -- "$candidate")"
                fi
            done
            [[ -n "$stage2" ]] ||
                fail "ISO record ${slug} has no passing datastore check in this build's evidence: no record is written"
            # The check must be one the index covers, or the record would cite
            # evidence the index hash does not vouch for.
            jq -e --arg name "$stage2" '.files | any(.name == $name)' "$index_file" >/dev/null ||
                fail "the datastore check ${stage2} is not in the evidence index"
            isos="$(jq -c --arg record "${slug}.json" --arg stage2 "$stage2" --slurpfile r "$iso_record" \
                '. + [{record: $record, filename: $r[0].filename,
                       sha256: $r[0].sha256, stage2_evidence: $stage2}]' <<<"$isos")"
            # The ISO record's description is left out on purpose: it is a note
            # for whoever maintains the record, and the file name and hash are
            # what identify the media to a consumer.
        done
        shopt -u nullglob
        [[ "$(jq 'length' <<<"$isos")" -gt 0 ]] || fail "no ISO records found in ${ISO_RECORD_DIR}"

        commit="${CI_COMMIT_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
        ref="${CI_COMMIT_REF_NAME:-$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)}"

        jq -n \
            --arg version "$VERSION" \
            --arg instance_uuid "$INSTANCE_UUID" \
            --arg vm_name "$(basename -- "$VM_PATH")" \
            --arg datacenter "$(cut -d/ -f2 <<<"$VM_PATH")" \
            --arg folder "$(dirname -- "$VM_PATH")" \
            --arg snapshot_name "$SNAPSHOT_NAME" \
            --arg snapshot_id "$SNAPSHOT_ID" \
            --arg pipeline_id "${CI_PIPELINE_ID:-}" \
            --arg job_id "${CI_JOB_ID:-}" \
            --arg project "${CI_PROJECT_PATH:-}" \
            --arg job_url "${CI_JOB_URL:-}" \
            --arg commit "$commit" \
            --arg ref "$ref" \
            --arg timestamp "$(ts_iso)" \
            --argjson isos "$isos" \
            --arg seal_evidence "$(basename -- "$SEAL_RESULT")" \
            --arg index_sha "$(sha256sum "$index_file" | cut -d' ' -f1)" \
            --arg snapshot_evidence "$(basename -- "${SNAPSHOT_EVIDENCE:-}")" \
            '{
                schema_version: 1,
                version: $version,
                vm: {instance_uuid: $instance_uuid, name: $vm_name, datacenter: $datacenter, folder: $folder},
                snapshot: {name: $snapshot_name, id: $snapshot_id},
                build: {
                    pipeline_id: (if $pipeline_id == "" then null else $pipeline_id end),
                    job_id: (if $job_id == "" then null else $job_id end),
                    project: (if $project == "" then null else $project end),
                    job_url: (if $job_url == "" then null else $job_url end),
                    commit: $commit,
                    ref: (if $ref == "" then null else $ref end),
                    timestamp: $timestamp
                },
                source: {isos: $isos},
                seal: {sealed: true, evidence: $seal_evidence},
                evidence_index_sha256: $index_sha,
                evidence: ({index: "index.json", sha256sums: "SHA256SUMS"}
                    + (if $snapshot_evidence == "" then {} else {snapshot: $snapshot_evidence} end))
            }' >"$OUT" || fail "could not write the record"

        if ! check_record "$OUT"; then
            # A record that fails its own check must not be left where
            # collect-evidence.sh would take it for a published build.
            rm -f -- "$OUT"
            fail "the record was not valid and has been removed"
        fi
        printf 'Image reference written: %s\n' "$OUT"
        printf '  version %s, VM %s (%s), snapshot %s (%s)\n' \
            "$VERSION" "$(basename -- "$VM_PATH")" "$INSTANCE_UUID" "$SNAPSHOT_NAME" "$SNAPSHOT_ID"
        printf '  evidence_index_sha256 %s\n' "$(jq -r '.evidence_index_sha256' "$OUT")"
        ;;

    check)
        require_command jq
        [[ -f "$RECORD" ]] || fail "record not found: ${RECORD}"
        check_record "$RECORD" || exit 1
        printf 'Image reference is valid: %s (version %s)\n' "$RECORD" "$(jq -r '.version' "$RECORD")"
        ;;

    lookup)
        require_command govc jq
        require_env VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD
        [[ -f "$RECORD" ]] || fail "record not found: ${RECORD}"
        [[ -n "$OUT" ]] || fail "lookup needs --out"

        export GOVC_URL="https://${VCENTER_HOST}"
        export GOVC_USERNAME="${VCENTER_USERNAME}"
        export GOVC_PASSWORD="${VCENTER_PASSWORD}"
        export GOVC_INSECURE=true

        instance_uuid="$(jq -r '.vm.instance_uuid' "$RECORD")"
        snapshot_id="$(jq -r '.snapshot.id' "$RECORD")"

        # By instance UUID only. The name and the folder are what the lookup
        # is checking, so they must not be what it searches by.
        found_paths="$(govc find / -type m -config.instanceUuid "$instance_uuid")" ||
            fail "vCenter could not be searched for instance UUID ${instance_uuid}"
        found_count="$(grep -c . <<<"$found_paths" || true)"
        [[ "$found_count" -eq 1 ]] ||
            fail "instance UUID ${instance_uuid} resolved to ${found_count} VM(s), expected exactly 1"
        vm_path="$found_paths"

        snapshot_json="$(govc object.collect -json "$vm_path" snapshot)" ||
            fail "the snapshots of ${vm_path} could not be read"
        # Any depth: a master has one snapshot, but the tree is searched whole
        # so a snapshot under another is still found by its id.
        found_snapshot_name="$(jq -r --arg id "$snapshot_id" \
            'first(.. | objects | select(.snapshot?.value? == $id) | .name) // empty' <<<"$snapshot_json")"
        snapshot_count="$(jq '[.. | objects | select(has("snapshot") and has("createTime"))] | length' <<<"$snapshot_json")"

        jq -n \
            --arg timestamp "$(ts_iso)" \
            --arg version "$(jq -r '.version' "$RECORD")" \
            --arg instance_uuid "$(govc object.collect -s "$vm_path" config.instanceUuid)" \
            --arg vm_name "$(govc object.collect -s "$vm_path" name)" \
            --arg datacenter "$(cut -d/ -f2 <<<"$vm_path")" \
            --arg folder "$(dirname -- "$vm_path")" \
            --arg power_state "$(govc object.collect -s "$vm_path" runtime.powerState)" \
            --arg snapshot_id "$snapshot_id" \
            --arg snapshot_name "$found_snapshot_name" \
            --argjson snapshot_count "$snapshot_count" \
            --slurpfile record "$RECORD" \
            '{
                schema_version: 1,
                timestamp: $timestamp,
                version: $version,
                searched_by: {instance_uuid: $record[0].vm.instance_uuid, snapshot_id: $snapshot_id},
                found: {
                    vm: {instance_uuid: $instance_uuid, name: $vm_name, datacenter: $datacenter, folder: $folder},
                    snapshot: {name: (if $snapshot_name == "" then null else $snapshot_name end), id: $snapshot_id},
                    power_state: $power_state,
                    snapshot_count: $snapshot_count
                }
            }
            | .differences = [
                (if .found.vm != $record[0].vm then "the VM found is not the VM recorded" else empty end),
                (if .found.snapshot != $record[0].snapshot then "the snapshot found is not the snapshot recorded" else empty end),
                (if .found.power_state != "poweredOff" then "the master is not powered off" else empty end)
              ]
            | .matches = (.differences | length == 0)' >"$OUT" || fail "could not write the lookup result"

        if [[ "$(jq -r '.matches' "$OUT")" != "true" ]]; then
            printf 'Error: the lookup does not match the record:\n' >&2
            jq -r '.differences[] | "  - " + .' "$OUT" >&2
            exit 1
        fi
        printf 'Lookup matches the record: %s, snapshot %s (%s)\n' \
            "$(jq -r '.found.vm.name' "$OUT")" "$(jq -r '.found.snapshot.name' "$OUT")" "$snapshot_id"
        ;;

    *)
        fail "the first argument must be 'write', 'check' or 'lookup'"
        ;;
esac
