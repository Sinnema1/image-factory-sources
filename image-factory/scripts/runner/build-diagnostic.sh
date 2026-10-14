#!/usr/bin/env bash
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

TIMESTAMP="$(ts_file)"
CONSOLE_LOG="${EVIDENCE_DIR}/packer-console-${TIMESTAMP}.log"
DEBUG_LOG="${EVIDENCE_DIR}/packer-build-${TIMESTAMP}.log"
PROVENANCE_FILE="${EVIDENCE_DIR}/packer-provenance-${TIMESTAMP}.txt"
VALIDATE_LOG="${EVIDENCE_DIR}/packer-validate-${TIMESTAMP}.log"

require_command packer

require_readable_file \
    "$PACKER_TEMPLATE" \
    "$PACKER_VARS" \
    "$UNATTEND_TEMPLATE" \
    "$WINRM_SCRIPT"

require_env \
    VCENTER_HOST \
    VCENTER_USERNAME \
    VCENTER_PASSWORD \
    ADMIN_SERVICE_ACCOUNT \
    ADMIN_SERVICE_ACCOUNT_PASSWORD \
    AD_DOMAIN \
    AD_NETBIOS_DOMAIN

ensure_evidence_dir

# Index the evidence when the script ends, whether the build passed or failed.
collect_evidence() {
    local rc=$?
    local outcome="failed"
    trap - EXIT
    [[ $rc -eq 0 ]] && outcome="success"
    if ! bash "${SCRIPT_DIR}/collect-evidence.sh" --evidence-dir "$EVIDENCE_DIR" --outcome "$outcome"; then
        [[ $rc -eq 0 ]] && rc=1
    fi
    exit "$rc"
}
trap collect_evidence EXIT

# Relative paths in the template resolve from the repository root.
cd "$REPO_ROOT" || fail "Failed to change directory to: $REPO_ROOT"

# Verify the lock, the package-runner binary and the package files on the
# runner before anything is built. This also writes the Packer variables that
# describe them (package_lock, package_artifact_root, package_runner,
# execution_id).
bash "${SCRIPT_DIR}/stage-packages.sh" \
    --evidence-dir "$EVIDENCE_DIR" \
    --emit-var-file "$PACKAGE_VARS_FILE" ||
    fail "Package staging failed."

# Optional shorter WinRM wait for diagnostic runs (for example WINRM_TIMEOUT=15m).
# When unset, the template default applies.
extra_var_args=(-var-file="$PACKAGE_VARS_FILE" -var "evidence_dir=${EVIDENCE_DIR}")

if [[ -n "${WINRM_TIMEOUT:-}" ]]; then
    [[ "$WINRM_TIMEOUT" =~ ^([0-9]+[hms])+$ ]] ||
        fail "WINRM_TIMEOUT must be a duration such as 15m or 1h30m."
    extra_var_args+=(-var "winrm_timeout=${WINRM_TIMEOUT}")
fi

# A published master has a versioned name (ADR 0005), which publish-image.sh
# chooses and passes here. Unset, the name comes from the variable file as it
# always has, and nothing about a diagnostic build changes.
IMAGE_VM_NAME="${IMAGE_VM_NAME:-}"
if [[ -n "$IMAGE_VM_NAME" ]]; then
    [[ "$IMAGE_VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] ||
        fail "IMAGE_VM_NAME may only contain letters, digits, '.', '_' and '-'."
    # A -var given after the variable file overrides the value in it.
    extra_var_args+=(-var "vm_name=${IMAGE_VM_NAME}")
    printf 'VM name for this build: %s\n' "$IMAGE_VM_NAME"
fi

# Sealing is off unless asked for (ADR 0002). A sealed VM has no WinRM, so its
# result is read from vCenter by a watcher that has to be running before the
# seal reports: the value is gone once the VM powers off.
SEAL_IMAGE="${SEAL_IMAGE:-false}"
[[ "$SEAL_IMAGE" == "true" || "$SEAL_IMAGE" == "false" ]] || fail "SEAL_IMAGE must be 'true' or 'false'."
seal_watcher_pid=""
if [[ "$SEAL_IMAGE" == "true" ]]; then
    require_env ADMIN_GROUP_SID
    extra_var_args+=(-var "seal_image=true")
    # Both values are read from the variable files the build is about to use,
    # so the watcher looks at the VM and the execution the build means.
    seal_vm_name="$IMAGE_VM_NAME"
    [[ -n "$seal_vm_name" ]] ||
        seal_vm_name="$(sed -n 's/^[[:space:]]*vm_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$PACKER_VARS" | head -1)"
    seal_execution_id="$(sed -n 's/^[[:space:]]*execution_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$PACKAGE_VARS_FILE" | head -1)"
    [[ -n "$seal_vm_name" ]] || fail "SEAL_IMAGE is true but vm_name could not be read from the Packer variable file."
    [[ -n "$seal_execution_id" ]] || fail "SEAL_IMAGE is true but execution_id could not be read from ${PACKAGE_VARS_FILE}."
    printf 'Sealing requested: the image will be sealed and its result read from vCenter (VM %s, execution %s).\n' \
        "$seal_vm_name" "$seal_execution_id"
fi

# Record where this build came from before it starts.
# Computed before the block below so a hashing failure is recorded as such: an
# empty field would be indistinguishable from a successful hash of nothing.
if ! vars_file_sha="$(sha256sum "$PACKER_VARS" | cut -d' ' -f1)"; then
    vars_file_sha="UNAVAILABLE (sha256sum failed)"
fi

