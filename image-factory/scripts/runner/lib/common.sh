# Shared helpers for the scripts in scripts/runner/.
#
# Sourced, never executed. Source it as the first thing after `set -uo pipefail`:
#
#   SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/lib/common.sh"
#
# Sourcing sets REPO_ROOT, EVIDENCE_DIR, BUILD_DIR and the common repository
# paths, but never overwrites a value the caller set first, so a script that
# parses --evidence-dir after sourcing still wins.
#
# Exit codes are split deliberately:
#   1  a check failed        (fail)
#   2  the environment cannot run the check (require_command)
# A caller that needs different semantics defines its own fail() after sourcing;
# stage-packages.sh does exactly that, so it can write evidence before exiting.
#
# Timestamps are UTC everywhere. Filenames and the timestamp fields inside the
# JSON they contain were previously in different zones, which made an evidence
# file impossible to correlate with its own recorded time across a zone change.

# Sourcing twice is harmless but pointless.
[[ -n "${_RUNNER_COMMON_SOURCED:-}" ]] && return 0
_RUNNER_COMMON_SOURCED=1

_COMMON_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_DIR="$(cd -- "${_COMMON_LIB_DIR}/.." && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "${RUNNER_DIR}/../.." && pwd)}"

EVIDENCE_DIR="${EVIDENCE_DIR:-${REPO_ROOT}/evidence}"

# Build inputs derived at runtime. Kept out of evidence/ so they are never
# indexed or uploaded as part of the build's own output.
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
PACKAGE_VARS_FILE="${PACKAGE_VARS_FILE:-${BUILD_DIR}/package-vars.pkrvars.hcl}"

PACKER_TEMPLATE="${PACKER_TEMPLATE:-${REPO_ROOT}/packer/templates/windows-11-vsphere.pkr.hcl}"
PACKER_VARS="${PACKER_VARS:-${REPO_ROOT}/configs/windows-11-vsphere.pkrvars.hcl}"
UNATTEND_TEMPLATE="${UNATTEND_TEMPLATE:-${REPO_ROOT}/packer/unattended/autounattend.xml.pkrtpl}"
WINRM_SCRIPT="${WINRM_SCRIPT:-${REPO_ROOT}/packer/unattended/enable-winrm.ps1}"

# --- Timestamps (UTC) ---

# For filenames: 20260922-141530Z
ts_file() { date -u +%Y%m%d-%H%M%SZ; }

# For JSON bodies: 2026-09-22T14:15:30Z
ts_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- Paths ---

# A path Packer can read. On the Windows workstation Git Bash paths (/c/...)
# mean nothing to packer.exe; on the runner this is the identity.
abs_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# --- Failure ---

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

# --- Requirements ---

# Exits 2: a missing tool means the check could not run, which is a different
# condition from the check running and failing.
require_command() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || {
            printf 'Error: %s is not installed or not in PATH.\n' "$command_name" >&2
            exit 2
        }
    done
}

require_readable_file() {
    local file_path
    for file_path in "$@"; do
        [[ -f "$file_path" ]] || fail "Required file not found: $file_path"
        [[ -r "$file_path" ]] || fail "Required file is not readable: $file_path"
    done
}

# Reports every missing variable at once rather than stopping at the first, so
# a misconfigured runner takes one round trip to diagnose instead of several.
require_env() {
    local var_name
    local missing=()

    for var_name in "$@"; do
        [[ -n "${!var_name:-}" ]] || missing+=("$var_name")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'Error: required variable(s) not set: %s\n' "${missing[*]}" >&2
        exit 1
    fi
}

# --- Evidence ---

ensure_evidence_dir() {
    mkdir -p "$EVIDENCE_DIR" ||
        fail "Failed to create evidence directory: $EVIDENCE_DIR"
}

ensure_build_dir() {
    mkdir -p "$BUILD_DIR" ||
        fail "Failed to create build directory: $BUILD_DIR"
}
