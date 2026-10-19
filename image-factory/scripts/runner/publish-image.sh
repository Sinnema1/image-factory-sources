#!/usr/bin/env bash
# Builds, seals and publishes a master image (STORY-11, STORY-03; ADR 0005).
#
# A published master is a powered-off VM with one snapshot, both named with the
# image version, and an image-reference record that says which they are. This
# script is the only thing that publishes. packer-build-diagnostic never does:
# it builds an unsealed VM for inspection and for the harness.
#
# The steps, in order. Each fails closed, and nothing after a failure runs:
#
#   1. Version and names. <UTC date>-<job id>, for example 2026.10.08-4294. The
#      VM is <prefix>-<version> and the snapshot sealed-<version>, so a new
#      build never replaces or collides with a published master.
#   2. The ISO gate (ADR 0004, stage 2). Every ISO record is checked against its
#      copy on the datastore, here, in this job, before the build. A master is
#      published only from media that was qualified in the same run.
#   3. Build and seal (build-diagnostic.sh with SEAL_IMAGE=true). That script
#      already fails unless the seal's result was captured and says sealed.
#   4. Snapshot, taken here and not by Packer, so that it cannot exist unless
#      step 3 passed.
#   5. The last evidence collection. The index it writes is final.
#   6. The image-reference record, carrying that index's SHA-256.
#   7. Continuity: the VM is looked up by the recorded instance UUID and the
#      snapshot by the recorded id, twice, and both must match the record.
#   8. The record and the lookups are scanned for secrets.
#   9. The evidence is copied to the evidence store (STORY-18), where it
#      outlives the job's artifacts and the master itself. A master is listed
#      as published (masters.sh) only once it is there.
#
# A failure after step 3 leaves a sealed VM with a versioned name and no
# record. That is the correct outcome: it is not a published master, and it is
# removed by hand.
#
# A failure at step 9 is treated the same way, although the image itself is
# sound: published means stored, and nothing else can put the evidence in the
# store afterwards (a job cannot download another job's artifacts with its own
# token on this GitLab; OBSERVED 2026-10-12, HTTP 404). So the record is
# removed, and the cost of a share that could not be written is one rebuild.
#
# Usage:
#   publish-image.sh
#
# Published only from the default branch, so a master always comes from
# reviewed code. PUBLISH_FROM_BRANCH=true lifts that for one run, to prove a
# change to this step before it merges; the record's build.ref then names the
# branch, which marks the image as a test.
#
# Optional: IMAGE_NAME_PREFIX (default image-master). Needs everything
# build-diagnostic.sh needs, plus govc.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_command govc jq sha256sum
require_env VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD
ensure_evidence_dir

export GOVC_URL="https://${VCENTER_HOST}"
export GOVC_USERNAME="${VCENTER_USERNAME}"
export GOVC_PASSWORD="${VCENTER_PASSWORD}"
export GOVC_INSECURE=true

step() { printf '\n=== Publish %s\n' "$1"; }

# --- 1. Version and names. ---
step "1/9: version and names"

publish_ref="${CI_COMMIT_REF_NAME:-$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)}"
default_branch="${CI_DEFAULT_BRANCH:-main}"
if [[ "$publish_ref" != "$default_branch" ]]; then
    [[ "${PUBLISH_FROM_BRANCH:-}" == "true" ]] ||
        fail "publishing is only allowed from ${default_branch}; this is ${publish_ref:-an unknown ref}. Set PUBLISH_FROM_BRANCH=true to publish a test image from a branch."
    printf 'WARNING: publishing from %s, not %s, because PUBLISH_FROM_BRANCH is set. The image reference will say so; treat this master as a test.\n' \
        "$publish_ref" "$default_branch"
fi

IMAGE_NAME_PREFIX="${IMAGE_NAME_PREFIX:-image-master}"
[[ "$IMAGE_NAME_PREFIX" =~ ^[a-z][a-z0-9-]{1,30}$ ]] ||
    fail "IMAGE_NAME_PREFIX must be lower-case letters, digits and '-', starting with a letter."

