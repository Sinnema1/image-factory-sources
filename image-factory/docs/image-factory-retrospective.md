# Image Factory: retrospective and cross-repository overview

- **Covers:** 2026-08-17 to 2026-09-30 (Phase 1, Image Factory)
- **Written:** 2026-09-23; brought up to date 2026-09-24, 2026-09-28 and 2026-09-30
- **Repository state:** `main` at `76c8672`, plus the changes recorded in the timeline

## How to read this

Three readers, three entry points. **Section 1** is the summary for anyone who needs the
state of Phase 1 and nothing else. **Section 4** is the cross-repository detail, and is the
section to read before agreeing the package install contract. **Sections 3, 5 and 7** are
the engineering record: how the system works, what broke on the way here, and what is still
carrying risk.

Evidence labels follow the repository engineering rules: `OBSERVED`, `INFERRED`, `PROPOSED`,
`BLOCKED`, `DEFERRED`. An `OBSERVED` claim was checked directly, at the file and line cited.
An `INFERRED` claim is the leading explanation and is marked as such rather than stated as
fact.

> Everything said here about `ci-platform`, `runner-image` and `package-runner`
> was read from local clones on 2026-09-23, at the branches named. Two of those branches are
> unmerged development branches. The reading is first-hand, but the code is in flux.
> Proposals below were proposals when written; **the install contract was agreed on
> 2026-09-28** (ADR 0003, Contract terms), and the register was extended at `4881c5d`.

---

## 1. Summary

The Image Factory builds a Windows 11 image on vSphere from a GitLab CI pipeline. A Linux
runner verifies its inputs, invokes Packer, and Packer creates a VM, installs Windows from a
datastore ISO, joins the domain, brings up WinRM over HTTPS, proves it is talking to the
expected administrative account, stages a package into the guest, removes the credential
material Windows Setup cached, shuts the VM down, and indexes everything it learned as
hashed, secret-scanned evidence.

Four repositories are involved, in one direction: `ci-platform` (the CI
platform) publishes `runner-image` (the toolchain container), which this repository runs on to
build the image, and `package-runner` (the package engine) is what will install software in
the guest. The first three are owned by the tooling owner.

**The one thing to know:** the build stages a package and nothing installs it. That is not
waiting on engineering time in this repository. It was waiting on a contract across the seam,
agreed on 2026-09-28 (ADR 0003), and is now waiting on tooling on both sides of that seam
that does not yet run — the runner-side staging script does not parse, and the guest-side engine never
recomputes a hash.

### Capability status

| Capability | State | Detail |
|---|---|---|
| Windows 11 vSphere image build from CI | **Working** | ~23 to 25 minutes since the software install and first-run setup were added. Most recent: 2026-10-08, job 4362, the first master published from `main` (27m13s for the build, about 30 minutes in all). Job 4330 the same day was the first published master, a test from the feature branch (28m14s for the build, about 31 minutes with the ISO check and the publish steps); job 4329 the same day (24m43s) was a default diagnostic build. Job 4294 (27m27s) was the first sealed build. Job 4245 (2026-10-07, 25m03s) was a trial run on a branch and the first in which `package-runner` itself, not the stand-in, installed the package in the guest. Job 4074 (2026-10-07, 23m34s) was the first to stage its package with the owner's `download-packages`. Job 4015 (2026-10-07, 24m02s) was the first in the `runner-image` `0.2.1` image. Job 3497 (2026-09-28, 22m08s) was the first on the shared `runner-01` runner and the first with ISO paths read from the qualification records. |
| WinRM communicator over HTTPS | **Working** | [ADR 0001](decisions/0001-winrm-https-communicator.md). Every build since the change connects. |
| Guest identity proof | **Working** | Fails the build unless the session is the expected admin account (STORY-01). |
| Build evidence, indexed and secret-scanned | **Working** | Runs on success, failure and cancellation (STORY-07). |
| Credential cleanup in the guest | **Working on success** | A failed build retains its VM with the password on disk and on the build floppy — accepted for the lab by owner override (`AGENT_HANDOFF.md`, Key Design Decision 8). |
| ISO qualification, record and intake copy | **Working** | Stage 1. Record validated every pipeline. |
| ISO qualification, the copy the build boots | **Verified** | Both ISOs match their records, measured 2026-09-23 with `govc` on the workstation. Since 2026-09-24 the template takes its ISO paths from those same records, so the path qualified and the path booted cannot diverge. Re-verified 2026-09-30 (Windows ISO streamed in 175 s). `govc` shipped in `runner-image` `0.1.0` on 2026-09-30, the pin moved to `0.1.0` the same day, and the manual CI job `verify-iso-datastore` ran stage 2 for both ISOs (job 3757). [ADR 0004](decisions/0004-iso-library-and-qualification.md). |
| VMware Tools ISO qualification | **Verified** | Record added and measured 2026-09-23 (142,280,704 bytes). Closes the gap where the one input executed in the guest as SYSTEM had no identity at all. |
| Package staging | **Proven once, on a fixture** | Verify on the runner, upload, re-verify in the guest. Replaced on 2026-10-01 by the install flow in the next row. |
| Package install | **Build side proved in CI against a stand-in; engine blocked** | STORY-04, 2026-10-01: the build verifies, transfers, installs, collects evidence, restarts on 3010 and re-checks, against a fixture and a stand-in for `package-runner`. One full build and a harness run per exit code passed as designed (ADR 0003, "Build side written"). The real engine and real packages stay blocked: [ADR 0003](decisions/0003-package-install-contract.md) and section 4.5. **State 2026-10-08:** a full build has now run the real engine as a trial (job 4245, 2026-10-07): a build of the proposal branch, selected with `PACKAGE_RUNNER`, installed and verified the fixture package in the guest. The default is still the stand-in, and the owner has not merged or tagged the code the trial ran (ADR 0003, "Trial of a `package-runner` build"). Real packages are still untried. **2026-10-12:** a real package was installed end to end for the first time (STORY-17). PuTTY 0.83.0 was staged from the package share by `download-packages` and installed by a trial build of `package-runner`, in a diagnostic build (job 4408) and in a publish from `main` (job 4441). Both are selected by pipeline variables; the default is still the fixture and the stand-in, and the engine still has no release (D18). See ADR 0003, "First real package installed". |
| Master image sealing | **Seal step built and proved; off by default** | [ADR 0002](decisions/0002-master-image-identity-and-sealing.md) was accepted on 2026-10-01 (STORY-10): a domain-joined master, no sysprep, for Citrix MCS. The seal step and what it depends on are STORY-03 (corrected 2026-10-08: what the seal removes and verifies is STORY-19; STORY-03 runs it at shutdown and takes the snapshot). **2026-10-08:** the seal step runs when a build is asked to seal (`SEAL_IMAGE=true`) and was proved by harness job 4288 and full sealed build job 4294. Still to do under STORY-03: the masters OU and join account (deferred in the lab), then the snapshot and the MCS catalog proof. |
| Approved image identity | **Built and proved 2026-10-08** | [ADR 0005](decisions/0005-publish-form-and-image-identity.md): a master VM with a versioned snapshot in the project folder (revised 2026-10-01 for MCS), identified by instance UUID and snapshot, with the evidence-index SHA-256 as provenance. Waits on the seal step (STORY-03). **2026-10-08:** `packer-build-publish` produced the first published master, `image-master-2026.10.08-4330` with snapshot `sealed-2026.10.08-4330`, and its `image-reference.json` (job 4330, from the feature branch; STORY-11), and then the first from `main`, `image-master-2026.10.09-4362` (job 4362). It proves the mechanism; the image holds the test fixture, not real software. |
| Terraform / Citrix provisioning | **Not started** | Phase 2. |

---

## 2. Timeline

| Dates | Arc | What happened |
|---|---|---|
| 08-17 → 08-18 | Discovery and ISO intake | vCenter discovery, the first qualification record and schema, the first Packer template. Content Library abandoned for datastore paths after `GET /api/content/library` returned 404 for lack of permissions — a workaround, not a preference. |
| 09-21 | The WinRM pivot | The project's original blocker cleared. The communicator moved from HTTP to HTTPS on 5986 (ADR 0001). Repository cleanup, dead code removal, environment config untracked, `packer-fmt` and `runner-capabilities` jobs added. ADRs 0002 and 0003 opened. |
| 09-21 → 09-22 | Staging and evidence | Package staging against a fixture (STORY-06) and evidence collection with an index and secret guard (STORY-07). The staging harness arrived, cutting the feedback loop from 21 minutes to 90 seconds. |
| 09-22 | Guest identity, and the cross-repo read | STORY-01 proved guest communication as the administrative service account. The three adjacent repositories were read directly for the first time, five weeks in; ADR 0003 was rewritten around what that read found. Five defects fixed in this repository. |
| 09-23 | Credential hygiene and ISO qualification | The domain-join password found cached in plaintext in the guest, removed, and proven gone. ISO validators ported from PowerShell to bash so they can run on the runner. ADR 0004 rewrote qualification to describe the copy the build actually boots. |
| 09-24 | CI hardening and closing the ISO loop | Runner image pinned by digest; the smoke test enforces a tool list derived from actual invocations; `runner-capabilities` probes outbound connectivity and found the internal CA gap (section 7). The template now reads its ISO paths from the qualification records, so the build attaches exactly the item that was qualified. Defect numbering settled on `D1`–`D21`. |
| 09-28 | Runner move | CI moved to the tooling owner's shared runner `runner-01` (Docker executor, host 192.0.2.35). The podman-read digest was absent there, so the image was re-pinned to that host's digest; `PACKER_RUNNER_SOURCE_IP` was corrected from `.36` to `.35` before the first build, which would otherwise have failed at the guest firewall; the stale ISO lines were removed from `PACKER_VARS_FILE`. Job 3497 then built end to end: every gate passed, no `Undefined variable` warning. |
| 09-28 | Credential exceptions (STORY-02) | A datastore scan found seven orphaned build floppy images (Sep 2–22) and a retained VM running since Sep 4 with its floppy attached; all removed. `Remove-VM -DeletePermanently` was shown to leave the floppy behind, so `Remove-PackerTestVm.ps1` now deletes it. An induced failure (job 3531) showed `-on-error=abort` leaves the password in the guest and on the floppy; kept for the lab by owner override. The Panther scan's fail-open on unreadable paths was closed. `LocalAccountTokenFilterPolicy` found to persist (pre-seal item). |

---

## 3. The system as built

### 3.1 The four-repository stack

The build-time dependency runs in one direction only.

| Layer | Repository | Responsibility | Owner |
|---|---|---|---|
| CI platform | `ci-platform` | The reusable `build`/`publish` pipeline template every container repository in the group includes, plus the image publish script and script promotion to the runner. Generic: it never knows what an image contains. | The tooling owner |
| Toolchain | `runner-image` | One Dockerfile producing `runner-image:<tag>`, the image every job here runs on. Its entire `.gitlab-ci.yml` is a four-line `include:` of the layer above. | The tooling owner |
| Image build | **this repository** | The Packer template, the answer file, the guest bootstrap, ISO intake and qualification, guest cleanup, and build evidence. | The image-build owner |
| Package engine | `package-runner` | A Go CLI: recipe → resolver → immutable lock → handlers and validators, run in the guest. | The tooling owner |

All four are in `image-factory-group` on `gitlab.example.test`.

### 3.2 End-to-end execution flow

Copy-pasteable. Renders anywhere monospace works.

