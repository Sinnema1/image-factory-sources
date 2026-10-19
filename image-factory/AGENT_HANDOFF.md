# Agent Handoff: Example Labs Image Factory

> **📌 Purpose**: This file is the **entrypoint** for AI agents (e.g., Continue) to understand the repository's context, goals, and current state.
> **Last Updated**: 2026-10-19. **The lab proof of concept is closed out:** start with
> [docs/lab-closeout.md](docs/lab-closeout.md), then come back here for the detail.

---

---

## **📜 Project Overview**
### **Objective**
Greenfield implementation of the **Example Labs Image Factory** proof of concept.
**Goal**: Automate the build, configuration, and deployment of Windows desktop images (VDI) with:
- **Packer** for image templating.
- **Terraform** for Citrix resource provisioning.
- **PowerShell** for host-side validation and package management.
- **vSphere** as the virtualization platform.
- **Linux Runners** as replaceable execution agents for **image building (Phase 1)** and **downstream lifecycle management (Phase 2)**.

### **Key Stakeholders**
- **The image-build owner**: Owner (vSphere, Packer, ISO intake).
- **The tooling owner**: Owner (CI/CD, Runner management, Package Catalog).
- **VDI SMEs**: Consumers.

### **Engineering Rules**
This project adheres to the Example Labs Engineering Rules, kept in one place:
[`.continue/rules/engineering-principles.md`](.continue/rules/engineering-principles.md).
**Core Principles** (a summary; the rules file governs):
- **Minimal viable implementation**: Only implement the current requested increment.
- **Fail-closed**: Validation failures halt execution (no partial builds).
- **Immutable artifacts**: SHA-256 integrity checks for all inputs (ISOs, packages).
- **Evidence-driven**: All actions generate auditable JSON evidence in `/evidence/`.

---

---

