# image-factory

Packer/vSphere image factory for the Example Labs Windows 11 master image (Phase 1).

## Read first
1. `AGENT_HANDOFF.md` — current state, cross-repository interfaces, key design decisions
   (including owner overrides), open questions and next steps. Authoritative.
2. `.continue/rules/engineering-principles.md` — the engineering rules; the single source.
3. `docs/image-factory-retrospective.md` — history, the canonical defect register (cite
   defects as `D<n>`), open risks (section 7) and next steps (section 8).
4. The ADRs in `docs/decisions/` that the task touches. ADR 0003 is the package install
   contract with the `package-runner` and `runner-image` owner.

## Boundaries
- **Change only this repository.** `runner-image`, `package-runner`,
  `ci-platform` and `runner-test-bed` are owned by the tooling owner: record findings about them in the
  register, do not fix them.
- Superseded code is deprecated first, and deleted only once its owner agrees.

## Conventions
- Findings carry evidence labels (`OBSERVED`, `INFERRED`, `PROPOSED`, `BLOCKED`,
  `DEFERRED`) and absolute dates. Verify before asserting: run it, read it, or say it was
  not checked.
- The user runs builds and CI jobs, and commits and pushes. Draft commit messages as a file
  for `git commit -F <file>`; heredocs have lost quoted words in their shell.
- One branch per story, cut from an up-to-date `main`.
- Comments explain why, and match the density and idiom of the surrounding file.

## Environment facts
- `make` is not installed on the Windows workstation: run scripts directly
  (`bash scripts/runner/<name>.sh`). `govc`, `pwsh` and PowerCLI are on the workstation,
  not in the runner image.
- GitLab runs job scripts under `set -e`: capture a failing command with `|| rc=$?`.
- Quote `.env` values that contain a backslash (`DOMAIN\user`), or bash drops it.
- Git Bash rewrites arguments that start with `/` into Windows paths; set
  `MSYS_NO_PATHCONV=1` for vCenter inventory paths.
- In scripted edits, build Windows backslash paths with `chr(92)` or use an exact-match
  editor, then scan for control characters: an escaped `\n` once split a table row.