> **Changed 2026-10-01 (STORY-04); the diagram below is the 2026-09-24 flow.** Three things
> differ. In phase 2 the runner gate is `stage-packages.sh`, which checks the lock and the
> `package-runner` binary against their committed hashes and then stages the package files
> (with `verify-package.sh` until 2026-10-07, with `download-packages` since).
> In phase 4d, steps 4 to 7 are replaced by: empty and create `C:\Packer\staging` and
> `C:\Packer\evidence`; upload the lock, its sidecar, the binary and the package tree; run
> `package-runner install`; download `install-result.json`; fail unless the exit code was 0
> or 3010; restart if it was 3010; run `package-runner verify`; download
> `install-result-verify.json`; fail unless it exited 0. And failure gate 3 is now the
> install's own exit code (10 package failed, 11 integrity, 12 not elevated). The binary is a
> stand-in until STORY-05 ships (ADR 0003, "Build side written"). Since 2026-10-07 the
> template also runs a real `package-runner.exe` when `PACKAGE_RUNNER` names one (job 4245).

```text
╔═══════════════════════════════════════════════════════════════════════════╗
║  EXAMPLE LABS IMAGE FACTORY — END-TO-END EXECUTION FLOW                   ║
║  Entry point: .gitlab-ci.yml → job "packer-build-diagnostic" (manual)     ║
║  As of 2026-09-24 (main at 4a01fdc, plus the ISO path derivation)         ║
╚═══════════════════════════════════════════════════════════════════════════╝

┌─ PHASE 1 ─ GITLAB CI ─────────────────────────── runs on: GitLab ─────────┐
│  Image for every job: registry.example.test/images/runner-image:0.1.0,    │
│  pinned by digest, once, in variables. Runner tag: shared-medium.         │
│                                                                           │
│  Supplied at runtime, never stored in the repo:                           │
│    VCENTER_HOST / VCENTER_USERNAME / VCENTER_PASSWORD                     │
│    ADMIN_SERVICE_ACCOUNT / ADMIN_SERVICE_ACCOUNT_PASSWORD  (masked)       │
│    AD_DOMAIN / AD_NETBIOS_DOMAIN / PACKER_RUNNER_SOURCE_IP                │
│    ADMIN_GROUP_SID / ADMIN_GROUP_NAME                                     │
│    PACKER_VARS_FILE  (file variable: placement values only)               │
│                                                                           │
│  1. require-env.sh        → 11 names must be set, or stop                 │
│  2. install PACKER_VARS_FILE → configs/windows-11-vsphere.pkrvars.hcl     │
│  3. make init             → packer init (installs vsphere plugin)         │
│  4. make build-diagnostic → scripts/runner/build-diagnostic.sh            │
│                                                                           │
│  (The separate packer-validate job additionally runs                      │
│   validate-iso-metadata.sh — the ISO record is checked every pipeline.)   │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─ PHASE 2 ─ RUNNER ────────────── runs on: Linux runner, bash only ────────┐
│  scripts/runner/build-diagnostic.sh                                       │
│                                                                           │
│  ├─ preflight: packer present, required files exist, env vars set         │
│  ├─ arm EXIT trap → collect-evidence.sh (fires pass or fail)              │
│  │                                                                        │
│  ├─ ⛔ GATE ─ scripts/runner/verify-package.sh                            │
│  │     reads   packer/fixtures/software/                                  │
│  │     writes  build/package-vars.pkrvars.hcl      ← build INPUT          │
│  │             evidence/package-verify-<ts>.json   ← evidence             │
│  │     on fail "|| fail" exits 1 — Packer is never invoked                │
│  │             (load-bearing: this script runs without set -e)            │
│  │                                                                        │
│  ├─ write evidence/packer-provenance-<ts>.txt                             │
│  │     commit, CI ref, dirty count, packer version, vars-file SHA-256     │
│  ├─ packer validate  → tee evidence/packer-validate-<ts>.log              │
│  └─ packer build -on-error=abort                                          │
│        -var-file=configs/windows-11-vsphere.pkrvars.hcl                   │
│        -var-file=build/package-vars.pkrvars.hcl                           │
│        → tee evidence/packer-console-<ts>.log                             │
│        → PACKER_LOG → evidence/packer-build-<ts>.log                      │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─ PHASE 3 ─ PACKER / vSPHERE ─ packer/templates/windows-11-vsphere.pkr.hcl ┐
│  source "vsphere-iso" "windows-11"                                        │
│    ├─ create VM (EFI secure boot, vTPM, pvscsi)                           │
│    ├─ mount ISOs from the datastore: Windows 11 + VMware Tools            │
│    │     paths read from the qualification records (ADR 0004)             │
│    ├─ build floppy:                                                       │
│    │     enable-winrm.ps1     (copied as-is)                              │
│    │     autounattend.xml     (rendered from autounattend.xml.pkrtpl)     │
│    ├─ power on, type boot command                                         │
│    ├─ wait for guest IP                                (~13 min)          │
│    └─ connect WinRM  HTTPS 5986, NTLM, winrm_insecure  (~5 min)           │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─ PHASE 4 ─ WINDOWS GUEST ─────────────── runs on: the temporary VM ───────┐
│  a. Windows Setup reads A:\autounattend.xml                               │
│       windowsPE   → partition and install                                 │
│       specialize  → set computer name, join domain,                       │
│                     RunSynchronous → A:\enable-winrm.ps1                  │
│                                                                           │
│  b. enable-winrm.ps1  (computer name is still MINWINPC here)              │
│       ├─ install VMware Tools, confirm VMTools service running            │
│       ├─ Enable-PSRemoting                                                │
│       ├─ create self-signed build certificate                             │
│       ├─ create HTTPS listener on 5986 bound to that certificate          │
│       ├─ firewall rule scoped to the runner IP only                       │
│       ├─ TLS handshake self-check on 127.0.0.1:5986                       │
│       ├─ map the domain admin group → local Administrators (by SID)       │
│       └─ write C:\Windows\Temp\enable-winrm-bootstrap.log                 │
│                                                                           │
│  c. ⟳ REBOOT — specialize → OOBE. Computer name becomes the real name.    │
│       The VM halts at the OOBE account screen and stays there. WinRM is   │
│       a service, so Packer connects regardless.                           │
│                                                                           │
│  d. Packer provisioners, in order:                                        │
│       1. upload  Test-GuestCommunicator.ps1 → C:\Windows\Temp\            │
│       2. ⛔ GATE run it via inline $env: assignments + exit $LASTEXITCODE  │
│             proves: identity == expected account, is administrator        │
│             on fail → build aborts, staging never begins                  │
│       3. download communicator-result.json → evidence/                    │
│       4. create C:\Packer\staging                                         │
│       5. upload  payload + manifest + install.ps1 → C:\Packer\staging\    │
│       6. ⛔ GATE Test-StagedPackage.ps1                                    │
│             proves: files present, non-empty, SHA-256 still matches       │
│       7. download staging-result.json → evidence/                         │
│       8. download enable-winrm-bootstrap.log → evidence/                  │
│             (collected before step 9 deletes it)                          │
│       9. ⛔ GATE Remove-BuildArtifact.ps1                                  │
│             deletes the cached answer files, then fails the build unless  │
│             a recursive scan of C:\Windows\Panther finds no surviving     │
│             <Password> element                                            │
│      10. download cleanup-result.json → evidence/                         │
│                                                                           │
│  e. shutdown.exe /s  → VM powers off, floppy + CD detached                │
│       (destroy = false, so the VM is retained)                            │
│                                                                           │
│  ✗ NOT YET IMPLEMENTED: nothing installs the staged package.              │
│  ✗ NOT YET BUILT:       the seal step. Decided 2026-10-01: a              │
│                         domain-joined master, no sysprep (ADR 0002).      │
│                         (Built 2026-10-08, off by default; see the note   │
│                         above the diagram and ADR 0002.)                  │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─ PHASE 5 ─ EVIDENCE ──────────── scripts/runner/collect-evidence.sh ──────┐
│  Runs twice: EXIT trap in build-diagnostic.sh, and CI after_script        │
│  (so it also runs on failure, cancellation, or timeout)                   │
│                                                                           │
│  ├─ scan every file for literal secret values                             │
│  │     hit → delete file, list in "withheld", exit 1 (value never shown)  │
│  ├─ evidence/index.json    run metadata + per-file role, size, SHA-256    │
│  └─ evidence/SHA256SUMS    verify with: cd evidence && sha256sum -c       │
│                                                                           │
│  → CI uploads evidence/ as job artifacts, expire_in: 30 days              │
└───────────────────────────────────────────────────────────────────────────┘

FAILURE GATES (each stops the build; -on-error=abort retains the VM)
  1. Runner   package hash mismatch / missing file → Packer never invoked
  2. Guest    wrong identity or not administrator  → staging never begins
  3. Guest    staged file missing or hash mismatch → build aborts
  4. Guest    credential material survives cleanup → build fails
  5. Any      secret value found in evidence       → job fails, file deleted

TOTAL RUNTIME ≈ 21 min  (13 waiting for IP, 5 for WinRM, ~3 provisioning)
```

### 3.3 Evidence

Every build produces an indexed, hashed evidence package that survives job failure and
cancellation. The full file-by-file map, the `index.json` shape, and the secret guard's
fail-closed semantics are in [`docs/evidence.md`](evidence.md) and are not duplicated here.

Two properties worth carrying into any discussion of the seam:

- `collect-evidence.sh` assigns a **role** to each file by name pattern. `install-result*.json`
  is already reserved and mapped to the role `install`. Nothing produces those files, because
  nothing installs software — see section 4.5.
- **`secret_scan.status` in `index.json`, not the job's exit code, is what tells you whether
  an artifact was checked.** A GitLab `after_script` exit code does not fail the job, and
  `artifacts: when: always` uploads regardless.

---

## 4. Cross-repository integration

This is the section to read before agreeing the install contract.

### 4.1 `ci-platform` — the CI platform

*Read at `main` (`2cae5b0`, tag `0.0.14`) on 2026-09-23. Five tracked files, 37 commits,
2026-08-31 to 2026-09-08, single author.*

**It is a mock, and there is no registry.** OBSERVED: `README.md:2` reads "Mock artifactory
image publishing pipeline" and `README.md:6` "publishing container images to a mock
artifactory system." A search of every tracked file for `podman push`, `docker push`,
`skopeo`, any login verb, `CI_REGISTRY`, or any credential-suffixed variable returns **zero
matches**. Every occurrence of the word "artifactory" in executable code is a filesystem path
segment (`.gitlab-ci.yml:7`, `templates/pipeline.yml:11`,
`scripts/cleanup-publish-image.sh:9`).

The transport is `podman save` to a docker-archive tar on the mounted share. A consumer
retrieves an image with `podman load`, not `podman pull`. The `registry.example.test/images` prefix at
`templates/pipeline.yml:7` looks like a registry hostname and is never resolved or contacted;
its own comment says `# Local namespace used to organize images`. **This matters for any
statement about image provenance or supply chain in this stack: there is no registry to
sign to, scan in, or authenticate against.**

**The pipeline template** (`templates/pipeline.yml`, 108 lines) is what consuming repositories
include. Two stages, two jobs, both pinned to `tags: - container-publish`:

- `build:container:image` (`:40`) derives `IMAGE_NAME` from `$CI_PROJECT_NAME` and
  `IMAGE_VERSION` from `${CI_COMMIT_TAG:-${CI_COMMIT_SHORT_SHA}}` (`:47-48`), runs one
  `podman build --file Dockerfile .` (`:55-62`), and hands off four variables through a
  dotenv artifact (`:65-75`). **The entire contract on the consuming repository is: provide
  a `Dockerfile` at the repository root.**
