# Example Labs Image Factory

Greenfield implementation of the Example Labs Image Factory proof of concept.

## Objectives

- Build Windows image automation with Packer
- Install approved software from Example Labs sources
- Configure Citrix test resources with Terraform
- Generate repeatable evidence and validation artifacts
- Support execution on Linux CI runners

---

Stakeholders in VDI provisioning (Citrix, VDI, vSphere, Active Directory, packaging): start
with the project wiki, whose source is [docs/wiki/](docs/wiki/home.md). It summarizes this
repository in plainer terms and says what each team is being asked for.

## Phase 1: Image Factory

For the whole-project retrospective, the end-to-end execution flow, and the cross-repository
integration detail (including the verified defect register for `ci-platform`,
`runner-image` and `package-runner`), see
[docs/image-factory-retrospective.md](docs/image-factory-retrospective.md).

### Completed
- [x] Windows 11 vSphere image build with Packer, run from GitLab CI (`packer/templates/windows-11-vsphere.pkr.hcl`)
- [x] WinRM communicator over HTTPS ([ADR 0001](docs/decisions/0001-winrm-https-communicator.md)); several CI builds succeed, and the `-on-error=abort` retention path has now been exercised by a failed build
- [x] Guest communication proved as the administrative service account (STORY-01): identity, transport, authentication and admin rights are checked in the guest and recorded as evidence (`packer/provisioners/Test-GuestCommunicator.ps1`, [docs/evidence.md](docs/evidence.md))
- [x] Diagnostic build with provenance and logs in `evidence/`, configured to keep a failed build's VM
- [x] Variable file supplied from a CI file variable; only the `.example` is tracked
- [x] Test VM cleanup (`scripts/windows/Remove-PackerTestVm.ps1`, workstation only): deletes one named VM **and its build floppy image**, which vSphere leaves behind; exercised against vCenter 2026-09-28 (STORY-02)
- [x] Guest credential cleanup: the build deletes the answer files Windows Setup caches in `C:\Windows\Panther`, and fails unless a scan finds no surviving `<Password>` element and no unreadable path (`packer/provisioners/Remove-BuildArtifact.ps1`, [ADR 0002](docs/decisions/0002-master-image-identity-and-sealing.md))
- [x] Windows first-run setup (OOBE) completes in the build: the answer file sets the time zone to UTC and defines one build-time local administrator, and the guest cleanup removes it and `defaultuser0` and fails the build unless setup has finished (first slice of STORY-03, proved 2026-10-02; [ADR 0002](docs/decisions/0002-master-image-identity-and-sealing.md))
- [x] Runner image pinned by digest, on the shared runner `runner-01` (`.gitlab-ci.yml`)
- [x] Package staging proof with a fixture: verified on the runner, uploaded by Packer, re-verified in the guest (ADR 0003, interim; replaced on 2026-10-01 by the install flow under In Progress)
- [x] Build evidence index and secret guard ([docs/evidence.md](docs/evidence.md))
- [x] ISO qualification: one record per ISO, a two-stage hash chain, and the build reading its ISO paths from the records (`packer/sources/`, `scripts/runner/validate-iso-metadata.sh`, `verify-iso.sh`, `verify-datastore-iso.sh`; [ADR 0004](docs/decisions/0004-iso-library-and-qualification.md))

### In Progress
Nothing in the lab: the proof of concept was closed out on 2026-10-19. What it proved, what it
accepted only as a lab, and what Site B must change are in
[docs/lab-closeout.md](docs/lab-closeout.md).

- [x] Software install: the released `package-runner` 1.0.0 installs and validates in every
  build, and a real package (PuTTY) was installed end to end (ADR 0003).
- [x] Retention: each published master's evidence is kept on the share, and masters are
  listed and retired deliberately (ADR 0005, STORY-18).

### Blocked
See the Blocked table in [AGENT_HANDOFF.md](AGENT_HANDOFF.md). The one substantive item is the
MCS catalog proof: no desktop has been made from a master, because Example Labs has no Citrix
site.

### Not started
- [x] The seal step and publishing the master (STORY-19, STORY-03, STORY-11): done 2026-10-08. The manual job `packer-build-publish` produces a sealed master VM with a versioned snapshot and an image-reference record (ADR 0005). Background, kept as written: Sealing is decided: a domain-joined master, no sysprep, for Citrix MCS ([ADR 0002](docs/decisions/0002-master-image-identity-and-sealing.md), accepted 2026-10-01). The build completes Windows first-run setup and sets the time zone to UTC (done 2026-10-02), and the seal step is built and proved (2026-10-08, `packer/provisioners/Invoke-ImageSeal.ps1`), off unless the build is run with `SEAL_IMAGE=true`; the versioned snapshot and the masters OU (deferred in the lab) remain. The publish form is a master VM with a versioned snapshot ([ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md)).
- [ ] Terraform / Citrix provisioning (Phase 2)

