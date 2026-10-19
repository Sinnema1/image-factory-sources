#!/usr/bin/env bash
# Lists published masters and retires one (STORY-18, ADR 0005).
#
# A published master is a version in the evidence store whose record still
# resolves in vCenter to the same VM and snapshot. The rule for how many to
# keep is ADR 0005's: the current master and the one before it, counted among
# masters built from the default branch. A master built from another branch is
# a test: never current or previous, and free to retire at any time.
#
#   list     Joins the evidence store with vCenter and gives every version one
#            state:
#              current, previous   kept by the rule
#              beyond-retention    older than the rule keeps; may be retired
#              test                built from a branch; may be retired
#              retired             removed by this script; its evidence remains
#              missing             in the store, but vCenter has no such VM
#              mismatch            vCenter returns something the record does
#                                  not describe (renamed, moved, powered on,
#                                  snapshot changed)
#            and lists VMs named like a master that have no record in the
#            store as "unpublished". Writes masters-list-<timestamp>.json.
#
#   retire   Removes one master: the VM, its snapshot and its files. A dry run
#            unless --execute is given. It refuses unless all of these hold:
#              - the version is beyond-retention or test;
#              - its record resolves in vCenter exactly (instance UUID and
#                snapshot id), and the VM is powered off;
#              - no floppy image is attached (STORY-02);
#              - CATALOG_USE_STATEMENT says no catalog uses it;
#              - with --execute, the run is from the default branch
#                (MASTER_RETIRE_FROM_BRANCH=true lifts that for one run, to
#                prove a change to this step before it merges).
#            Its evidence is NOT removed. A retirement record is written to
#            the job's evidence and beside the version in the store.
#
# The catalog check is a statement by the person retiring the master, because
# Example Labs has no Citrix site to ask. The statement and who made it are
# recorded. When a site exists, a query replaces the statement here, and the
# rule stays the same: no confirmation, no removal.
#
# A build never removes a master. Nothing calls retire but a person.
#
# Usage:
#   masters.sh list
#   masters.sh retire --version V [--execute]
#
# Environment: VCENTER_HOST, VCENTER_USERNAME, VCENTER_PASSWORD. Optional:
# MASTER_RETAIN_COUNT (default 2), IMAGE_NAME_PREFIX (default image-master),
# MASTER_FOLDER (the agreed inventory folder; a master elsewhere is flagged),
# and for retire CATALOG_USE_STATEMENT and RETIRE_REASON. Needs govc and jq.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODE="${1:-}"
[[ $# -gt 0 ]] && shift

VERSION=""; EXECUTE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --execute) EXECUTE=true; shift ;;
        -h|--help) sed -n '2,51p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         fail "unknown argument: $1" ;;
    esac
done

require_command govc jq
require_env VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD
ensure_evidence_dir

export GOVC_URL="https://${VCENTER_HOST}"
export GOVC_USERNAME="${VCENTER_USERNAME}"
export GOVC_PASSWORD="${VCENTER_PASSWORD}"
export GOVC_INSECURE=true