- `publish:container:image` (`:80`) runs only on a semver-shaped tag (`:107`), carries
  `resource_group: image-share-publisher` (`:108`), and invokes
  `/home/gitlab-runner/bin/publish-image.sh` with no arguments (`:105`). Everything passes by
  environment.

**`publish-image.sh`** (404 lines, `set -Eeuo pipefail`) is careful work. `podman save
--format docker-archive` (`:163-166`); SHA-256 generated and immediately re-verified;
a 15-field YAML metadata file (`:135-150`: `schema_version`, `name`, `version`,
`image_reference`, `image_id`, `image_digest`, `archive`, `archive_sha256`,
`archive_size_bytes`, `source_repository`, `source_commit`, `pipeline_id`, `job_id`,
`git_tag`, `published_at_utc`); published versions are **immutable** — an existing version is
a hard failure (`:212-216`); files are staged into a hidden sibling directory, the checksum is
**re-verified after the copy to the share** (`:236-242`), and the directory is then moved into
place with a single `mv` (`:245`), so a reader never sees a partial version. `flock` is
`--exclusive --nonblock` (`:389`), so a concurrent publish fails fast rather than queueing —
a second mutex layer on top of GitLab's `resource_group`.

**Script promotion** (`.gitlab-ci.yml`) is how `publish-image.sh` reaches the runner. Tagging
this repository triggers `promote:scripts` (`:45`, rule `if: $CI_COMMIT_TAG`), which copies
every file in `scripts/` into `/home/gitlab-runner/bin/` and `chmod +x`es it (`:61-69`). That
`chmod` is the only one in the file that is not commented out (`:17`, `:36`, `:58` are all
commented) — the share rejects mode-setting, the runner's home does not. The same root cause
produced the `install` → `cp` change at `publish-image.sh:230`.

OBSERVED, and worth flagging to the owner: **the template's fallback for a missing script
cannot work.** `templates/pipeline.yml:33` runs `cp "${SHARED_SCRIPT_DIR}"
"${LOCAL_SCRIPT_PATH}"` — no `-r`, and `SHARED_SCRIPT_DIR` (`:11`) names a *directory*, so the
copy fails. The path is also wrong: it resolves under `PUBLISH_ROOT`
(`/mnt/image-factory/images/artifactory/…`) while `.gitlab-ci.yml:7` promotes to
`/mnt/image-factory/artifactory/…`, with no `images` segment and a version directory the
template does not name. The system therefore runs entirely on the `~/bin` promotion. Not a
problem we hit, but a single-point failure worth knowing about.

**It is fully generic.** It never reads, unpacks or branches on image contents. The two labels
it applies and the two build-args it passes are provenance, not content. There is no scan,
sign, or SBOM step. **Corollary: no question about what is inside `runner-image` can be answered
or enforced at this layer.** That belongs to the consuming repository's Dockerfile, which is
section 4.2.

### 4.2 `runner-image` — the toolchain

*Read at `main`, `dev-branch`, tag `0.0.20`, and branch `add-more-items` (`5c740bd`) on
2026-09-23. Five tracked files, ten commits.*

> **Update 2026-10-02 (read at `main`, `a321d26`, tag `0.1.0`).** What follows describes the
> repository as it was on 2026-09-23, and two of its warnings have reversed. `main` is now the
> newest content and is what the runner has: `0.1.0` carries Packer 1.16.0, `git`, `make`,
> `jq`, `unzip`, `tar`, `yq` v4.45.1, `govc` v0.56.0 and `download-packages`. It got there by
> one squash commit (`d752d5b`, STORY-14) on top of `2654d2f`, so tag `0.0.20` and `5c740bd`
> are not ancestors of `main`, and the `add-more-items` branch no longer exists. `govc` is in
> the image, so ISO stage 2 runs in CI. `download-packages.sh` is unchanged and still does not
> parse (D1). Still five tracked files. Detail: ADR 0003, "Read 2026-10-02".
>
> **Update 2026-10-05 (branch `adjust-script`, `671e967`).** Two commits on 2026-10-02 rework
> `download-packages.sh` on an unmerged, untagged branch. It now parses and runs: D1, D2, D3
> and D32 are fixed there, and it reads the nested lock shape (D5). Still open on that
> branch: paths that escape the mount (D31), no enforcement of the repository name (D4), a
> single `filename` where C1 agreed `files[]`, and a new finding, D35: an entry with no hash
> is staged unverified and reported as verified. `main` and tag `0.1.0`, which is the image
> we pin, are unchanged. Detail: ADR 0003, "Read 2026-10-05".

Its entire `.gitlab-ci.yml` is four lines:

```yaml
include: 
  project: image-factory-group/ci-platform
  ref: "main"
  file: templates/pipeline.yml
```

Note `ref: "main"`, not a tag: a push to `ci-platform`'s default branch changes
every consuming repository's pipeline immediately.

**What `0.0.20` — the tag we pinned until 2026-09-30, when the pin moved to `0.1.0` — actually contains.** UBI 10 minimal
(`FROM registry.access.redhat.com/ubi10/ubi-minimal:latest`, unpinned), Packer **1.16.0**, and
`ca-certificates`, `curl`, `git`, `make`, `jq`, `unzip` from `microdnf`. Neither the Packer zip
nor, on the branch, the `yq` binary is checksum-verified after download.

**`govc` and `pwsh` did not exist on any branch or tag** (as read 2026-09-23; `govc` shipped in `0.1.0` on 2026-09-30). OBSERVED then: `git grep -inE
'govc|pwsh|powershell'` across every commit reachable from all refs returns zero matches. This
is the direct cause of three things in this repository: `make validate` cannot run in CI,
`make preflight` and `make list-vms` have never been runnable by anyone, and — the one that
matters — **ISO qualification stage 2 cannot run, so the ISO the build boots is unverified in
CI** (ADR 0004).

**The tag series does not track content.** Twenty-one tags over three distinct commits
(corrected 2026-09-30; first recorded as four), numbered in an order that runs backwards in history;
`0.0.5` through `0.0.17` all point at the same merge commit. `0.0.20` is the head of
`dev-branch`, not of `main` — and `main` is *older* in content terms, still carrying Packer
1.11.2 with no `git`, `make` or `jq`. Anyone reasoning about "what is on the runner" from the
default branch will be wrong. (True until 2026-09-30. Since `0.1.0`, `main` and the tag we pin
are the same commit.)

**The `add-more-items` branch** (unmerged when read; its content reached `main` in `0.1.0`
by a squash, and the branch is gone) was four commits ahead of `0.0.20` and added exactly
three things: `yq` v4.45.1, `scripts/download-packages.sh` installed to
`/usr/local/bin/download-packages` (`Dockerfile:32-33`), and a Windows sibling
`scripts/download-packages.bat`. The `.bat` is **not** copied into the image.

`download-packages.sh` is the runner half of the agreed flow: it reads a `package-runner`
lock, and for each entry copies an artifact out of the mounted package-content share into a
staging tree, failing closed on a size or SHA-256 mismatch. Despite the name it downloads
nothing — there is no network call, it is a `cp` from a mount. Its defects are in section 4.5.

### 4.3 `package-runner` — the package engine

*Read at branch `init` (`1a9b51c`) on 2026-09-23. 31 files, ~4,100 lines of Go, eleven commits
2026-09-09 to 2026-09-22.*

> **Update 2026-10-02 (read at `init`, `8e538aa`: 18 commits, 32 files, 20 Go files).** The
> architecture below is unchanged, and none of the agreed contract terms C1–C4 has landed.
> Four things are different. **The head does not compile** as committed, and has not since
> `626e691` on 2026-09-29: it imports a package that was never committed and calls a function
> that was deleted (D34). Validation was reorganised: `validation` is now a list per package,
> the validators in `internal/validators/` are the live ones, and `internal/validation/` is
> gone, which changes D9 and D10. A 368-line `README.md` now states the owner's intent, and
> claims more than the code does in three places. The sample lock lists two packages
> (firefox and putty) and the committed evidence is a new two-package run from 2026-10-01.
> Still no tags, no CI, no tests, and `main` still holds only the initial commit. Detail and a
> per-defect table: ADR 0003, "Read 2026-10-02".
>
> **Update 2026-10-08 (read at `main`, `a27199e`).** `init` was merged into `main` on
> 2026-10-07 and deleted, with the missing source committed, so **the head compiles** (D34
> closed). The lock key typo is fixed (D15 closed at `34bfc7f`). Otherwise `main` is as
> described above: still no tags, no CI and no tests, and none of C1 to C4. Two branches by
> the image-build owner, offered to the owner as proposals, implement C3 and C4 against the interim lock
> shape; she has reviewed them and asked for two changes, which are made. The per-defect
> state is in the register (section 4.5), and the account is in ADR 0003, "Trial of a
> `package-runner` build" and "The owner's review".

A coherent architecture: **recipe → resolver → immutable lock → executor → handler**.

- `ImageRecipe` (`internal/models/models.go:64`) — metadata, a `target` block, defaults, and
  `packages[]` of name, version and `installOrder`.
- `PackageDefinition` (`models.go:103`) — an `artifact` block (`repository`, `path`,
  `filename`, `sha256`, `sizeBytes`) and an `install` block (`handler`, `arguments`,
  `timeout`, `successExitCodes`).
- `ImageRecipeLock` (`models.go:157`) — the recipe resolved against the definitions, ordered,
  carrying `generatedAt` and a `lockHash` computed over the lock with the hash field blanked
  (`models.go:262`). **This is the artifact ADR 0003 makes the contract** (accepted 2026-09-28),
  though not its embedded `lockHash`: the agreed integrity anchor is the lock's expected
  SHA-256 committed in this repository (ADR 0003, C1).
- Commands (`internal/cli/cli.go:38`): `resolve`, `validate`, `install`, `install-package`,
  `detect`, `handlers`, `version`. `install` takes `--lock`, `--evidence-dir` and
  `--execution-id`, which covers part of the interface ADR 0003 agreed; `--artifact-root`
  (C2, C3) is still to be added (checked at `4881c5d`).
- Handlers for `msi`, `exe`, `powershell`, `psadt`; validators for file, registry, service and
  command.

**The design is right and the implementation is a spike.** The default branch `main` holds
only an initial commit — all the real work is on the unmerged `init` branch (ten commits when first read on 2026-09-23; 13 at `4881c5d`). There
are no tags, no CI configuration, no `Makefile`, and **zero test files**. It compiles and vets
cleanly; `resolve` has demonstrably run once end to end, producing the committed
`out/windows-vm.lock.yaml`. As of `4881c5d` (re-read 2026-09-28), committed evidence records one
`install` run on a workstation (2026-09-23): firefox succeeded, putty failed with `1603` because
the run was not elevated (D28), and vscode failed with exit 1.

**There is no transfer mechanism, and none appears to have been designed.** A search of every
`.go` file for download, transfer, copy, WinRM, SSH or HTTP verbs returns nothing. `Repository`
is used as a **directory name**, joined with `path` and `filename` and resolved relative to the
process's working directory. The binary and the artifact tree are both expected to already be
on the guest, placed there by a step that does not exist in that repository. That step is ours
— ADR 0003 step 3 — which is the seam.

### 4.4 The seam

[ADR 0003](decisions/0003-package-install-contract.md), accepted 2026-09-28, makes the resolved lock file
the single artifact crossing the boundary, and has this repository treat it as opaque and
immutable: it never parses package semantics, never chooses a handler, never resolves a
version.

