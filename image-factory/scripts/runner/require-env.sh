#!/usr/bin/env bash
# Fails unless every named variable is set and non-empty.
#
# A thin wrapper over require_env in lib/common.sh so CI jobs can use the same
# check the scripts use, instead of a column of hand-written `test -n` guards
# that drifted between jobs.
#
# Usage:
#   require-env.sh VCENTER_HOST VCENTER_USERNAME VCENTER_PASSWORD
#
# Reports every missing variable at once, so a misconfigured runner takes one
# pipeline run to diagnose rather than one per variable.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/runner/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

[[ $# -gt 0 ]] || fail "require-env.sh needs at least one variable name."

require_env "$@"

printf 'All %s required variable(s) are set.\n' "$#"