RETAIN_COUNT="${MASTER_RETAIN_COUNT:-2}"
[[ "$RETAIN_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "MASTER_RETAIN_COUNT must be a whole number, 1 or more"
IMAGE_NAME_PREFIX="${IMAGE_NAME_PREFIX:-image-master}"
DEFAULT_BRANCH="${CI_DEFAULT_BRANCH:-main}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Builds the list as JSON on stdout: {masters: [...], unpublished: [...]}.
build_list() {
    local store entries count i version path lookup_file rc checked vm_names
    # Asked first, so that an unreachable vCenter stops the list here and is
    # not mistaken, further down, for every master being missing.
    vm_names="$(govc find / -type m -name "${IMAGE_NAME_PREFIX}-*")" ||
        fail "vCenter could not be searched for ${IMAGE_NAME_PREFIX}-* VMs"
    store="$(bash "${SCRIPT_DIR}/evidence-store.sh" list)" || fail "the evidence store could not be read"
    count="$(jq 'length' <<<"$store")"
    entries="[]"

    for ((i = 0; i < count; i++)); do
        version="$(jq -r ".[$i].version" <<<"$store" | tr -d '\r')"
        path="$(jq -r ".[$i].path" <<<"$store" | tr -d '\r')"
        checked='{"resolves": false, "found": null, "differences": []}'

        if [[ "$(jq -r ".[$i].record == null" <<<"$store" | tr -d '\r')" == "true" ]]; then
            checked='{"resolves": false, "found": null, "differences": ["the store has no readable record for this version"]}'
        else
            # The same lookup the publish step uses for continuity: by instance
            # UUID and snapshot id, never by name. It exits 1 both when nothing
            # is found (no result file) and when what is found differs (a
            # result file that says how).
            lookup_file="${WORK_DIR}/lookup-${version}.json"
            rc=0
            bash "${SCRIPT_DIR}/image-reference.sh" lookup \
                --record "${path}/image-reference.json" --out "$lookup_file" >/dev/null 2>&1 || rc=$?
            if [[ -f "$lookup_file" ]]; then
                checked="$(jq -c '{resolves: .matches, found: .found, differences: .differences}' <"$lookup_file")"
            fi
        fi

        entries="$(jq -c --argjson entry "$(jq -c ".[$i]" <<<"$store")" --argjson checked "$checked" \
            '. + [$entry + $checked]' <<<"$entries")"
    done

    jq -n \
        --argjson entries "$entries" \
        --argjson retain "$RETAIN_COUNT" \
        --arg default_branch "$DEFAULT_BRANCH" \
        --arg folder "${MASTER_FOLDER:-}" \
        --arg vm_paths "$vm_names" \
        '
        # Newest first among masters from the default branch that still exist.
        ($entries
         | map(select(.retired == null and .resolves == true and .record.build.ref == $default_branch))
         | sort_by(.record.build.timestamp) | reverse | map(.version)) as $kept_order
        | ($entries | map(
            . as $e
            | ($kept_order | index($e.version)) as $rank
            | {
                version: $e.version,
                state: (
                    if $e.retired != null then "retired"
                    elif $e.record == null then "mismatch"
                    elif $e.found == null then "missing"
                    elif $e.resolves != true then "mismatch"
                    elif $e.record.build.ref != $default_branch then "test"
                    elif $rank == 0 then "current"
                    elif $rank < $retain then "previous"
                    else "beyond-retention" end),
                vm: ($e.record.vm // null),
                snapshot: ($e.record.snapshot // null),
                built: ($e.record.build.timestamp // null),
                ref: ($e.record.build.ref // null),
                evidence: $e.path,
                differences: $e.differences,
                retired: $e.retired,
                outside_agreed_folder: (
                    $folder != "" and $e.retired == null and $e.found != null and $e.found.vm.folder != $folder)
              })) as $masters
        | ($masters | map(select(.state != "retired" and .vm != null) | .vm.name)) as $known
        | {
            masters: $masters,
            unpublished: ($vm_paths | split("\n") | map(gsub("\r"; "") | select(length > 0))
                          | map(select((split("/") | last) as $n | ($known | index($n)) == null)))
          }'
}

print_list() {
    jq -r '
        ["VERSION", "STATE", "BUILT", "REF", "VM"],
        (.masters | sort_by(.version) | reverse | .[]
         | [.version, .state, (.built // "-"), (.ref // "-"), (.vm.name // "-")])
        | @tsv' <<<"$1" | tr -d '\r' | column -t -s $'\t' 2>/dev/null ||
        jq -r '.masters[] | "\(.version)  \(.state)"' <<<"$1"

    jq -r '.masters[] | select(.state == "mismatch" or .state == "missing")
           | "  \(.version): " + (if (.differences | length) > 0 then (.differences | join("; ")) else "vCenter has no VM with the recorded instance UUID" end)' <<<"$1" | tr -d '\r'
    jq -r '.masters[] | select(.outside_agreed_folder) | "  \(.version): the VM is outside the agreed folder"' <<<"$1" | tr -d '\r'
    if [[ "$(jq '.unpublished | length' <<<"$1")" -gt 0 ]]; then
        printf '\nNamed like a master, but with no record in the evidence store (not published):\n'
        jq -r '.unpublished[] | "  " + .' <<<"$1" | tr -d '\r'
    fi
}

case "$MODE" in
    list)
        list_json="$(build_list)" || exit 1
        out="${EVIDENCE_DIR}/masters-list-$(ts_file).json"
        jq --arg timestamp "$(ts_iso)" --argjson retain "$RETAIN_COUNT" --arg folder "${MASTER_FOLDER:-}" \
            '{schema_version: 1, timestamp: $timestamp, retain_count: $retain,
              agreed_folder: (if $folder == "" then null else $folder end)} + .' <<<"$list_json" >"$out" ||
            fail "the list could not be written"
        printf 'Published masters (keep %s from %s):\n' "$RETAIN_COUNT" "$DEFAULT_BRANCH"
        print_list "$list_json"
        printf '\nEvidence: %s\n' "$out"
        ;;

    retire)
        [[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+$ ]] ||
            fail "retire needs --version <date>-<build id>"
        list_json="$(build_list)" || exit 1
        master="$(jq -c --arg v "$VERSION" '.masters[] | select(.version == $v)' <<<"$list_json")"
        [[ -n "$master" ]] ||
            fail "version ${VERSION} is not in the evidence store, so it is not a published master. An unpublished VM is removed by hand."

        state="$(jq -r '.state' <<<"$master" | tr -d '\r')"
        case "$state" in
            beyond-retention) default_reason="older than the retention rule keeps (keep ${RETAIN_COUNT})" ;;
            test)             default_reason="a test master, built from $(jq -r '.ref' <<<"$master" | tr -d '\r')" ;;
            current|previous) fail "version ${VERSION} is the ${state} master. The retention rule keeps it; it is not removed." ;;
            retired)          fail "version ${VERSION} is already retired." ;;
            missing)          fail "version ${VERSION} is in the store, but vCenter has no VM with its instance UUID. There is nothing to remove." ;;
            *)                fail "version ${VERSION} does not match its record in vCenter ($(jq -r '.differences | join("; ")' <<<"$master" | tr -d '\r')). Nothing is removed until that is understood." ;;
        esac
        reason="${RETIRE_REASON:-$default_reason}"

        instance_uuid="$(jq -r '.vm.instance_uuid' <<<"$master" | tr -d '\r')"
        vm_path="$(govc find / -type m -config.instanceUuid "$instance_uuid")" ||
            fail "vCenter could not be searched for instance UUID ${instance_uuid}"
        [[ "$(grep -c . <<<"$vm_path" || true)" -eq 1 ]] || fail "instance UUID ${instance_uuid} did not resolve to exactly one VM"

        # A successful build removes its floppy, so this should never be true
        # for a master. If it is, the image holds a credential and deleting the
        # VM would leave it on the datastore (STORY-02).
        devices="$(govc device.ls -vm.ipath "$vm_path")" || fail "the devices of ${vm_path} could not be read"
        ! grep -qi '^floppy' <<<"$devices" ||
            fail "${vm_path} has a floppy drive attached. Remove the VM with Remove-PackerTestVm.ps1's floppy handling in mind; nothing is removed here."

        vmx_path="$(govc object.collect -s "$vm_path" config.files.vmPathName)" ||
            fail "the datastore location of ${vm_path} could not be read"

        printf 'Retire %s\n' "$VERSION"
        printf '  state:     %s\n' "$state"
        printf '  reason:    %s\n' "$reason"
        printf '  VM:        %s (%s)\n' "$vm_path" "$instance_uuid"
        printf '  snapshot:  %s (%s)\n' "$(jq -r '.snapshot.name' <<<"$master" | tr -d '\r')" "$(jq -r '.snapshot.id' <<<"$master" | tr -d '\r')"
        printf '  files:     %s\n' "$vmx_path"
        printf '  evidence:  kept, at %s\n' "$(jq -r '.evidence' <<<"$master" | tr -d '\r')"

        statement="${CATALOG_USE_STATEMENT:-}"
        if [[ -z "${statement//[[:space:]]/}" ]]; then
            fail "no catalog check. Set CATALOG_USE_STATEMENT to say how you know no catalog uses this master. Without it nothing is removed."
        fi
        printf '  catalogs:  %s\n' "$statement"

        if [[ "$EXECUTE" != "true" ]]; then
            printf '\nDry run: nothing was removed. Run again with --execute to remove the VM.\n'
            exit 0
        fi

        # Removal runs from reviewed code, as publishing does. The escape is for
        # proving a change to this step on a test master before it merges.
        run_ref="${CI_COMMIT_REF_NAME:-$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)}"
        if [[ "$run_ref" != "$DEFAULT_BRANCH" && "${MASTER_RETIRE_FROM_BRANCH:-}" != "true" ]]; then
            fail "a master is only removed from ${DEFAULT_BRANCH}; this is ${run_ref:-an unknown ref}. Set MASTER_RETIRE_FROM_BRANCH=true to prove a change to this step from a branch."
        fi

        who="${GITLAB_USER_LOGIN:-${USER:-${USERNAME:-unknown}}}"
        govc vm.destroy -vm.ipath "$vm_path" || fail "the VM could not be removed: ${vm_path}"

        remaining="$(govc find / -type m -config.instanceUuid "$instance_uuid")" ||
            fail "the VM was removed, but vCenter could not be searched to confirm it"
        [[ -z "$remaining" ]] || fail "the VM is still in vCenter after removal: ${remaining}"

        # Names only. Anything left in the VM's folder is reported for a person
        # to look at; nothing is opened and nothing more is deleted.
        datastore="$(sed -n 's/^\[\([^]]*\)\].*/\1/p' <<<"$vmx_path")"
        folder="$(sed -n 's/^\[[^]]*\] *\(.*\)\/[^/]*$/\1/p' <<<"$vmx_path")"
        leftover="[]"
        if [[ -n "$datastore" && -n "$folder" ]]; then
            if listing="$(govc datastore.ls -ds "$datastore" "$folder" 2>/dev/null)" && [[ -n "$listing" ]]; then
                leftover="$(jq -R -s -c 'split("\n") | map(gsub("\r"; "") | select(length > 0))' <<<"$listing")"
            fi
        fi

        record="${EVIDENCE_DIR}/master-retired-${VERSION}.json"
        jq -n \
            --arg timestamp "$(ts_iso)" --arg version "$VERSION" \
            --arg state "$state" --arg reason "$reason" \
            --argjson vm "$(jq -c '.vm' <<<"$master")" --argjson snapshot "$(jq -c '.snapshot' <<<"$master")" \
            --arg vm_path "$vm_path" --arg files "$vmx_path" \
            --arg statement "$statement" --arg who "$who" \
            --arg job_url "${CI_JOB_URL:-}" --argjson retain "$RETAIN_COUNT" \
            --arg evidence "$(jq -r '.evidence' <<<"$master" | tr -d '\r')" \
            --argjson leftover "$leftover" \
            '{
                schema_version: 1, timestamp: $timestamp, version: $version,
                removed: {vm: $vm, snapshot: $snapshot, inventory_path: $vm_path, files: $files},
                why: {state_before: $state, reason: $reason, retain_count: $retain},
                catalog_check: {method: "operator statement", statement: $statement, stated_by: $who},
                retired_by: $who,
                job_url: (if $job_url == "" then null else $job_url end),
                evidence_kept_at: $evidence,
                files_left_on_datastore: $leftover
            }' >"$record" || fail "the VM was removed, but the retirement record could not be written"

        bash "${SCRIPT_DIR}/evidence-store.sh" mark-retired --version "$VERSION" --record "$record" ||
            fail "the VM was removed and ${record} written, but the store could not be marked. Copy that file to the store as ${VERSION}.retired.json."

        printf '\nRetired: %s. The VM, its snapshot and its files are removed; its evidence is kept.\n' "$VERSION"
        if [[ "$(jq 'length' <<<"$leftover")" -gt 0 ]]; then
            printf 'WARNING: files remain in the VM folder on the datastore (names are in the record): [%s] %s\n' "$datastore" "$folder"
        fi
        printf 'Evidence: %s\n' "$record"
        ;;

    *)
        fail "the first argument must be 'list' or 'retire'"
        ;;
esac