{
    printf 'timestamp: %s\n' "$TIMESTAMP"
    printf 'git branch: %s\n' "$(git branch --show-current 2>/dev/null || true)"
    printf 'ci ref: %s\n' "${CI_COMMIT_REF_NAME:-not set}"
    printf 'git commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'dirty files: %s\n' "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    printf 'winrm_timeout override: %s\n' "${WINRM_TIMEOUT:-none}"
    printf 'seal_image: %s\n' "$SEAL_IMAGE"
    printf 'vm_name override: %s\n' "${IMAGE_VM_NAME:-none}"
    # The variable file is not tracked in git. Record its hash, not its content.
    printf 'vars file sha256: %s\n' "$vars_file_sha"
    printf '\n'
    packer version
    printf '\n'
    packer plugins installed 2>&1
} >"$PROVENANCE_FILE" 2>&1

printf 'Provenance: %s\n' "$PROVENANCE_FILE"

printf '%s\n' "Validating Packer template..."

# The output is kept as validation evidence.
packer validate \
    -var-file="$PACKER_VARS" \
    ${extra_var_args[@]+"${extra_var_args[@]}"} \
    "$PACKER_TEMPLATE" 2>&1 | tee "$VALIDATE_LOG"

if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    fail "Packer template validation failed."
fi

printf '%s\n' "Starting diagnostic build..."
printf 'Console log: %s\n' "$CONSOLE_LOG"
printf 'Debug log: %s\n' "$DEBUG_LOG"

export PACKER_LOG=1
export PACKER_LOG_PATH="$DEBUG_LOG"

# -on-error=abort keeps a failed build's VM in place for inspection. This is an
# OWNER OVERRIDE for the lab only (AGENT_HANDOFF.md, Key Design Decision 8;
# STORY-02), not the default: re-decide it before any other environment.
#
# A retained VM still holds the domain-join service account password in
# plaintext, in two places: C:\Windows\Panther\unattend-original.xml in the
# guest, and the build floppy image on the datastore, whose cleanup abort also
# skips (OBSERVED 2026-09-28, job 3531). The build's last provisioner removes
# the guest copy, but a failed build never reaches that provisioner.
# Remove retained VMs promptly with scripts/windows/Remove-PackerTestVm.ps1
# (or `make clean-vm VM_NAME=<name>`), which deletes the floppy image too.
#
# PARKED, deliberately inactive (2026-09-24). Salvaged from
# feature/STORY-01-windows-communicator (9669668) before that branch was
# deleted: a PACKER_ON_ERROR switch that defaults to cleanup, so a failed build
# deletes its VM unless the caller asks to keep it. On 2026-09-28 the owner
# decided to keep abort for the lab (AGENT_HANDOFF.md, Key Design Decision 8), so
# this stays commented out; it is the starting point when that is re-decided
# for Site B. To activate, uncomment the block below and pass
# -on-error="$PACKER_ON_ERROR" instead of -on-error=abort.
#
# Do NOT then pin the packer-build-diagnostic job to PACKER_ON_ERROR=abort, as
# the original branch did: the diagnostic job is the only CI build, so that
# would change nothing. Leave the variable unset so cleanup is the default, and
# set PACKER_ON_ERROR=abort on the "Run job" page for a run you mean to inspect.
# INFERRED, not exercised here: that cleanup on the vsphere-iso builder deletes
# the VM and its floppy image from disk. Prove it with one induced failure
# (WINRM_TIMEOUT=1m) before relying on it.
#
# PACKER_ON_ERROR="${PACKER_ON_ERROR:-cleanup}"
# case "$PACKER_ON_ERROR" in
#     cleanup|abort) ;;
#     *) fail "PACKER_ON_ERROR must be either 'cleanup' or 'abort'." ;;
# esac
# printf 'Packer on-error behavior: %s\n' "$PACKER_ON_ERROR"
# if [[ "$PACKER_ON_ERROR" == "abort" ]]; then
#     printf '%s\n' "A failed build's VM will be kept in vSphere; remove it after inspection."
# fi
if [[ "$SEAL_IMAGE" == "true" ]]; then
    bash "${SCRIPT_DIR}/verify-seal.sh" watch \
        --vm "$seal_vm_name" --execution-id "$seal_execution_id" --evidence-dir "$EVIDENCE_DIR" &
    seal_watcher_pid=$!
fi

packer build -timestamp-ui \
    -on-error=abort \
    -var-file="$PACKER_VARS" \
    ${extra_var_args[@]+"${extra_var_args[@]}"} \
    "$PACKER_TEMPLATE" 2>&1 | tee "$CONSOLE_LOG"

BUILD_EXIT_CODE=${PIPESTATUS[0]}

# The watcher has either captured the result by now or has nothing more to
# wait for: Packer only returns once the VM is off, or has given up on it.
if [[ -n "$seal_watcher_pid" ]]; then
    for _ in 1 2 3 4 5 6; do
        kill -0 "$seal_watcher_pid" 2>/dev/null || break
        sleep 5
    done
    kill "$seal_watcher_pid" 2>/dev/null || true
    wait "$seal_watcher_pid" 2>/dev/null || true
fi

if [[ $BUILD_EXIT_CODE -ne 0 ]]; then
    printf 'Error: Packer build failed with exit code %s.\n' "$BUILD_EXIT_CODE" >&2
    exit $BUILD_EXIT_CODE
fi

printf '%s\n' "Packer build completed successfully."

# A sealed build is only as good as its seal result. No result, or a result
# that does not say sealed, fails the job even though Packer passed.
if [[ "$SEAL_IMAGE" == "true" ]]; then
    bash "${SCRIPT_DIR}/verify-seal.sh" check \
        --execution-id "$seal_execution_id" --evidence-dir "$EVIDENCE_DIR" ||
        fail "The image seal could not be verified."
fi
exit 0