| Step | Where | Tool | Owner |
|---|---|---|---|
| 1. Resolve | Anywhere, pinned and committed | `package-runner resolve` | The tooling owner |
| 2. Stage and verify | The runner, inside `runner-image` | `download-packages --lock … --output packages/` | The tooling owner |
| **3. Transfer** | **Runner → guest** | **Packer `file` provisioners** | **Here** |
| 4. Install and re-verify | The guest | `package-runner install --lock … --artifact-root … --evidence-dir … --execution-id …` (ADR 0003, C3) | The tooling owner |
| **5. Collect** | **The runner** | **`collect-evidence.sh`** | **Here** |

Two of five steps are ours. That is the whole interface, and it replaces the fixture staging
that exists today without changing the mechanism — only its inputs.

> **Update 2026-10-02: what runs today.** Steps 3 and 5 are built and proved in CI
> (STORY-04, jobs 3836 and 3835 to 3839), and so is a sixth step the table does not show: a
> post-restart check, `package-runner verify`, whose name is this repository's assumption.
> Steps 2 and 4 run on substitutes, because neither of the owner's tools is usable yet:
> step 2 was `scripts/runner/stage-packages.sh` with `verify-package.sh` in place of
> `download-packages`; **since 2026-10-07 step 2 is the real `download-packages`**, called by
> `stage-packages.sh`, with the fixture lock restated in the lock shape the owner's tools
> read today (ADR 0003, "Interim lock shape"). Step 4 is a **stand-in**,
> `packer/fixtures/package-runner/package-runner.ps1`, in place of a `package-runner` release
> (none exists, and the head does not compile, D34). Step 1 has never run for our lock: the
> fixture lock is hand-written. The swap to the real binary is gated on D8 and D22
> (ADR 0003, "Build side written").
>
> **Update 2026-10-08.** Step 4 has run with the real engine once, as a trial: job 4245
> (2026-10-07) installed and verified the fixture with a build of the proposal branch, which
> fixes D8 and D22. The stand-in remains the default until the owner merges and tags that
> code. There is still no release, but the head now compiles (D34 closed). The owner's stated
> direction for step 1 is to run `resolve` in this repository's pipeline; not designed.

**The proposal was made concrete.** [`packer/fixtures/software/windows-vm-fixture.lock.yaml`](../packer/fixtures/software/windows-vm-fixture.lock.yaml)
expresses the existing `testpkg` fixture in `package-runner`'s `ImageRecipeLock` format, with
real computed hashes and sizes. Nothing in this repository read it when this was written
(since 2026-10-01 it is the lock the build uses, restated in the C1 shape); it existed so the
conversation with the owner is "here is your format describing my fixture — is this what
`resolve` would emit?" rather than "do you agree in principle?". It carries six explicit
`OPEN` markers, each a question the format does not currently answer: what `lockHash` covers
and how it is canonicalised; whether `amd64` or `x64` is the canonical architecture spelling;
what `resolvedFrom` holds in a hand-written lock; which enumerated `repository` names are
valid, and what a package living in git rather than the share is called; what `path` is
relative to; and how a package with more than one file is described, since the fixture ships
both a payload and an `install.ps1` and the artifact block describes exactly one file. It also
carries the one field this repository is asking to have added, `installScope: machine-wide`
(D13). **This file was the agenda for the conversation in step 2 of section 8**, held
2026-09-28. The restated lock is JSON and carries no `OPEN` markers; the questions still
unanswered are in section 4.6 and in the fixture's README.

Until 2026-10-01 the fixture's `install.ps1` threw on purpose, so `package-runner install`
would have failed against this lock by design. Since STORY-04 it copies its payload to
`C:\Program Files\testpkg`, so a completed install leaves something a validation can check.
It is still a fixture: it proves the sequence, not that a real installer works.

The strongest evidence that this is the intended design is that **it is already half built**:
`download-packages.sh` consumes the `package-runner` lock format field for field, on the
runner, before anything is transferred. Neither repository references the other, and the file
format matches anyway.

### 4.5 Defect register

> None of these is a design problem. They are all defects or omissions, listed so the owners
> can see the whole set at once.