# The job id makes the version unique; the date makes it sort and read well.
# Outside CI there is no job id, and a local run is marked as one.
build_id="${CI_JOB_ID:-local$(date -u +%H%M%S)}"
[[ "$build_id" =~ ^[A-Za-z0-9]+$ ]] || fail "the build id has unexpected characters: ${build_id}"
VERSION="$(date -u +%Y.%m.%d)-${build_id}"
VM_NAME="${IMAGE_NAME_PREFIX}-${VERSION}"
SNAPSHOT_NAME="sealed-${VERSION}"

existing="$(govc find / -type m -name "$VM_NAME")" || fail "vCenter could not be searched for ${VM_NAME}."
[[ -z "$existing" ]] || fail "a VM named ${VM_NAME} already exists: ${existing}"

printf 'Version:  %s\nVM:       %s\nSnapshot: %s\n' "$VERSION" "$VM_NAME" "$SNAPSHOT_NAME"

# --- 2. The ISO gate. ---
step "2/9: ISO qualification, datastore copies"
shopt -s nullglob
iso_records=("${REPO_ROOT}"/packer/sources/windows/*.json)
shopt -u nullglob
[[ ${#iso_records[@]} -gt 0 ]] || fail "no ISO records found: nothing to qualify, so nothing is published."
for iso_record in "${iso_records[@]}"; do
    bash "${SCRIPT_DIR}/verify-datastore-iso.sh" --metadata "$iso_record" --evidence-dir "$EVIDENCE_DIR" ||
        fail "ISO qualification failed for $(basename -- "$iso_record"). Publication stopped before the build; no image reference is written."
done

# --- 3. Build and seal. ---
step "3/9: build and seal"
SEAL_IMAGE=true IMAGE_VM_NAME="$VM_NAME" bash "${SCRIPT_DIR}/build-diagnostic.sh" ||
    fail "the build or its seal failed. Nothing is published."

seal_execution_id="$(sed -n 's/^[[:space:]]*execution_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$PACKAGE_VARS_FILE" | head -1)"
SEAL_RESULT="${EVIDENCE_DIR}/seal-result-${seal_execution_id}.json"
[[ -f "$SEAL_RESULT" ]] || fail "the seal result is missing after a passing build: ${SEAL_RESULT}"

# --- 4. Snapshot. ---
step "4/9: snapshot"
vm_paths="$(govc find / -type m -name "$VM_NAME")" || fail "vCenter could not be searched for ${VM_NAME}."
[[ "$(grep -c . <<<"$vm_paths" || true)" -eq 1 ]] || fail "expected exactly one VM named ${VM_NAME}, found: ${vm_paths:-none}"
VM_PATH="$vm_paths"

power_state="$(govc object.collect -s "$VM_PATH" runtime.powerState)"
[[ "$power_state" == "poweredOff" ]] || fail "${VM_NAME} is ${power_state}; a master is snapshotted powered off."

snapshot_json="$(govc object.collect -json "$VM_PATH" snapshot)" || fail "the snapshots of ${VM_NAME} could not be read."
[[ "$(jq '[.. | objects | select(has("snapshot") and has("createTime"))] | length' <<<"$snapshot_json")" -eq 0 ]] ||
    fail "${VM_NAME} already has a snapshot. A master has exactly one, taken here."

govc snapshot.create -vm.ipath "$VM_PATH" \
    -d "Sealed master ${VERSION}. Taken by the image build after the seal was verified. Desktops are created from this snapshot." \
    "$SNAPSHOT_NAME" || fail "the snapshot could not be created."

snapshot_json="$(govc object.collect -json "$VM_PATH" snapshot)" || fail "the snapshot could not be read back."
SNAPSHOT_ID="$(jq -r --arg name "$SNAPSHOT_NAME" \
    'first(.. | objects | select(has("snapshot") and has("createTime") and .name == $name) | .snapshot.value) // empty' <<<"$snapshot_json")"
[[ "$SNAPSHOT_ID" =~ ^snapshot-[0-9]+$ ]] || fail "the snapshot was created but its id could not be read."
INSTANCE_UUID="$(govc object.collect -s "$VM_PATH" config.instanceUuid)"

SNAPSHOT_EVIDENCE="${EVIDENCE_DIR}/image-snapshot-${VERSION}.json"
jq -n \
    --arg timestamp "$(ts_iso)" --arg version "$VERSION" \
    --arg vm_name "$VM_NAME" --arg vm_path "$VM_PATH" --arg instance_uuid "$INSTANCE_UUID" \
    --arg snapshot_name "$SNAPSHOT_NAME" --arg snapshot_id "$SNAPSHOT_ID" \
    --arg create_time "$(jq -r --arg id "$SNAPSHOT_ID" 'first(.. | objects | select(.snapshot?.value? == $id) | .createTime) // empty' <<<"$snapshot_json")" \
    --arg seal_result "$(basename -- "$SEAL_RESULT")" \
    '{
        schema_version: 1, timestamp: $timestamp, version: $version,
        vm: {name: $vm_name, path: $vm_path, instance_uuid: $instance_uuid, power_state: "poweredOff"},
        snapshot: {name: $snapshot_name, id: $snapshot_id, create_time: $create_time},
        taken_after: {seal_result: $seal_result}
    }' >"$SNAPSHOT_EVIDENCE" || fail "the snapshot evidence could not be written."
printf 'Snapshot taken: %s, id %s, on %s (instance UUID %s)\n' "$SNAPSHOT_NAME" "$SNAPSHOT_ID" "$VM_NAME" "$INSTANCE_UUID"

# --- 5. The last evidence collection. ---
step "5/9: final evidence index"
bash "${SCRIPT_DIR}/collect-evidence.sh" --evidence-dir "$EVIDENCE_DIR" --outcome success ||
    fail "the final evidence collection failed. Nothing is published."

# --- 6. The record. ---
step "6/9: image reference"
bash "${SCRIPT_DIR}/image-reference.sh" write \
    --version "$VERSION" --vm-path "$VM_PATH" \
    --snapshot-name "$SNAPSHOT_NAME" --snapshot-id "$SNAPSHOT_ID" --instance-uuid "$INSTANCE_UUID" \
    --seal-result "$SEAL_RESULT" --snapshot-evidence "$SNAPSHOT_EVIDENCE" \
    --evidence-dir "$EVIDENCE_DIR" ||
    fail "the image reference could not be written. The VM and snapshot exist but are not a published master."
RECORD="${EVIDENCE_DIR}/image-reference.json"

# Without a record the image is not published, so a failure from here on takes
# the record away again: a record that could not be shown to resolve, or that
# was not scanned, must not be left for a consumer to find.
unpublish() {
    rm -f -- "$RECORD"
    fail "$1 The image reference has been removed; this build is not published."
}

# --- 7. Continuity. ---
step "7/9: continuity lookups"
for attempt in 1 2; do
    bash "${SCRIPT_DIR}/image-reference.sh" lookup --record "$RECORD" --out "${EVIDENCE_DIR}/image-lookup-${attempt}.json" ||
        unpublish "Lookup ${attempt} did not match the record."
done
[[ "$(jq -c '.found' "${EVIDENCE_DIR}/image-lookup-1.json")" == "$(jq -c '.found' "${EVIDENCE_DIR}/image-lookup-2.json")" ]] ||
    unpublish "The two lookups did not return the same identity."
printf 'Continuity: two lookups by instance UUID and snapshot id returned the same VM and snapshot.\n'

# --- 8. Secret scan of the record and the lookups. ---
step "8/9: secret scan of the record and lookups"
bash "${SCRIPT_DIR}/collect-evidence.sh" --evidence-dir "$EVIDENCE_DIR" ||
    unpublish "The record and lookups did not pass the evidence check."

# --- 9. The lasting copy of the evidence. ---
step "9/9: evidence store"
bash "${SCRIPT_DIR}/evidence-store.sh" put --version "$VERSION" --evidence-dir "$EVIDENCE_DIR" ||
    unpublish "The evidence could not be copied to the evidence store."

printf '\nPublished: %s, snapshot %s (%s), version %s\n' "$VM_NAME" "$SNAPSHOT_NAME" "$SNAPSHOT_ID" "$VERSION"
printf 'Image reference: %s\n' "$RECORD"
