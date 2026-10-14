# Example Labs Engineering Rules

This file is the single source of the engineering rules (since 2026-09-30).
`AGENT_HANDOFF.md` and `CLAUDE.md` point here rather than repeating them.
Environment-specific exceptions are recorded as owner overrides in
`AGENT_HANDOFF.md` (Key Design Decisions), never here.

## Scope
- Implement **only the current requested increment**.
- Do **not** create future-phase functionality unless explicitly requested.
- Do **not** scaffold speculative abstractions.

## Architecture
- Decisions precede consequential implementation. Record them as ADRs in `docs/decisions/`.
- Distinguish: `OBSERVED`, `INFERRED`, `PROPOSED`, `BLOCKED`, `DEFERRED`. Use absolute dates.
- Do **not** treat target architecture as evidence of current implementation.

## Software Inputs
- A package's identity, source, integrity and installation metadata are declared in its
  `package-runner` package definition and frozen into the resolved lock, which is the
  contract artifact (ADR 0003). They do not define deployment policy.
- Use **exact versions** and **exact source references** (no `latest`, wildcards, or auto-discovery).
- Expected SHA-256 values **must be established before runtime**.
- Host verifies package integrity **before transfer**.
- Guest **re-verifies** against the same SHA-256 after transfer.
- Integrity failure = **fail-closed**.

## Credentials
- Credentials are supplied **at run time only**, from the CI secret store (masked variables)
  or an untracked local file. Never from a tracked file, and never left in an image.
- Pass them through the environment or a protected file, **never as command-line
  arguments**, which show up in process listings and logs.
- Never write them to logs or evidence. Mark them sensitive so tools mask them, and
  **secret-scan evidence before it is kept**. A scan that could not run is not a pass.
- Where a tool must be handed a credential in a file (the Windows answer file is the one
  case today), render the file per build, never track it, and remove every copy once it is
  consumed. The build fails if a copy survives.
- Prefer one purpose per account, least privilege, and per-build or short-lived credentials
  over shared, long-lived ones. Rotate a credential that may have been exposed.

## Responsibilities
- **Definitions** declare.
- **Scripts** execute.
- **Contracts** define boundaries.
- **Tests** prove behavior.
- **CI** orchestrates.

## Engineering
- Prefer the **smallest implementation** satisfying the current requirement.
- Do **not** introduce generalized frameworks where explicit scripts/functions suffice.
- Do **not** commit secrets or installer binaries.
- Preserve evidence required to explain build outcomes: every validation writes an
  auditable record to `evidence/`.
- Validation fails closed. In the runner scripts, `fail()` exits 1 (the check ran and
  failed) and `require_command` exits 2 (a required tool is missing, so the check could
  not run). Keep that distinction.
