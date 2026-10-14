#!/usr/bin/env bash
# Runner side of the software install flow (ADR 0003): checks everything the
# build is about to transfer into the guest, before Packer starts.
#
#   1. The lock, against the SHA-256 committed beside it (<lock>.sha256). That
#      committed value is the trust anchor (ADR 0003, C1): the guest only checks
#      the lock against the sidecar uploaded with it, which catches a corrupted
#      transfer, not a lock that is not the one this repository reviewed.
#   2. The package-runner binary, against the SHA-256 committed beside it, the
#      same way. Today that is the stand-in in packer/fixtures/package-runner/.
#   3. The package files. runner-image's download-packages (in the runner image
#      since 0.2.1) reads the lock, copies each package's file from the source
#      root into <artifact-root>/<name>/<version>/, and checks its size and
#      SHA-256 against the lock. That tree is what Packer uploads. This script
#      never parses the lock: the tools that own the format read it (ADR 0003,
#      decision 2). It does hash what was staged, for the evidence record,
#      because download-packages writes none of its own.
#
#      Two things that tool does not do, and the committed lock hash in step 1
#      is what stands in for them: it does not reject a path that leaves the
#      source root (D31), and it treats a lock entry with no sha256 as verified
#      (D35). Both can only be reached through a lock this repository reviewed.
#
# Any problem fails closed. A JSON evidence record is written on success and on
# failure. --emit-var-file writes the Packer variables the template needs
# (package_lock, package_artifact_root, package_runner, execution_id).
#
# Usage:
#   stage-packages.sh [--lock FILE] [--source-root DIR] [--artifact-root DIR]
#                     [--runner FILE] [--evidence-dir DIR] [--emit-var-file FILE]
#
#   --source-root    where download-packages reads from. Default: the fixture's
#                    packages folder. For catalog packages, the package share
#                    as mounted in the job (/mnt/image-factory/package-content).
#   --artifact-root  where the verified tree is written. Emptied first. Default:
#                    build/packages, which git ignores.
#
# The defaults can also be set as PACKAGE_LOCK, PACKAGE_SOURCE_ROOT,
# PACKAGE_ARTIFACT_ROOT and PACKAGE_RUNNER. Needs bash, sha256sum, jq, yq and
# download-packages; the last two are in the runner image, not on a workstation.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

LOCK="${PACKAGE_LOCK:-${REPO_ROOT}/packer/fixtures/software/windows-vm-fixture.lock.yaml}"
SOURCE_ROOT="${PACKAGE_SOURCE_ROOT:-${REPO_ROOT}/packer/fixtures/software/packages}"
ARTIFACT_ROOT="${PACKAGE_ARTIFACT_ROOT:-${REPO_ROOT}/build/packages}"
RUNNER="${PACKAGE_RUNNER:-${REPO_ROOT}/packer/fixtures/package-runner/package-runner.ps1}"
VAR_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lock)            LOCK="${2:-}"; shift 2 ;;
        --source-root)     SOURCE_ROOT="${2:-}"; shift 2 ;;
        --artifact-root)   ARTIFACT_ROOT="${2:-}"; shift 2 ;;
        --runner)          RUNNER="${2:-}"; shift 2 ;;
        --evidence-dir)    EVIDENCE_DIR="${2:-}"; shift 2 ;;
        --emit-var-file)   VAR_FILE="${2:-}"; shift 2 ;;
        -h|--help)         sed -n '2,39p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)                 printf 'Error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

require_command jq sha256sum yq download-packages

TIMESTAMP="$(ts_file)"
ensure_evidence_dir
EVIDENCE_FILE="${EVIDENCE_DIR}/package-stage-${TIMESTAMP}.json"
DOWNLOAD_LOG="${EVIDENCE_DIR}/package-download-${TIMESTAMP}.log"

# The execution id the guest tooling stamps into its evidence (C3). The CI job
# id when there is one; a workstation run has none.
EXECUTION_ID="${CI_JOB_ID:-local-${TIMESTAMP}}"

# Filled in as the checks progress, so a failure still records what was known.
lock_expected=""; lock_actual=""; runner_expected=""; runner_actual=""; error=""
download_exit=""; staged_files="[]"

write_evidence() {
    local result="$1"
    jq -n \
        --arg timestamp "$(ts_iso)" \
        --arg result "$result" \
        --arg error "$error" \
        --arg execution_id "$EXECUTION_ID" \
        --arg lock "$(basename -- "$LOCK")" \
        --arg lock_expected "$lock_expected" --arg lock_actual "$lock_actual" \
        --arg runner "$(basename -- "$RUNNER")" \
        --arg runner_expected "$runner_expected" --arg runner_actual "$runner_actual" \
        --arg download_exit "$download_exit" \
        --arg download_log "$(basename -- "$DOWNLOAD_LOG")" \
        --argjson staged_files "$staged_files" \
        '{
            schema_version: 2,
            timestamp: $timestamp,
            result: $result,
            error: (if $error == "" then null else $error end),
            execution_id: $execution_id,
            lock: {file: $lock, expected_sha256: $lock_expected, actual_sha256: $lock_actual},
            package_runner: {file: $runner, expected_sha256: $runner_expected, actual_sha256: $runner_actual},
            packages: {
                tool: "download-packages",
                exit_code: (if $download_exit == "" then null else ($download_exit | tonumber) end),
                log: $download_log,
                staged_files: $staged_files
            }
        }' >"$EVIDENCE_FILE"
}