## **🗺️ Current State (Phase 1: Image Factory)**
### **✅ Completed**
| Task | Owner | Artifact | Notes |
|------|-------|----------|-------|
| WinRM communicator over HTTPS | The image-build owner/Agent | [`windows-11-vsphere.pkr.hcl`](packer/templates/windows-11-vsphere.pkr.hcl), [`enable-winrm.ps1`](packer/unattended/enable-winrm.ps1), [ADR 0001](docs/decisions/0001-winrm-https-communicator.md) | Every CI build since the change connects over 5986 and finishes; most recently job 4015 on 2026-10-07 (the first build in the `runner-image` `0.2.1` image), on the shared runner `runner-01`. The HTTP failure mechanism is the leading explanation, not proven. |
| Packer vSphere template | The image-build owner/Agent | [`windows-11-vsphere.pkr.hcl`](packer/templates/windows-11-vsphere.pkr.hcl) | Datastore-backed ISO template; answer file rendered from [`autounattend.xml.pkrtpl`](packer/unattended/autounattend.xml.pkrtpl). |
| Software install, build side (fixture and stand-in) | The image-build owner/Agent | [`stage-packages.sh`](scripts/runner/stage-packages.sh), [`windows-11-vsphere.pkr.hcl`](packer/templates/windows-11-vsphere.pkr.hcl), [`package-runner.ps1`](packer/fixtures/package-runner/package-runner.ps1), [`windows-vm-fixture.lock.yaml`](packer/fixtures/software/windows-vm-fixture.lock.yaml) | STORY-04, written 2026-10-01. The runner checks the lock and the `package-runner` binary against hashes committed beside them, then the package files; the build uploads them in the C2 layout, runs `install`, downloads `install-result.json` **before** failing on exit 10, 11 or 12, restarts on 3010, runs the post-restart `verify` and downloads its result. **The binary is a stand-in** (a test double speaking C3 and C4 for the fixture only) and the package is the fixture, whose `install.ps1` now copies its payload to `C:\Program Files\testpkg\`. **Proved in CI on 2026-10-01**: one full build (job 3836) and one harness run per forced exit code 10, 11, 12 and 3010 (jobs 3835, 3837, 3838, 3839). See ADR 0003, "Build side written". **Since 2026-10-07 the runner half is the owner's real tool:** `stage-packages.sh` calls `download-packages` (in the `runner-image` `0.2.1` image), and the fixture lock is in the lock shape the owner's tools read today. The guest half is still the stand-in. See ADR 0003, "Interim lock shape". **Tried with the real engine on 2026-10-07:** job 4245, a full build with `PACKAGE_RUNNER` naming the trial executable in `packer/fixtures/package-runner/`, installed and verified the fixture (install exit 0, verify exit 0). The stand-in is still the default. See ADR 0003, "Trial of a `package-runner` build". **First real package, 2026-10-12 (STORY-17):** with `PACKAGE_LOCK`, `PACKAGE_SOURCE_ROOT` and `PACKAGE_RUNNER` set for the pipeline, a build stages PuTTY 0.83.0 from the package share with `download-packages` and installs the MSI with the trial executable, using the lock in [`packer/software/`](packer/software/README.md). Job 4408 (a diagnostic build) and job 4441 (a publish from `main`) both ended install exit 0 and verify exit 0. Nothing is the default: without the three variables a build still installs the fixture with the stand-in. See ADR 0003, "First real package installed". |
| CI pipeline | The image-build owner/Agent | [`.gitlab-ci.yml`](.gitlab-ci.yml) | Seven jobs: `runner-smoke-test`, `packer-fmt`, manual `runner-capabilities`, `packer-validate`, manual `verify-iso-datastore` (ISO stage 2, since 2026-09-30), manual `packer-build-diagnostic`, manual `staging-harness`. The runner image is pinned once, **by digest**, in `PACKER_CI_IMAGE`. The smoke test enforces a tool list derived from what the jobs actually invoke; `runner-capabilities` also probes outbound connectivity. |
| Diagnostic build with evidence | The image-build owner/Agent | [`build-diagnostic.sh`](scripts/runner/build-diagnostic.sh) | `-on-error=abort`, provenance file, console and debug logs in `evidence/`. |
| Packer variable file handling | The image-build owner/Agent | [`.example`](configs/windows-11-vsphere.pkrvars.hcl.example) | The real file is gitignored. CI supplies it as the `PACKER_VARS_FILE` file variable. |
| Package staging proof (fixture) | The image-build owner/Agent | `verify-package.sh`, `Test-StagedPackage.ps1` (both deleted 2026-10-07), [`fixtures/software/`](packer/fixtures/software/README.md) | Verify on the runner, upload with Packer, re-verify in the guest. Stages only; installs nothing. STORY-06. **Replaced 2026-10-01** by the install row above. Both scripts were deleted on 2026-10-07, after `download-packages` took over the runner-side check; git history holds them. |
| Build evidence collection | The image-build owner/Agent | [`collect-evidence.sh`](scripts/runner/collect-evidence.sh), [`docs/evidence.md`](docs/evidence.md) | Indexes evidence with hashes and guards against secrets. STORY-07. |
| Test VM cleanup | The image-build owner/Agent | [`Remove-PackerTestVm.ps1`](scripts/windows/Remove-PackerTestVm.ps1), `make clean-vm` | Deletes exactly one named VM from disk, **and its build floppy image**, which `Remove-VM -DeletePermanently` leaves behind (OBSERVED 2026-09-28; STORY-02). Exercised against vCenter 2026-09-28: `packer-build-001` (already off) and `packer-build-002` (powered off by the script, then deleted). The floppy-deletion branch is not yet exercised: `001` was deleted by the earlier version, which is how the leftover floppy was found, and `002` had none. |
| ISO qualification records | Agent | [`windows-11.json`](packer/sources/windows/windows-11.json), [`vmware-tools.json`](packer/sources/windows/vmware-tools.json) | One record per attached ISO (ADR 0004). Both measured from the datastore copy on 2026-09-23. |
| ISO paths derived from the records | Agent | [`windows-11-vsphere.pkr.hcl`](packer/templates/windows-11-vsphere.pkr.hcl) | Since 2026-09-24 the template reads `iso_paths` from the two records; `iso_source_path` and `vmware_tools_iso_path` are gone. An older variable file that still sets them validates with a warning and the values are ignored. Remove the two lines from the `PACKER_VARS_FILE` CI variable. |
| ISO metadata schema | Agent | [`iso-metadata.schema.json`](packer/schemas/iso-metadata.schema.json) | Contract for `windows-11.json`. |
| Windows-source validation scripts | Agent | [`validate-iso-metadata.sh`](scripts/runner/validate-iso-metadata.sh), [`verify-iso.sh`](scripts/runner/verify-iso.sh) | Validates the qualification record (runs in CI every pipeline), and stage 1 of qualification — the intake copy's filename, size and SHA-256. Bash, so both can run on the CI runner; stage 1 still needs the share mounted, which it is not. |
| Guest credential cleanup | The image-build owner/Agent | [`Remove-BuildArtifact.ps1`](packer/provisioners/Remove-BuildArtifact.ps1), [ADR 0002](docs/decisions/0002-master-image-identity-and-sealing.md) | Windows Setup caches the domain-join password in plaintext in `C:\Windows\Panther\unattend-original.xml` (it scrubs `unattend.xml` and leaves the original). The build deletes both and **fails unless a recursive scan finds no surviving `<Password>` element**, and since 2026-09-28 also fails if the scan cannot read a path (previously an unreadable file or folder counted as clean; STORY-02); `cleanup-result.json` records the outcome, including `unreadable_paths`. Known gap: a failed build retains its VM and never reaches this step. |
| Windows first-run setup (OOBE) completes in the build | The image-build owner/Agent | [`autounattend.xml.pkrtpl`](packer/unattended/autounattend.xml.pkrtpl), [`Remove-BuildArtifact.ps1`](packer/provisioners/Remove-BuildArtifact.ps1), [ADR 0002](docs/decisions/0002-master-image-identity-and-sealing.md) | First slice of STORY-03, proved 2026-10-02 (job 3859). The answer file sets the time zone (UTC) and defines one local administrator, `pkr-setup`, with a password generated per build and no auto-logon, because OOBE on a client edition does not finish without an account. The guest cleanup deletes that account and `defaultuser0`, and fails the build unless OOBE has finished, both accounts are gone and the time zone matches; the outcome is `first_run_setup` in `cleanup-result.json`. Before this the build sat at the OOBE account page, and every desktop made from the master would have booted there. |
| ISO qualification, two-stage chain | Agent | [`verify-iso.sh`](scripts/runner/verify-iso.sh), [`verify-datastore-iso.sh`](scripts/runner/verify-datastore-iso.sh), [ADR 0004](docs/decisions/0004-iso-library-and-qualification.md) | One `sha256` in the record, checked twice: stage 1 against the intake copy, stage 2 against the copy on the datastore that the build actually boots. **The Windows ISO was verified on 2026-09-23** (8.5 GB, 190s): its datastore copy matches the hash recorded from the intake copy. **VMware Tools was only measured that day** (142,280,704 bytes): its record was written from the datastore copy, so a match proved nothing until 2026-09-30, when the same bytes were found inside the Broadcom archive (STORY-08). Both passed stage 2 again on 2026-09-30. Stage 2 also runs in CI since 2026-09-30, as the manual `verify-iso-datastore` job (`runner-image` `0.1.0` has `govc`). |
| Fixture lock in the `package-runner` format | Agent | [`windows-vm-fixture.lock.yaml`](packer/fixtures/software/windows-vm-fixture.lock.yaml) | **Restated in the C1 shape on 2026-10-01 and now the lock the build uses** (JSON syntax, which is valid YAML; see the fixture README). What follows describes the earlier discussion artifact. The `testpkg` fixture expressed as an `ImageRecipeLock` with real computed hashes, carrying six `OPEN` markers and the proposed `installScope` field. It served as the agenda for the ADR 0003 conversation with the tooling owner, which was held: the contract was accepted on 2026-09-28, and C1–C4 answer all six `OPEN` markers but the `resolvedFrom` one — provenance in a hand-written lock, question 8 in ADR 0003's owner table, carried into implementation. It is restated in the agreed format under STORY-04. |
| Seal step | The image-build owner/Agent | [`Invoke-ImageSeal.ps1`](packer/provisioners/Invoke-ImageSeal.ps1), [`verify-seal.sh`](scripts/runner/verify-seal.sh), [ADR 0002](docs/decisions/0002-master-image-identity-and-sealing.md) | STORY-19, STORY-03. Removes build-time access in the guest, checks itself, reports through vCenter; the build fails without the result. Proved 2026-10-08 (jobs 4288, 4294, 4302) and in every publish since. |
| Publish step and image reference | The image-build owner/Agent | [`publish-image.sh`](scripts/runner/publish-image.sh), [`image-reference.sh`](scripts/runner/image-reference.sh), [ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md) | STORY-11, STORY-03. Versioned VM and snapshot, the record, two continuity lookups, the ISO gate in the same job. Proved 2026-10-08 (jobs 4330, 4362) and since. |
| Released install engine | The tooling owner (release), the image-build owner/Agent (adoption) | [`packer/package-runner/`](packer/package-runner/README.md) | `package-runner` 1.0.0, copied from the share and pinned by hash. Default since 2026-10-19 (jobs 4592, 4608). Reports its version as `dev` (D39). |
| A real package end to end | The image-build owner/Agent | [`packer/software/`](packer/software/README.md), [STORY-17 summary](docs/demonstrations/story-17-integrated-build.md) | PuTTY 0.83.0 from the share, installed and validated, in a published master (job 4441, 2026-10-12). |
| Retention and the evidence store | The image-build owner/Agent | [`evidence-store.sh`](scripts/runner/evidence-store.sh), [`masters.sh`](scripts/runner/masters.sh), [ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md) | STORY-18. Evidence kept on the share and outliving the master; masters listed and retired deliberately. Proved 2026-10-19 (jobs 4643 to 4657). |
| vCenter discovery script | Agent | [`Get-VCenterDiscovery.ps1`](infrastructure/scripts/Get-VCenterDiscovery.ps1) | Read-only vCenter inventory discovery. |
| ~~Package validation scripts (provisional)~~ | Agent | — | **Deleted 2026-09-29**: `software-source/` and `packer/manifests/`, superseded by ADR 0003 (accepted). |

### **🔄 In Progress**
Nothing in the lab. The proof of concept was closed out on 2026-10-19; the next work is Site B's
(PI4: FEATURE-01 and FEATURE-02). See [docs/lab-closeout.md](docs/lab-closeout.md).

### **⏳ Blocked**
| Task | Reference | Owner | Blocked By |
|------|-----------|-------|------------|
| MCS catalog proof: a desktop made from a master | ADR 0002, ADR 0005 | Citrix; scope decision by the image factory's owner | Example Labs has no Citrix site. PROPOSED 2026-10-19: out of the lab's scope, carried into Site B with an owner. |
| vCenter certificate checks | ADR 0004, retrospective section 7 | Pipeline platform | The runner image does not trust the internal certificate authority. Accepted for the lab; STORY-22 and STORY-25 in Site B. |
| Credential cleanup on a **failed** build | ADR 0002 | The image-build owner | `-on-error=abort` keeps the VM before cleanup runs, leaving the domain-join password in the guest and on the floppy image. Accepted for the lab by owner override; STORY-23 in Site B. |
| OU placement for masters and desktops | ADR 0002 | Active Directory | The OUs do not exist in the lab. STORY-32 in Site B. |

Everything that used to be listed here was cleared before closeout; the history is in the
changelog below and in the retrospective.

---

### **🔗 Cross-repo interfaces (as understood; confirm with the owners)**
These repositories are in the same GitLab group (`image-factory-group`) and are maintained by the tooling owner. **Do not modify them, and do not duplicate their responsibilities here. Raise changes with the owner.**

They form a layered stack, and the build-time dependency runs one way: `ci-platform` (CI platform) → `runner-image` (toolchain) → **this repository** (image build) → `package-runner` (package engine). [ADR 0003](docs/decisions/0003-package-install-contract.md), accepted 2026-09-28, makes the `package-runner` lock file the contract between the last two.

All four were read directly from local clones. **Last read, per repository** (fetched on 2026-10-07):

| Repository | Ref and commit | Last read | Depth |
|------------|----------------|-----------|-------|
| `ci-platform` | `main`, `2cae5b0` (tag `0.0.14`) | 2026-09-23; unchanged on 2026-10-06 | Full |
| `runner-image` | `main`, `d730652` (tags `0.2.0` and `0.2.1`; `0.2.1` is the image we pin) | 2026-10-06 | `download-packages.sh` read in full and run in a scratch folder (2026-10-05; byte-identical in the release). Dockerfile and pipeline read. `download-packages.bat` not re-read since it changed |
| `package-runner` | `main`, `a27199e` (`init` was merged into it and deleted on 2026-10-07); `add-publish`, `8c2dc2f` (a GoReleaser release pipeline whose publish step is a placeholder; unmerged) | 2026-10-12: `main` unchanged since 2026-10-07 | Full read on 2026-10-02 at `8e538aa`; on 2026-10-06 the seven new commits: compiled (fails), the install flags, `validateArtifact`, the sample lock and the committed evidence |
| `runner-test-bed` | `test-runner`, `570a4ee`; `test-image`, `6beb26d` | 2026-10-07 | Full: three files and their history, plus one job log supplied by the image-build owner |

The install contract with `package-runner` was agreed on 2026-09-28 (ADR 0003). The full cross-repository account, with the verified defect register (D1–D38), is in [docs/image-factory-retrospective.md](docs/image-factory-retrospective.md#4-cross-repository-integration); the most recent read is ADR 0003, "Read 2026-10-06".


| Repository | What it is | Our relationship |
|------------|------------|------------------|
| `ci-platform` | The reusable `build`/`publish` pipeline template every container repository in the group includes, plus `publish-image.sh` (podman save to a docker-archive with a SHA-256 and YAML metadata, under `flock`) and script promotion to the shared drive and the runner's `~/bin`. Read at `main` (`2cae5b0`, tag `0.0.14`). **There is no registry** — its README calls it a "mock artifactory", and the publish path contains no push, login, credential or network call. Images are consumed with `podman load` from the share. | Indirect. It is how `runner-image` gets built and published; we never call it. Generic — it never knows what an image contains, so no question about what is on the runner can be answered at this layer. |
| `runner-image` | The Dockerfile and pipeline for `runner-image:<tag>`. At `0.1.0` (`a321d26`, 2026-09-30): UBI 10 minimal, Packer 1.16.0, git, make, jq, curl, unzip, tar, `yq` v4.45.1, `govc` v0.56.0, and `download-packages`, which is shipped and still does not parse (D1). No `pwsh`, and no internal CA. Its whole `.gitlab-ci.yml` is a four-line `include:` of the template above, at the moving `ref: "main"` (D21). `main` now equals the tag we pin; it was rebuilt by one squash commit, so the older tags (22 over four commits, D19) are not its ancestors. | Our CI jobs run on it, pinned by digest once in `.gitlab-ci.yml`'s `PACKER_CI_IMAGE`. We use its Packer, `govc` (ISO stage 2, the manual `verify-iso-datastore` job), `jq`, `make` and `sha256sum`; the smoke test asserts that list. We do **not** use `download-packages` yet: `scripts/runner/stage-packages.sh` and `verify-package.sh` stand in for it until D1–D7 and D29–D32 are cleared. Tool additions are requests to the owner; the manual `runner-capabilities` job reports what the image has. The image does not trust the internal CA (OBSERVED 2026-09-24), which is why internal TLS from CI still needs an `insecure` setting. The owner's stated position (2026-09-30) is that checksum-verifying downloads is unnecessary (D20). **Update 2026-10-06:** the pin is `0.2.1` (`d730652`). Its `download-packages` parses and runs (D1–D3, D32 fixed), and the owner's own job stages real packages with it on our runner. We still do not call it: it reads the owner's lock shape, not the agreed C1 shape our fixture lock uses, and D31 and D35 are open. |
| `package-runner` | A Go CLI, early in development. Recipe (`ImageRecipe`) → resolver → immutable lock (`ImageRecipeLock`, with a `lockHash`) → handlers (msi/exe/powershell/psadt) and validators (file/registry/service/command). Commands: `resolve`, `validate`, `install`, `install-package`, `detect`, `handlers`, `version`. At `init` `8e538aa` (2026-10-01): 18 commits, all unmerged; no tags, no CI, **zero test files**; a README stating the intended design; and **the head does not compile as committed** (D34). None of the contract terms C1–C4 has landed. | The install engine, to be run **in the guest**, against a lock we transfer but never parse (ADR 0003). **Today the build does not run it.** It runs a stand-in, [`packer/fixtures/package-runner/package-runner.ps1`](packer/fixtures/package-runner/package-runner.ps1), a test double that speaks the agreed command line (`install` and `verify` with `--lock`, `--artifact-root`, `--evidence-dir`, `--execution-id`), exit codes (0, 10, 11, 12, 3010) and result file for the fixture package only; proved in CI 2026-10-01. The swap to a real release needs, in order: a commit that builds (D34), a tagged release to pin by hash (D18), the C1–C4 terms, and before anything else guest-side hash re-verification (D8) and failing on a failed validation (D22), without which a real binary would pass builds the stand-in fails. Unconfirmed with the owner: the `verify` command name, the lock's field names, and two additions to the result file. **State 2026-10-08:** `main` is at `a27199e` (`init` merged into it and deleted on 2026-10-07): it builds from source control (D34 closed), still with no tags, no CI and no tests, and none of C1–C4. Two proposal branches by the image-build owner (`proposal/validation-evidence`, `proposal/build-contract` at `c9f1439`, 42 Go tests) implement C3 and C4 against the interim lock shape, including D8 and D22; the owner has reviewed both and asked for two changes, now made. A build of that branch is committed here as a trial executable, off by default, and installed the fixture in a full build (job 4245). **Update 2026-10-06 (`7f73e52`):** seven more commits; the sample lock now has real hashes and the owner has run real installs with it. Still no release, still does not compile as committed (D34), still none of C1–C4. Its lock shape and `download-packages` now agree with each other, but not with C1: choosing one shape is the next decision (ADR 0003, "Read 2026-10-06"). |
| `runner-test-bed` | The owner's test bed for the runner half of the install flow: one job, `test:download`, on the `shared-medium` runner with image `runner-image:0.2.1`, running `download-packages` against the `package-runner` sample lock. OBSERVED 2026-10-06: it stages and hash-verifies Firefox 156.0.1 and PuTTY 0.83.0 from the share mounted at `/mnt/image-factory/package-content`, as `root`, in under two seconds. | None in code; we never call it. It is where to look for a working example of step 2 on our runner, and it is where the `0.2.1` digest came from. Read it; do not change it. |
| `Example Manifest` | The software baseline manifest (`software-baseline-windows-vm.yml`) and catalog scripts (`generate_sha.sh`, `validate_sha.sh`, `load_software_catalog.sh`, `move_files.sh`). **Not read directly** — still inferred from names and a pasted excerpt. | Likely superseded. ADR 0003 argues (INFERRED) that `package-runner`'s recipe format is this manifest's successor: near-identical `target` block, and it carries the install metadata the manifest lacked. Confirm with the owner before relying on either. |

---

## **🏗️ Architecture & Design Decisions**
### **Directory Structure**
```text
image-factory/
├── .env                          # Local environment values for runs outside CI (gitignored)
├── .gitignore                    # Excludes ISOs, evidence, temp files
├── AGENT_HANDOFF.md              # This file (AI entrypoint)
├── CLAUDE.md                     # Points Claude Code sessions at this file and the rules
├── README.md                     # Project overview and Phase 1 progress
├── evidence/                     # Generated validation evidence (gitignored)
│   └── .gitkeep
├── configs/                      # Packer variable files
│   ├── windows-11-vsphere.pkrvars.hcl          # Runtime variables (gitignored; CI supplies it from the PACKER_VARS_FILE file variable)
│   └── windows-11-vsphere.pkrvars.hcl.example   # Example variables (no secrets)
├── infrastructure/               # vSphere discovery scripts
│   └── scripts/
│       └── Get-VCenterDiscovery.ps1            # Read-only vCenter inventory discovery
├── packer/                       # Packer templates, sources, and validation
│   ├── schemas/
│   │   └── iso-metadata.schema.json            # Schema for ISO metadata
│   ├── sources/
│   │   └── windows/
│   │       ├── windows-11.json                 # Windows ISO qualification record; the template reads its path
│   │       └── vmware-tools.json               # VMware Tools ISO qualification record; likewise
│   ├── templates/
│   │   └── windows-11-vsphere.pkr.hcl          # Packer vSphere ISO template
│   ├── unattended/
│   │   ├── autounattend.xml.pkrtpl             # Answer file template; rendered to autounattend.xml on the floppy
│   │   └── enable-winrm.ps1                    # Guest bootstrap: VMware Tools, WinRM over HTTPS, firewall, admin group
│   ├── fixtures/
│   │   ├── package-runner/
│   │   │   ├── package-runner.exe              # TRIAL build of a proposal, off by default (ADR 0003)
│   │   │   └── package-runner.ps1              # STAND-IN for package-runner: a test double speaking the
│   │   │                                       # agreed command line and evidence (ADR 0003, C3 and C4).
│   │   │                                       # Its .sha256 beside it is what the runner checks it against.
│   │   └── software/                           # Fixture package and its lock
│   │       ├── README.md                       # What the fixture is, and how to re-hash it after a change
│   │       ├── windows-vm-fixture.lock.yaml    # The fixture as a package-runner lock (C1). The build uses it.
│   │       ├── windows-vm-fixture.lock.yaml.sha256  # Its committed hash: trust anchor and sidecar
│   │       └── packages/                       # Artifact root, <name>/<version>/<file> (C2)
│   ├── provisioners/
│   │   ├── Test-GuestCommunicator.ps1          # Guest check of WinRM identity, transport and admin rights
│   │   ├── Remove-BuildArtifact.ps1            # Guest cleanup: deletes the cached answer files, then fails
│   │                                           # the build unless no <Password> element survives (ADR 0002).
│   │                                           # Also removes the two accounts first-run setup leaves and
│   │                                           # fails the build unless that setup has finished.
│   │   └── Invoke-ImageSeal.ps1                # The seal (ADR 0002): removes the WinRM channel and the build's
│   │                                           # traces by name, in two stages. Off unless seal_image is set.
│   ├── tests/
│   │   └── staging-provisioners.pkr.hcl        # Manual harness for the communicator and install provisioners
├── scripts/
│   ├── runner/                   # Linux runner scripts
│   │   ├── lib/common.sh                       # Shared helpers: paths, UTC timestamps, fail, require_*
│   │   ├── require-env.sh                      # Env guard used by the CI jobs
│   │   ├── build-diagnostic.sh                 # Retained diagnostic build (CI)
│   │   ├── stage-packages.sh                   # Runner-side check of the lock and the package-runner binary,
│   │   │                                       # then download-packages stages and verifies the package files
│   │   │                                       # into build/packages; emits the build's package variables (CI)
│   │   ├── verify-seal.sh                      # Reads the seal's result from vCenter (it cannot be downloaded)
│   │   │                                       # and fails a sealed build that cannot show it is sealed (CI)
│   │   ├── publish-image.sh                    # The only thing that publishes (ADR 0005): ISO gate, sealed build,
│   │   │                                       # snapshot, image-reference record, continuity lookups (CI)
│   │   ├── image-reference.sh                  # Writes, checks and looks up the image-reference record
│   │   ├── collect-evidence.sh                 # Evidence index + fail-closed secret scan (CI)
│   │   ├── validate-iso-metadata.sh            # ISO record vs. its schema (CI: reads only this repo)
│   │   ├── verify-iso.sh                       # ISO qualification stage 1: the intake copy (needs the share)
│   │   ├── verify-datastore-iso.sh             # ISO qualification stage 2: the copy the build boots (needs govc)
│   │   ├── validate.sh                         # Full validation (workstation: needs the share)
│   │   ├── preflight.sh                        # Runner/repo checks (workstation: needs govc)
│   │   └── check-vm-name.sh                    # Lists candidate test VMs (workstation: needs govc)
│   └── windows/
│       └── Remove-PackerTestVm.ps1             # Deletes one named Packer test VM from disk
├── build/                        # Build inputs derived at runtime, gitignored, never evidence
├── docs/
│   ├── evidence.md               # What lands in evidence/, its roles, and the known limits
│   ├── image-factory-retrospective.md  # Whole-project retrospective, end-to-end flow, and the
│   │                             # cross-repository defect register. Start here for context.
│   ├── wiki/                     # Source of the GitLab project wiki, for stakeholders. A derived
│   │                             # view: it summarizes and links here, and this repository wins.
│   │                             # Rules and publish steps: docs/wiki/README.md
│   ├── requirements/
│   │   └── vsphere-discovery.md
│   └── decisions/                # ADRs: 0001 WinRM over HTTPS (Accepted), 0002 sealing (Accepted),
│                                 # 0003 package install (Accepted), 0004 ISO library (Accepted for the lab),
│                                 # 0005 publish form and image identity (Accepted for the lab)
├── .env.example                  # Names the scripts read; copy to .env (gitignored)
├── .gitattributes                # Line endings; fixtures excluded so their hashes stay stable
├── .continue/rules/              # The engineering rules: the single source (engineering-principles.md)
├── .gitlab-ci.yml                # Seven jobs; the runner image is pinned by digest, once, in variables
└── Makefile                      # init, fmt, validate-packer, validate, build-diagnostic, list-vms, clean-vm, ...
```

Not started: Terraform (Phase 2, post-Packer provisioning). Empty `terraform/` and `tests/`
scaffold directories were removed; create them when there is something to put in them, per the
engineering rule against scaffolding speculative abstractions. The tests that do exist live in
`packer/tests/`.

### **Key Design Decisions**
1. **The datastore is the ISO library** ([ADR 0004](docs/decisions/0004-iso-library-and-qualification.md)):
   - Packer references ISOs via **datastore paths** (e.g., `[datastore-01] image-factory/iso/...iso`). ESXi hosts cannot read a UNC path, so the ISO has to be on storage the hosts can reach — that part was never a choice.
   - **Rationale**: Content Library was never rejected on merit. It is **permission-blocked** (`GET /api/content/library` returned 404 on 2026-08-18 and **403** on 2026-09-28: the role holding the Content Library privileges is granted on a VM folder, which never reaches a library — see [ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md)), so the 2026-08-18 pivot was a workaround, not a preference. It stays DEFERRED and would be a management improvement rather than an integrity one.
   - The qualification record therefore describes the **datastore item**; the intake location survives as optional `originPath`, which stage 1 reads to find the intake copy; an ISO delivered inside a vendor archive records `origin` instead (the Broadcom zip for VMware Tools, member hash verified 2026-09-30; vendor signatures verified 2026-10-05). Verifying it needs vSphere access via `govc` — correcting the original rationale, which claimed none was required.
   - The template reads `iso_paths` **from the records** (since 2026-09-24), so the record is the only place an ISO path is written and the item qualified is the item booted.

2. **Separate ISO and Package Validation**:
   - ISO: [`validate-iso-metadata.sh`](scripts/runner/validate-iso-metadata.sh) (the record), [`verify-iso.sh`](scripts/runner/verify-iso.sh) (stage 1, intake), [`verify-datastore-iso.sh`](scripts/runner/verify-datastore-iso.sh) (stage 2, the copy the build boots). All three compare against the single `sha256` in the record.
   - Packages: [`stage-packages.sh`](scripts/runner/stage-packages.sh) checks the lock and the `package-runner` binary against committed hashes and calls `download-packages` (from the `runner-image` image, since 2026-10-07) to stage and verify the package files; the guest re-verifies every file before installing ([ADR 0003](docs/decisions/0003-package-install-contract.md), build side proved 2026-10-01 against a stand-in). `Test-StagedPackage.ps1` is deprecated and no longer called; the PowerShell package validator was deleted on 2026-09-29.
   - **Rationale**: ISOs and packages are distinct entities with different validation needs.

3. **Fail-Closed Validation**:
   - All scripts throw errors on validation failures (e.g., SHA-256 mismatch, missing files).
   - **Rationale**: Ensures integrity and prevents incomplete builds.

4. **Lowercase SHA-256 Hashes**:
   - All hashes are normalized to lowercase for comparison.
   - **Rationale**: Avoids case-sensitivity issues.

5. **Evidence Storage**:
   - Validation results are written to `/evidence/` as JSON files.
   - **Rationale**: Machine-readable, auditable, and excluded from Git.

6. **Environment Variables for vCenter**:
   - In CI the values are masked GitLab CI/CD variables. On a workstation they come from an untracked `.env` file (`VCENTER_HOST`, `VCENTER_USERNAME`, `VCENTER_PASSWORD`, and the build identity).
   - **Rationale**: Non-interactive, kept out of git, and the same names in both places. It is not a secret store: `.env` holds passwords in plaintext on the workstation, protected only by the file system. Follow-up, not done: stop storing them there (prompt per session or read from a credential manager).

7. **Runner-Based Execution**:
   - Use **Linux runners** as stateless, replaceable agents for Phase 1 (Packer) and Phase 2 (Terraform/Citrix).
   - **Rationale**: Aligns with the tooling owner's ownership of CI/CD and Runners, ensuring modularity and scalability.

8. **Failed builds keep their VM in the lab: `-on-error=abort` retained (OWNER OVERRIDE, STORY-02 AC2)**:
   - **Decision** (the image-build owner, 2026-09-28): `scripts/runner/build-diagnostic.sh` keeps `-on-error=abort` in the lab environment, overriding the fail-closed default of cleaning up after a failure. The parked `PACKER_ON_ERROR` switch there stays commented out.
   - **Rationale**: the lab is a lab, and a failed build's VM is how most failures have been diagnosed. This override does **not** carry over to Site B, or to any other environment: it must be re-decided there.
   - **Accepted risk** (OBSERVED 2026-09-28, induced failure, job 3531): a failed build leaves the domain-join service account password, and since 2026-10-02 the per-build `pkr-setup` account's password beside it in the same answer file, in **two places** until its VM is deleted — the build floppy image on the datastore (`<vm folder>/packer-<n>.flp`, readable by anyone with datastore browse rights), and `C:\Windows\Panther\unattend-original.xml` in the guest, which Windows Setup does not scrub. The VM also stays powered on. Packer's own log confirms the cause: `aborted: skipping cleanup of step "StepAddFloppy"`. The two passwords differ in weight: the domain-join one is a shared, long-lived account; the `pkr-setup` one is random per build and its account exists only on that VM.
   - **Mitigation, procedural and not enforced**: after inspecting a failed build, delete its VM promptly with `scripts/windows/Remove-PackerTestVm.ps1`, which since 2026-09-28 also deletes the build floppy (`Remove-VM -DeletePermanently` alone leaves it), then confirm the VM's datastore folder is gone. Nothing prompts or checks this; before this story, seven orphaned floppy images and a VM running for 24 days had accumulated.

---

---

## **🔧 Technical Stack**
| Component | Technology | Purpose |
|-----------|------------|---------|
| **Image Build** | Packer | Automate Windows image creation. |
| **Provisioning** | Terraform | Deploy Citrix test resources. |
| **ISO validation** | Bash (`sha256sum`, `jq`) | Qualification record and both ISO stages. Bash so it can run on the CI runner, which has no `pwsh`. |
| **Package validation and install** | Agreed: `download-packages` (runner), `package-runner` (guest). Today: `stage-packages.sh` calling the real `download-packages` (runner, since 2026-10-07), and a stand-in for `package-runner` (guest) | Per ADR 0003. The build side is implemented and proved in CI (2026-10-01) against a fixture and the stand-in; neither of the owner's tools is usable yet (true on 2026-10-01; since 2026-10-07 `download-packages` is in use, and a trial build of `package-runner` has run in a full build, job 4245). The repository's own PowerShell package validator was deleted on 2026-09-29. |
| **Testing** | Manual only | **No automated tests.** The staging harness (`packer/tests/staging-provisioners.pkr.hcl`) replays the guest provisioners against a retained VM, and is run by hand. Script behaviour has been checked by hand-run tests recorded in the ADRs and commit messages, not by committed test files. The only committed suite (Pester) was deleted with the package validator it tested. This is a gap against the engineering rule "Tests prove behavior". |
| **Virtualization** | vSphere | Target platform for Packer builds. |
| **Schema Validation** | JSON Schema | `validate-iso-metadata.sh` reads the `required` list from `packer/schemas/iso-metadata.schema.json` and checks the qualification record against it. It is not full schema validation — types and patterns are ignored. This is the only schema in the repository; the package-manifest schema was deleted on 2026-09-29. |

---

## **🏃 Runner Integration Model**
> **Key Concept**: Linux runners are **replaceable execution agents** that perform discrete, auditable tasks in the Image Factory pipeline.

### **Runner Types and Responsibilities**
| Runner | Scope | Responsibilities | Phase | Inputs | Outputs |
|--------|-------|------------------|-------|--------|---------|
| **Image-Build Runner** | **Phase 1 (Host-Side Validation + Packer)** | Validates the ISO records, verifies the install inputs on the runner, executes Packer against vSphere (Windows setup, software install, guest cleanup), captures evidence to `evidence/`. | 1 | The ISO qualification records, the ISOs on the datastore, the vendored lock with the `package-runner` binary and package files, vSphere and AD credentials (CI variables). | A retained build VM in vSphere, `evidence/` artifacts (index, install-input verification, communicator, install and cleanup results, Packer logs). Not yet: a published master and its image-reference record. |
| **Downstream Runner** | **Phase 2 (Terraform + Citrix Lifecycle)** | Consumes **approved image identities** (from Phase 1), provisions Citrix resources via Terraform, manages lifecycle (scaling, updates). | 2 | The image-reference record from Phase 1 (the master VM's instance UUID and its versioned snapshot), Terraform modules, Citrix APIs. | Provisioned Citrix desktops, Terraform state. |

### **Runner Workflow**
1. **Image-Build Runner**:
   - **Where it runs**: the shared GitLab runner `runner-01` (tag `shared-medium`, host
     192.0.2.35, Docker executor; since 2026-09-28), in the `runner-image:0.1.0` image pinned
     by digest. `PACKER_RUNNER_SOURCE_IP` must be that host's address, because the guest
     firewall opens WinRM to it alone.
   - **Input**: the ISO qualification records in `packer/sources/windows/`, the vendored lock,
     the `package-runner` binary and the package files in `packer/fixtures/` (today a fixture
     and a stand-in), and the vCenter and AD credentials supplied as CI variables (`.env` is
     the workstation equivalent; see `.env.example`).
   - **Execution** (what CI actually runs, per `.gitlab-ci.yml`):
     - `validate-iso-metadata.sh` checks every ISO record in the `packer-validate` job, every
       pipeline. Stage 2 (`verify-datastore-iso.sh`) runs in CI as the manual
       `verify-iso-datastore` job, since `runner-image` `0.1.0` shipped `govc` (2026-09-30).
       Stage 1 (`verify-iso.sh`) is not in CI: it needs the share mounted on the runner.
     - `make init`, then `make build-diagnostic`, which runs `stage-packages.sh` and
       `packer validate` itself before building.
     - The build installs Windows, completes first-run setup, proves the WinRM identity, then
       uploads the lock, the binary and the package files, runs `install`, downloads its
       result before failing on a bad exit code, restarts on 3010 and runs the post-restart
       check ([ADR 0003](docs/decisions/0003-package-install-contract.md)). Today the binary
       is a stand-in and the package a fixture.
     - The guest cleanup removes credential material, build leftovers and the two build-time
       local accounts, and the build shuts the VM down. There is no seal step yet.
   - **Output**:
     - A retained build VM in vSphere (`destroy = false`; remove it with
       `scripts/windows/Remove-PackerTestVm.ps1`).
     - Evidence in `evidence/`, indexed by `collect-evidence.sh` into `index.json` and
       `SHA256SUMS`. The file list and each file's role are in
       [docs/evidence.md](docs/evidence.md); a build's own files are the Packer logs and
       provenance, `package-stage-<ts>.json`, `package-download-<ts>.log`,
       `communicator-result.json`, `install-result.json`, `install-result-verify.json`,
       `cleanup-result.json` and `enable-winrm-bootstrap.log`.
     - **Approved Image Identity**: decided ([ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md)), not
       implemented. The image is published as a powered-off master VM with a versioned
       snapshot in the project folder, identified by the VM's instance UUID and the snapshot
       (revised 2026-10-01: MCS takes a VM and a snapshot, not a template); `create_snapshot`
       stays `false` until the seal step exists (STORY-03). This is a prerequisite for the Phase 2 handoff below.

2. **Downstream Runner**:
   - **Input**: The image-reference record from `/evidence/`: the master VM's instance UUID and its versioned snapshot, with the VM's name, folder, datacenter and version, and the build evidence index's SHA-256 as provenance (ADR 0005, revised 2026-10-01).
   - **Execution**:
     - Will use Terraform modules to provision Citrix resources. Phase 2; no modules exist yet.
     - References the approved image by the master VM's instance UUID and snapshot, which is what an MCS machine catalog takes. There is no checksum of the image itself; `evidence_index_sha256` ties the reference to the build that produced it (ADR 0005).
   - **Output**:
     - Provisioned Citrix desktops.
     - Terraform state files (version-controlled or remote backend).

### **Key Properties of Runners**
- **Replaceable**: Runners are stateless; any Linux machine (or container) can assume the role.
- **Isolated**: Image-Build Runner **cannot** modify downstream Terraform/Citrix workflows (and vice versa).
- **Evidence-Driven**: All actions generate JSON evidence in `/evidence/` for auditability.
- **Fail-Closed**: If any step fails (e.g., SHA-256 mismatch, Packer build error), the runner **terminates** and writes failure evidence.

---

## **🚀 How to Engage**
### **For AI Agents (e.g., Continue)**
1. **Start Here**: Always begin by reading this file (`AGENT_HANDOFF.md`).
2. **Context First**:
   - Check `README.md` for project goals and Phase 1 progress.
   - Review `evidence/` for recent validation runs (if available).
3. **Respect Engineering Rules**: read [`.continue/rules/engineering-principles.md`](.continue/rules/engineering-principles.md),
   the single source of the rules.
4. **Key Commands**:
   ```bash
   # Validate the Windows source metadata. Reads only files in this repository,
   # so it needs no share and runs anywhere, including CI:
   bash scripts/runner/validate-iso-metadata.sh

   # Stage 1: verify the INTAKE copy's filename, size and SHA-256. Needs the ISO
   # reachable. Uses the record's originPath if it has one, or --source-path:
   bash scripts/runner/verify-iso.sh --source-path /mnt/fileshare-shared/image-factory/<iso>

   # Stage 2: verify the copy on the datastore — the bytes the build actually
   # boots. Needs govc: on the workstation, or in CI via the manual
   # verify-iso-datastore job (runner-image 0.1.0 and later).
   # Add --metadata packer/sources/windows/vmware-tools.json for the Tools ISO.
   bash scripts/runner/verify-datastore-iso.sh
   ```

   ```powershell
   # Discover vCenter inventory:
   .\infrastructure\scripts\Get-VCenterDiscovery.ps1  # Uses .env automatically
   ```
   ```bash
   # Runner and CI entry points (see the Makefile):
   make init validate-packer      # plugins, then validate the template with the variable file
   make fmt                       # packer fmt check
   make verify-iso-datastore      # ISO qualification stage 2 (needs govc; streams the whole ISO)
   make collect-evidence          # write evidence/index.json and SHA256SUMS
   make build-diagnostic          # retained diagnostic build (CI: manual job)
   make clean-vm VM_NAME=<name>   # delete one named test VM from disk (add FORCE=1 to skip the prompt)
   ```
5. **File Modifications**:
   - Use **exact versions** and **exact source references** (no `latest` or wildcards).
   - Update `AGENT_HANDOFF.md` after significant changes.

### **Runner-Specific Context**
- **Image-Build Runner**: Your work in **Phase 1** (Packer, validation) is executed by this runner.
- **Downstream Runner**: **Phase 2** (Terraform, Citrix) is out of scope for now. Focus on enabling the Image-Build Runner with:
  - Validated inputs (`windows-11.json`; the package install contract is agreed, ADR 0003, accepted 2026-09-28, and awaits implementation in STORY-05 and STORY-04).
  - Hand-tested scripts (`verify-iso.sh`, `verify-datastore-iso.sh`, `stage-packages.sh`); none has a committed test (see Technical Stack, Testing).
  - Packer templates that generate **auditable evidence** (`evidence/`).

### **For Humans (Collaborators)**
1. **Environment Setup**:
   - Install PowerShell 7+.
   - Install VMware PowerCLI:
     ```powershell
     Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
     ```
   - Install Packer for template validation:
     ```powershell
     choco install packer -y
     ```
   - Clone the repo, then `cp .env.example .env` and fill it in. The names in `.env.example` are
     the ones the scripts read; a name that does not match exactly is treated as unset.
   - **Loading .env in PowerShell** (for `scripts/windows/Remove-PackerTestVm.ps1`, which
     reads environment variables, not `.env`). Run from the repository root; it strips the
     quotes around a `DOMAIN\user` value:
     ```powershell
     Get-Content .env | ForEach-Object { if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2].Trim().Trim('"').Trim("'") } }
     ```
     In Git Bash, for the runner scripts and `govc`:
     `set -a && . ./.env && set +a`, then
     `export GOVC_URL="https://$VCENTER_HOST" GOVC_USERNAME="$VCENTER_USERNAME" GOVC_PASSWORD="$VCENTER_PASSWORD" GOVC_INSECURE=true`.
2. **Testing**:
   - Validate ISO:
     ```bash
     bash scripts/runner/verify-iso.sh --source-path <path to the ISO>
     ```
3. **Contributing**:
   - Follow [Example Labs Engineering Rules](#example-labs-engineering-rules).
   - Update this file (`AGENT_HANDOFF.md`) when adding new components.

---
---

## **📜 Example Labs Engineering Rules**
> **⚠️ Critical**: All implementations **must** adhere to these rules.

The rules live in one place: [`.continue/rules/engineering-principles.md`](.continue/rules/engineering-principles.md).
They are no longer repeated here (since 2026-09-30); two copies had drifted apart, and this
one still described package manifests, which ADR 0003 replaced with the `package-runner`
lock.

lab-specific exceptions to the rules are owner overrides, recorded under Key Design
Decisions: currently decision 8 (`-on-error=abort` kept for the lab).

---
---

## **🔍 Current Open Questions**
| Question | Context | Owner | Status |
|----------|---------|-------|--------|
| How should Packer reference the ISO? | Datastore vs. Content Library. | The image-build owner | **Decided** ([ADR 0004](docs/decisions/0004-iso-library-and-qualification.md)): the **datastore is the ISO library**, and the qualification record describes the datastore item. Content Library is DEFERRED on permissions, not merit. |
| Should ISO validation be merged into `Invoke-HostValidation.ps1`? | Modularity vs. simplicity. | The image-build owner | **Decided**: Keep separate (`verify-iso.sh`, `validate-iso-metadata.sh`). |
| Should Packer cache packages locally? | Performance vs. complexity. | The image-build owner | **Superseded**: how packages reach the guest is part of the software install contract (ADR 0003, accepted 2026-09-28): the runner stages them and Packer uploads them. |
| How do runners communicate approval of image identities? | Handoff from Image-Build Runner to Downstream Runner. | The image-build owner/the tooling owner | **Decided** ([ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md), 2026-09-28): one image-reference record in `evidence/` — the master VM's instance UUID and its versioned snapshot (revised 2026-10-01; first written for a template), plus name, folder, datacenter and version, with the SHA-256 of the build evidence index as provenance (not an image checksum). Built by STORY-11, into which STORY-12 was merged. |
| Which manifest format and install tooling does the build consume? | The recipe, catalog and tooling live in the tooling owner's repositories. | The image-build owner/the tooling owner | **Decided** (ADR 0003, accepted 2026-09-28): the `package-runner` lock, resolved from its recipe, which supersedes the baseline manifest. |
| Where does the expected SHA-256 come from at runtime? | It appears in the baseline manifest, the catalog's `sha256sums.txt`, the package definition and the lock. | The image-build owner/the tooling owner | **Decided** (ADR 0003): the lock, frozen at resolve time and protected by a `.sha256` sidecar (C1). `sha256sums.txt` becomes an authoring input, not a runtime authority. |
| Does install tooling run on the runner, in the guest, or both? | Host verification before transfer and guest re-verification after it are both required. | The image-build owner/the tooling owner | **Decided** (ADR 0003): both, reading the same lock. Since 2026-10-19 the released engine recomputes every staged file's hash in the guest (D8 fixed in 1.0.0). |
| How does the `package-runner` binary reach the guest? | A single static Go binary, but it needs a pinned version and a published build. | The tooling owner | **Answered 2026-10-19:** the 1.0.0 release, copied from the share and pinned by a committed SHA-256 (`packer/package-runner/`). Earlier note, kept for history: This repository uploads it with the lock and pins it by a committed SHA-256 (ADR 0003, C3; done for the stand-in). Still open on the owner's side: there is no tagged release to pin (D18), and the head of `init` does not compile (D34). **2026-10-08:** the head compiles (D34 closed at `a27199e`); still no tag. A trial build of a proposal branch is pinned here by hash and reached the guest in job 4245. |
| Generalize with sysprep, or keep a domain-joined master? | Some software cannot be generalized. | The image-build owner | **Decided** (ADR 0002, accepted 2026-10-01, STORY-10): domain-joined, no sysprep, because desktops are created by Citrix MCS. Citrix input: the Citrix stakeholders. |
| What are the lab's OU names for masters and for MCS desktops? | The stakeholders agreed the model and gave Site B's OUs as an example. | The image-build owner | **DEFERRED in the lab, 2026-10-01.** The OUs do not exist in the lab domain, so the build there keeps joining into the default computers container and the OU is not mocked (ADR 0002, requirement 3). The masters OU becomes an optional template variable, and Site B supplies it. |
| What does the build do with a `per-user` package? | `installScope` is an agreed lock field (ADR 0003, C1), but its enforcement was written for a generalization check that no longer exists. A per-user install lands in the build account's profile and reaches no desktop user. | The image-build owner | **Open, for STORY-03.** PROPOSED: fail the build on a `per-user` package. No check exists today. |

---
---

## **📅 Next Steps**
The lab proof of concept was closed out on 2026-10-19. The full list of what the lab proved,
what it accepted only as a lab, and what Site B must change is
[docs/lab-closeout.md](docs/lab-closeout.md); the Site B plan is PI4 (FEATURE-01,
FEATURE-02). What is left here:

| Priority | Task | Owner | Dependencies |
|----------|------|-------|--------------|
| 1 | **Decide the MCS catalog proof's scope.** PROPOSED: out of the lab, carried into Site B with an owner, since STORY-29 checks requirements but creates no catalog. | Image factory owner | None |
| 1 | **Ask for the D39 fix** (the release reports version `dev`), before Site B. | The image-build owner, then the tooling owner | None |
| 1 | **Settle where the lock comes from**: `resolve` in this pipeline (the owner's direction, 2026-10-07), or a reviewed vendored lock. Decides STORY-28. | The image-build owner/the tooling owner | None |
| 2 | Optional proofs of three failure paths in CI: a tampered staged file with the released engine (exit 11), a failed seal in a full build, the ISO gate stopping a publish. | The image-build owner | A build VM for the first |
| 2 | Remove `image-master-2026.10.09-4362`, and `image-master-2026.10.12-4441` once STORY-17 no longer needs it, by hand: neither is in the evidence store. | The image-build owner | None |
| 2 | Move the repository to Site B as a fresh import of the current files, not the history (STORY-30). | The image-build owner | Site B GitLab group |
| Parallel | The tooling owner's open items: D31 and D35 in `download-packages`, D38, release hygiene (moved tag, overwritten versions). | The tooling owner | None |

The previous next-steps table, as it stood before closeout, is in this file's history.

---
---

## **📞 Contact & Support**
- **Primary Owner**: the image-build owner (`image-build-owner@example.test`).
- **Collaborator**: the tooling owner (`tooling-owner@example.test`).

---
---
## **🔄 Changelog**
| Date | Change | Owner |
|------|--------|-------|
| 2026-08-17 | Initial `AGENT_HANDOFF.md` created. | Agent |
| 2026-08-17 | Added vCenter discovery script. | Agent |
| 2026-08-17 | Updated to use `.env` for vCenter credentials. | Agent |
| 2026-08-18 | Pivoted from Content Library to **datastore-backed ISO paths**. | Agent |
| 2026-08-18 | Added `packer/sources/windows/windows-11.json` (active qualification record). | Agent |
| 2026-08-18 | Added `packer/validation/Test-ShareIso.ps1` and `Test-WindowsSourceMetadata.ps1`. | Agent |
| 2026-08-18 | Added Packer template (`packer/templates/windows-11-vsphere.pkr.hcl`) and variable files (`configs/`). | Agent |
| 2026-08-18 | Removed readiness comment from `windows-11-vsphere.pkr.hcl`. | Agent |
| 2026-08-18 | Aligned `AGENT_HANDOFF.md` with actual repository state. | Agent |
| 2026-08-18 | Added **Runner Integration Model** section. | Agent |
| 2026-09-21 | WinRM communicator moved to HTTPS (see `docs/decisions/0001-winrm-https-communicator.md`). The real Packer variable file is no longer tracked; CI supplies it as the `PACKER_VARS_FILE` file variable, and the runner IP comes from `PACKER_RUNNER_SOURCE_IP`. | Agent |
| 2026-09-21 | Removed unreferenced code (`src/vcenter`, Content Library integration, unused runner and Windows scripts). Fixed the Makefile, `validate.sh` and `.gitignore`. Added `packer-fmt` and `runner-capabilities` CI jobs. Marked the package scripts provisional. Added ADRs 0002 and 0003 (Proposed). Refreshed this file. | Agent |
| 2026-09-21 | Added package staging with a fixture (runner verification, Packer upload, guest re-verification; STORY-06) and build evidence collection with an index and secret guard (STORY-07). Added `docs/evidence.md`. | Agent |
| 2026-09-22 | Proved guest communication as the administrative service account (STORY-01): added `packer/provisioners/Test-GuestCommunicator.ps1`, fixed environment-variable delivery and exit propagation, and moved the derived package var file out of `evidence/` into `build/`. | Agent |
| 2026-09-22 | Revised ADR 0003 after reading the three adjacent repositories directly: named the `package-runner` lock as the contract artifact, recorded the four-repository layer model, resolved four open questions subject to the owner's agreement, and listed seven defects that block an end-to-end run. Updated the cross-repo, Blocked, Open Questions and Next Steps sections to match. | Agent |
| 2026-09-22 | Repository cleanup. Fixed five defects: `make validate` could never pass, `make build-diagnostic` could never pass from a workstation, a dead WinRM harness called a non-existent method, the evidence secret scan was fail-open, and a second evidence collection erased the record of a caught leak. Closed a `.gitignore` gap that left non-default `*.pkrvars.hcl` files committable, added certificate patterns and line-ending enforcement. Deleted `packer/manifests/iso-metadata.json`, `packer/tests/winrm-auth-test.pkr.hcl` and the empty `terraform/`/`tests/` scaffolds; deprecated `software-source/` and `packer/manifests/` pending ADR 0003. Added `scripts/runner/lib/common.sh` and `require-env.sh`, pinned the runner image in one place, and reconciled the docs with the code. | Agent |
| 2026-09-23 | Ported the ISO validators from PowerShell to bash (`validate-iso-metadata.sh`, `verify-iso.sh`) so they can run on the CI runner, which has no `pwsh`. Wired metadata validation into `packer-validate`; ISO byte verification still needs the share mounted on the runner. Removed the PowerShell originals. | Agent |
| 2026-09-23 | Brought this file current after an audit against the working tree: added the guest credential cleanup, the two-stage ISO chain and the fixture lock to Completed; added ISO stage 2, the VMware Tools record and the failed-build credential gap to Blocked; made `govc` the first Next Step; listed six files that existed but were undocumented; and corrected the Technical Stack, both ISO-related Key Design Decisions, and stale build and job counts. | Agent |
| 2026-09-23 | Added [docs/image-factory-retrospective.md](docs/image-factory-retrospective.md): the whole-project retrospective and cross-repository overview. Re-read the three adjacent repositories, confirmed all seven ADR 0003 findings and added eight more (ADR 0003 findings 8 to 15), and recorded that `ci-platform` is a mock with no registry. Two previously suspected defects were investigated and dropped as unsupported. | Agent |
| 2026-09-24 | CI hardening: runner image pinned by digest, smoke test enforces a tool list derived from actual invocations, `runner-capabilities` probes outbound connectivity. Found that the runner image does not trust the internal CA (retrospective section 7). | Agent |
| 2026-09-24 | Settled defect numbering: the retrospective register's `D1`–`D21` is canonical. ADR 0003 relabelled, with a mapping from its earlier 1–15; every citation in the repository updated. The rows above dated 2026-09-23 and earlier use the old numbers. | Agent |
| 2026-09-24 | `iso_paths` now derived from the qualification records (ADR 0004); `iso_source_path` and `vmware_tools_iso_path` removed. Backward compatible with the existing `PACKER_VARS_FILE`. | Agent |
| 2026-09-24 | Salvaged `PACKER_ON_ERROR` from `feature/STORY-01-windows-communicator` (`9669668`) into `build-diagnostic.sh`, **commented out** by the owner's decision; behavior unchanged (`-on-error=abort`). The branch was then deleted. Brought this file and the retrospective up to date. | Agent |
| 2026-09-28 | CI moved to the shared runner `runner-01` (tag `shared-medium`, host 192.0.2.35). Image re-pinned to that host's digest; `PACKER_RUNNER_SOURCE_IP` and `PACKER_VARS_FILE` updated. Full build succeeded there (job 3497). **If the runner host changes again, both the digest and `PACKER_RUNNER_SOURCE_IP` must change with it.** | The image-build owner/Agent |
| 2026-09-28 | STORY-02, credential exceptions: removed seven orphaned build floppy images and a VM retained since Sep 4; `Remove-PackerTestVm.ps1` now deletes the build floppy; the Panther scan fails on unreadable paths; an induced failure (job 3531) recorded what `-on-error=abort` leaves behind, and the owner kept `abort` for the lab (Key Design Decision 8). | The image-build owner/Agent |
| 2026-09-28 | STORY-09: wrote ADR 0003's "Proposed contract terms" — C1 lock schema, C2 staging layout, C3 invocation and exit codes, C4 evidence, and the rule for what "installed correctly" means — as the agenda for the tooling owner. Re-read `package-runner` at `4881c5d`: D12 and D16 revised, D22–D28 added, and two claims dropped on 09-23 corrected (D26, D27). | Agent |
| 2026-09-28 | **ADR 0003 accepted** (STORY-09): contract terms C1–C4 agreed as written. Carried into implementation: the post-restart check's command name, provenance for hand-written locks, and verifying that WinRM downloads named files only. `package-runner` work is STORY-05 (the tooling owner); this repository's side is STORY-04. | The image-build owner/Agent |
| 2026-09-28 | STORY-13: added [ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md), accepted for the lab. Publish form is a vSphere template in the project folder; Content Library DEFERRED to Site B, its block now traced to a 403 caused by the role being granted on a VM folder. The image is identified by instance UUID; the reference's "checksum" is the SHA-256 of the build evidence index, so STORY-12 wins over STORY-11 AC2; the two stories are merged. | The image-build owner/Agent |
| 2026-09-29 | ADR 0003 contract terms clarified after review, within what was agreed: the lock's trust anchor is its expected SHA-256 committed here (the sidecar check in the guest catches transfer corruption, not tampering); `files[].path` includes the filename and only `package-runner` takes `--artifact-root`; any failure code beats 3010; `restart_required` is never a final status; `installScope` enforcement waits on ADR 0002; the post-restart check uses the proven upload-plus-inline `$env:` pattern. | Agent |
| 2026-09-29 | ADR 0005 clarified after review: Content Library is "not pursued in the lab" rather than "deferred to Site B"; the reference field is `evidence_index_sha256`, the hash of the final `index.json`, with the reference record written after the last collection and excluded from the index; publishing depends on `EXAMPLE.TEST\builduser`'s membership of `PROJ_image_factory`. STORY-12 invalidated and merged into STORY-11. | Agent |
| 2026-09-29 | Review fixes: repaired the retrospective's D16 row, broken by escape processing during an edit; corrected D27 (vscode ran and failed, it was not installed); updated D4 and D6 to the current sample lock; corrected line numbers for D8, D9 and D11; and removed every remaining statement that ADR 0003 is not agreed, in the README, this file, the retrospective, the fixture README and ADR 0003's older sections. | Agent |
| 2026-09-29 | Deleted the deprecated package tooling now that ADR 0003 is accepted: `software-source/` (the PowerShell download and host-validation scripts and their Pester tests) and `packer/manifests/` (the manifest schema and its example). Removed `validate.sh`'s optional `PACKAGE_MANIFEST` step, which made it need `pwsh`, and `collect-evidence.sh`'s role pattern for the validator's evidence files. | The image-build owner/Agent |
| 2026-09-30 | Read all of `runner-image` (`add-more-items` at `5c740bd`, all 21 tags). Corrected D2 (exit 127, `set -e` aborts), D3 (`--mount-root` silently ignored, not a loop) and D19 (three commits, not four). Added D29–D32: the `.bat` overwrites verified artifacts and has three more defects (delete it), the `.sh` accepts escaping paths and leaves unverified files in the staging tree. Recorded a contract gap in ADR 0003: runner-side verification leaves no evidence after `verify-package.sh` retires. `govc` is on no `runner-image` ref. | Agent |
| 2026-09-30 | Governance and Site B preparation: the engineering rules now live only in `.continue/rules/engineering-principles.md` (the two copies had drifted, and this file's still described package manifests); added `CLAUDE.md`; the template's ISO records are chosen by `windows_iso_record` and `vmware_tools_iso_record` (defaults unchanged), so another environment cannot silently build from the lab's ISOs. Recorded the tooling owner's 2026-09-30 agreement to ship `govc`, and corrected D30's wording. Staleness pass over the README, this file, the retrospective, ADR 0002, `.env.example` and the discovery doc. | Agent |
| 2026-09-30 | `runner-image` `0.1.0` shipped `govc`. Pinned `0.1.0@sha256:d1b990a1…`, the digest read from a tag-only branch pipeline since the runner host is not ours to log into (tag-only pins now fail the smoke test on `main`); `govc` required in the smoke test; manual `verify-iso-datastore` job added for ISO stage 2 (STORY-08). Both ISOs re-verified from the workstation with the job's loop. Register: D7 shipped but broken, D19 improved (`main` is the release), D20 now includes `govc`, recorded as the owner's position. | Agent |
| 2026-10-01 | STORY-04, build side of the software install, written against a stand-in for `package-runner` (owner's decision, since `package-runner` at `8e538aa` implements none of C1–C4). Added `scripts/runner/stage-packages.sh`, the stand-in in `packer/fixtures/package-runner/`, and committed hashes for the lock and the stand-in; restated the fixture lock in the C1 shape; moved the fixture package under `packages/` and made its `install.ps1` a benign machine-wide install; replaced the template's staging provisioners with the install sequence (exit-code gate after the evidence download, restart on 3010, post-restart check); `Remove-BuildArtifact.ps1` also removes the guest evidence directory; the harness mirrors the sequence and takes `HARNESS_FORCE_EXIT_CODE`. `Test-StagedPackage.ps1` deprecated. Verified on the workstation; the CI proof has its own entry below. Register: D33. STORY-08 is closed. | The image-build owner/Agent |
| 2026-09-30 | ISO record provenance (STORY-08): the VMware Tools ISO is `vmtools/windows.iso` from the Broadcom zip in `vendor-archives`, hash-verified and recorded in a new optional `origin` block; both records gained `qualifiedOn`. The Windows `originPath` pointed where the file is not; corrected to `windows-iso\` after stage 1 matched. Fixed `verify-iso.sh`, which reported a matching file as a mismatch whenever the path contained a backslash. | Agent |
| 2026-10-01 | **Sealing decided** (STORY-10): ADR 0002 accepted as option B, a domain-joined master with no sysprep, because desktops are created by Citrix MCS; Citrix input from the Citrix stakeholders. Recorded what that requires of the build (complete OOBE, a seal step, a masters OU and join account, a policy for the reused computer object, the VDA's restart codes) and the MCS catalog proof that replaces the sysprep proof. **ADR 0005 revised**: the publish form is a master VM with a versioned snapshot, not a vSphere template, since MCS cannot consume a template. The lab's OU names are still open. | The image-build owner/Agent |
| 2026-10-01 | **STORY-04 proved in CI** (commit `5b34a5c`). Full build, job 3836: VM creation through software install and cleanup with nothing done by hand, 24m59s. Harness against that VM: forced exit codes 10, 11 and 12 (jobs 3835, 3837, 3838) each failed the job after the result file was downloaded; 3010 (job 3839) restarted the guest and passed the post-restart check. The first build attempt (job 3834) failed on a one-minute `winrm_timeout` left in the CI variables from the STORY-02 failed-build test, not on the branch. | The image-build owner/Agent |
| 2026-10-02 | **The build completes Windows first-run setup** (first slice of STORY-03; CI job 3859, commit `e9ae3bc`). The answer file sets the time zone to UTC and defines one local administrator (`pkr-setup`, password generated per build, no auto-logon); `Remove-BuildArtifact.ps1` deletes it and `defaultuser0` and fails the build unless OOBE has finished, both accounts are gone and the time zone matches. `cleanup-result.json` is now `schema_version` 2 with `first_run_setup`. Confirmed at the console: the built VM powers on to the sign-in screen. | The image-build owner/Agent |
| 2026-10-02 | Documentation completeness pass: a Completed row for first-run setup, the sealing line no longer says nothing is built, the directory tree lists the fixture README and baseline manifest, and the vSphere discovery notes no longer say VM creation is untested or the Packer plugin is uninstalled. | The image-build owner/Agent |
| 2026-10-02 | Adjacent repositories re-read and the relationship brought up to date: `runner-image` at `a321d26` (`0.1.0`; `main` rebuilt by a squash, 22 tags over four commits, `download-packages` still does not parse) and `package-runner` at `8e538aa` (every register entry re-checked; D9 and D10 changed, the rest stand; **D34 added: the head does not compile as committed**; the owner's new README read). Added a last-read table to the cross-repo section and the STORY-04 questions to the retrospective's list for the owner. ADR 0003, "Read 2026-10-02". | The image-build owner/Agent |
| 2026-10-02 | Review corrections. This file: the image identity is the master VM and its versioned snapshot everywhere (three places still said template or SHA-256); Key Design Decision 8 names the `pkr-setup` password; Decision 6 no longer calls `.env` secure; the Runner Integration Model is rewritten to what CI runs today, including the runner host; VMware Tools is recorded as measured 2026-09-23 and verified 2026-09-30. ADR 0002: sysprep-only proof items struck, the template wording dated. ADR 0003: the VDA restart codes recorded as a requested C3 change. ADR 0005: a retention rule for published masters. Engineering rules: a Credentials section. | The image-build owner/Agent |
| 2026-10-04 | Added `docs/wiki/`: eight stakeholder-facing pages (home, how a desktop is built, status and roadmap, what we need from you, decisions, security and known risks, running and operating, glossary) for the Citrix, VDI, vSphere, Active Directory and packaging teams. They are the source of the GitLab project wiki, reviewed here and published by a manual copy. Reviewed before publishing, with the review's corrections included. Internal use only; not to be copied into any public repository. Publishing touches only the pages the folder manages (a `.managed-pages` list kept in the wiki). The wiki is a derived view: volatile facts live only on its status page, every page names its source document, and the repository is authoritative. | The image-build owner/Agent |
| 2026-10-05 | Wiki published (first publish, from `2bbd4d4`). "How a desktop is built" redrawn as a gated flow of six stages (qualify and prepare; build and join the domain; install software; clean up and verify; seal and shut down; publish), each with a gate question, three outcomes, and a table of inputs. The structure follows a Confluence wireframe of the image-build owner's, corrected to this repository's design: no sysprep, domain join shown, current stage states, and no separate approval step. ADR 0002 records that the desktops are persistent (stated by the image-build owner; to reconcile with the non-persistent example OU and confirm with Citrix). | The image-build owner/Agent |
| 2026-10-05 | Adjacent repositories fetched. One new ref: `runner-image` branch `adjust-script` (`671e967`, 2026-10-02), which reworks `download-packages.sh`. Read in full and run in a scratch folder: D1, D2, D3 and D32 are fixed there and it reads the nested lock shape (D5); D31 stands and is now tested; D4 changed (any repository name is accepted); **D35 added: an entry with no hash is staged unverified and reported as verified.** The branch is unmerged and untagged, so the pinned image and the build are unaffected. `package-runner` and `ci-platform` are unchanged. ADR 0003, "Read 2026-10-05". | The image-build owner/Agent |
| 2026-10-05 | **VMware Tools vendor authenticity verified** (ADR 0004). The installer the build runs, `setup.exe` inside the qualified ISO, has a valid Authenticode signature by Broadcom Inc chained to DigiCert, and all 69,473 blocks of the ISO match the vendor's own signed hash list in the archive. Not done, optional: comparing the archive's SHA-256 with a checksum on the Broadcom portal. How the archive reached the share (downloaded by the lab administrators) is stated, not observed. **Publish gate required** (ADR 0005): a master is published only if stage 2 ISO qualification passed for every ISO the build used; an acceptance criterion on STORY-11, not a new story. | The image-build owner/Agent |
| 2026-10-06 | Wiki: added `docs/wiki/Technical-sequence.md`, three Mermaid sequence diagrams of one build (pipeline start and validation; the virtual machine and Windows; software install, cleanup and shutdown), with tables of the participants, how they connect and as whom, and where each script runs. Read from `.gitlab-ci.yml`, `build-diagnostic.sh` and the Packer template at `cb1c6fc`; rendered locally before commit. It is the third wiki page that carries state. | The image-build owner/Agent |
| 2026-10-06 | **Runner image pin moved to `runner-image:0.2.1`** (`sha256:62c3d2b8…`, digest read from the owner's `runner-test-bed` job on the same runner). Adjacent repositories re-read: `runner-image` released the reworked `download-packages` (D1–D3, D7, D32 closed; D31, D35 open); `package-runner` at `7f73e52` still does not compile (D34) and has none of C1–C4, but its sample lock is now real; `runner-test-bed` added to the table of adjacent repositories. OBSERVED: the package share is mounted in job containers on our runner, and two real packages stage and verify there. **New first blocker for removing the placeholders: the owner's tools and this repository use different lock shapes.** ADR 0003, "Read 2026-10-06". | The image-build owner/Agent |
| 2026-10-07 | **The `0.2.1` pin is proved by a full build** (job 4015, commit `0f9e429`, 24m02s): smoke test and validation passed in the new image, then the build ran end to end with the same results as before the move (install exit 0, first-run setup finished, no password in 7 Panther files, floppy removed, 11 evidence files indexed). The image ID the runner used, `8281ad65…`, is the one the owner's test job reported. | The image-build owner/Agent |
| 2026-10-07 | ISO stage 2 passed in CI in the `0.2.1` image (job 4038 on `main`, both records). **Jobs now start from an empty project directory** (`GIT_STRATEGY: clone`): a job that failed before checkout had been uploading the previous job's `evidence/` as its own artifacts, seen twice on 2026-10-07. Proved by repeating the failure on a deleted branch: the retried job uploaded nothing (`evidence/: no matching files`). `docs/evidence.md` records the limit and the check a reader should make (`run.job_id` and `run.commit` in `index.json`). | The image-build owner/Agent |
| 2026-10-07 | **Interim lock shape** (decision by the image-build owner; ADR 0003): the build now reads the lock shape the owner's tools read today, with C1 to C4 kept as the strategic design. The fixture lock is one file per package; the fixture package is one self-contained script; `stage-packages.sh` calls the real `download-packages` from the `0.2.1` image and records what it staged; the stand-in reads the new shape. `verify-package.sh`, the baseline manifest, `sha256sums.txt` and the payload are deprecated and unread. Verified on the workstation (staging: 6 cases; stand-in: 23 cases under PowerShell 5.1, including a real timeout). **Proved in CI by a full build** (job 4074, commit `95ee61d`, 23m34s): the smoke test found `yq` and `download-packages`; staging reported 1 file staged; `build/packages` was uploaded; install exit 0, verify exit 0, installed-state check passed. Also read: `package-runner` `66a9d0a` (still does not compile; the D22 remark first written here was wrong, see the next entry) and `runner-test-bed` `test-image`. | The image-build owner/Agent |
| 2026-10-07 | **Deleted the deprecated fixture pieces** (the image-build owner's decision, after job 4074 proved the replacement): `scripts/runner/verify-package.sh` and its `make verify-package` target, `software-baseline-fixture.yml`, the fixture's `sha256sums.txt` and payload, and `packer/provisioners/Test-StagedPackage.ps1`. Nothing called or read them. The `package-verify-*` and `staging-result*` evidence role patterns stay, so older artifacts still classify. | The image-build owner/Agent |
| 2026-10-07 | **Correction: D22 did not get worse at `66a9d0a`.** The line that commit comments out is in a second copy of the validation block, inside `getArtifactPath`; the copy in `installPackage` still sets `validation_failed`. D22 stands as first recorded. Read `34bfc7f` (the `restartExitCodes` spelling; still does not build, D34) and the validator, logger and executor files against the owner's proposed validation evidence: two panics on the validation path and a placeholder `service` validator, recorded under D22. | The image-build owner/Agent |
| 2026-10-07 | **A proposal for `package-runner`, on the image-build owner's own branch** (his decision; an exception to "change only this repository", and none of the owner's branches was changed). Branch `proposal/validation-evidence`, cut from `34bfc7f` and pushed by the image-build owner the same day (`0078d7d`): validators record every check and what they observed, as a `validation.evidence` log entry and in `package-execution-evidence.json`; a failed validation fails the run (D22); the two panics are gone; the `service` validator queries the real service. Tested on the workstation (15 Go tests, and the built binary exits 1 on a failed validation, 0 on a pass). It is the owner's to accept, change or decline; until she merges something, every defect row stands as written. | The image-build owner/Agent |
| 2026-10-07 | **Trial build of `package-runner` committed, off by default.** The image-build owner's branch `proposal/build-contract` in `package-runner` (`e523e19`, 41 Go tests) closes the gap between the runner and C3/C4 as a proposal for the owner: `--artifact-root`, `verify`, the C4 result file, exit codes 0/10/11/12/3010, the elevation, sidecar and staged-file checks, stop at first failure, restart reporting and install timeouts. A reproducible build of it is at `packer/fixtures/package-runner/package-runner.exe` (first `0.0.0-trial.1`, SHA-256 `87067e7976a6…`, unsigned; replaced the same evening, see the next entry), used only when a job sets `PACKAGE_RUNNER`. The template and harness start an executable with stderr merged into the output; the stand-in's path is unchanged. The harness gained `tamper_staged_file`. To prove: the harness with the executable, the tamper case, then one full build (ADR 0003, "Trial of a `package-runner` build"). Not a release: D18 and D34 stand. | The image-build owner/Agent |
| 2026-10-07 | **The owner reviewed both proposal branches; trial binary rebuilt as `0.0.0-trial.2`.** `package-runner` `main` now builds from source control (`a27199e`): **D34 closed**. At her request the proposal now carries on after a failed package (a reversal of C3's stop-at-first-failure; `--stop-on-failure` restores it) and treats the lock sidecar as optional (checked when present; our build still uploads and checks it). Rebuilt from `c9f1439` (42 Go tests), SHA-256 `b03b918af51b…`. Her direction for the lock: generate it in this repository's pipeline with `resolve`; DEFERRED, to design with her (ADR 0003, "The owner's review"). New findings D36 (`validate --verify-artifacts` verifies nothing) and D37 (`/packages/*` ignored). Proved so far: job 4217, a full build on `c578e40` with the default stand-in, unchanged by the template edit; and `PACKAGE_RUNNER`, set for a whole pipeline, selects the executable. The executable has not yet run in a guest. | The image-build owner/Agent |
| 2026-10-07 | **The real `package-runner` installed a package in a full build** (job 4245, commit `b2699cf`, `0.0.0-trial.2`, 25m03s, `PACKAGE_RUNNER` set for the pipeline). The guest ran the unsigned executable; `install` exit 0 with a `validation.evidence` entry carrying the package, its version and the job id; `verify` exit 0 after the restart; installed-state check passed; the rest of the build unchanged. First build with the owner's tools on both sides of the seam: `download-packages` on the runner and `package-runner` in the guest. Still off by default and still a build of a proposal, not a release (D18). Not yet proved: the tamper case in a guest. New finding D38 (console timestamps print the year as 8086). | The image-build owner/Agent |
| 2026-10-08 | **Documentation audit after the trial.** Every `package-runner` row of the register now carries its state at `main` `a27199e` and on the proposal branches: D15 closed (`34bfc7f`), D27 withdrawn by the owner's decision, D18 and the rest restated. The status tables, the interface rows and the next steps here, the retrospective's dated notes, the README, the fixture README, ADR 0003's C1 and C3, the evidence guide and three wiki pages were brought forward. No behaviour changed. | The image-build owner/Agent |
| 2026-10-08 | **The seal step is written** (STORY-19 and STORY-03; ADR 0002, requirement 2), off by default and not yet run in a guest. `packer/provisioners/Invoke-ImageSeal.ps1` works in two stages: a provisioner that inventories every pre-seal item by name and registers a SYSTEM task, and that task, started by the shutdown command, which removes the WinRM listeners, firewall rules, certificate, administrative group mapping and build profile, returns remote management to the Windows default, re-checks everything and shuts down only if sealed. Because the seal removes the channel, its result leaves through VMware Tools: OBSERVED the same day that a guest-set `guestinfo` value is readable from vCenter while the VM is on and gone after power-off, so the guest holds for 120 seconds and `scripts/runner/verify-seal.sh` captures it. Decisions (the image-build owner): off by default (`SEAL_IMAGE=true` to seal), and remote management back to the Windows default. Verified on the workstation only (dry runs, the checker, `packer validate`). | The image-build owner/Agent |
| 2026-10-08 | **The seal step is proved in a guest** (commit `c177a0c`). Harness job 4288 sealed the VM from job 4280: every removal done, nothing left on the pre-seal list, local `Administrators` down to `Domain Admins` and the built-in `Administrator`; the VM powered itself off and comes back to the sign-in screen. Full sealed build job 4294 (27m27s, `SEAL_IMAGE=true`): the seal ran from Packer's shutdown command, the runner captured `seal-result-4294.json` from vCenter (`sealed: true`), Packer ended normally and the check passed. Still off by default. Not yet shown: the failure path in a guest, the unsealed default path on this code in a build, and that an MCS desktop is clean (the catalog proof). **Both shown later the same day** (commit `1f7729b`): job 4301, a default build, skipped the seal and behaved as before; harness job 4302, with a forced failure, captured `sealed: false`, failed the job and left the VM powered on. Still open: a failed seal inside a full build (Packer's 15 minute timeout), and the catalog proof. | The image-build owner/Agent |
| 2026-10-08 | **Finding: an idle guest goes to standby.** While checking that the VM from the forced-failure run stayed on, vCenter showed "Your guest has entered a standby sleep state" 15 minutes after power-on. The image's power plan allows it; no build sees it because Packer keeps the guest busy. OPEN, for the Citrix stakeholders: should the image disable standby itself, or is that left to Group Policy and the VDA (ADR 0002, requirement 2, proof notes). | The image-build owner/Agent |
| 2026-10-08 | **Story numbers corrected.** The seal was recorded everywhere under STORY-03 and STORY-19 was never mentioned. Per Jira: **STORY-19** (Pre-Seal Artifact and Credential Cleanup) owns what is removed and how removal is verified; **STORY-03** (Image Sealing Workflow) owns first-run setup, running the teardown at shutdown, the power-off and the snapshot; **STORY-11** owns naming, the version scheme and the image-reference record. State against their acceptance criteria: STORY-19 AC1 to AC3 and AC5 met in substance, AC4 partly (fails closed; the residue check on a clone is not built); STORY-03 AC1 and AC2 met, AC3 not started, AC4 partly; STORY-11 not started, its dependency now satisfied. Four differences from STORY-19's wording are tabled in ADR 0002. | The image-build owner/Agent |
| 2026-10-08 | **The publish step is written** (STORY-11; STORY-03 AC3 and AC4), not yet run in a guest. New manual job `packer-build-publish` runs `scripts/runner/publish-image.sh`: the ISO datastore check for both records in the same job, a sealed build under a versioned name (`image-master-<UTC date>-<job id>`), a snapshot taken by the runner only after the seal is verified, the final evidence index, `image-reference.json` (schema in `packer/schemas/`) carrying that index's SHA-256, and two continuity lookups by instance UUID and snapshot id. `collect-evidence.sh` now leaves an index alone once a record points at it. `packer-build-diagnostic` is unchanged. Decisions (the image-build owner): the version scheme; the ISO check must be in the same job; a publish build always seals; the in-guest check stands as STORY-19's residue check. Verified on the workstation: the final-index rule (6 cases), the record writer and checker (8), the lookup against vCenter read-only (3). OBSERVED first: what `govc` reports for a snapshot (ADR 0005). | The image-build owner/Agent |
| 2026-10-08 | **The publish step is proved** (commit `4d1315e`). Job 4329, a default diagnostic build, was unchanged. Job 4330, `packer-build-publish`: both ISOs qualified in the job; a sealed build as `image-master-2026.10.08-4330`; snapshot `sealed-2026.10.08-4330` (`snapshot-37754`) taken after the seal was verified; a 16-file final index; `image-reference.json` carrying its SHA-256; two matching continuity lookups; and `after_script` left the index alone. A third lookup from the workstation matched. **Story state:** STORY-03 all four criteria met. STORY-11 all five met, with AC5 implemented as "the same job" by decision. STORY-19 met, with AC4's residue check standing as the in-guest check by decision; its wording is to be updated in Jira. Not yet shown: the gate stopping a publish in CI, and that MCS accepts the snapshot. The master carries the test fixture, not real software. | The image-build owner/Agent |
| 2026-10-08 | **Three changes on review of the first image-reference record**, before the publish MR merged. Publishing is refused from any branch but the default one unless `PUBLISH_FROM_BRANCH=true` marks the run as a test, so `image-master-2026.10.08-4330`, published from the feature branch, is a test image by that rule. The record drops the ISO `description` and gains `build.project` and `build.job_url`. Verified on the workstation (the record writer; the branch rule with a stand-in for `govc`); not yet shown by a publish run. | The image-build owner/Agent |
| 2026-10-08 | **First publish from `main`** (job 4362, `c4bec34`; version `2026.10.09-4362` by UTC date). All eight steps passed; the default-branch rule let `main` through with no warning; `image-master-2026.10.09-4362`, snapshot `sealed-2026.10.09-4362` (`snapshot-37873`). A lookup from the workstation found both masters by instance UUID, the first one about 100 minutes after it was published. The record, read from the artifact, shows the three review changes: `build.ref` is `main`, the job's project and address are present, and the ISO entries have no description. Jira closing comments for STORY-19, STORY-03 and STORY-11 were drafted the same day. | The image-build owner/Agent |
| 2026-10-12 | **First real package installed, and the STORY-17 demonstration run.** A lock for PuTTY 0.83.0 was added in `packer/software/` (hand-written from the owner's resolved entry, hash committed), and `runner-capabilities` now reports the package share: it is mounted for this project's jobs at `/mnt/image-factory/package-content`. With `PACKAGE_LOCK`, `PACKAGE_SOURCE_ROOT` and `PACKAGE_RUNNER` set for the pipeline: job 4408 (`fdb13f6`), a diagnostic build, staged the MSI from the share, installed it with the trial executable (exit 0) and validated `C:\Program Files (x86)\PuTTY\putty.exe` as PuTTY suite 0.83.0.0, before and after the restart check; job 4441 (`0efc166`, `main`) did the same inside `packer-build-publish`, with both ISOs checked on the datastore in the same job, and published `image-master-2026.10.12-4441`, snapshot `sealed-2026.10.12-4441` (`snapshot-38593`), the first master with real software. A harness run against an old build VM (job 4410) timed out waiting for WinRM before anything was uploaded; the VM was replaced by job 4408's. Not shown: more than one package, an installer that asks for a restart, a released `package-runner`. Adjacent repositories fetched: unchanged since 2026-10-07 except `package-runner` `add-publish`. Summary: [docs/demonstrations/story-17-integrated-build.md](docs/demonstrations/story-17-integrated-build.md). | The image-build owner/Agent |
| 2026-10-19 | **`package-runner` 1.0.0 is the default install engine.** The owner tagged `1.0.0` on `main` (`7d49d76`) on 2026-10-16 and published it to the share. Read by content: it holds both proposal branches, her release pipeline and registry validator, and builds for other platforms; built from the tag, every test package passes. The Windows binary was copied from the share, matched against the release's checksums file (`92daa2c3…3647`), and its hash committed in `packer/package-runner/`, with the path it is published at. The binary is not committed, because Site B's GitLab refuses `.exe` files: `stage-packages.sh` now copies it from the share into `build/` and checks it against the committed hash. The trial build stays in history, so the move to Site B (STORY-30) must be a fresh import of the current files. The copy from the share was proved in a full build the same day (job 4608). The trial build was removed. The stand-in was kept for one purpose, the harness's forced-exit tests, and the harness selects it when `HARNESS_FORCE_EXIT_CODE` is set. New defect D39: the release reports its version as `dev`; accepted for the lab, since the hash identifies the binary. D18 closed. OBSERVED 2026-10-19 in job 4592 (`e4c28b78`), a full build with no variables set: the release's hash matched, the fixture installed (exit 0) and validated before and after the restart step (verify exit 0), and cleanup passed. The console timestamps still show the wrong year (D38, now `19196`). | The image-build owner/Agent |
| 2026-10-19 | **Retention and the evidence store proved (STORY-18).** Merged `feat/master-retention-2026-10-12`: `evidence-store.sh`, `masters.sh` and the `masters-list` and `master-retire` jobs, and a ninth publish step that stores the evidence; a failure there unpublishes. Store: `/mnt/image-factory/artifactory/image-factory-group/image-factory/masters/`, agreed with the share's owner. On the branch: a test master published and stored (job 4643, 21 files), listed as `test` (4644), a dry run (4645), retired with its evidence kept (4647), listed as `retired` (4648). On `main` (`ecfde3b9`): `image-master-2026.10.19-4655` published and stored (4655), listed as `current` (4656), and its retirement refused (4657). The catalog check is a recorded statement, since the lab has no Citrix site. Backfilling 4362 and 4441 was dropped: a job token cannot download another job's artifacts here (HTTP 404, jobs 4489 and 4492). | The image-build owner/Agent |