### Key Decisions
- **Fail-Closed**: Scripts throw errors on any validation failure (SHA-256 mismatch, missing files).
- **Lowercase Hashes**: All SHA-256 hashes are normalized to lowercase for comparison.
- **Evidence Storage**: Local `evidence/` directory (excluded from Git); CI keeps it as a job artifact for 30 days.
- **Datastore-backed ISOs**: the datastore is the ISO library, and the build reads each ISO's datastore path from its qualification record, chosen per environment by `windows_iso_record` and `vmware_tools_iso_record` ([ADR 0004](docs/decisions/0004-iso-library-and-qualification.md)).
- **Separate ISO and package validation**: ISOs and packages are different entities with different validation needs.
- **Publish form and image identity**: the image is published as a powered-off master VM with a versioned snapshot, which is what Citrix MCS consumes, identified by the VM's instance UUID and the snapshot, with the build evidence index's SHA-256 as provenance ([ADR 0005](docs/decisions/0005-publish-form-and-image-identity.md), the lab; revised 2026-10-01).
- **Sealing**: the master stays domain-joined and is not generalized; sysprep does not run, and a seal step removes the build's leftovers ([ADR 0002](docs/decisions/0002-master-image-identity-and-sealing.md), accepted 2026-10-01 with Citrix input from the Citrix stakeholders).
- **Failed builds keep their VM in the lab**: `-on-error=abort`, by owner override (`AGENT_HANDOFF.md`, Key Design Decision 8). Not carried over to other environments.
- **Package delivery is agreed**: [ADR 0003](docs/decisions/0003-package-install-contract.md), accepted 2026-09-28, makes the `package-runner` lock file the contract artifact, anchored by its expected SHA-256 committed in this repository, and this repository transfers it without parsing it (contract terms C1–C4). The earlier PowerShell package validator (`software-source/`) and manifest schema (`packer/manifests/`) it superseded were deleted on 2026-09-29.

## 📜 Capability Boundaries

| **Concern**                     | **Purpose**                                                                                     | **Components**                                      |
|---------------------------------|-------------------------------------------------------------------------------------------------|----------------------------------------------------|
| **Windows-source qualification** | Validates ISO identity, SHA-256, and source accessibility; one record per ISO per environment. | `packer/sources/windows/*.json`, `scripts/runner/validate-iso-metadata.sh`, `scripts/runner/verify-iso.sh`, `scripts/runner/verify-datastore-iso.sh` |
| **Packer image-build foundation** | Defines the Packer template, answer file, guest bootstrap, and variables for vSphere builds. | `packer/templates/`, `packer/unattended/`, `configs/` |
| **Runner and CI**                | Seven jobs: smoke test, format check, capability report, validation, ISO stage 2 (manual), diagnostic build and the staging harness. Shared helpers live in `scripts/runner/lib/`. | `.gitlab-ci.yml`, `Makefile`, `scripts/runner/`     |
| **Guest communication proof**   | Checks in the guest that WinRM authenticated as the expected administrative account over the expected transport, and records it as evidence. | `packer/provisioners/Test-GuestCommunicator.ps1` |
| **vSphere discovery**            | Read-only scripts to discover vCenter inventory. Workstation only, run by hand.              | `infrastructure/scripts/`                          |
| **VM cleanup**                   | Deletes one named Packer test VM from disk, and its build floppy image. Workstation only (needs `pwsh` and PowerCLI).     | `scripts/windows/Remove-PackerTestVm.ps1`, `make clean-vm`, `make list-vms` |
| **Evidence**                    | Build logs, validation results, provenance and an index, with a fail-closed secret scan. See [docs/evidence.md](docs/evidence.md). | `evidence/`, `scripts/runner/collect-evidence.sh` |
| **Software install**  | Verifies the lock, the `package-runner` binary and the package files on the runner, uploads them, runs the install in the guest and collects its evidence (ADR 0003). By default the package is a fixture; the runner-side staging is the real `download-packages` since 2026-10-07. Since 2026-10-19 the guest engine is the `package-runner` 1.0.0 release, pinned by hash in `packer/package-runner/` and copied from the share at build time; a trial build of it installed the fixture on 2026-10-07 and a real package, PuTTY 0.83.0 from the package share, on 2026-10-12 with the lock in `packer/software/` (ADR 0003, "First real package installed"). The stand-in is kept only for the harness's forced-exit tests. | `packer/fixtures/`, `scripts/runner/stage-packages.sh` |
| **Decisions**                   | Architecture decision records.                                                                | `docs/decisions/`                                  |

### Diagnostics
- `packer/tests/staging-provisioners.pkr.hcl` replays the guest-communicator and software install provisioners against an already running, retained build VM, so provisioner details can be debugged in minutes instead of a full build. It runs from the manual `staging-harness` CI job, not from a workstation: the VM only accepts WinRM from the runner.

### ISO Metadata
- **`packer/sources/windows/windows-11.json`**:
  The Windows ISO's **qualification record**, described by
  `packer/schemas/iso-metadata.schema.json`. Its required fields name the item on the
  vSphere datastore, which is the authoritative ISO library ([ADR 0004](docs/decisions/0004-iso-library-and-qualification.md)).
  `originPath` records the intake copy, which stage 1 reads to find the file. An ISO that
  arrived inside a vendor archive under another name records its provenance in `origin`
  instead (the VMware Tools record: the Broadcom download, verified 2026-09-30). Each record
  also carries `qualifiedOn`, the date stage 2 first passed.
- Qualification is a **two-stage chain against one hash**:
  `validate-iso-metadata.sh` checks the record itself (runs in CI),
  `verify-iso.sh` checks the intake copy, and `verify-datastore-iso.sh` checks the copy the
  build actually boots. All three compare against the single `sha256` in the record.
- **`packer/sources/windows/vmware-tools.json`**: the VMware Tools ISO's record. Attached as
  the second ISO and installed in the guest during specialize, so it is qualified for the
  same reason the Windows ISO is.
- **Verified 2026-09-23:** both datastore copies match their records, measured with
  `verify-datastore-iso.sh`, and re-verified 2026-09-30. `govc` shipped in `runner-image`
  `0.1.0` on 2026-09-30, so stage 2 runs in CI as the manual `verify-iso-datastore` job.
  See ADR 0004's Consequences.

  A second representation, `packer/manifests/iso-metadata.json`, was removed: it carried the
  same SHA-256 and size as the record above with a less specific source path, nothing read it,
  and its presence implied a second source of truth that did not exist.