# Overrides lib/common.sh's fail: a failed check is recorded before exiting, so
# it is as auditable as a passing one.
fail() {
    error="$1"
    write_evidence "failed"
    printf 'Package staging FAILED: %s\n' "$error" >&2
    printf 'Evidence: %s\n' "$EVIDENCE_FILE" >&2
    exit 1
}

# Reads the expected hash from a sha256sum-format file that must name exactly
# the file beside it.
expected_sha_for() {
    local file="$1" sidecar="$1.sha256" line
    [[ -f "$sidecar" ]] || return 1
    line="$(tr -d '\r' <"$sidecar" | sed -n '1p')"
    [[ "$line" =~ ^([0-9a-fA-F]{64})[[:space:]]+\*?(.+)$ ]] || return 1
    [[ "${BASH_REMATCH[2]}" == "$(basename -- "$file")" ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}" | tr 'A-F' 'a-f'
}

[[ "$EXECUTION_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "the execution id has unexpected characters"

# --- 1. The lock, against the committed hash. ---
[[ -f "$LOCK" ]] || fail "lock not found: ${LOCK}"
lock_expected="$(expected_sha_for "$LOCK")" ||
    fail "no usable committed SHA-256 for the lock: expected $(basename -- "$LOCK").sha256 beside it, in sha256sum format"
# Hashed through stdin, here and below: given a path that contains a backslash,
# GNU sha256sum escapes its output and prefixes the hash with one.
lock_actual="$(sha256sum <"$LOCK" | cut -d' ' -f1)"
[[ "$lock_actual" == "$lock_expected" ]] || fail "the lock does not match its committed SHA-256"

# --- 2. The package-runner binary, against the committed hash. ---
[[ -f "$RUNNER" ]] || fail "package-runner not found: ${RUNNER}"
runner_expected="$(expected_sha_for "$RUNNER")" ||
    fail "no usable committed SHA-256 for package-runner: expected $(basename -- "$RUNNER").sha256 beside it, in sha256sum format"
runner_actual="$(sha256sum <"$RUNNER" | cut -d' ' -f1)"
[[ "$runner_actual" == "$runner_expected" ]] || fail "package-runner does not match its committed SHA-256"

# --- 3. The package files, staged and verified by download-packages. ---
[[ -d "$SOURCE_ROOT" ]] || fail "source root not found: ${SOURCE_ROOT}"

# Emptied first, so the tree holds this run's verified files and nothing an
# earlier run left behind. Refuse anything that is not plainly a staging folder:
# this path is deleted recursively.
case "$(abs_path "$ARTIFACT_ROOT")" in
    build/packages|*/build/packages|build/packages/*|*/build/packages/*) ;;
    *) fail "refusing to empty an artifact root outside build/packages: ${ARTIFACT_ROOT}" ;;
esac
rm -rf -- "$ARTIFACT_ROOT"
mkdir -p -- "$ARTIFACT_ROOT"

download_exit=0
download-packages --lock "$LOCK" --output "$ARTIFACT_ROOT" --mount-root "$SOURCE_ROOT" \
    >"$DOWNLOAD_LOG" 2>&1 || download_exit=$?
[[ "$download_exit" -eq 0 ]] ||
    fail "download-packages exited ${download_exit} (see $(basename -- "$DOWNLOAD_LOG"))"

# What Packer is about to upload, hashed here because download-packages leaves
# no record of its own. Paths are relative to the artifact root.
staged_files="$(
    cd -- "$ARTIFACT_ROOT" &&
        find . -type f | LC_ALL=C sort | while IFS= read -r staged; do
            jq -n --arg path "${staged#./}" \
                --arg sha256 "$(sha256sum <"$staged" | cut -d' ' -f1)" \
                --argjson size "$(wc -c <"$staged" | tr -d '[:space:]')" \
                '{path: $path, sha256: $sha256, size_bytes: $size}'
        done | jq -s '.'
)" || fail "could not list the staged files"
[[ "$(jq 'length' <<<"$staged_files")" -gt 0 ]] ||
    fail "download-packages reported success but staged no files"

write_evidence "passed"

if [[ -n "$VAR_FILE" ]]; then
    mkdir -p "$(dirname -- "$VAR_FILE")"
    {
        printf 'package_lock          = "%s"\n' "$(abs_path "$LOCK")"
        printf 'package_artifact_root = "%s"\n' "$(abs_path "$ARTIFACT_ROOT")"
        printf 'package_runner        = "%s"\n' "$(abs_path "$RUNNER")"
        printf 'execution_id          = "%s"\n' "$EXECUTION_ID"
    } >"$VAR_FILE"
fi

printf 'Package staging passed: lock %s, package-runner %s, %s file(s) staged\n' \
    "$(basename -- "$LOCK")" "$(basename -- "$RUNNER")" "$(jq 'length' <<<"$staged_files")"
printf 'Evidence: %s\n' "$EVIDENCE_FILE"
exit 0
