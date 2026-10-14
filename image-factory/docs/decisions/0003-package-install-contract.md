# ADR 0003: Software install contract with the software baseline

- **Status:** **Accepted, 2026-09-28** (STORY-09), as refined by Contract terms below.
  History: proposed 2026-09-21, revised 2026-09-22; findings re-verified and extended
  2026-09-23; renumbered to the canonical `D` scheme 2026-09-24; contract terms proposed,
  `package-runner` re-read at `4881c5d`, and the terms accepted 2026-09-28.
  This is the second revision. The first (2026-09-21) replaced a draft that proposed a
  manifest and guest install script owned by this repository. This revision names the
  **resolved lock file as the contract artifact** between the image build and the package
  tooling, after a direct read of the three adjacent repositories rather than a pasted
  excerpt. On 2026-09-23 all seven findings below were re-checked against the same
  repositories and all seven stand; the additional findings that second read produced are
  recorded below and in
  [the Image Factory retrospective](../image-factory-retrospective.md#45-defect-register).
- **Date:** 2026-09-22
- **Scope:** how software packages get from the software catalog into the guest before
  generalization and sealing

Evidence labels follow the repository engineering rules: `OBSERVED`, `INFERRED`,
`PROPOSED`, `BLOCKED`, `DEFERRED`.

> Everything labelled OBSERVED about an adjacent repository was read from a local clone on
> 2026-09-22 unless another date or commit is given (the Contract terms and "Re-read
> 2026-09-28" were read at `package-runner` `4881c5d`). Two of those branches are unmerged
> development branches, so the code is in flux. **The contract itself is agreed** (Contract
> terms, accepted 2026-09-28); sections written before then keep their original wording as
> the record of how the decision was reached, and Contract terms takes precedence.

## Context

The engineering rules require exact versions and exact sources, an expected SHA-256
established before runtime, host verification before transfer, guest re-verification
after transfer, and fail-closed behavior on any integrity failure.

Software sourcing, the software catalog, the runner image, and package install behavior
are maintained in other repositories in the same group by the runner and catalog owner.
The image build in this repository should consume that work, not duplicate it.

### The four repositories form a layered stack (OBSERVED)

All four are in `image-factory-group` on `gitlab.example.test`. The build-time
dependency runs in one direction only.

| Layer | Repository | Responsibility | Depends on |
|-------|-----------|----------------|------------|
| CI platform | `ci-platform` | The reusable `build` and `publish` pipeline template every container repository in the group includes, plus `publish-image.sh` (podman save to a docker-archive with a SHA-256 and YAML metadata, under `flock`) and script promotion to the shared drive and the runner's `~/bin`. Generic: it never knows what an image contains. **There is no registry**: OBSERVED 2026-09-23, its README calls it a "mock artifactory", and no push, login, credential or network call exists anywhere in the publish path. Images are consumed with `podman load` from the share, not `podman pull`, and the `registry.example.test/images` prefix is a local naming convention that is never contacted. | — |
| Toolchain | `runner-image` | One Dockerfile (UBI 10 minimal, Packer 1.16.0, git, make, jq, curl, unzip) and the scripts baked onto `PATH`. Its entire `.gitlab-ci.yml` is a four-line `include:` of the layer above. | CI platform |
| Image build | **this repository** | The Packer vSphere template, the answer file, the guest bootstrap, ISO intake and qualification, sealing, and build evidence. | Toolchain |
| Package engine | `package-runner` | A Go CLI: recipe to resolver to immutable lock, then handlers and validators in the guest. | consumed by the image build |

This matters because the previous revision's ownership table had only two rows, "this
repository" and "the owner". Three distinct outside responsibilities are now visible, with
different interfaces and different failure modes.

### What this repository has (OBSERVED)

- `packer/manifests/package-manifest.schema.json`,
  `packer/manifests/packages.example.json` (placeholder hashes),
  `software-source/scripts/Download-Package.ps1` (copy and SHA-256 check),
  `Invoke-HostValidation.ps1`, and Pester tests for the first. These predate the
  baseline manifest below and are provisional. **All deleted on 2026-09-29**, after this
  ADR was accepted, together with `scripts/runner/validate.sh`'s optional call to the
  validator.
- `scripts/runner/verify-package.sh`, the bash runner-side verifier used by the interim
  staging proof.
- The Packer template stages and verifies one fixture package (see Interim staging below).
  Nothing installs software today.

### What the adjacent repositories contain (OBSERVED, 2026-09-22)

**`package-runner`** (branch `init`, early development, Go 1.21):

- `windows-vm.yaml`, `kind: ImageRecipe`: `metadata` (name, version,
  `baselineClassification: slim-vdi-base`), a `target` block (platform, release,
  architecture, imageType), `defaults.failurePolicy`, and `packages[]` entries of name,
  version and `installOrder`.
- `packages/<name>/<version>/package-definition.yml`, `kind: PackageDefinition`: an
  `artifact` block (repository, path, filename, sha256, sizeBytes) and an `install` block
  (handler, timeout, successExitCodes).
- `out/windows-vm.lock.yaml`, `kind: ImageRecipeLock`: the recipe resolved against the
  definitions, ordered by `installOrder`, carrying a `metadata.lockHash` and `generatedAt`,
  and per package `resolvedFrom`, `install` and `artifact`.
- Commands: `resolve` (`--recipe`, `--package-root`, `--output`), `validate`, `install`
  (`--lock`, `--evidence-dir`, `--execution-id`, `--continue-on-failure`),
  `install-package`, `detect`, `handlers`, `version`.
- Handlers for `msi`, `exe`, `powershell` and `psadt`; validators for file, registry,
  service and command.

**`runner-image`** (branch `add-more-items`, unmerged):

- `scripts/download-packages.sh` takes `--lock <lock.yaml>`, `--output <dir>` and
  `--mount-root`, and for each `.packages[]` entry reads `name`, `version`, `repository`,
  `path`, `filename`, `sha256` and `sizeBytes`, copies the artifact out of the package
  content repository and fails closed on a size or SHA-256 mismatch. Default mount root
  `/mnt/image-factory/package-content`.
- The Dockerfile on this branch adds `yq` and installs the script to
  `/usr/local/bin/download-packages`.
- A `download-packages.bat` sibling exists, INFERRED to be the guest-side equivalent.

**`ci-platform`** (branch `main`): `templates/pipeline.yml` (the `build` and
`publish` stages `runner-image` includes), `scripts/publish-image.sh` and
`scripts/cleanup-publish-image.sh`.

### The recipe format is the successor of the baseline manifest (INFERRED)

The two formats are near-isomorphic. The baseline manifest's `baseline: {name, version}`
maps to the recipe's `metadata`, both carry the same four-field `target` block, and the
recipe's `baselineClassification` looks like the baseline-name concept. The difference is
where per-package detail lives: the manifest inlines `location` and `sha256`, while the
recipe defers both to a `PackageDefinition` and adds `installOrder` and `failurePolicy`.

This answers the previous revision's main objection. That revision recorded that the
baseline manifest "carries no installer type, silent arguments, install order, install
scope, post-install check, or accepted exit codes". The recipe and definition pair supplies
handler, timeout, `successExitCodes`, `installOrder` and `failurePolicy`. Only **install
scope** is still absent, and ADR 0002's generalization check needs it.

## Decision

Accepted 2026-09-28. The items below keep their original PROPOSED wording as the record of
how the decision was reached; **Contract terms (STORY-09)**, the next section, is what was
agreed and takes precedence where the two differ — notably decision 4, whose embedded
`lockHash` is replaced by a sidecar hash file (C1).

1. **Consume, do not duplicate.** Unchanged. This repository does not add its own install
   engine or a competing manifest.

2. **The resolved lock file is the contract.** PROPOSED: `ImageRecipeLock` is the single
   artifact that crosses the seam between the image build and the package tooling. The
   build treats it as opaque and immutable: it never parses package semantics, never
   chooses a handler, and never resolves a version. It passes the lock to tooling that
   already understands it.

   The strongest evidence that this is the intended design is that it is already half
   built. `runner-image`'s `download-packages.sh` consumes the `package-runner` lock format
   field for field, on the runner, before the build transfers anything. Neither repository
   references the other, but the file format matches exactly.

3. **The resulting flow.**

   | Step | Where | Tool | Output |
   |------|-------|------|--------|
   | 1. Resolve | Anywhere, pinned and committed | `package-runner resolve --recipe … --output …` | `ImageRecipeLock`, with its expected SHA-256 committed in this repository (C1) |
   | 2. Stage and verify | The runner, inside the `runner-image` image | `download-packages --lock … --output packages/` | Verified artifacts on the runner |
   | 3. Transfer | The runner to the guest | Packer `file` provisioners (this repository) | Artifacts, the lock and the runner binary in `C:\Packer\staging` |
   | 4. Install and re-verify | The guest | `package-runner install --lock … --artifact-root … --evidence-dir … --execution-id …` (C3) | Installed software plus `install-result.json` (C4) |
   | 5. Collect | The runner | `scripts/runner/collect-evidence.sh` (this repository) | `evidence/` |

   Rows 1 and 4 updated 2026-09-29 to the agreed Contract terms.

   Steps 1, 2 and 4 are owned outside this repository. Steps 3 and 5 are owned here. That
   is the whole interface.

4. **Hash authority: the lock.** This supersedes the previous revision's proposal. The
   expected SHA-256 lives in the `PackageDefinition`, is frozen into the lock at resolve
   time, and every later check compares against the lock. The catalog's `sha256sums.txt`
   becomes an input to authoring a definition, not a runtime authority, and the baseline
   manifest's inline `sha256` disappears with the manifest. The `lockHash` makes the whole
   set tamper-evident.

5. **Where the tooling runs: both sides, same lock.** The previous revision listed this as
   an open question. PROPOSED: the runner verifies before transfer and the guest
   re-verifies after it, and both read the same lock. This satisfies the engineering rule
   for host verification and guest re-verification without a second format.

6. **Ownership.** As understood, and to be confirmed:

   | Area | Owner |
   |------|-------|
   | Packer template, vSphere, ISO intake, guest bootstrap, sealing, build evidence, transfer into the guest | This repository |
   | The runner image and the tools on it, including the staging entry point | `runner-image` owner |
   | The CI publish and promote mechanism | `ci-platform` owner |
   | The software catalog, the recipe, package definitions, the resolver and install behavior | `package-runner` and catalog owner |

7. **Until the contract is implemented** (agreed 2026-09-28; STORY-05 and STORY-04), the build stages and verifies only the fixture package
   (Interim staging below) and has no install step. The provisional scripts were deleted
   on 2026-09-29, and `scripts/runner/validate.sh` no longer validates packages.

## Contract terms (STORY-09)

**ACCEPTED 2026-09-28, as written below**, between this repository (the image-build owner) and the
`package-runner` and `runner-image` owner (the tooling owner). Proposed the same day as the agenda for that
conversation; the answers to the owner's questions are recorded at the end of this section,
together with the three points carried into implementation and who implements what.

**Clarified 2026-09-29**, after review, without changing what was agreed: where the lock's
trust anchor lives and what the sidecar check does and does not protect against (C1), what
`path` includes and which tool takes which flag (C2), which exit code wins when outcomes mix
(C3), that `restart_required` is never a *final* status, and how the build runs the
post-restart check (Who implements what). Each is marked "Clarified 2026-09-29" below.

Evidence below was re-read from `package-runner` branch `init` at `4881c5d` on 2026-09-28.
That is newer than the 2026-09-22/23 reads elsewhere in this ADR, and several findings
changed; see "Re-read 2026-09-28" below.

### The shape: one input, one invocation, one output

"The lock is the contract" (decision 2) hides four separate agreements, and every defect in
the register is a disagreement about one of them.

```
        package-runner owns                      │  image-factory owns
                                                 │
 recipe + definitions ──resolve──► LOCK ─────────┼──► vendored + pinned, with the binary
                                    │            │          │
      runner-image: download-packages reads LOCK    │          ▼ Packer file provisioners
                                    │            │    C:\Packer\staging\packages\<layout>
                                    ▼            │          │
                          (C1) lock schema       │          ▼
                          (C2) staging layout ◄──┼── package-runner install …  (C3) invocation
                                                 │          │
                          (C4) evidence schema ──┼──► install-result.json → collect-evidence.sh
```

**Deliberately outside the contract:** the recipe format, how a `PackageDefinition` is
authored, handler internals, how each validator works, and the `resolve` command. This
repository reads none of them, which is decision 2's rule that the build "never parses
package semantics". What *is* inside the contract is what the runner guarantees about the
outcome — see "What installed correctly means".

### C1 — Lock schema

`package-runner` publishes it; this repository and `runner-image` read it.

- **A published JSON Schema**, for example `schemas/image-recipe-lock.v1.schema.json`,
  versioned by `apiVersion`, that **rejects unknown fields**. Today unknown fields are
  silently accepted, which is why the `restartExistCodes` typo (D15) is part of the wire
  format: the correct spelling is ignored rather than refused. Fix the spelling to
  `restartExitCodes` before the schema is frozen.
- **Integrity through a sidecar file, not an embedded `lockHash`.** An embedded hash needs a
  written canonicalisation rule, and none exists (the fixture's first `OPEN` marker). A plain
  `sha256sum`-format sidecar, `<lock>.sha256`, replaces it. This amends decision 4, which
  relied on `lockHash`.

  **Clarified 2026-09-29 — the trust anchor is this repository, not the sidecar.** A sidecar
  that travels with the lock detects corruption, not tampering: anyone who can change the
  lock can change the sidecar beside it. So the **expected lock SHA-256 is committed in this
  repository alongside the vendored lock**, and changes only through a reviewed commit here.
  The checks then do different jobs:

  | Check | Against | Catches |
  |---|---|---|
  | `sha256sum -c` on the runner, before upload | the committed hash | a lock that is not the one this repository reviewed and pinned |
  | The runner binary in the guest, before any handler | the same hash, uploaded with the lock | corruption in transfer |

  The guest check alone would prove nothing about tampering; it is the runner-side check
  against the committed value that makes "execute only from the pinned lock" enforceable.

  **Updated 2026-10-07, at the owner's request.** The guest check is optional in the runner:
  made when the sidecar is present, skipped when it is absent, and a mismatch is still exit
  11. This build still uploads the sidecar, so the check still runs here. See "The owner's
  review".
  A lock produced by `package-runner resolve` with its own sidecar is an input to that
  review, not the anchor.
- **Provenance inside the lock:** `generatedBy: package-runner <version>`, `recipeSha256`,
  and a per-package `definitionSha256`. This fixes D14 without a hash that refers to itself.
- **Fixed vocabularies.** One spelling for architecture — PROPOSED `amd64`, which the sample
  lock already uses; the resolver normalises rather than accepting both. A **closed set of
  `repository` values** (D4) — PROPOSED a single value, `package-content`, the governed
  file share, with the resolver rejecting any other. `repository` locates a file on the
  source side only; the guest never uses it.
- **`installScope`, required** (D13): PROPOSED values `machine-wide` and `per-user`, declared
  by the package definition and copied into the lock; `package-runner resolve` rejects a
  missing or invalid value. Enforcement stays with the consumer. **Clarified 2026-09-29:** no
  such check exists today — ADR 0002 is still Proposed. Once sealing is decided, the image
  build's generalization check will fail an image that contains a `per-user` package.
  **Updated 2026-10-02:** sealing was decided on 2026-10-01, and there is no generalization
  check: the master stays domain-joined and sysprep does not run (ADR 0002). The reason to
  classify packages stands, since a `per-user` install lands in the build account's profile
  and reaches no desktop user. Still no check exists. OPEN, for STORY-03: what the build
  does with a `per-user` package under a domain-joined master. PROPOSED: fail the build on
  one, the same rule as before with a different reason.
- **A list of files per package instead of one:** `artifact.files[]` of `{path, sha256,
  sizeBytes}`, plus `install.entryPoint`. The fixture already needs this (a payload and an
  `install.ps1`), and so do the `powershell` and `psadt` handlers, since a script or a PSADT
  folder is never a single file.

### C2 — Staging layout

- One rule for both sides: **`<artifact-root>/<name>/<version>/<files[].path>`**. `path` is
  relative, uses forward slashes, and contains no `..` and no leading slash. This fixes D5 and
  D6; the current sample lock still breaks it (Windows separators, and a leading `/` on
  putty's filename, D16).
- `download-packages` writes exactly this layout on the runner, Packer uploads it unchanged to
  `C:\Packer\staging\packages`, and `package-runner` reads it from the root it is given with
  `--artifact-root`. Today the executor resolves artifact paths against its working
  directory, which is why the two sides do not line up.
- **Clarified 2026-09-29.** `files[].path` **includes the filename**: it is the file's path
  relative to `<name>/<version>/`, for example `install.ps1` or `bin/setup.exe`. Only
  `package-runner` takes `--artifact-root`. `download-packages` writes the same layout under
  the directory it is given with `--output`, which Packer then uploads as the artifact root;
  its `--mount-root` still names where it reads from on the source side.

### C3 — Invocation

The exact command:

```
package-runner.exe install --lock <path> --artifact-root <dir> --evidence-dir <dir> --execution-id <CI job id>
```

Required behavior:

- **Before any handler runs:** check the lock's sidecar hash, then recompute the SHA-256 and
  size of every file in `files[]` against the lock (D8). This is what lets
  `packer/provisioners/Test-StagedPackage.ps1` retire.
- **Check elevation at startup** and fail with its own exit code (D28). The committed PuTTY
  run failed with MSI error 1925, insufficient privileges, which surfaced as a confusing
  per-package `1603`.
- **Enforce each package's `timeout`** (D11).
- **Never reboot.** A needed restart is reported; the build owns the machine's lifecycle and
  the WinRM channel.
- **Stop at the first failed package** unless `--continue-on-failure` is given (D27), and
  never install a package whose dependency failed (D25).

  **Reversed 2026-10-07, at the owner's request.** The runner carries on after a failed
  package, so one run reports every failure, and still exits 10; only the dependents of a
  failed package are skipped. `--stop-on-failure` gives the term as first agreed. See "The
  owner's review".
- **A small documented set of exit codes**, so Packer's `valid_exit_codes` can tell them
  apart. PROPOSED values, negotiable:

  | Code | Meaning |
  |---|---|
  | 0 | every package installed correctly |
  | 10 | a package failed |
  | 11 | integrity or lock failure (sidecar, file hash, size, unsupported `apiVersion`) |
  | 12 | not elevated |
  | 3010 | every package installed correctly, and at least one needs a restart |

  **Clarified 2026-09-29 — which code wins.** Any failure code beats 3010: 3010 is returned
  only when nothing failed. Among the failures the order of the checks decides, and only
  one can be reached: 12 is checked at startup, 11 before any handler runs, 10 during the
  run. So a run where one package fails and another needs a restart exits 10.

On this repository's side, the template accepts all of these, downloads the evidence, and
only then fails the build on anything other than 0 or 3010. That closes the limit recorded in
`docs/evidence.md`, where a failed step leaves its evidence stranded on the VM. On 3010 the
template runs a `windows-restart` provisioner and then the post-restart check below.

### What "installed correctly" means

The one rule about validation that the contract must carry, even though validator internals
stay outside it. A package is reported `success` only if **all** of these hold:

1. Every file's recomputed SHA-256 and size match the lock.
2. The exit code is in `successExitCodes`; or it is in `restartExitCodes` and the checks below
   pass after the restart.
3. The package's declared validation passed.
4. A validator that fails, errors, or is not implemented is a failure, never a skip.

`validation_failed` is a failure. `restart_required` is **never a final status**
(clarified 2026-09-29): it means "installed, not yet checked". The package's final status is
set by the post-restart check — `success` if it passes, a failure if it does not. A restart
followed by a passing check is therefore a success, as condition 2 says.

Today neither status counts as success or failure, so `install` exits 0 and a build would
pass (D22), and a package that needs a restart is never validated at all (D23).

OPEN: how the post-restart check is invoked. PROPOSED: a second, read-only invocation against
the same lock (for example `package-runner verify --lock … --evidence-dir …`) that runs the
validations and writes its own evidence. `detect` exists, but its semantics have not been
read.

### C4 — Evidence

- **Always write `install-result.json`** into `--evidence-dir` before exiting, pass or fail.
  If it cannot be written, exit non-zero. That filename already maps to the `install` role in
  `scripts/runner/collect-evidence.sh`; the current `package-execution-evidence.json` would
  be indexed as `other` (D12).
- **One fixed file at a fixed guest path**, PROPOSED `C:\Packer\evidence\install-result.json`.
  INFERRED, to verify before agreeing: Packer's WinRM communicator downloads named files, not
  directories, so the build needs a name it knows in advance.
- **Fields**, snake_case throughout (the current file mixes `OverallSuccess` with `status`):
  `schema_version`, `execution_id`, `runner_version`, `lock_sha256`, `outcome` (`success`,
  `failed`, `degraded`), `publication_eligible`, and per package: `name`, `version`, `status`,
  `exit_code`, `duration_ms` (today durations are Go nanoseconds), `timed_out`,
  `restart_required`, the SHA-256 **computed** for each file, and the validation result.
  UTC timestamps (`…Z`); today they carry a local offset. UTF-8 without a byte order mark,
  so the runner's `jq` reads it.
- **Installer stdout and stderr are redacted and size-capped, or omitted.** Today they are
  written raw. `collect-evidence.sh`'s secret guard stays the backstop, not the control.
- An optional JSON Lines log, if wanted, is named `install-log-<ts>.jsonl`; this repository
  adds a `role_of` pattern for it.

### Versioning

This repository vendors the lock at a pinned version, with its expected SHA-256 committed
beside it as the trust anchor (C1; the Open questions below already prefer vendoring), and
pins a **tagged** `package-runner` release by SHA-256
(D18). The runner rejects any `apiVersion` it does not support. A breaking change to C1–C4
bumps that version, so a consumer is never broken by accident.

### How the terms close STORY-09

| STORY-09 AC | Closed by |
|---|---|
| 1. The lock accepted or rejected as the contract artifact | C1 and Versioning |
| 2. One canonical set of `repository` names | C1 (closed set) and C2 |
| 3. Install evidence JSON shape and guest path | C4 |
| 4. `installScope` as a required `PackageDefinition` field | C1 |
| 5. The restart contract, including exit 3010 | C3 (exit codes, never reboot) and the post-restart check |
| 6. The installed-state definition | "What installed correctly means" |
| 7. ADR 0003 moves to Accepted | Every term above agreed, 2026-09-28 |

### Questions put to the owner, and the answers (2026-09-28)

| # | Question | Answer |
|---|---|---|
| 1 | Sidecar `.sha256` instead of an embedded `lockHash`? | Agreed |
| 2 | `installScope` values | Agreed: `machine-wide`, `per-user` |
| 3 | `files[]` plus `entryPoint` for multi-file packages | Agreed |
| 4 | Exit codes | Agreed: 0, 10, 11, 12, 3010 as in C3 |
| 5 | The post-restart check | Approach agreed (a second, read-only invocation against the same lock); **command name and flags carried into implementation** |
| 6 | Evidence fields and guest path | Agreed as in C4 |
| 7 | Only `package-content` as a `repository` value? | Agreed |
| 8 | Provenance in a hand-written lock (`resolvedFrom`, `recipeSha256`, `definitionSha256`) | **Carried into implementation**: no answer was proposed |
| 9 | **Added 2026-10-02, not yet put to the owner.** Restart codes other than 3010, for the Citrix VDA installer (ADR 0002, requirement 5): can a package definition list its own `restartExitCodes` (3 and 8), and can one of them mean "restart, then run the installer again"? | **Requested change to C3.** C3 anticipates only 3010, and no "run again after the restart" step exists on either side. The codes' meanings are INFERRED from Citrix documentation and are to be verified for the VDA version in use before this is raised |

Also carried into implementation: C4's INFERRED premise that Packer's WinRM communicator
downloads named files rather than directories. Verify it before the build side is written;
it decides only how the build fetches the evidence, not the file's name or shape.

### Who implements what

| Owner | Work | Covers |
|---|---|---|
| The tooling owner, `package-runner` (STORY-05, in progress) | C1 schema, sidecar, provenance, vocabularies, `installScope`, `files[]`/`entryPoint`, `restartExitCodes` spelling; C3 behaviour and exit codes; the installed-correctly rule; C4 evidence; a tagged, hashed release | D8, D9, D11, D12, D13, D14, D15, D18, D22–D25, D27, D28 (and D26 before any package declares a dependency) |
| The tooling owner, `runner-image` | C2 layout in `download-packages`, including rejecting `..` and absolute paths and leaving only verified files in the output tree; deleting `download-packages.bat`; and a tagged release carrying it | D1–D7, D29–D32 |
| This repository (STORY-04, future) | Vendor the lock and commit its expected SHA-256, verify the lock against it on the runner before upload, pin the runner release by hash, upload the C2 layout, run the C3 command, accept its exit codes and download the evidence before failing, restart on 3010 and run the post-restart check, index `install-result.json`, enforce `installScope` once ADR 0002 is decided; retire `verify-package.sh` and `Test-StagedPackage.ps1` once D8 is fixed; restate the fixture lock in the C1 format. **The post-restart check is the first command after a reboot** — exactly where `environment_vars` delivery failed in STORY-01 (ADR 0001 addendum) — so it uses the proven pattern: upload the script with a `file` provisioner, set its inputs as `$env:` assignments in an `inline` block, and end with `exit $LASTEXITCODE`. | — |

### Build side written (STORY-04, 2026-10-01)

This repository's row in the table above is implemented, against a stand-in. **Status of the
evidence:** every script was run on the workstation, both Packer files validate, and **the
sequence was proved in CI on 2026-10-01** (commit `5b34a5c`): one full build and one harness
run per forced exit code. What the guest does is OBSERVED for the stand-in and the fixture.

| CI job | Run | Result (OBSERVED 2026-10-01) |
|---|---|---|
| 3836 | `packer-build-diagnostic`, full build | Passed in 24m59s. The directory upload created `C:\Packer\staging\packages`; install exit 0; `install-result.json` and `install-result-verify.json` downloaded; no restart; cleanup removed every target and the Panther scan found no `<Password>` element in 7 XML files. |
| 3835 | `staging-harness`, forced 10 | Failed, as intended, **after** `install-result.json` was downloaded and indexed. |
| 3837 | `staging-harness`, forced 11 | The same. |
| 3838 | `staging-harness`, forced 12 | The same. |
| 3839 | `staging-harness`, forced 3010 | Passed: outcome `degraded`, the guest restarted, `verify` returned 0 and its result was downloaded. |

The harness ran against the VM job 3836 built (`packer-build-002`), powered back on. A
plain harness run was not made: the full build covers that case. The build could be played
without `verify-iso-datastore`, so the `needs` change to the build jobs is OBSERVED too.

What these runs do not show: the codes were **forced**, so no real package failure, tampered
file or unelevated session has been produced in a guest (those cases were run against the
stand-in on the workstation only); and the stand-in's timeout path has never been run.

| Piece | Where | State |
|---|---|---|
| Vendored lock, expected SHA-256 committed beside it | `packer/fixtures/software/windows-vm-fixture.lock.yaml` and `.sha256` | The fixture restated in the C1 shape. One committed file is both the trust anchor and the sidecar that travels with the lock. |
| Lock and binary verified on the runner before upload | `scripts/runner/stage-packages.sh` | OBSERVED 2026-10-01: a changed lock, a changed binary, a missing hash file and a missing artifact root each exit 1 and write `package-stage-<ts>.json`. |
| Runner release pinned by hash | `PACKAGE_RUNNER` in `stage-packages.sh` | Pins the stand-in. No release exists to pin (D18). |
| C2 layout uploaded | the template's `file` provisioner with a trailing-slash directory source | OBSERVED 2026-10-01 (jobs 3835 to 3839): the `packages/` tree arrives, and the stand-in finds and hashes the files in it. |
| C3 command, exit codes accepted, evidence downloaded before failing | the template's install sequence | Accepts 0, 10, 11, 12 and 3010, downloads `install-result.json`, then fails on anything but 0 or 3010. |
| Restart on 3010 | a `windows-restart` provisioner whose restart command acts only when the recorded exit code is 3010 | OBSERVED 2026-10-01 by contrast: with exit 0 (job 3836) Packer reported the guest back 9 seconds after "Waiting for machine to restart", too short for a restart; with 3010 (job 3839) it took 2m34s. Packer prints "Restarting Machine" in both cases. On the real restart Packer also printed `A system shutdown has already been scheduled.(1190)` in red: INFERRED to be the provisioner's own probe for a pending restart meeting the one already scheduled, and harmless. |
| Post-restart check | `package-runner verify`, same four flags, literal arguments | **The command name `verify` is this repository's assumption** (owner's question 5). It runs on every build, restart or not. |
| `install-result.json` indexed | `collect-evidence.sh` | The `install` role already matched. |

Not done, and why: `installScope` enforcement waited on ADR 0002, which was decided on
2026-10-01, and is now an open item for STORY-03 (see C1, updated 2026-10-02); `verify-package.sh` stays as
the interim package-file check until `download-packages` works (D1–D7); `Test-StagedPackage.ps1`
is no longer called and is marked deprecated, pending the owner's agreement to delete it.

**The stand-in** (`packer/fixtures/package-runner/package-runner.ps1`) is a test double, chosen
by the owner on 2026-10-01 so the build side could be proved before STORY-05 lands. It
implements the C3 command line, the checks C3 requires before any handler runs (elevation,
sidecar, every file's size and SHA-256), the exit codes, and C4's result file, for the
`powershell` handler and the `file` validator only. It is not an install engine and must not
grow into one: decision 1 stands. It also makes this repository's reading of C1 concrete, so
**the lock's field names are ours until the schema is published**.

**The swap is gated.** Replacing the stand-in with a `package-runner` release removes the
guest-side re-verification the stand-in performs, so it must not happen before that release
recomputes hashes (D8) and fails on a failed validation (D22). Until then a real binary would
pass builds the stand-in fails.

**C4's premise is confirmed** (OBSERVED 2026-10-01, `packer-plugin-sdk` `main`,
`sdk-internals/communicator/winrm/communicator.go`): `DownloadDir` returns
`WinRM doesn't support download dir.`, so the build does need a file name it knows in advance.
The same read found that `Download` discards the remote command's result, so **downloading a
missing file does not fail**; the template therefore checks that the result file exists in
the install step itself, where a missing file can still stop the build.

**Two additions for the owner**, neither changing what was agreed: the result carries a
top-level `exit_code` and `command`, and the installer's stdout and stderr are written to
`<evidence-dir>\<name>-<version>-stdout.log` and `-stderr.log` in the guest and omitted from
the result.

### Read 2026-10-01 (OBSERVED, `package-runner` `init` at `8e538aa`)

Four commits past `4881c5d`. Only the diff of `cli.go`, `executor.go`, `models.go` and the
sample lock was read, not the whole tree. None of C1–C4 has landed: there is no
`--artifact-root`, no `install-result.json`, no contract exit code, and still no tag. The
sample lock keeps the old shape (`lockHash`, `repository: packages`, one `filename`, Windows
separators); it now lists two packages, still with one shared `sha256`. What changed is
validation: `validation` is now a list, the live validators moved to `internal/validators/`
(the package D10 called unreachable), and `internal/validation/` was deleted. D8–D10 were
re-read against the new package on 2026-10-02: see the next section.

- **D33 — A validation that fails, or names an unknown handler, crashes the run instead of
    failing it.** `executor.go:284-299`: when `NewValidator` returns an error the code logs
    "Skipping validation" and then calls `validator.Validate()` on the nil it was given; and
    when `Validate` returns a non-success result with a nil error, the log call evaluates
    `err.Error()` on that nil. Both are nil dereferences. INFERRED by reading; not run.

### Read 2026-10-02 (OBSERVED, `package-runner` `init` at `8e538aa`; `runner-image` `main` at `a321d26`)

`git ls-remote` on 2026-10-02 shows nothing newer than these two commits, and
`ci-platform` unchanged at `2cae5b0` (tag `0.0.14`). This read closes the
partial one above: every Go file on the install path was read in full, and each
`package-runner` entry in the register was checked against the code as it is now. Nothing
was run except a compile.

**D34 — the head of `init` does not compile.** `git archive 8e538aa`, extracted outside the
clone, fails `go build ./...`: `internal/executor/executor.go:16` and
`internal/validators/file_validator.go:13` import `package-runner/internal/pathutil`, a
package that is in no commit of the repository, and `internal/cli/cli.go:151` calls
`validators.NewLockValidator`, which existed only in the deleted `internal/validation/`
package. The first break is `626e691` (2026-09-29); `4881c5d`, built the same way, compiles.
So no commit since 2026-09-24 can be built from source control, and any binary the owner has
run since then came from a working tree that holds files the repository does not. This
matters to C3: a release has to be buildable from a commit before it can be pinned by hash.

| Entry | State at `8e538aa` | Where |
|---|---|---|
| D8 | **Stands.** `validateArtifact` still checks only a non-zero size and a 64-character hash; nothing on the install path hashes a file. The `verifyFileHash` stub it was first recorded against is gone with its package. | `executor.go:323-333` |
| D9 | **Changed.** The live validators are now the `internal/validators/` ones. `file` recomputes SHA-256 and compares size, but a `version` parameter always fails, because `getFileVersion` returns an empty string. `registry` and `command` are implemented. `service` prints "Service validation simulated" and returns success unconditionally. | `file_validator.go:74-109`, `service_validator.go:58-62` |
| D10 | **Changed.** `internal/validators/` is no longer unreachable: it is the package the executor calls, so the false-passing `service` validator D10 warned about is now live. `internal/schema/` still has no importer. | `executor.go:284` |
| D11 | Stands. Three handlers still create the timeout after `cmd.Start()`, and the executor still passes `context.Background()`. | `exe.go:92`, `powershell.go:100`, `psadt.go:87`, `executor.go:217` |
| D12 | Stands. Same file name and shape. | `executor.go:356-381` |
| D13 | Stands. No install scope and no elevation term anywhere in the Go or YAML. | search |
| D14 | Stands. | `resolver.go:91-92`, `:167`, `:477` |
| D15 | Stands, and the new README spells the field `restartExitCodes`, the spelling the code ignores. | `models.go:134` |
| D18 | Stands: no tags, no CI file, no test files. | tree |
| D22, D23, D24 | Stand. | `executor.go:152-177`, `:281`, `:305-317` |
| D25, D27 | Stand. The committed evidence was replaced by a two-package run on 2026-10-01 (putty succeeded, firefox failed with 1603), so it no longer shows a later package running after a failure; the code still does. `PublicationEligible` is still `true` beside a failed package. | `executor.go:124-135`, `:152-171` |
| D26 | Stands; traced by reading, not run. | `resolver.go:417-425` |
| D28 | Stands in the code. The MSI log it cited, `evidence/putty/instal.log`, was removed upstream. | search |
| D33 | Stands, now read in the whole function, not the diff. Still not run. | `executor.go:284-298` |

**The owner's README and the code disagree in three places.** A 368-line `README.md` arrived
with these commits. It is the first statement of intent from the owner, and it is consistent
with the agreed design (an immutable lock, an allow-list of handlers, validators, structured
evidence). It also says more than the code does: "Comprehensive Validation: Artifacts
(SHA-256, size)" against D8; a `service` validator that "queries service status" against the
simulated one; and `restartExitCodes` against D15. None of C1–C4 appears in it: there is no
`--artifact-root`, no `install-result.json` and no contract exit code.

**`runner-image`: `main` was rebuilt, not merged forward.** `0.1.0` is `a321d26`, a merge of one
commit, `d752d5b` ("[STORY-14] - add govc"), whose parent is `2654d2f`. That one commit
carries everything `dev-branch` and `add-more-items` had, plus `govc`. So tag `0.0.20`
(`1dac874`) and `5c740bd` are **not ancestors** of `main`, the `add-more-items` branch no
longer exists on the remote, and `main` is now the newest content, where on 2026-09-23 it was
the oldest. There are 22 tags over four commits. `download-packages.sh` is byte-identical to
the `5c740bd` copy and still fails `bash -n` at line 16 (D1, re-run 2026-10-02). The
Dockerfile matches what D20 records, and `.gitlab-ci.yml` still includes the template at
`ref: "main"` (D21).

### Read 2026-10-05 (OBSERVED, `runner-image` `adjust-script` at `671e967`)

A fetch on 2026-10-05 found one new ref across the three repositories: `runner-image` branch
`adjust-script`, two commits by the owner on 2026-10-02 ("update script", "publish a new
image to test"), changing `scripts/download-packages.sh` and one blank line of the README.
`main` and tag `0.1.0` are unchanged, so **the image this repository pins is unchanged**.
`package-runner` (`8e538aa`) and `ci-platform` (`2cae5b0`) have nothing new.

The script was read in full and run in a scratch folder on the workstation (Git Bash, `yq`
v4.53.3) against hand-written locks. Not run: anything in a pipeline, or on Linux.

| Run | Result |
|---|---|
| A correct lock, `--mount-root` given | Staged to `<output>/<name>/<version>/<filename>`, hash verified, exit 0 |
| A wrong `sha256` | Reported, the copied file deleted, output tree empty, exit 1 |
| No `sha256` and no `sizeBytes` | **Copied unverified, reported "downloaded and verified successfully", exit 0** (D35) |
| An unknown `repository` name | Accepted; staged from the mount root, exit 0 |
| `path: ../outside` | **A file outside the mount was copied into the output tree, exit 0** (D31) |
| This repository's fixture lock (C1 shape, `files[]`) | Failed: `Source artifact not found: …/null`, exit 1 |

| Entry | State on `adjust-script` | Where |
|---|---|---|
| D1, D2, D3 | **Fixed.** The script parses, assigns its variables, and honours `--mount-root`. | `:4-16`, `:69-85`, `:26` |
| D4 | **Changed, not closed.** The misspelling is gone, but any repository name is now accepted. | `:45-49` |
| D5 | **Fixed for the nested shape.** Reads `artifact.*`; the `.bat` is unchanged. | `:81-85` |
| D6 | Stands. The output layout matches C2 for one file, but the source is still `<mount>/<path>/<filename>` from a lock whose sample uses Windows separators; not tested on Linux. | `:91-93` |
| D7 | Stands: unmerged, untagged, in no released image. A test image built from the branch is INFERRED from the commit message. | refs |
| D31 | **Stands, now tested.** | `:91-93` |
| D32 | **Fixed.** A failed file is removed. | `:113`, `:124` |
| D35 | **New.** A missing hash or size skips its check, and the entry counts as verified. | `:84-85`, `:111`, `:119` |
| D29, D30 | Stand: `download-packages.bat` is unchanged and still in the repository. | — |
| D20, D21 | Stand: the Dockerfile and `.gitlab-ci.yml` are unchanged. | — |

Against the contract: the branch moves the runner half of step 2 from "cannot run" to "runs
for the owner's current lock shape". It does not yet implement C1 and C2 as agreed: it reads
one `filename` where C1 has `files[]`, it does not reject `..` or an absolute path (C2), and
it writes no result file (the runner-side evidence gap under "Still open"). So this
repository cannot switch to it yet, and `verify-package.sh` stays. D35 is the one to raise
first, because it is a fail-open in a check that exists to fail closed.

### Read 2026-10-06 (OBSERVED: `runner-image` `0.2.1` at `d730652`, `package-runner` `init` at `7f73e52`, `runner-test-bed` `test-runner` at `570a4ee`)

A fetch on 2026-10-06 found the owner's work on all sides of the runner half.

**`runner-image` released the reworked staging tool.** `adjust-script` was merged to `main`
(`d730652`) and tagged `0.2.0` and `0.2.1`, both on that commit. `scripts/download-packages.sh`
is byte-identical to the branch copy read and run on 2026-10-05, so that read stands for the
release: D1, D2, D3 and D32 are fixed in a released image, D5 is fixed for the nested lock
shape, and D31, D35 and D4 are as recorded. The Dockerfile is unchanged (D20), and
`.gitlab-ci.yml` still includes the template at `ref: "main"` (D21).
`download-packages.bat` changed substantially and was **not** re-read, so D29 and D30 are
unverified against it; it is still not copied into the image.

**The runner half now runs on the runner this repository uses.** `runner-test-bed` is a
fifth repository in the group, the owner's test bed: one job, `test:download`, on the
`shared-medium` runner with image `runner-image:0.2.1`, running
`download-packages --lock ./windows-vm.lock.yaml`. Its lock is the `package-runner` sample
lock. From the job log of 2026-10-06 06:38 UTC, supplied by the image-build owner:

| Fact | Evidence in the log |
|---|---|
| The job ran on `runner-01`, Docker executor, and succeeded | `Preparing the "docker" executor`, `Job succeeded` |
| Image `0.2.1` on that host | image ID `sha256:8281ad65…`, digest `sha256:62c3d2b8571f1d8bdccae8116b4d2e65ffce08d340e4ba3aa278ad315aadc038` |
| The job runs as root in its container | `whoami` printed `root` |
| The package share is mounted in the job container | `Mount root: /mnt/image-factory/package-content`, and both sources were found there |
| Two real packages staged and hash-verified | Firefox 156.0.1 (92,909,568 bytes) and PuTTY 0.83.0 (3,508,736 bytes), `All 2 packages downloaded and verified successfully` |
| Copying and hashing 93 MB took under one second | Timestamps 06:38:23.55 to 06:38:24.37 |

This closes the question of whether the share reaches a job on this runner, and it supplies
the digest for the pin without a discovery pipeline. **The pin moved to `0.2.1` on
2026-10-06**, and a full build in the new image passed on 2026-10-07 (job 4015, commit
`0f9e429`, 24m02s). Nothing here calls `download-packages` yet.

**`package-runner` moved, and the guest half is still not usable.** Seven commits on
2026-10-05 (`8e538aa` to `7f73e52`):

| Entry | State at `7f73e52` |
|---|---|
| D34 | **Stands.** `git archive` of the commit, extracted outside the clone, still fails `go build ./...` on the missing `internal/pathutil`; `cli.go:151` still calls the missing `NewLockValidator`. |
| D8 | Stands. `validateArtifact` (`executor.go:347-357`) is unchanged: size non-zero, hash 64 characters. |
| D18 | Stands. No tag, no CI file, no test files. |
| C1–C4 | Not landed. `install` takes `--lock`, `--evidence-dir`, `--execution-id`; there is no `--artifact-root`, no `install-result.json`, no contract exit code (the binary exits 1 or 0), and no `verify` command. |
| D16 | **Improved.** The sample lock's two packages now carry distinct, real hashes and sizes, and forward-slash paths (`./firefox/156.0.1`). PuTTY's `filename` still has a leading `/`, which both tools tolerate. |
| D15 | Stands (`models.go:134`). |
| D33 | Not re-analysed. The diff adds a second copy of the validation block the finding is in. |
| Evidence | A run on 2026-10-05: PuTTY succeeded, Firefox failed with 1603; `PublicationEligible` is `true` beside the failure (D27's symptom). |

**The owner's two tools now agree with each other, in a shape that is not C1.** INFERRED from
reading both, not run in a guest: `download-packages` writes
`packages/<name>/<version>/<filename>`, and `package-runner` joins `repository` (`packages`),
`path` (`./firefox/156.0.1`) and `filename` relative to its working directory, which is the
same relative path if it runs from the folder that holds `packages`. So D6 is resolved in
practice for her lock, by convention and not by `--artifact-root`. But that lock is the
pre-contract shape: one `filename` per package, no `files[]`, no `entryPoint`, no
`installScope`. This repository's fixture lock and stand-in use the C1 shape, and
`download-packages` cannot read it (run 2026-10-05). **So the two sides cannot be joined
until one shape is chosen.** That is a decision for the two owners: implement C1 as agreed,
or amend this ADR to the shape that is running. The Packer template is indifferent (it never
reads the lock); the fixture lock and the stand-in are what would change.

What each placeholder here waits on:

| Placeholder | Replaced by | Waits on |
|---|---|---|
| ~~`verify-package.sh`, `software-baseline-fixture.yml`, `sha256sums.txt`~~ | `download-packages` | **Replaced and deleted 2026-10-07** (see "Interim lock shape"). D31 and D35 are still open, covered by the committed lock hash |
| The fixture package and lock | A vendored, resolved lock with its committed hash | The shape decision |
| The stand-in `package-runner.ps1` | A `package-runner` release pinned by hash | A commit that builds (D34) and a tag (D18); hash re-verification in the guest (D8); failing on a failed validation (D22) |
| ~~`Test-StagedPackage.ps1` (unused)~~ | Nothing | **Deleted 2026-10-07**, with the owner's agreement |

### Interim lock shape (decided 2026-10-07)

**Decision (the image-build owner, 2026-10-07): for now the build reads the lock shape the owner's
tools read today. The contract terms C1 to C4 stay the strategic design and are not
amended.** This removes the blocker recorded on 2026-10-06 without waiting for either side
to change tools: the runner half of the flow now runs on the owner's real tool.

What "the owner's shape" is, per package: one file, named by `artifact.filename`, with
`artifact.sha256` and `artifact.sizeBytes`, located by `artifact.repository` and
`artifact.path`. C1 has a list (`artifact.files[]`), an `install.entryPoint` and a required
`installScope`.

What changed here on 2026-10-07:

| Piece | Before | Now |
|---|---|---|
| Fixture lock | C1 shape: two files, `entryPoint`, `installScope` | Owner's shape: one file, `install.ps1`, which the `powershell` handler runs |
| Fixture package | A payload and a script that copied it | One self-contained script that writes a marker file |
| Runner-side package check | `verify-package.sh`, a baseline manifest and `sha256sums.txt` | **`download-packages`** from the `runner-image` `0.2.1` image, called by `stage-packages.sh` |
| What Packer uploads | The fixture folder | `build/packages`, the tree `download-packages` wrote and verified |
| Stand-in | Read `files[]` and `entryPoint` | Reads `artifact.filename`; reads timeouts as Go durations (`5m0s`); accepts the owner's `restartExistCodes` and the agreed `restartExitCodes` |

Unchanged, because they are this repository's own and do not depend on the lock's shape: the
committed SHA-256 as the lock's trust anchor (C1), the staged layout
`<artifact-root>/<name>/<version>/<file>` (C2, which is also what `download-packages`
writes), the command line and exit codes the template uses (C3), and `install-result.json`
(C4). The stand-in still speaks C3 and C4, so the template did not change.

What is given up until the tools reach C1, and what stands in for it:

- **Only one file per package is verified.** A package that is more than one file cannot be
  described, so it cannot be used yet.
- **No `installScope`.** The build cannot tell a per-user package from a machine-wide one.
  The open question about per-user packages (C1, updated 2026-10-02) stays open.
- **`download-packages` does not reject a path that leaves the source root (D31) and counts
  an entry with no hash as verified (D35).** Both are reachable only through the lock, and
  the lock is vendored and pinned by a committed hash, so a lock that did either would have
  to pass review here first. The stand-in also refuses a package with no `sha256`, which the
  real engine does not.
- **`download-packages` writes no evidence** (the gap under "Still open"). Closed on this
  side: `stage-packages.sh` keeps the tool's output as `package-download-<ts>.log` and
  records the path, size and SHA-256 of every staged file in `package-stage-<ts>.json`.

Proof, 2026-10-07, on the workstation (`download-packages` taken from tag `0.2.1`, `yq`
v4.53.3; Windows PowerShell 5.1): `stage-packages.sh` staged the fixture with the released
tool and failed closed on a changed lock, a package file that does not match the lock, a
missing source root, an artifact root outside `build/packages`, and a missing tool (exit 2).
The stand-in passed 23 cases, including a real timeout, which had never been run. Both
Packer files validate.

Proof in CI, 2026-10-07, commit `95ee61d`, `runner-image` `0.2.1` (OBSERVED from the job logs).
The smoke test found `yq` and `download-packages`, now required. `packer-validate` reported
"Package staging passed … 1 file(s) staged". The full build, job 4074 (23m34s), staged the
fixture with `download-packages`, uploaded `build/packages` to `C:\Packer\staging\packages`,
and the stand-in ran the fixture script in the guest: install exit 0, verify exit 0 after the
restart, installed-state check passed. That is the first build in which the owner's released
tool staged what was installed. The rest of the build was unchanged: first-run setup
finished, no password in 7 Panther files, floppy removed, 11 evidence files indexed.

**Deleted 2026-10-07**, once job 4074 had proved the replacement and the owner of this
repository agreed: `scripts/runner/verify-package.sh`, `software-baseline-fixture.yml`, the
fixture's `sha256sums.txt` and payload, and `packer/provisioners/Test-StagedPackage.ps1`
(deprecated since 2026-10-01). Earlier sections of this record name them as they stood on
the day each was written; git history holds the files.

### Trial of a `package-runner` build (2026-10-07)

**Not a release.** D18 stands: the owner has tagged nothing. This is a build of a proposal,
made so the build side can be tried against a real executable. (D34 was closed the same
evening; see "The owner's review" below.)

The proposal is the image-build owner's branch `proposal/build-contract` in `package-runner` (his decision,
2026-10-07; none of the owner's branches is changed). It was written against the gap list
between the runner at `34bfc7f` and C3 and C4: the `--artifact-root` flag and the `verify`
command; `install-result.json` in the C4 shape; exit codes 0, 10, 11, 12 and 3010; the
elevation, sidecar and staged-file checks before any handler runs (D8, D28); stop at the first
failure (D27) and no install after a failed dependency (D25); a failed or absent validation
fails the package (D22); restart reporting (D23); and install timeouts, which no handler
enforced (D11). 42 Go tests pass on the workstation. It reads the interim lock shape, not C1.

The binary is `packer/fixtures/package-runner/package-runner.exe`, with its SHA-256 committed
beside it:

- Built from `c9f1439`, the head of that branch, from a `git archive` of the commit and not
  from a working tree. Every source file in it is the owner's or part of the proposal: the two
  stand-in files the first trial build carried are gone, replaced by hers.
- `GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-s -w
  -X main.Version=0.0.0-trial.2 -X main.Commit=c9f1439 -X main.Date=2026-10-08" ./cmd/package-runner`,
  with Go 1.26.5. Two builds gave the same hash: `b03b918af51bff3854df76a4817c924404664c70ef40fa79ec3bdb44d7a58051`.
- It replaces `0.0.0-trial.1` (`e523e19`, `87067e7976a6…`), which was committed here
  earlier the same day and never ran in a guest.
- Unsigned. The guest runs it: see job 4245 below.

Nothing uses it unless a job is played with `PACKAGE_RUNNER` set to that path. The default is
still the stand-in, so a build from `main` is unchanged.

One change the executable needed in the template and the harness: it writes its log to stderr,
which the stand-in never did. Windows PowerShell turns a native program's stderr into error
records in a session with no console, and a session that stops on errors would end at the
first log line. For an executable the install and verify steps now continue on errors and
merge stderr into the output as text; pass or fail is still decided from the exit code alone.
The stand-in's path is unchanged. INFERRED that the plain call would have failed under
Packer: it does not fail from a console on the workstation, and it was not tried in a guest.
With the change in place the runner's log lines arrive in the Packer output as plain text
(job 4245).

The harness gained one knob for any runner, `tamper_staged_file` (`HARNESS_TAMPER_STAGED_FILE`
in the job): it changes a staged file after the upload, so the install must end with 11. The
stand-in's forced exit codes do not apply to the executable, which has no such knob; 10, 12 and
3010 are covered by its own tests and by the template's handling, proved with the stand-in on
2026-10-01.

To prove: one full build with the executable (install exit 0, verify exit 0); and the harness
with the executable and the tamper knob (exit 11, nothing installed).

**Proved 2026-10-07: a full build with the executable** (OBSERVED from the log of job 4245,
commit `b2699cf`, `0.0.0-trial.2`, 25m03s, in a pipeline started with `PACKAGE_RUNNER` set).
It is the first build in which both halves of the install were the owner's tools and not
placeholders: `download-packages` staged the package on the runner, and `package-runner`
installed and checked it in the guest.

- Staging reported "package-runner package-runner.exe, 1 file(s) staged", so the runner-side
  check matched the committed hash, and the executable was uploaded to
  `C:\Packer\staging\package-runner.exe`.
- The guest ran the unsigned executable from an elevated WinRM session.
- `install` exited 0 and logged a `validation.evidence` entry for `testpkg` 1.0.0: `exists`
  expected true, actual true, with the marker file's SHA-256, size and modified time, the
  package name and version, and the execution id 4245, which is the job id.
- After the restart `verify` exited 0 with the same evidence, and the installed-state check
  passed.
- The rest of the build was as before: first-run setup finished, no password in 7 Panther
  files, floppy removed, 11 evidence files indexed.

Seen in that log and not this repository's to fix: the runner's console timestamps print the
year as 8086 (D38).

Not yet proved: the tamper case in the harness (exit 11 in a guest), which needs a retained
VM. The check itself is covered by the runner's own tests.

Earlier the same day (OBSERVED from the job logs, commit `c578e40`):

- **The template change does not disturb the stand-in.** Job 4217, a full build with the
  default runner (24m56s): install exit 0, verify exit 0, installed-state check passed, 11
  evidence files. This run was meant to use the executable; the variable was set on the job
  and did not reach it.
- **`PACKAGE_RUNNER` selects the executable when set for the whole pipeline.** In a pipeline
  started with the variable, `packer-validate` reported "package-runner package-runner.exe, 1
  file(s) staged": the runner-side hash check accepts the committed binary. That was
  `0.0.0-trial.1`.

#### The owner's review (2026-10-07)

The owner read both branches the same evening and replied in chat. Her account, with what the
repository shows:

- **Her missing source is committed, and `main` builds.** `internal/pathutil` and
  `NewLockValidator` are on `main`, `init` is merged into it and deleted, and she merged `main`
  into `proposal/validation-evidence`, removing the stand-ins. OBSERVED: a `git archive` of
  `main` at `a27199e` builds, the first commit to do so since `626e691` on 2026-09-29. **D34 is
  closed.** `main` does not yet hold either proposal branch, so D8, D11, D22, D23, D25, D27
  and D28 stand there.
- **She ran the evidence branch.** The evidence sample she committed at `73a4243` is from a run
  on her own machine at 20:17: two packages installed, with validation evidence that passed.
  Her run, not reproduced here.
- **Two changes she asked for, both made in `c9f1439`:**
  - *Carry on after a failed package.* The run installs the rest, blocks only the dependents
    of a failed package, reports every failure, and still exits 10. Her reason: one build
    then shows every broken package, not one per build. **This reverses a term of C3**, agreed
    on 2026-09-28, which stopped at the first failure unless told otherwise (D27).
    `--stop-on-failure` gives the old behaviour. The outcome `degraded` is gone: a run with a
    failure is `failed`.
  - *The lock sidecar is optional.* Checked when present, skipped when absent; a sidecar that
    is present and does not match is still exit 11. The result file records `lock_sidecar` as
    `verified` or `absent`, and the lock's hash either way. Her reason: a lock generated and
    used inside one pipeline is already protected where it is stored. **This relaxes C1 and
    C3**, which made the guest-side sidecar check mandatory. Nothing changes on this side: the
    template still uploads the sidecar, so the check still runs in our build, and the trust
    anchor is still the hash committed here and checked on the runner.
- **Her direction for the lock: generate it in the pipeline that installs.** That is this
  repository's pipeline. DEFERRED, not designed: the build would run `resolve` each time
  against her recipe and package definitions at a pinned commit, in place of reading a lock
  committed here. It replaces the vendored-lock rule of C1, so the pinned and reviewed thing
  becomes that commit. To settle with her first: whether `resolve` gives the same lock for the
  same inputs, and where the generated lock and its hash are kept as evidence.

Two findings from the same read, both in the register:

- `validate --verify-artifacts` verifies nothing. `verifyFileHash` in her new
  `lock_validator.go` checks that the hash is 64 characters long and never reads the file; its
  comment says the real check is still to be written (D36). `install` does not use it.
- Her new `.gitignore` ignores `/packages/*`. The package definitions already tracked stay
  tracked, but a new package folder is not picked up by `git add` (D37). That matters once the
  lock is generated from those definitions.

When the owner's tools implement C1, this section is reversed: the fixture lock is restated
in the C1 shape and the stand-in reads `files[]` again, or is gone.

**Also read 2026-10-07.** `package-runner` `init` moved to `66a9d0a` ("fixed
package-runner"). It still does not compile as committed (D34). `runner-test-bed` gained a branch, `test-image` (`6beb26d`), with a second job
that prints the versions of the tools in the `0.2.1` image.

**Corrected 2026-10-07.** This paragraph first said that `66a9d0a` made D22 worse. That was
a misreading. `executor.go` holds the validation block twice. The copy `66a9d0a` edited is
inside `getArtifactPath`, where it runs before the install and its result is discarded; the
line it comments out referred to a variable that function does not have. The copy in
`installPackage` is unchanged and still sets `validation_failed`. D22 is as first recorded:
`Run` counts only `failed`, so a failed validation does not fail the run.

**Read 2026-10-07, `34bfc7f` ("fix typo").** One line: the lock key `restartExistCodes` is
now `restartExitCodes`. The stand-in reads both, and the fixture lock sets neither. An
extracted archive still fails `go build ./cmd/package-runner` on the missing
`internal/pathutil` (D34). Two more findings on the validation path, recorded under D22: a
validator type the factory does not know is logged as skipped and then called through a nil
interface, and a validator that returns a non-success status with a nil error is
dereferenced (`err.Error()`); either would end the run with a panic. The `service` validator
is a placeholder that always returns success.

### First real package installed (2026-10-12, STORY-17)

Until this date every build installed the fixture, a script that writes a marker file. On
2026-10-12 a build installed a real application, with the owner's tools on both sides of
the seam. Nothing in the template or in `stage-packages.sh` changed for it; the lock, the
source root and the runner are chosen by three pipeline variables.

| Variable | Value |
|---|---|
| `PACKAGE_LOCK` | `packer/software/windows-11-lab.lock.yaml` |
| `PACKAGE_SOURCE_ROOT` | `/mnt/image-factory/package-content` |
| `PACKAGE_RUNNER` | `packer/fixtures/package-runner/package-runner.exe` |

**The lock** is new: one package, PuTTY 0.83.0, an MSI of 3,508,736 bytes with SHA-256
`d816fba5…e4b8`. It is hand-written from the owner's resolved entry
(`package-runner`, `out/windows-vm.lock.yaml`) with two changes, both recorded in
`packer/software/README.md`: no leading slash on the filename, and no MSI log argument, whose
relative path depends on where the runner is started. Its SHA-256 is committed beside it, as
C1 requires. Generating the lock with `resolve` in this pipeline is still DEFERRED ("The
owner's review").

**The runner** is the trial executable, `0.0.0-trial.2`, built from `proposal/build-contract`
at `c9f1439`. It is not a release (D18).

OBSERVED 2026-10-12:

| Job | What | Result |
|---|---|---|
| `runner-capabilities` on `fdb13f6` | Is the share mounted for this project's jobs? | Yes: the folder and the PuTTY file are present |
| 4410, `staging-harness` | The same install against an old build VM | Staging passed; WinRM never answered, so nothing was installed. The VM, not the package |
| 4408, `packer-build-diagnostic` on `fdb13f6` | A full build | Staged from the share; install exit 0; `file` validation passed before and after the restart check; cleanup passed |
| 4441, `packer-build-publish` on `main` (`0efc166`) | The demonstration run | Both ISOs matched on the datastore; the same install and validation; sealed; published as `image-master-2026.10.12-4441` |

The validation evidence in both builds names
`C:\Program Files (x86)\PuTTY\putty.exe`, product "PuTTY suite", file version 0.83.0.0,
1,151,080 bytes.

What this settles: `msiexec` runs in the build's WinRM session; the runner's `msi` handler
and its staged-file layout work with a file that `download-packages` staged from the share;
guest cleanup and the seal are unaffected by a real install.

What it does not show: more than one package or an install order; an installer that asks
for a restart (3010 has only been forced, with the stand-in); a per-user installer; the
`exe` and `psadt` handlers; a released runner. The default build is unchanged: the fixture
and the stand-in.

**Adjacent repositories, fetched 2026-10-12.** Unchanged since 2026-10-07, except one new
branch in `package-runner`: `add-publish` (`8c2dc2f`, 2026-10-07), which adds a GoReleaser
configuration and a pipeline job for it. Its publish command is a placeholder (`echo`) and
the branch is unmerged, so there is still no release. D38 showed again, as year `12126`.

## What must be fixed before this flow can be exercised (OBSERVED, 2026-09-22)

None of these is a design problem. They are all defects or omissions, listed so the owners
can see the whole set at once. They are requests to the `runner-image`, `package-runner` and
`ci-platform` owners; this repository should not fix them.

### Numbering (settled 2026-09-24)

The canonical identifiers are **`D1` upward** (`D35` as of 2026-10-07), from the defect register in
[the Image Factory retrospective](../image-factory-retrospective.md#45-defect-register),
which is grouped by blast radius. Cite a defect by its `D` number everywhere.

This ADR first numbered its findings 1 to 15, and the register then numbered the same
defects 1 to 21 in a different order, so a bare "finding 4" meant the guest-side hash gap
in one document and the `repository` vocabulary in the other. The earlier numbers may
already be quoted in conversations and in commit messages, so they are mapped here and not
reused:

| Earlier ADR 0003 number | Canonical |
|---|---|
| 1 | D1, D2, D3 (and the `package-conten` typo, part of D4) |
| 2 | D4 |
| 3 | D6 |
| 4 | D8 |
| 5 | D12 |
| 6 | D7 |
| 7 | D16 |
| 8 | D5 |
| 9 | D11 |
| 10 | D9, D10 |
| 11 | D14 |
| 12 | D15 |
| 13 | D18, D19 |
| 14 | D20, D21 |
| 15 | D17 |
| — | D13 (install scope; recorded here under Open questions, not as a finding) |

The entries below keep their text and are labelled with their canonical numbers.

- **D1, D2, D3 — `download-packages.sh` cannot execute.** `usage()` closes with `)` instead of `}`,
   which is a parse error, so the script fails before it runs. Seven variable assignments
   are missing their `=` (`name $(yq …)` runs a command named `name`, which fails with
   exit 127 and `set -e` aborts). One case arm ends `MOUNT_ROOT="$2": shift 2` with a colon
   for a semicolon, which makes `--mount-root` silently ignored. `resolve_repo_root` matches
   the truncated string `package-conten`. (D2 and D3 corrected 2026-09-30 after testing;
   they were first recorded as "runs the output as a command" and "loops forever".)

- **D4 — The `repository` vocabulary does not agree across the seam.** `download-packages.sh`
   resolves only `package-content`. The sample lock's two entries declare `packages` and
   `software-artifacts`. Neither resolves, even after the typo in item 1 is fixed. One
   enumerated set of repository names has to be agreed and shared. **At `4881c5d`:** the
   sample lock has three entries, all declaring `packages`; the defect stands. Agreed fix:
   `package-content` only (C1).

- **D6 — The runner-side and guest-side path layouts disagree.** `download-packages.sh` writes
   to `<output>/<name>/<version>/<filename>`. `package-runner`'s executor resolves an
   artifact by joining `artifact.repository`, `artifact.path` and `artifact.filename`
   relative to the working directory. For the sample lock that is
   `packages\..\..\packages\firefox\18.5.0\Firefox Installer.exe`, which is not where the
   staging step put the file. The sample lock's two entries also disagree with each other
   (`..\..\packages\…` against `.\packages\…`) and both use Windows separators, which the
   Linux runner will not resolve. PROPOSED: the lock carries a path relative to a staging
   root that both sides are told, and the separator is normalised at resolve time. **At
   `4881c5d`:** all three entries use `.\<name>\<version>` and the firefox filename is now
   `Firefox-Installer.exe`; the entries agree with each other but still use Windows
   separators resolved against the working directory, so the defect stands. Agreed fix: C2.

- **D8 — Guest-side re-verification is not implemented.** `package-runner`'s
   `validateArtifact` checks only that the declared size is non-zero and that the declared
   hash is 64 characters. It does not read the file or recompute its SHA-256. Until it
   does, step 4 above does not satisfy the guest re-verification rule, and decision 5 is
   not met. This is the single most important gap.

- **D12 — Evidence is not in an agreed form.** As read 2026-09-22/23, `saveEvidence`
   returned `nil` without writing anything. **Changed at `4881c5d` (2026-09-28):** it now
   writes `package-execution-evidence.json` (`executor.go:347-372`), but under a name
   `collect-evidence.sh` indexes as `other`, with mixed key casing, durations in Go
   nanoseconds, local-offset timestamps, and raw installer stdout/stderr; a failed write is
   only logged. The agreed format is C4 under Contract terms.

- **D7 — The staging entry point is not shipped.** `download-packages` and `yq` exist only on
   `runner-image`'s unmerged `add-more-items` branch. Tag `0.0.20`, which this repository pins,
   contains neither. This is consistent with the `runner-capabilities`
   job reporting no `pwsh`, no `govc` and no mounted share. A tagged release of `runner-image`
   is a prerequisite, and this repository will need to move its pin. **Update 2026-09-30:**
   shipped in `0.1.0`, still broken (D1).

- **D16 — Placeholder values in the sample data.** Both sample package definitions carry the
   same `sha256` and `sizeBytes: 123456`. Expected for a scaffold; noted so it is not
   mistaken for a resolved lock. **At `4881c5d`:** the sample lock has three entries (firefox,
   putty, vscode), all `repository: packages` with Windows-style `.\name\version` paths, all
   three with the **same** `sha256`; firefox's validation path is misspelled `flirefox.exe`,
   and putty's filename has a leading `/`.

### Additional findings (OBSERVED, 2026-09-23)

A second direct read confirmed the seven entries above and produced these. The full register,
grouped by blast radius rather than by repository, and the one numbering to cite, is in
[the Image Factory retrospective](../image-factory-retrospective.md#45-defect-register).

- **D5 — The two halves of the staging step read different lock shapes.** This sharpens D4
   and D6. `download-packages.sh:57-61` reads `.packages[i].repository`, `.path`,
   `.filename`, `.sha256` and `.sizeBytes` — flat. Its Windows sibling
   `download-packages.bat:105-109` reads `.packages[i].artifact.repository` and so on —
   nested. The sample lock is **nested** (`out/windows-vm.lock.yaml:26`), so the `.bat`
   matches the real format and the Linux runner script is reading fields that do not exist.
   Note also that the `.bat` is not copied into the image; only the `.sh` is
   (`Dockerfile:32`).

- **D11 — The `timeout` field is inert in every handler.** `exe.go:92`, `powershell.go:100` and
   `psadt.go:87` create `context.WithTimeout` *after* `cmd.Start()`, binding it to a new local
   that the already-started process does not use; `cmd.Wait()` then blocks indefinitely. The
   executor calls handlers with a bare `context.Background()` (`executor.go:212` at `4881c5d`), so even the
   structurally sound MSI path has no deadline. A package that hangs, hangs the build. This
   matters for the seam because the build has no other timeout on the install step.

- **D9, D10 — Three of four live validators are unimplemented**, returning
    `"… not implemented"` (`internal/validation/validator.go:122`, `:157`, `:192`). The
    fourth, `file`, does an existence check only. A second, unreachable implementation in
    `internal/validators/` (723 of ~4,100 Go lines, no importers) returns
    `PackageStatusSuccess` unconditionally for registry and service checks
    (`registry_validator.go:72`, `service_validator.go:62`) — harmless while dead, dangerous
    if ever wired up.

- **D14 — The recipe hash is computed and then discarded.** `resolver.go:92` computes it and
    `:484` sets it as the lock's `LockHash`; `:174` then overwrites that with the lock hash.
    No `PackageDefinition` hash is computed at all.

- **D15 — A spec typo is baked into the wire format.** `models.go:134` tags the field
    `restartExistCodes` in both YAML and JSON. A definition author writing the correct
    `restartExitCodes` has it silently ignored. Cheap to fix now, breaking to fix later.

- **D18, D19 — Release discipline, restated with evidence.** `package-runner` has no tags, no CI
    configuration and **zero test files**, and its default branch holds only an initial
    commit — all work is on the unmerged `init` branch. `runner-image` carries 21 tags over three
    distinct commits (corrected 2026-09-30; first recorded as four), and `0.0.20` was cut from `dev-branch` while `main` is older in
    content terms (Packer 1.11.2, no `git`/`make`/`jq`). Version numbers in neither repository
    identify content.

- **D20, D21 — The runner image's own supply chain does not meet the rules this repository applies to
    its inputs.** `runner-image`'s base image is `ubi10/ubi-minimal:latest` (unpinned), the Packer
    and `yq` downloads are not checksum-verified, distro packages are unpinned, and
    `runner-image`'s `.gitlab-ci.yml` includes the pipeline template at `ref: "main"` — a moving
    reference, so a change to `ci-platform`'s default branch changes every
    consumer's pipeline with no version gate.

- **D17 — `ci-platform`'s script-fallback path cannot work.**
    `templates/pipeline.yml:33` runs `cp "${SHARED_SCRIPT_DIR}" "${LOCAL_SCRIPT_PATH}"` with no
    `-r`, where `SHARED_SCRIPT_DIR` (`:11`) names a directory; the path also resolves under
    `PUBLISH_ROOT` (`…/images/artifactory/…`) while promotion writes to
    `…/artifactory/…` with no `images` segment and a version directory the template does not
    name. The stack runs entirely on the `~/bin` promotion. Not on our critical path, but a
    single point of failure worth knowing about.

Two claims were investigated on 2026-09-23 and **dropped** because a direct read did not
support them: that `ContinueOnFailure` handling is inverted, and that the resolver's
topological sort is inverted. **Corrected 2026-09-28: both drops were wrong, or only half
right.** The flag is not inverted, but without it the executor still installs every
remaining independent package instead of stopping (D27). And the sort *is* broken: it
reports a false cycle for any dependency at all (D26).

### Re-read 2026-09-28 (OBSERVED, `package-runner` `init` at `4881c5d`)

The branch moved on from `1a9b51c` after the reads above. D8, D9, D11 and D15 still stand
(D9's lines are now `validator.go:123`, `:158`, `:193`). D12 and D16 changed, as recorded in
their entries. These are new:

- **D22 — A package that fails its installed-state check, or needs a restart, does not fail
    the run.** `executor.go:147-172` counts only `success` and `failed`; a package ending
    `validation_failed` or `restart_required` is neither, so `OverallSuccess` stays true and
    `install` exits 0 (`cli.go:212`). Combined with D9, nothing on the install path can
    currently fail on installed state.
- **D23 — A package that needs a restart is never validated.** Validation runs only when the
    status is `success` (`executor.go:276`).
- **D24 — `restartBehavior: block` blocks nothing.** It logs a warning (`executor.go:296-300`).
- **D25 — A package whose dependency failed is still installed.** The `continue` at
    `executor.go:128` leaves only the loop over dependencies, not the loop over packages.
- **D26 — `resolve` reports a false cycle for any dependency.** `resolver.go:425-431`
    decrements the in-degree of the current package's *dependencies* rather than its
    dependents, so a package that depends on anything never reaches zero and is reported as
    part of a cycle. Traced by reading; not run.
- **D27 — Without `--continue-on-failure`, installation continues anyway.** The loop never
    stops on a failure (`executor.go:149-166`). The committed evidence shows it: putty
    (`installOrder` 10) failed, then firefox (20) ran and succeeded, then vscode (30) ran and
    failed with exit 1. `PublicationEligible` stays `true` despite two failed packages.
- **D28 — No elevation check.** The committed PuTTY run failed with `1603`; its MSI log
    (`evidence/putty/instal.log:382`) reads `Error 1925. You do not have sufficient
    privileges`. A non-elevated run surfaces as confusing per-package failures.

### Read 2026-09-30 (OBSERVED, `runner-image` `add-more-items` at `5c740bd`)

A full read of `runner-image` (all branches and all 21 tags), with the questionable parts of
both staging scripts run in a scratch folder. D1, D4–D7, D20 and D21 were confirmed. Three
earlier entries were wrong and are corrected where they appear: **D2** fails with exit 127
and `set -e` aborts, **D3** makes `--mount-root` silently ignored rather than looping, and
**D19** is three commits, not four. `govc` appears in no file on any of the 28 refs, and
nothing has been committed since 2026-09-22. (Later the same day `0.1.0` shipped `govc`.)

- **D29 — `download-packages.bat` overwrites the artifact it has just verified.** The
    unescaped `>` in `echo     OK-> !dest!` (`:159`) writes the status text into the file
    (tested in `cmd`). The `.bat` is not in the image and has no role under this ADR;
    PROPOSED to the owner: delete it.
- **D30 — `download-packages.bat` has three more defects** (each tested in `cmd` by a 2026-09-30 review): a
    label inside a `for` block that fails to parse, a success path that falls through to
    `exit /b 1`, and unescaped `)` that cut blocks short. Moot if D29's deletion is agreed.
- **D31 — `download-packages.sh` accepts paths that escape its folders**
    (`:66-68`). C2 requires relative paths with no `..`; the script must enforce it.
- **D32 — A file that fails verification is left in the staging tree** (`:77` copies before
    checking; `:82-92` only `continue`). The tree Packer uploads must hold only verified
    bytes.

## Interim staging (STORY-06)

**Superseded 2026-10-01 by "Build side written (STORY-04)" above.** The template no longer
runs this sequence; of its parts only `verify-package.sh` is still called, by
`stage-packages.sh`. The fixture's `install.ps1` no longer throws: it copies the payload to
`C:\Program Files\testpkg\`. The text below is the record of the interim.

Unchanged by this revision, and unaffected by it. To prove package staging without waiting
for the contract, the build stages and verifies one fixture package. This is a mechanism
proof: it installs nothing and does not add an install engine.

- **Fixture:** a placeholder payload and a placeholder install script kept in
  `packer/fixtures/software/`, described by a one-entry manifest in the baseline format. The
  package is not a real installer.
- **Runner side:** `scripts/runner/verify-package.sh` (bash, `sha256sum`) reads the manifest
  strictly, finds the payload through `sha256sums.txt`, and recomputes its SHA-256. The runner
  image has no `pwsh` and the share is not mounted there, so this uses neither.
- **Transfer:** Packer `file` provisioners upload the payload, the manifest and the install
  script over the existing WinRM-over-HTTPS channel into `C:\Packer\staging`.
- **Guest side:** `packer/provisioners/Test-StagedPackage.ps1` checks that all three files
  exist and are not empty, recomputes the payload's SHA-256, and compares it with the value
  the runner verified. Any failure fails the build. The result is downloaded to `evidence/`.
- **Cleanup:** the staging directory must be removed before sealing (ADR 0002).
- **Replacing the fixture:** the staging and transfer steps are unchanged under the decision
  above; only their inputs change. `verify-package.sh` is replaced by `download-packages`,
  and the fixture manifest by the pinned lock.

Four implementations of "verify a hash" exist across the two repositories, and the decision above
disposes of each differently:

| Implementation | Where | Disposition |
|---|---|---|
| `scripts/runner/verify-package.sh` | here, runner side | Retired with the fixture; `download-packages` replaces it. |
| `download-packages.sh` | `runner-image`, runner side | Kept. This is the runner half of the flow. |
| `validateArtifact` | `package-runner`, guest side | Kept, once it actually recomputes the hash (D8). This is the guest half. |
| `packer/provisioners/Test-StagedPackage.ps1` | here, guest side | **Temporary.** It currently covers D8 on `package-runner`'s behalf, and its own header says so. Retire it when the guest half re-verifies. |

The fourth is the one to watch. It works, so there is no pressure to remove it, and leaving it in
place would quietly move the guest-side fail-closed guarantee into this repository permanently.

### First CI run (OBSERVED, 2026-09-21)

- The build created the staging directory, uploaded the three files, and the guest check
  reported that all three files were present and the package hash matched. The result file was
  downloaded, and the build finished in 20 minutes 58 seconds.
- Runner-side package verification passed twice in one CI run: once in `make validate-packer`
  and once in the build itself. Each writes its own `package-verify-<ts>.json`.
- Each upload of a tiny file took about 6 seconds from one step to the next. That is per-file
  overhead. It says nothing about throughput for a large package, which is still unmeasured.
- OBSERVED (staging harness against a retained VM, 2026-09-21): with a deliberately wrong
  expected hash, runner verification still passed (it uses the real hash), the three files
  uploaded, and the guest check failed with "The staged package does not match the expected
  SHA-256." Packer stopped the build with a non-zero script exit status, the job failed, and
  the evidence was still indexed. `staging-result.json` was not downloaded, as documented in
  `docs/evidence.md`. The same harness passed with the real hash in 1 minute 30 seconds.
- Not yet exercised in a real run: missing-file cases (covered by local tests of the runner
  script and the guest script only), and the `-on-error=abort` retention of a failed full
  build's VM (the harness has no VM of its own to retain).

## Open questions

### Resolved, and agreed with the owner 2026-09-28

- *Which hash is authoritative* — the lock (decision 4), anchored by its expected SHA-256
  committed in this repository (C1).
- *Whether the install tooling runs on the runner, in the guest, or both* — both, from the
  same lock (decision 5).
- *How catalog packages will reach the runner* — `download-packages` against the package
  content mount, once shipped (decision 3, step 2). Previously BLOCKED.
- *Which manifest the build consumes* — the lock, resolved from the recipe. The baseline
  manifest is superseded rather than pinned.

- *Install scope per package* — AGREED as a required `PackageDefinition` field with the
  values `machine-wide` and `per-user` (C1; owner's question 2).
- *The evidence format, and where the guest writes it* — AGREED as C4.
- *How the lock reaches the build* — AGREED: vendored into this repository at a pinned
  version, with its expected SHA-256 committed beside it (Versioning; C1). The alternative,
  fetching at build time, needed cross-project job-token access that was never verified.
  Vendoring's usual objection, drift from a moving source, does not apply to a resolved
  lock pinned by a committed hash.

### Still open
- **Runner-side evidence — a gap in the agreed contract** (found 2026-09-30). The runner
  verifies packages before transfer, which is an engineering rule, but after the switch that
  step leaves no evidence record: `scripts/runner/verify-package.sh`, which C2 retires, writes
  `package-verify-<ts>.json`, while `download-packages` writes only to the console. C4 covers
  the guest's evidence only. PROPOSED, to agree with the owner: either `download-packages`
  gains a result-file option (for example `--result <file>`, JSON with each file's computed
  SHA-256 and size), or this repository wraps it and writes the record itself. The first
  keeps the record next to the check that produced it.
- **How the `package-runner` binary reaches the guest.** It is a single static Go binary
  with no runtime dependency, so it can be transferred with the packages, but it needs a
  pinned version and a published build.
- **Transfer time for real packages.** INFERRED, not measured: WinRM upload is slow for
  large files, and the one real package is about 230 MB. If upload time is unacceptable,
  attach packages as an ISO. DEFERRED until measured. Unchanged by this revision.
- **A machine-wide first package** in the catalog, for the generalization proof (ADR 0002).
  The only current entry is a per-user installer.
- ~~**`runner-image` pinning.**~~ RESOLVED (`4204ac9`): the pin is now a single
  `PACKER_CI_IMAGE` variable in `.gitlab-ci.yml`, so moving it for `download-packages` is a
  one-line change.

## Consequences

- No new install code lands here. The interface is two Packer provisioner steps, a transfer
  and an invocation, against a file format this repository does not define.
- The seam becomes testable before either side is finished. A hand-written lock naming the
  fixture package exercises steps 2 to 5 without the catalog, the resolver or a real
  installer.
- The findings list above is the critical path. D1 to D6 block any end-to-end run, D8
  blocks the fail-closed guarantee, and D7 blocks all of them from running in CI.
- This repository takes a dependency on a `package-runner` version and a `runner-image` tag.
  Both need release discipline that does not exist yet: `package-runner` has no tags, and
  `runner-image` builds only on feature branches and semver tags, never on its default branch.
- Any package added later still needs a pinned hash established before runtime and a
  generalization check (ADR 0002).