All seven findings recorded in ADR 0003 on 2026-09-22 were re-verified on 2026-09-23 and all
seven stand. The register below adds what the second read found, D29–D32 what a read of
`runner-image`'s `add-more-items` at `5c740bd` found on 2026-09-30, D22–D28 what a third read
of `package-runner` at `4881c5d` found on 2026-09-28, D33 what a partial read at
`8e538aa` found on 2026-10-01, and D34 what the full read of that commit found on
2026-10-02, when every `package-runner` entry was also re-checked (ADR 0003, "Read
2026-10-02"; the rows below carry the result where it changed). D35 is what a read and a
scratch-folder run of `runner-image`'s `adjust-script` branch found on 2026-10-05, when the
`runner-image` staging entries were re-checked against that branch (ADR 0003, "Read
2026-10-05"). The rows also carry the read of the `0.2.1` release and of `package-runner` at
`7f73e52` on 2026-10-06 (ADR 0003, "Read 2026-10-06"). Items in `runner-image` and
`package-runner` are requests to their owner; this repository should not fix them.

**The `D` numbers are canonical** (settled 2026-09-24). ADR 0003 originally numbered the
same defects 1 to 15 in a different order; it now carries the mapping from those earlier
numbers, and they are not reused. Cite a defect as `D8`, never as a bare "finding 8".

#### Blocks any end-to-end run

| # | Where | Finding |
|---|---|---|
| D1 | `runner-image` | **`download-packages.sh` does not parse.** `usage()` opens with `{` at `:4` and closes with `)` at `:16`. `bash -n scripts/download-packages.sh` reports `syntax error near unexpected token ')'`. The script aborts before executing anything, whatever arguments it is given. Once it parses, its usage text will print `0` instead of the script name (`:6` reads `Usage: 0` where `$0` was meant). **On branch `adjust-script` at `671e967` (read and run 2026-10-05; unmerged, untagged):** **fixed.** `bash -n` passes, and the usage text prints the script name. **Released 2026-10-06 in `0.2.1` (`d730652`).** The fix is in the image this repository pins. |
| D2 | `runner-image` | **Seven variable assignments are missing their `=`.** `:55-61` read `name $(yq …)`, `version $(yq …)` and so on — each runs a command *named* `name`, `version` and so on, with the yq output as its argument. **Corrected 2026-09-30 (tested):** the first one fails with `name: command not found`, exit 127, and it is `set -e` (`:2`) that aborts the script, not `set -u`. **On branch `adjust-script` at `671e967` (read and run 2026-10-05; unmerged, untagged):** **fixed.** The assignments have their `=` (`:69-85`); a run reads every field. **Released 2026-10-06 in `0.2.1` (`d730652`).** The fix is in the image this repository pins. |
| D3 | `runner-image` | **`--mount-root` is silently ignored.** `:26` reads `MOUNT_ROOT="$2": shift 2 ;;` — a colon where a semicolon belongs. **Corrected 2026-09-30 (tested):** it does not loop. With no space before the colon, the colon is part of the assignment word, so bash parses `MOUNT_ROOT=<value>: shift 2` as an assignment prefixed to the `shift` command: `shift` runs and the loop ends, but the assignment applies only to that one command. The script then reads from the default mount, and nothing reports it — worse than the loop first recorded. **On branch `adjust-script` at `671e967` (read and run 2026-10-05; unmerged, untagged):** **fixed.** `:26` has its semicolon, and a run with `--mount-root` reads from the folder given. **Released 2026-10-06 in `0.2.1` (`d730652`).** The fix is in the image this repository pins. |
| D4 | `runner-image` / `package-runner` | **The `repository` vocabulary does not agree.** `resolve_repo_root` (`:42-47`) accepts exactly one name, and it is misspelled `package-conten` (missing the `t`). The sample lock's two entries declare `packages` (`out/windows-vm.lock.yaml:27`) and `software-artifacts` (`:43`). **Neither resolves, even after the typo is fixed.** One enumerated set of repository names has to be agreed and shared. **At `4881c5d`:** the sample lock has three entries, all declaring `packages`; the defect stands. Agreed fix: `package-content` only (ADR 0003, C1). **On branch `adjust-script` at `671e967` (read and run 2026-10-05; unmerged, untagged):** **changed, not closed.** The misspelled name is gone, but `resolve_repo_root` (`:45-49`) now ignores the name and returns the mount root for anything: a lock naming `not-a-real-repository` staged its file and exited 0. C1 asks for a closed set with `package-content` as its one value; nothing enforces it on this side. **Released 2026-10-06 in `0.2.1` (`d730652`).** Unchanged from the branch: any repository name is accepted. The owner's lock says `packages` and stages correctly. |
| D5 | `runner-image` | **The two halves of the staging step read different lock shapes.** `download-packages.sh:57-61` reads `.packages[i].repository`, `.path`, `.filename`, `.sha256`, `.sizeBytes` — flat. `download-packages.bat:105-109` reads `.packages[i].artifact.repository` and so on — nested. The real lock is **nested** (`out/windows-vm.lock.yaml:26`), so the `.bat` is right and the Linux runner script is reading fields that do not exist. This is a sharper statement of D4 and D6. **On branch `adjust-script` at `671e967` (read and run 2026-10-05; unmerged, untagged):** **fixed for the owner's current lock shape:** the script reads the nested `artifact.*` fields (`:81-85`). It reads one `filename`, not the agreed `files[]` list (C1), so this repository's C1-shaped fixture lock fails with `Source artifact not found: …/null`. The `.bat` is unchanged. **Released 2026-10-06 in `0.2.1` (`d730652`).** `download-packages.bat` changed in the release and was not re-read. |
| D6 | `runner-image` / `package-runner` | **Runner-side and guest-side path layouts disagree.** `download-packages.sh:67` writes to `<output>/<name>/<version>/<filename>`. `package-runner`'s executor joins `artifact.repository`, `path` and `filename` relative to its working directory. For the sample lock that is `packages\..\..\packages\firefox\18.5.0\Firefox Installer.exe` — not where staging put the file. The lock's two entries also disagree with each other (`..\..\packages\…` vs `.\packages\…`) and both use Windows separators, which the Linux runner will not resolve. PROPOSED: the lock carries a path relative to a staging root both sides are told, normalised at resolve time. **At `4881c5d`:** all three entries use `.\<name>\<version>` and the filename is now `Firefox-Installer.exe`; the entries agree with each other, but still use Windows separators relative to the working directory, so the defect stands. Agreed fix: ADR 0003, C2. **At `0.2.1` and `7f73e52` (2026-10-06):** resolved in practice for the owner's lock, by convention. `download-packages` writes `packages/<name>/<version>/<filename>` and `package-runner` joins `packages`, `./<name>/<version>` and the filename relative to its working directory, which is the same path when it runs from the folder holding `packages` (INFERRED from reading both; not run in a guest). There is still no `--artifact-root` (C2). **State 2026-10-08:** still no `--artifact-root` on `main` (`a27199e`). the proposal branch `proposal/build-contract` (`c9f1439`) adds it and resolves each file as `<root>/<name>/<version>/<filename>`; OBSERVED working in a guest in job 4245. The owner has not merged it. |
| D7 | `runner-image` | **The staging entry point is not shipped.** `download-packages` and `yq` exist only on the unmerged `add-more-items` branch. Tag `0.0.20`, which we pin, has neither. A tagged release is a prerequisite, and our pin will have to move. **Update 2026-09-30:** shipped in `0.1.0` (`a321d26`) as `/usr/local/bin/download-packages`, with `yq` — but the script is byte-identical to `5c740bd` and still does not parse (D1); D2–D6, D31 and D32 stand. Shipped, and broken. **Update 2026-10-05:** a reworked script that parses and runs is on the unmerged branch `adjust-script` (`671e967`, 2026-10-02). It is in no tagged image: the newest tag is still `0.1.0`. Its commit message, "publish a new image to test", suggests a test image was built from the branch (INFERRED; the pipeline tags branch builds with the short commit hash). **Closed 2026-10-06:** `0.2.0` and `0.2.1` (both `d730652`) ship a `download-packages` that runs. OBSERVED in the owner's `runner-test-bed` job on our runner: two real packages staged and verified. The pin moved to `0.2.1` the same day. |

#### Breaks the fail-closed guarantee

| # | Where | Finding |
|---|---|---|
| D8 | `package-runner` | **Guest-side SHA-256 is never recomputed.** `verifyFileHash` (`internal/validation/validator.go:431-438` at `4881c5d`) takes a `filePath` it never uses; its comment reads "Implementation would read the file and compute SHA256", and it checks only that the expected hash is 64 characters. On the `install` path it is weaker still: `validateArtifact` (`internal/executor/executor.go:314-324` at `4881c5d`) checks only that `SizeBytes != 0` and the hash is 64 characters long. **No file on the install path is ever hashed.** This is the single most important gap — until it closes, step 4 does not meet the guest re-verification rule, and the engineering rules are not satisfied. **Re-read 2026-10-02 at `8e538aa`: stands.** `validateArtifact` is at `executor.go:323-333`, unchanged in substance; the `verifyFileHash` stub is gone with `internal/validation/`. Nothing on the install path hashes a file. **State 2026-10-08:** stands on `main` (`a27199e`): nothing on the install path hashes a file. the proposal branch `proposal/build-contract` (`c9f1439`) recomputes the size and SHA-256 of every staged file before any handler runs and exits 11 on a mismatch or a missing hash (tests). The owner has not merged it. |
| D9 | `package-runner` | **Three of the four live validators are unimplemented.** `internal/validation/validator.go:123`, `:158` and `:193` (at `4881c5d`) return `"Windows registry validation not implemented"`, `"Windows service validation not implemented"` and `"command validation not implemented"`. The fourth, `file`, does an existence check only. **Changed at `8e538aa` (re-read 2026-10-02).** The live validators are now those in `internal/validators/`. `file` recomputes SHA-256 and compares size (`file_validator.go:74-85`), but any `version` parameter fails, because `getFileVersion` returns an empty string (`:107-109`). `registry` and `command` are implemented. `service` is simulated and returns success unconditionally (`service_validator.go:58-62`). **State 2026-10-08:** stands on `main` (`a27199e`): `getFileVersion` still returns an empty string and `service` still returns success unconditionally. On the proposal branch `proposal/validation-evidence` (`73a4243`) the file version is read from the version resource and `service` queries the real service (tests). The owner has not merged it. |
| D10 | `package-runner` | **A second, unreachable validator implementation exists, and it false-passes.** `internal/validators/` and `internal/schema/` (723 of ~4,100 Go lines) have **no importers**. Its registry and service validators print a message and return `PackageStatusSuccess` unconditionally (`registry_validator.go:72`, `service_validator.go:62`). Harmless while dead; dangerous if ever wired up by mistake. **Changed at `8e538aa` (re-read 2026-10-02): it was wired up.** `internal/validators/` is now what the executor calls (`executor.go:284`), so the unconditional success of its `service` validator is live, not dead. `internal/schema/` still has no importer. **State 2026-10-08:** unchanged on `main` (`a27199e`): `internal/schema/` still has no importer. |
| D11 | `package-runner` | **The `timeout` field is inert in every handler.** `exe.go:92`, `powershell.go:100` and `psadt.go:87` all create `context.WithTimeout` *after* `cmd.Start()`, assigning it to a new local that the already-started process is not bound to; `cmd.Wait()` then blocks indefinitely. The executor compounds this by calling handlers with a bare `context.Background()` (`executor.go:212` at `4881c5d`), so even the structurally sound MSI path has no deadline. A package that hangs, hangs the build. **State 2026-10-08:** stands on `main` (`a27199e`). Confirmed handler by handler on 2026-10-07: `exe`, `powershell` and `psadt` create the timeout context after the process has started and attach it to nothing, and `msi` waits on a context with no deadline. the proposal branch `proposal/build-contract` (`c9f1439`) enforces the timeout once, in the executor, for every handler (a test stops a 60 second script in 3). The owner has not merged it. |
| D22 | `package-runner` | **Failed validation or a pending restart does not fail the run.** `executor.go:147-172` counts only `success` and `failed`; `validation_failed` and `restart_required` are neither, so `OverallSuccess` stays true and `install` exits 0 (`cli.go:212`). With D9, nothing on the install path can fail on installed state. **At `66a9d0a` and `34bfc7f` (2026-10-07): unchanged.** (An earlier version of this row said "worse"; that misread a second copy of the validation block, in `getArtifactPath`, which runs before the install and discards its result. The block in `installPackage` still sets `validation_failed`.) Also on this path at `34bfc7f`: an unknown validator type is logged as skipped and then called through a nil interface, a non-success result with a nil error is dereferenced, and the `service` validator is a placeholder that always passes. **State 2026-10-08:** stands on `main` (`a27199e`). On the proposal branch `proposal/validation-evidence` (`73a4243`) a failed validation and a validator that cannot be created fail the package and the run, and the two panics are gone. The later branch, `proposal/build-contract` (`c9f1439`), also fails a package that declares no validation, and gives the failure exit code 10. The owner has not merged it. |
| D23 | `package-runner` | **A package that needs a restart is never validated.** Validation runs only on `success` (`executor.go:276`). **State 2026-10-08:** stands on `main` (`a27199e`). the proposal branch `proposal/build-contract` (`c9f1439`) adds `verify`, which runs every package's validations after the restart, and reports the restart with exit 3010; OBSERVED `verify` exit 0 in a guest in job 4245 (no restart was needed in that run). The owner has not merged it. |
| D25 | `package-runner` | **A package whose dependency failed is still installed.** The `continue` at `executor.go:128` leaves only the inner loop over dependencies. **State 2026-10-08:** stands on `main` (`a27199e`). Fixed on the proposal branch `proposal/build-contract` (`c9f1439`): a package whose dependency did not install is recorded as `blocked_dependency` and not installed (test). The owner has not merged it. |
| D27 | `package-runner` | **Without `--continue-on-failure`, installation continues anyway** (`executor.go:149-166`): the committed evidence shows putty (`installOrder` 10) failing, then firefox (20) running and succeeding, then vscode (30) running and failing with exit 1. `PublicationEligible` stays `true` despite two failures. **At `8e538aa`:** the code is unchanged (`executor.go:152-171`); the committed evidence was replaced by a two-package run (putty succeeded, firefox failed 1603) that no longer shows the sequence, and still records `PublicationEligible: true` beside a failed package. **No longer a defect: the owner's decision, 2026-10-07.** She asked that `install` carry on after a failed package and report every failure, stopping only for dependents; C3's "stop at the first failed package" is reversed (ADR 0003, "The owner's review"). the proposal branch `proposal/build-contract` (`c9f1439`) implements that, adds `--stop-on-failure`, and records `publication_eligible: false` for any run with a failure. |
| D28 | `package-runner` | **No elevation check.** The committed PuTTY run failed `1603`; its MSI log (`evidence/putty/instal.log:382`) reads `Error 1925. You do not have sufficient privileges`. **At `8e538aa`:** still no elevation check anywhere in the code; the cited log was removed upstream. **State 2026-10-08:** stands on `main` (`a27199e`). the proposal branch `proposal/build-contract` (`c9f1439`) checks elevation before anything else and exits 12 (tests; OBSERVED exit 12 from the built binary in an unelevated shell on the workstation). The owner has not merged it. |
| D33 | `package-runner` | **A validation that fails, or names an unknown handler, crashes the run instead of failing it** (`executor.go:284-299` at `8e538aa`, read 2026-10-01). When `NewValidator` returns an error the code logs "Skipping validation" and then calls `Validate()` on the nil validator; when `Validate` returns a non-success result with a nil error, the log call evaluates `err.Error()` on that nil. INFERRED by reading the diff; not run. The same commits moved the live validators to `internal/validators/` and deleted `internal/validation/`, so D8–D10 were re-read on 2026-10-02 (their rows carry the result). Confirmed the same day against the whole function (`executor.go:284-298`); still not run. **State 2026-10-08:** stands on `main` (`a27199e`). Fixed on the proposal branch `proposal/validation-evidence` (`73a4243`): an unknown validator type leaves a failed evidence record, and a non-success result with a nil error is no longer dereferenced (tests). The owner has not merged it. |
| D34 | `package-runner` | **The head of `init` does not compile as committed.** OBSERVED 2026-10-02: `git archive 8e538aa`, extracted outside the clone, fails `go build ./...`. `executor.go:16` and `file_validator.go:13` import `package-runner/internal/pathutil`, which is in no commit, and `cli.go:151` calls `validators.NewLockValidator`, defined only in the deleted `internal/validation/`. First broken at `626e691` (2026-09-29); `4881c5d` compiles. Any binary run since then came from a working tree holding files the repository does not, so nothing since 2026-09-24 can be rebuilt, and nothing can be released and pinned by hash (C3, D18) until the commit builds. **At `7f73e52` (2026-10-06): stands.** The same build of an extracted archive fails on the same missing package. **At `66a9d0a` (2026-10-07): stands.** **At `34bfc7f` (2026-10-07): stands**, on `internal/pathutil`. **CLOSED 2026-10-07 at `a27199e`.** The owner committed `internal/pathutil` and `NewLockValidator`, merged `init` into `main` and deleted `init`. OBSERVED: a `git archive` of `main` builds. |
| D31 | `runner-image` | **`download-packages.sh` accepts paths that escape its folders.** `:66-68` build the source and destination from the lock's `name`, `version`, `path` and `filename` with no check, so a `..` or absolute value reads from outside the mount and writes outside `--output`. ADR 0003's C2 requires relative paths with no `..`; the script must enforce it. Found 2026-09-30, by reading `add-more-items` at `5c740bd`. **On branch `adjust-script` at `671e967` (read and run 2026-10-05; unmerged, untagged):** **stands, now tested.** A lock with `path: ../outside` copied a file from outside the mount into the output tree and exited 0 (`:91-93` are still unchecked). **Released 2026-10-06 in `0.2.1` (`d730652`).** Unchanged from the branch: stands. |
| D32 | `runner-image` | **A file that fails verification is left in the staging tree.** `:77` copies the artifact into the output tree before checking it, and a size or hash failure at `:82-92` only `continue`s. The script does exit 1 at the end (`:97-99`), so the harm depends on the caller stopping on that exit code; but the tree Packer uploads under C2 should only ever hold verified bytes. Copy to a temporary name and rename on success, or delete on failure. Found 2026-09-30, by reading. **On branch `adjust-script` at `671e967` (read and run 2026-10-05; unmerged, untagged):** **fixed.** A size or hash mismatch now deletes the copied file (`:113`, `:124`); a run with a wrong hash left the output tree empty and exited 1. **Released 2026-10-06 in `0.2.1` (`d730652`).** The fix is in the image this repository pins. |
| D35 | `runner-image` | **A lock entry with no hash is staged unverified and reported as verified.** Found 2026-10-05 on `adjust-script` at `671e967`, by running it. `:84-85` default a missing `sha256` to empty and a missing `sizeBytes` to 0, and `:111` and `:119` skip each check when its value is absent. A lock entry carrying neither was copied and the script ended `All 1 packages downloaded and verified successfully`, exit 0. The engineering rules require an expected SHA-256 before runtime and failure when a check cannot be made; a missing hash should fail the entry. The same script also skips, with a warning and exit 0, a package that has no `artifact` block (`:73-78`). **Released 2026-10-06 in `0.2.1` (`d730652`).** Unchanged from the branch: stands. The owner's lock carries a hash for every entry, so her test does not reach it. |
| D36 | `package-runner` | **`validate --verify-artifacts` verifies nothing.** OBSERVED 2026-10-07 at `a27199e`: `verifyFileHash` in `internal/validators/lock_validator.go` checks only that the expected hash is 64 characters long and never opens the file; its own comment says the implementation is still to come. A lock whose artifacts do not match passes. `install` does not call it; on the proposal branch `install` re-hashes every staged file. |
| D37 | `package-runner` | **New package definitions are ignored by git.** OBSERVED 2026-10-07 at `a27199e`: the new `.gitignore` lists `/packages/*`, meant for a local package store. The definitions already tracked under `packages/` stay tracked, but a new package folder is not picked up by `git add`. It matters once a lock is generated in the pipeline from those definitions, which must then come from a commit. |
| D38 | `package-runner` | **Console timestamps print the wrong year.** OBSERVED 2026-10-07 in the log of job 4245: lines begin `8086-10-08T02:52:24.654Z`. `internal/logging/console.go` formats the time with the layout `2026-01-02T15:04:05.000Z`, which is not Go's reference time (`2006-01-02…`), so the year digits are read as other fields. The JSON log and the result file are not affected. Cosmetic, but it is in every build log. Seen again 2026-10-12 (jobs 4408 and 4441) as `12126-10-12T…`: the wrong year changes with the date. |

#### Blocks evidence collection

| # | Where | Finding |
|---|---|---|
| D12 | `package-runner` | **Evidence is not in an agreed form.** Read 2026-09-23: `saveEvidence` was a no-op. **Changed at `4881c5d`:** it writes `package-execution-evidence.json` (`executor.go:347-372`) — a name `collect-evidence.sh` indexes as `other` (we reserve `install-result*.json`), with mixed key casing, durations in Go nanoseconds, local-offset timestamps and raw installer stdout/stderr; a failed write is only logged. The agreed format is C4 in [ADR 0003](decisions/0003-package-install-contract.md#contract-terms-story-09), accepted 2026-09-28. **State 2026-10-08:** stands on `main` (`a27199e`), which still writes `package-execution-evidence.json`. the proposal branch `proposal/build-contract` (`c9f1439`) writes `install-result.json` and `install-result-verify.json` in the C4 shape; OBSERVED downloaded by the build in job 4245. The owner has not merged it. |

#### Blocks ADR 0002 (sealing)

| # | Where | Finding |
|---|---|---|
| D13 | `package-runner` | **Install scope is absent.** A case-insensitive search of every `.go`, `.yaml` and `.md` file for scope, per-user, all-users, machine-wide, elevation or run-as returns **zero hits**. [ADR 0002](decisions/0002-master-image-identity-and-sealing.md)'s generalization check must classify every package as machine-wide or per-user. PROPOSED: a required field on `PackageDefinition`. **This is the one addition to the format this repository asks for.** It is not hypothetical — the vscode sample (`packages/vscode/1.135.0/package-definition.yml`) is `VSCodeUserSetup-x64-…exe`, the explicitly per-user installer, which would land in the build account's profile and be lost at generalization. **State 2026-10-08:** stands on `main` (`a27199e`): no `installScope` anywhere. Not addressed by either proposal branch. |

#### Correctness and hygiene, lower priority

| # | Where | Finding |
|---|---|---|
| D14 | `package-runner` | **The recipe hash is computed and then discarded.** `resolver.go:92` computes it and `:484` sets it as the lock's `LockHash`, then `:174` overwrites that with the lock hash. No `PackageDefinition` hash is computed at all. Provenance intended by the design does not reach the lock. **State 2026-10-08:** stands on `main` (`a27199e`): no recipe or definition hash reaches the lock. Not addressed by either proposal branch. |
| D15 | `package-runner` | **A spec typo is baked into the wire format.** `models.go:134` tags the field `restartExistCodes` (not `restartExitCodes`) in both YAML and JSON. A definition author writing the correct spelling has it silently ignored. Cheap to fix now, breaking to fix later. **Still so at `8e538aa`,** and the owner's new README writes `restartExitCodes`, the spelling the code ignores. **CLOSED 2026-10-07 at `34bfc7f`** ("fix typo"): the lock key is now `restartExitCodes`. The stand-in still reads both spellings. |
| D16 | `package-runner` | **Placeholder values in the sample data.** Both sample definitions carry the same `sha256` and `sizeBytes: 123456` (`out/windows-vm.lock.yaml:30-31`, `:46-47`). Expected for a scaffold; noted so a lock is not mistaken for resolved. **At `4881c5d`:** three entries, all `repository: packages` with Windows-style `.\name\version` paths and the **same** `sha256`; firefox's validation path is misspelled `flirefox.exe`, putty's filename has a leading `/`. **At `7f73e52` (2026-10-06): improved.** Two entries (Firefox 156.0.1, PuTTY 0.83.0) with distinct, real hashes and sizes and forward-slash paths; PuTTY's filename still has a leading `/`. **State 2026-10-08:** stands on `main` (`a27199e`): PuTTY's filename in `out/windows-vm.lock.yaml` still has a leading `/`. `download-packages` and the proposal branch `proposal/build-contract` (`c9f1439`) both tolerate it. |
| D17 | `ci-platform` | **The script-fallback path cannot work** (section 4.1): a directory `cp`'d onto a file path, at a path that does not match where promotion writes. The stack runs on the `~/bin` promotion alone. |
| D24 | `package-runner` | **`restartBehavior: block` blocks nothing** — it logs a warning (`executor.go:296-300`). **State 2026-10-08:** stands on `main` (`a27199e`): it still only logs. Not addressed by either proposal branch. |
| D26 | `package-runner` | **`resolve` reports a false cycle for any dependency.** `resolver.go:425-431` decrements the in-degree of the current package's dependencies instead of its dependents, so a package with any dependency never reaches zero. Traced by reading, not run. Dependencies are unusable until fixed. **State 2026-10-08:** not re-read. `resolve` ran without error against the owner's `windows-vm.yaml` on 2026-10-07, but that recipe declares no dependencies, so this path was not exercised. |
| D29 | `runner-image` | **`download-packages.bat` overwrites the artifact it has just verified.** `:159` reads `echo     OK-> !dest!`: the unescaped `>` redirects the status text into the verified file, which then contains `    OK-` instead of the installer. **Tested 2026-09-30** in `cmd`. The `.bat` is not copied into the image (`Dockerfile:32-33` installs only the `.sh`) and ADR 0003 gives the guest step to `package-runner`, so it has no role in the flow. PROPOSED to the owner: delete it rather than fix it. |
| D30 | `runner-image` | **`download-packages.bat` has three more defects**, each tested in `cmd` by a 2026-09-30 review; the misplaced `%` on `:62` below was found by reading. The `:next_package` label inside a `for` block (`:161`) fails to parse, so no package is processed. A successful run falls through from `:170` into `:usage` and exits 1 (`:184`). Unescaped `)` in `failure(s)` and `(expected …, got …)` (`:147`, `:154`, `:166`) close the surrounding block early. Also `:62` has a misplaced `%` (`"%OUTPUT_DIR\NUL%"`), so its existence check never works. Moot if the file is deleted (D29). |

#### Release discipline and supply chain

| # | Where | Finding |
|---|---|---|
| D18 | `package-runner` | No tags, no CI, **no tests**, and the default branch holds only an initial commit. ADR 0003 step 4 requires pinning a version of a binary that has never been released. **State 2026-10-08:** still no tags, no CI file and no test files on `main` (`a27199e`). `main` is no longer an initial commit: `init` was merged into it on 2026-10-07 and deleted. The two proposal branches add 42 Go tests in 9 files. The trial binary this repository carries is built from a commit, not from a tag. |
| D19 | `runner-image` | Twenty-one tags over **three** commits (corrected 2026-09-30; first recorded as four): `2654d2f` carries 14, `79a11ae` 6, `1dac874` 1. The numbering also runs backwards in history — `0.0.1`–`0.0.4` sit on a newer commit than `0.0.5`–`0.0.17`. `0.0.20` cut from `dev-branch`; `main` is stale. Version numbers do not identify content. **Update 2026-09-30:** `0.1.0` is the head of `main` (`a321d26`), the first release where `main` and the tag agree. **Counted 2026-10-02:** 22 tags over four commits (`2654d2f` 14, `79a11ae` 6, `1dac874` 1, `a321d26` 1). `main` was rebuilt by one squash commit (`d752d5b`) on `2654d2f`, so `0.0.20` is not an ancestor of `0.1.0`: the history of what earlier images contained survives only in the tags. |
| D20 | `runner-image` | Base image `ubi10/ubi-minimal:latest` is unpinned; the Packer, `yq` and (since `0.1.0`) `govc` downloads are pinned by version but not checksum-verified; distro packages are unpinned. On 2026-09-30 the owner said she does not agree with the extra checksum work, so this stands as her position rather than an open request. A repository whose own engineering rules require exact versions and pre-established hashes runs on an image built without them. |
| D21 | `runner-image` | The pipeline template is included at `ref: "main"` — a moving reference. A change to `ci-platform`'s default branch changes every consumer's pipeline with no version gate. |

**Two claims investigated and dropped on 2026-09-23 were wrong to drop** (corrected
2026-09-28). `ContinueOnFailure` is not inverted, but without it the executor still installs
every remaining independent package (D27). And the resolver's topological sort *is* broken:
it reports a false cycle for any dependency (D26).

### 4.6 Open questions for the owner

| Question | Why it matters |
|---|---|
| ~~Is the lock the contract artifact?~~ **Yes, agreed 2026-09-28** (ADR 0003). | Everything in section 4.4 depends on it. |
| ~~Does the recipe format supersede the baseline manifest?~~ **Yes, agreed 2026-09-28** (ADR 0003). | The formats are near-isomorphic. The interim baseline manifest retires when `download-packages` works. |
| Can install scope become a required field on `PackageDefinition`? **Agreed in principle 2026-09-28 (C1); not in the code at `8e538aa`.** | The MCS catalog proof needs every package classified (D13). |
| ~~What is the evidence format, and where does the guest write it?~~ **Agreed 2026-09-28: C4**, `install-result.json` in `--evidence-dir`. Not in the code at `8e538aa`. | `collect-evidence.sh` needs it to index installs (D12). |
| Which set of `repository` names is canonical? **`package-content` is the one agreed value** (C1); the sample lock at `8e538aa` still says `packages`. | D4. |
| Is `ci-platform` intended to stay a mock? | Section 4.1. A real registry would be the first credential and the first network dependency in this stack. Asked because the answer changes how image provenance is described, not to suggest a change. |
| How does the `package-runner` binary reach the guest, at what pinned version? **Half answered:** this repository uploads it and pins it by a committed SHA-256 (C3). There is still no release to pin, and the head does not compile (D34). **2026-10-08:** the head compiles (D34 closed at `a27199e`); still no tag. A trial build of a proposal branch is pinned here by hash, off by default. | D18. |
| **Raised by STORY-04, 2026-10-01:** is the post-restart command called `verify`? | The build already calls it, against the stand-in. A different name is a one-line change here, but it has to be agreed. **2026-10-08:** the proposal branch implements `verify` under that name and the owner, on review, raised no objection to it; not yet on `main`. |
| **Raised by STORY-04:** are the lock's field names (`files[]`, `entryPoint`, `installScope`, `restartExitCodes`) what the published schema will use? | The fixture lock is this repository's reading of C1; it is restated when the schema ships. |
| **Raised by STORY-04:** are a top-level `exit_code` and `command` in the result, and installer output in separate log files, acceptable additions to C4? | The stand-in writes them; the build reads `exit_code`. **2026-10-08:** the proposal branch writes all three, plus `restart_required` and `lock_sidecar` at the top level and `validation.results` per package; the owner has reviewed the branch. Not yet on `main`. |
| **To report:** D33 and D34. | A failed validation crashes the run, and the head of `init` does not build from source control. |
| **To raise, once verified (added 2026-10-02):** can a package list restart codes other than 3010, and can one mean "restart, then run the installer again"? | The Citrix VDA installer is reported to return 3 and 8 (ADR 0002, requirement 5). C3 anticipates only 3010. ADR 0003, owner's question 9. |

---

## 5. Retrospective

### 5.1 Defects found and resolved in this repository

**1. The original blocker: the WinRM communicator failing over HTTP.**
Builds installed Windows, joined the domain, ran the bootstrap, then timed out waiting for
WinRM — 476 `401 - invalid content type` errors over 40 minutes, while the guest's Security
log showed the service account logging in successfully. Two independent facts pointed the same
way: Packer's NTLM client completes the handshake but never signs or encrypts WinRM messages,
so unencrypted requests hit a service that rejects them by default (`AllowUnencrypted =
false`); and the fix was effectively a single-variable change — same account, same template,
same VM — that flipped behavior from 476 identical rejections to a clean connection. Fixed by
moving to HTTPS on 5986 with a per-build self-signed certificate, a bound listener, and a
firewall rule scoped to the runner ([ADR 0001](decisions/0001-winrm-https-communicator.md)).
**INFERRED, not proven:** a controlled same-build A/B test was never run, so this remains the
leading explanation rather than a demonstrated mechanism.

**2. Path resolution broke in CI but not locally.** `packer validate` passed locally with an
absolute template path, then failed in CI with a doubled path. CI invokes Packer relatively,
which makes `path.root` a relative string, and `templatefile()` prefixed it twice. Worth
recording that the *first* fix was wrong: switching from `path.cwd` to bare `path.root` passed
locally precisely because local testing used absolute paths. `abspath()` is what actually
resolved it, verified against four invocation styles before being trusted.

**3. The VM cleanup script was unsafe** — found by reading it before ever running it. `-Kill`
is not a real `Remove-VM` parameter; there was no `-DeletePermanently`, so a working run would
have left files on the datastore; and `Get-VM -Name` treats input as a wildcard while
`make clean-vm` piped arbitrary log lines into it. Rewritten to reject wildcards, require an
exact name containing `packer-`, refuse more than one match, and support `-WhatIf`/`-Force`.

**4. Repository hygiene.** A `.PHONY` typo, a `collect-evidence` target pointing at a
nonexistent script, `load-env` requiring a `.env` CI does not have, `build-diagnostic`
sourcing `./.enc`, `validate.sh` calling a script without its required parameter, malformed
`.gitignore` patterns that did not actually ignore local env files, unreferenced Python with a
syntax error, and a stale static `autounattend.xml` that `preflight.sh` was checking instead
of the real template. All fixed or removed.

**5. Environment-specific config was tracked in git** — the vCenter host, a personal username
and the runner IP. Untracked; CI now supplies it as the `PACKER_VARS_FILE` file variable.
**What this did not do:** `git rm --cached` does not rewrite history, and the values are still
reachable at `361ebda`. They are not secrets, so a rewrite is probably not warranted, but they
are not gone.

**6. Two CI syntax bugs.** A job-level `variables:` block using `description:` keys — legal
only at top level — broke the *entire* pipeline, not just its job. And a `sed` edit had turned
`set -- -var-file=…` into `set ---var-file=…`, caught by running the generated shell block
locally rather than reading the diff.

**7. The significant one: a silent environment-variable delivery failure.** The guest identity
check was added as the *first* provisioner to execute after WinRM connects, using Packer's
`environment_vars` on a `script=` provisioner — the same mechanism already working reliably at
position 6 for staging verification. The script executed, the variable was empty inside it,
and the build aborted. Nine local test cases passed, because nothing was wrong with the
script's logic. **INFERRED, and never traced:** Packer's environment-variable delivery may
behave differently for the first command after a fresh reboot. That rests on a single failed
run. Fixed by uploading the script with a `file` provisioner and setting its inputs as direct
`$env:` assignments in an `inline` block.

**A second, worse bug found while fixing the first:** `exit 1` inside a script invoked with
`& 'path'` from an inline block does not terminate the wrapping script. Without an explicit
`exit $LASTEXITCODE`, a *failing* identity check would have silently reported success.

**8. A deliberate choice, not a bug.** For the invalid-credential test, a made-up nonexistent
account is used rather than a wrong password for the real shared service account — WinRM
retries every few seconds for the whole timeout, and repeated failed logons could lock the
account out for every future build.

**9. A build input was being written into the evidence folder.** `verify-package.sh` emitted
`package-vars.pkrvars.hcl` into `evidence/`, which `collect-evidence.sh` indexes and CI
uploads — so a build *input* was hashed and published as part of the build's own *output*,
and a stale file from an earlier run could be indexed as though it belonged to the current
one. Moved to `build/`. Six touch points updated. The verified hash was never lost; it was
always in `package-verify-<ts>.json`.

**10. The domain-join password survived in the guest.** OBSERVED on retained VM
`packer-build-002`: Windows Setup keeps **two** copies of the answer file in
`C:\Windows\Panther\`. It scrubs `unattend.xml` and leaves `unattend-original.xml`
**unscrubbed**. The asymmetry is the whole finding — checking only `unattend.xml` shows a
scrubbed file and suggests there is no problem. The service account password was therefore
readable on every VM the build produced, and would have shipped in any template or clone made
from one. `Remove-BuildArtifact.ps1` now deletes both and fails the build unless a recursive
scan finds no surviving `<Password>` element. **Known gap:** a failed build retains its VM and
never reaches that step.

**11. The ISO qualification record described a copy the build never boots.** The record
carried a SHA-256 for a copy on the file share; the build boots a different copy on the
datastore; nothing compared them. The recorded hash said nothing about the bytes any VM
actually booted. Worse, the VMware Tools ISO had **no record at all** while
`enable-winrm.ps1` runs `setup.exe` from it as SYSTEM during specialize — the one build input
executed in the guest with no integrity checking of any kind. Rewritten as a two-stage chain
against one hash ([ADR 0004](decisions/0004-iso-library-and-qualification.md)). When
finally measured on 2026-09-23, both copies matched their records — so the chain had held
and no image booted unqualified media. That was not guaranteed; it was unchecked. The rename
immediately surfaced a real bug — `verify-iso.sh` still read the old field name, so stage 1
would have failed on every record — which is the argument for the change making the chain
checkable at all.

### 5.2 Stories completed

**STORY-01 — Windows communicator with the administrative service account.** `communicator =
"none"` replaced with WinRM/HTTPS/NTLM authenticating as the admin service account, plus
`Test-GuestCommunicator.ps1` as the build's first executing step: it runs inside the
authenticated session and fails the build unless the identity matches exactly and has
administrative rights, writing a sanitized JSON result containing no account name or
credential. AC1, AC3 and AC5 proven in the harness and a full build; AC4's two failure modes
proven in the harness only, since deliberately failing a two-hour build to watch it time out
is not worth the runner time.

AC2 is **Met, with its scope stated**: no credential material in the working tree, HCL,
variable files, pipeline YAML, logs or evidence, and a history scan across all 14 refs found
no occurrence of the current password values. Two disclosures stand. The rendered answer file
on the build floppy holds the domain-join password for the build's duration, because the join
requires it. The vSphere plugin deletes the floppy image on success; **on a failed build
under `-on-error=abort` it does not** — corrected 2026-09-28 (STORY-02, job 3531), when an
induced failure left the image attached and on the datastore, and a scan found seven orphaned
ones from earlier builds. And the
guest-side cache — item 10 above — is now found, removed and proven gone **on a successful
build**; a failed build's retained VM still has it.

**STORY-06 — package staging.** Two-layer verification: `verify-package.sh` checks the
manifest and SHA-256 on the runner before Packer starts, Packer uploads into a standard
staging directory, and `Test-StagedPackage.ps1` re-verifies in the guest. The catalog had no
suitable machine-wide package, so a self-contained fixture stands in — documented in ADR 0003
as interim, swappable for a real package without touching the mechanism. The failure path was
proven with a real harness run (wrong expected hash → guest check fails → build stops), and
the runner-side gate separately against a stubbed Packer: with a tampered fixture, `packer
build` is invoked **0 times**, no variable file is written, and evidence is still indexed with
`outcome: failed`.

**STORY-07 — build evidence collection.** `collect-evidence.sh` indexes every evidence file
into `index.json` (roles, sizes, SHA-256) and `SHA256SUMS`, running both at the natural end of
a build and from GitLab's `after_script`, so it captures evidence from failed and cancelled
jobs. A fail-closed secret guard deletes any file containing a literal secret and fails the
job without printing the value, verified by planting one. The stretch criterion (installation
results) is explicitly **not met** — nothing installs software — which is blocked on a
cross-team decision, not on anything this sprint owned.

### 5.3 Decisions

| ADR | Status | Substance |
|---|---|---|
| [0001](decisions/0001-winrm-https-communicator.md) | Accepted | WinRM over HTTPS on 5986 with a per-build certificate. |
| [0002](decisions/0002-master-image-identity-and-sealing.md) | **Accepted** 2026-10-01 | A domain-joined master, no sysprep, sealed by a scripted step, for Citrix MCS (STORY-10). |
| [0003](decisions/0003-package-install-contract.md) | **Accepted** 2026-09-28 | The `package-runner` lock is the contract artifact, with the contract terms C1–C4 (STORY-09). |
| [0005](decisions/0005-publish-form-and-image-identity.md) | Accepted for the lab; revised 2026-10-01 | The image is published as a master VM with a versioned snapshot and identified by instance UUID and snapshot; the reference's checksum is the build evidence index's SHA-256, not an image hash. |
| [0004](decisions/0004-iso-library-and-qualification.md) | Accepted for the lab | The datastore is the ISO library; qualification is a two-stage chain against one hash. |

**Sealing was undecided, not merely unbuilt, until 2026-10-01.** ADR 0002's choice determines
what the sealing step *does*, so the step could not be designed until someone decided, and
it waited on Citrix input, not on engineering time. That input arrived on 2026-10-01
(the Citrix stakeholders): desktops are created by MCS, so the master stays
domain-joined and is not generalized. The same was true of the install contract, which was
agreed on 2026-09-28. Both are now unbuilt rather than undecided.

---

## 6. What went well, and what to do differently

**Worth keeping:**

- **The staging harness.** `packer/tests/staging-provisioners.pkr.hcl` replays the guest
  provisioners against an already-running retained VM, turning a 21-minute feedback loop into
  90 seconds. Every guest-side fix since was developed against it. Building it was the single
  highest-leverage hour in the project.
- **Evidence that survives failure.** Collection runs from an `EXIT` trap *and* the CI
  `after_script`, so a cancelled or timed-out job still produces an indexed, hashed artifact.
  Most of what we learned about failure modes came from evidence of builds that failed.
- **Fail-closed by default, and testing that it is.** The secret guard was proven by planting
  a fake secret; the runner-side gate by tampering with a fixture; the guest-side gate by
  passing a deliberately wrong hash. Each of those found something.
- **`OBSERVED` / `INFERRED` labels in the ADRs.** This is why section 4 could be written at
  all. When the adjacent repositories were finally read, the ADRs already distinguished what
  had been measured from what had been assumed, so the read *corrected* specific claims
  instead of invalidating the document.

**Worth doing differently:**

- **Read the adjacent repositories in week one.** They were read directly for the first time
  on 2026-09-22 — five weeks in. That read immediately produced seven blocking findings and
  rewrote ADR 0003 from scratch. Every one of those findings existed on day one. The cost of
  finding them late is that two sprints of work were specified against an interface nobody had
  looked at.
- **Proving a mechanism on a fixture defers integration risk rather than reducing it.** The
  fixture staging proof was the right call under the constraint — the catalog had no suitable
  package — and it does work. But it proved the half of the problem we controlled, and the
  half we did not control is where all the blockers turned out to be.
- **Verify the thing, not a proxy for it.** Both ISO qualification (ADR 0004) and the Panther
  password were the same class of error: a check that looked correct and measured the wrong
  object. The hash described a copy nothing booted; the scan checked the file Windows scrubs
  rather than the one it does not. In both cases the fix was cheap and the exposure had been
  live for weeks. When writing a check, name precisely which bytes it reads.

---

## 7. Open risks and security debt

| Risk | State | Owner | Recorded |
|---|---|---|---|
| **A failed build leaves the domain-join password on its retained VM** | **Accepted for the lab by owner override, 2026-09-28** (`AGENT_HANDOFF.md`, Key Design Decision 8; STORY-02). OBSERVED on an induced failure (job 3531): the password is in the guest's `unattend-original.xml` **and** on the build floppy on the datastore, because `-on-error=abort` skips the plugin's floppy cleanup. Mitigation is procedural: delete the VM promptly with `Remove-PackerTestVm.ps1`, which now also deletes the floppy. Re-decide before Site B; the parked `PACKER_ON_ERROR` switch in `build-diagnostic.sh` is the starting point. | The image-build owner | AGENT_HANDOFF.md |
| ~~The ISO the build boots is unverified~~ **Measured 2026-09-23: it matches** | The Windows ISO (8.5 GB, 190s) and VMware Tools both hash to their recorded values, so no image booted unqualified media. Residual risk was that nothing re-checked it, because the runner image had no `govc`. Since `runner-image` `0.1.0` (2026-09-30) it does, and the manual `verify-iso-datastore` job re-checks every record; it is still manual, so drift is caught when someone runs it. | The image-build owner / the tooling owner | ADR 0004 |
| ~~The VMware Tools ISO has no qualification record~~ **Closed 2026-09-23** | `setup.exe` runs from it as SYSTEM during specialize. It now has a record (`packer/sources/windows/vmware-tools.json`, 142,280,704 bytes) measured from the datastore copy, so a change to the attached media is detectable. Nothing verifies it at the moment `setup.exe` runs from the mounted disc; qualifying the attached media is the proportionate control. | The image-build owner | ADR 0004 |
| One account does everything | The domain service account performs the join, the WinRM login, and holds admin rights on every build VM. A split is proposed, not built. | The image-build owner | ADR 0002 |
| No `MachineObjectOU` | Build VMs land in the default Computers container, under different Group Policy than production. | The image-build owner | ADR 0002 |
| `build-diagnostic.sh` runs without `set -e` | It uses `set -uo pipefail` only. The runner-side package gate depends entirely on the explicit `\|\| fail` on the `stage-packages.sh` call (and, inside that script, on the exit-code check after `download-packages`). **That check is load-bearing and must survive any edit to that line.** | The image-build owner | This document |
| The guest cleanup still uses the unexplained delivery path | `Remove-BuildArtifact.ps1` still receives its inputs through `environment_vars`, whose failure at position 2 was never explained. (Until 2026-10-01 this row was about `Test-StagedPackage.ps1`, which the build no longer runs; the install steps pass literal arguments.) If the order changes, or the failure is intermittent rather than position-dependent, the failure mode is a check reporting the wrong thing — not a crash. | The image-build owner | This document |
| `winrm_insecure = true` | Self-signed per-build certificate, no CA. | The image-build owner | ADR 0001 |
| `vcenter_insecure_connection` | `true` in the CI file variable (OBSERVED 2026-09-28). Cannot be turned off until the runner image trusts the internal CA (row below). | The image-build owner | — |
| vCenter API runs under a named personal account | `EXAMPLE.TEST\builduser` (OBSERVED 2026-09-28), not a service identity. It holds the project folder role only through membership of `PROJ_image_factory`, so building and publishing depend on one person's group membership (ADR 0005). | The image-build owner | — |
| ~~The admin group SID is hardcoded in `enable-winrm.ps1`~~ **Closed** | The SID is now a parameter, supplied as `ADMIN_GROUP_SID` and validated as a domain SID; the script holds only the pattern (OBSERVED 2026-09-30). Each environment supplies its own. | The image-build owner | ADR 0001 |
| No approved image identity | Decided in ADR 0005 (2026-09-28), not built: nothing publishes or records the image yet. The form is now a master VM with a versioned snapshot (revised 2026-10-01), taken only once the seal step exists (STORY-03). **Phase 2 needs this and does not have it.** **2026-10-08: it exists.** A publish job writes `image-reference.json` for a sealed, snapshotted master (job 4330). What Phase 2 still lacks is an image with real software in it, and the MCS catalog proof. | The image-build owner | `docs/evidence.md` |
| Transfer time for real packages is unmeasured | Each tiny-file upload took ~6 seconds. The one real package is ~230 MB. If WinRM upload is unacceptable, attach packages as an ISO. | The image-build owner | ADR 0003 |
| The `runner-image` image does not trust the internal CA | `curl` from inside the container fails GitLab's own HTTPS with `curl: (60) SSL certificate problem: self-signed certificate in certificate chain`, while public hosts succeed — the image's `ca-certificates` carries public roots and not the internal enterprise CA. `git` works only because the runner supplies its own CA configuration; nothing else in the container inherits it. This is the reason every internal TLS connection from CI currently needs an `insecure` flag, and it has to be fixed before the two certificate rows above can be. The host-side CA distribution gap fixed after the 2026-09-22 runner outage reached the hosts, not the images. OBSERVED in `runner-capabilities`, 2026-09-24. | The tooling owner / the lab admins | This document |
| Supply chain of the runner image | Unpinned base, unverified downloads, moving template ref (D20 and D21). | The tooling owner | This document |

---

## 8. Next steps

| # | Action | Owner | Blocked by |
|---|---|---|---|
| 1 | ~~Install `govc`, then run ISO qualification stage 2 on both ISOs.~~ **Done 2026-09-23.** `govc` v0.56.0 on the workstation; both ISOs match their records; the VMware Tools record now exists. What remains is getting `govc` into the `runner-image` image so the check runs in CI rather than by hand. **The tooling owner agreed on 2026-09-30 to ship it** in a release built from `1dac874`. | The image-build owner | Done |
| 2 | ~~Walk the tooling owner through this document's section 4 and agree the contract.~~ **Done 2026-09-28:** ADR 0003 accepted with contract terms C1–C4 (STORY-09). Originally: agree: the lock as the contract artifact, the recipe superseding the baseline manifest, install scope as a required field, the evidence format, and one canonical set of `repository` names. | The image-build owner / the tooling owner | Nothing |
| 3 | **Prove the seam before either side is finished.** The hand-written lock already exists — [`packer/fixtures/software/windows-vm-fixture.lock.yaml`](../packer/fixtures/software/windows-vm-fixture.lock.yaml), see section 4.4. What remains is running steps 2–5 of the ADR 0003 flow against it, without the catalog, the resolver or a real installer. This is the cheapest way to find the next layer of disagreement. **Partly done 2026-10-01 (STORY-04):** steps 3 to 5 are written and run against a stand-in for `package-runner` and the fixture restated in the C1 shape; step 2 still uses `verify-package.sh`. **Run in CI 2026-10-01:** one full build and one harness run per exit code, all as designed. **Done as a trial 2026-10-07:** step 2 with the real `download-packages` (job 4074) and steps 3 to 5 with a real `package-runner` build (job 4245), both against the fixture. What remains is the owner merging and tagging that code, and a real package. | The image-build owner | A working `download-packages` (D1–D7) for step 2; STORY-05 for the real step 4 |
| 4 | Clear D1–D7 and D29–D32 in `runner-image` (ADR 0003, C2), and in `package-runner` (STORY-05) D8, D12 and D22–D28. D8 and D22 are the ones that break the fail-closed guarantee; D12 blocks evidence collection. | The tooling owner | Nothing (the contract was agreed 2026-09-28) |
| 5 | ~~Run the manual `runner-capabilities` job and record what the runner image and share mount actually provide.~~ **Done 2026-09-24.** Present: `jq`, `sha256sum`. Missing: `pwsh`, `govc` — so neither the package validator nor ISO stage 2 can run in CI. The software share is mounted at neither expected path. The job runs as `root`. Outbound: the public internet is reachable (HashiCorp releases 200, Docker Hub registry 401), so a container registry need not be hosted inside this network; `CI_REGISTRY` is unset, so none is enabled on this instance; and the GitLab instance itself fails TLS from inside the container — see the CA row in section 7. | The image-build owner | Done |
| 6 | Get a machine-wide first package into the catalog, then prove it with an MCS catalog proof from a sealed master (ADR 0002). | The image-build owner / the tooling owner | Steps 3, 4; STORY-03 **Half done 2026-10-12:** PuTTY 0.83.0, a machine-wide MSI, is in a sealed, published master (job 4441). The MCS catalog proof remains. |
| 7 | ~~Decide sealing.~~ **Decided 2026-10-01** (ADR 0002, STORY-10): domain-joined, no sysprep, for MCS. What remains is STORY-03: ~~complete first-run setup~~ (**done 2026-10-02**, CI job 3859), ~~the seal step~~ (**done 2026-10-08**, jobs 4288 and 4294, off by default; its removals and check are STORY-19), and the versioned snapshot; the masters OU is deferred in the lab, which has none. | The image-build owner | None |
| 8 | ~~Publish the master and write the image-reference record~~ (form and identity decided in ADR 0005, revised 2026-10-01 to a master VM with a versioned snapshot; STORY-11, with STORY-12 merged in). **Done 2026-10-08**, job 4330. | The image-build owner | — |
| — | ~~Derive `iso_paths` from the qualification records.~~ **Done 2026-09-24.** The template reads both records with `jsondecode(file(...))`; `iso_source_path` and `vmware_tools_iso_path` are gone. An older variable file that still sets them validates with an "Undefined variable" warning and its values are ignored, so the CI file variable did not have to change in lockstep. Remove the two lines from `PACKER_VARS_FILE` so nobody edits them expecting an effect. | The image-build owner | Done |
| — | **Parallel, unblocked:** trust the vCenter certificate chain instead of `vcenter_insecure_connection` — which needs the internal CA in the runner image first, see section 7; a dedicated vCenter service identity. | The image-build owner / the tooling owner | Nothing |

---

## References

- [ADR 0001 — WinRM over HTTPS](decisions/0001-winrm-https-communicator.md)
- [ADR 0002 — Master image identity and sealing](decisions/0002-master-image-identity-and-sealing.md)
- [ADR 0003 — Software install contract](decisions/0003-package-install-contract.md)
- [ADR 0004 — ISO library and qualification](decisions/0004-iso-library-and-qualification.md)
- [Build evidence](evidence.md) — the evidence file map, `index.json` shape, and secret guard
- [AGENT_HANDOFF.md](../AGENT_HANDOFF.md) — repository state and engineering rules
