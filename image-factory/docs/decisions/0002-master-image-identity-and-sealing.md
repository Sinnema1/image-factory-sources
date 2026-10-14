# ADR 0002: Master image identity and sealing

- **Status:** **Accepted, 2026-10-01** (STORY-10): option B, a domain-joined master with no
  sysprep. Proposed 2026-09-21.
- **Date:** 2026-09-21
- **Scope:** how the Packer build ends and what the resulting master image contains

Evidence labels follow the repository engineering rules: `OBSERVED`, `INFERRED`,
`PROPOSED`, `BLOCKED`, `DEFERRED`.

## Context

The image factory must produce a vSphere VM template that Phase 2 (Citrix
provisioning) can deploy many desktops from. The open question is where machine
identity is assigned: at build time, or at deployment.

(Written 2026-09-21, before the consumer was known. Since 2026-10-01 the product is not a
vSphere template but a powered-off master VM with a versioned snapshot, which is what Citrix
MCS takes: [ADR 0005](0005-publish-form-and-image-identity.md). "Template" below, in Context
and Options, is the wording of the time.)

- OBSERVED: today's build bakes identity in. The answer file sets the computer
  name and joins the domain during specialize using a shared service account,
  and the build ends with a plain `shutdown.exe`. Nothing in the repository or
  its branches runs sysprep or a pre-seal cleanup. (Updated 2026-09-30: a
  credential gate now exists — `Remove-BuildArtifact.ps1`, below — but it removes
  credential material and build leftovers only; it is not the pre-seal cleanup.)
- OBSERVED: the build leaves artifacts that must not ship in a template: the
  build certificate, the HTTPS WinRM listener and its firewall rule, the default
  HTTP listener and built-in rules, the admin group mapping, the build
  identity's profile, the cached answer file in `C:\Windows\Panther\`, and the
  package staging directory `C:\Packer\staging` (see ADR 0003). The certificate,
  listeners and firewall rules are enumerated in `packer/unattended/enable-winrm.ps1`
  and in ADR 0001's Consequences. Also on the list:
  `LocalAccountTokenFilterPolicy`, which `Enable-PSRemoting` sets to `1`. OBSERVED
  2026-09-28 on `packer-build-002` after a successful build (job 3497): still
  `REG_DWORD 0x1` under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`.
  Left in place it gives every local administrator account full rights over a
  remote session on every clone — including `defaultuser0` below. The build
  itself does not need it: it connects with a domain account, which the filter
  never applies to. Revert by setting it to `0` or deleting the value.
  These need cleanup under either option below.
- **OBSERVED (retained VM `packer-build-002`, 2026-09-23): the cached answer
  file holds the domain-join password in plaintext.** This supersedes the earlier
  INFERRED note and answers the open question in `docs/evidence.md` AC2.

  | File in `C:\Windows\Panther\` | `<Password>` element | Scrubbed |
  |---|---|---|
  | `unattend.xml` | yes | **yes** (`*SENSITIVE*DATA*DELETED*`) |
  | `unattend-original.xml` | yes | **no** |

  Windows Setup scrubs the working copy and keeps an unscrubbed original beside
  it. The asymmetry is the whole finding and is easy to miss: checking only
  `unattend.xml` shows a scrubbed file and suggests there is no problem. The
  service account password is therefore readable on every VM this build
  produces, and would ship in any template or clone made from one.

  Addressed by the guest cleanup step (`packer/provisioners/Remove-BuildArtifact.ps1`),
  which removes both files and then fails the build unless a recursive scan of
  `C:\Windows\Panther` finds no surviving `<Password>` element. Known gap: a
  failed build retains its VM and never reaches that step. OBSERVED 2026-09-28
  on an induced failure (job 3531): `unattend-original.xml` and `unattend.xml`
  both present with a `<Password>` element, and the build floppy — which holds
  the rendered answer file — still attached and on the datastore, because
  `-on-error=abort` skips the plugin's floppy cleanup. **Accepted for the lab by
  owner override** (`AGENT_HANDOFF.md`, Key Design Decision 8; STORY-02):
  delete a failed build's VM promptly with `Remove-PackerTestVm.ps1`, which
  removes the floppy image as well.
- OBSERVED (retained VM `packer-build-002`, 2026-09-23): local
  `Administrators` after a successful build contains four members, and **only one
  of them is a build artifact**:

  | Member | SID | Origin | Remove before sealing? |
  |--------|-----|--------|------------------------|
  | `EXAMPLE\VDI_BUILD_ADMINS` | `…-10472` | This build, via `enable-winrm.ps1` | **Yes** |
  | `EXAMPLE\Domain Admins` | `…-512` | The domain join, automatically | No |
  | `PKR-BUILD-002\Administrator` | `…-500` | Windows built-in | No |
  | `PKR-BUILD-002\defaultuser0` | `…-1000` | OOBE (see below) | See below |

  "The admin group mapping" in the list above means the first row only. Stripping
  `Domain Admins` would be removing a property of domain membership rather than a
  build artifact, and under a domain-joined master (option B) that would change
  who can administer every deployed desktop. The cleanup step must name the SID it
  removes, not clear the group.
- OBSERVED (same VM): `defaultuser0` is a member of local `Administrators` and is
  **`Enabled: True`** (last logon 2026-09-22). It exists because the build never
  completes OOBE, as recorded below; Windows normally removes it when a real
  account is created at the end of OOBE.

  This bears directly on the choice below. Under option A the account is cleaned
  up by the fresh OOBE pass that follows `sysprep /generalize /oobe`. Under option
  B an enabled local administrator account ships in the image, on every clone,
  and removing it becomes another hand-written cleanup entry.

  Not addressed by the guest cleanup step: disabling or removing it is a sealing
  decision, not credential hygiene, and under option A it is handled for free.
- OBSERVED when written: nothing removed any of them, and no provisioner cleaned the
  guest. Also left behind were `C:\Windows\Temp\Test-GuestCommunicator.ps1`,
  `communicator-result.json`, `staging-result.json`, and the bootstrap transcript
  `C:\Windows\Temp\enable-winrm-bootstrap.log`.

  **Updated 2026-09-30.** Those leftovers are now handled: the transcript is downloaded
  as evidence, and `Remove-BuildArtifact.ps1` deletes it, the other three files, the
  staging directory and the cached answer files (OBSERVED in job 3497's
  `cleanup-result.json`). What still ships, and still needs the pre-seal cleanup this ADR
  decides, is the rest of the list above: the build certificate, the WinRM listeners and
  firewall rules, the admin group mapping, `LocalAccountTokenFilterPolicy`,
  `defaultuser0` and the build identity's profile.
- OBSERVED: the build never completes Windows OOBE. The install answer file
  defines no local account, domain account, auto-logon or first-logon commands,
  so the VM sits at the OOBE local account page for the whole build. WinRM is
  configured in specialize, so Packer connects, provisions and shuts the VM down
  from that state (every successful build since, most recently job 3497 on 2026-09-28).
  Under a domain-joined master with no sysprep, every desktop would boot into this state,
  so that option requires the build to complete OOBE (STORY-10).
  **No longer true since 2026-10-02:** the build completes OOBE (Decision, requirement 1).
- OBSERVED: the answer file's `oobeSystem` pass sets no `TimeZone`. **Set to UTC since
  2026-10-02** (the same requirement).
- INFERRED: the pilot architecture assumes Phase 1 generalizes the image, but
  the current build produces a domain-joined one. **Superseded 2026-10-01:** the decision
  below keeps the image domain-joined, so the build and the architecture now agree.

### Why the package proof depends on this

How packages are delivered and installed is covered by
[ADR 0003](0003-package-install-contract.md).

Some software cannot survive generalization, and a package that installs
cleanly can still fail the proof.

- Per-user installers place the application under the installing account's
  profile. Build-identity cleanup or sysprep removes it.
- Software that binds to the machine SID, computer name, domain membership or
  hardware identifiers, or that activates a licence at install time, can break
  or misbehave on clones.
- OBSERVED: the only package currently in the software catalog is the per-user
  installer of an editor (its filename says "UserSetup"). INFERRED from the
  vendor's naming and behavior, not tested: it would install into the build
  account's profile and be lost. A machine-wide installer, or a different
  package, is the right first proof.

## Options

| Option | Outcome |
|---|---|
| A. Generalize with `sysprep /generalize /oobe /shutdown` | The template carries no machine SID or computer name, and, reportedly, no domain membership (not verified). Clones get identity at deployment from their own answer file (`unattend.xml`, distinct from the install-time `autounattend.xml`). The domain join and the domain build account could leave the build entirely; Packer would connect with a temporary local account. |
| B. Domain-joined master, no sysprep | Simpler build. Identity is assigned by the deployment tool. Citrix Machine Creation Services is reported to handle clone identity without sysprep and to work with domain-joined masters, which must be confirmed against the specific deployment. Every clone would otherwise share the master's SID. |

Option B carries a cleanup burden that option A does not. Everything the build
leaves in the guest has to be removed by a step this repository would have to
write and maintain, and that step has to be right every time. Option A hands
part of that to `sysprep`: the build identity's profile and `defaultuser0` are
cleaned up by the OOBE pass rather than by us.

The `defaultuser0` observation above is a concrete instance. It is in local
`Administrators` today, it is there only because the build parks at OOBE, and
under option A it disappears without anyone writing code. Under option B it is
one more entry on a hand-written list, and the cost of forgetting it is a local
administrator account on every deployed desktop.

### How the build joins the domain, which is part of this choice

The build joins during specialize using `Microsoft-Windows-UnattendedJoin`, with
a reusable service account password written in plaintext into the answer file
(`packer/unattended/autounattend.xml.pkrtpl`). That is what puts the password in
`C:\Windows\Panther`, and the cleanup step is a control on the consequence rather
than a fix for the cause.

Two alternatives remove the cause. Neither has been investigated — a search
across every branch found no consideration of either — and both interact with the
choice above, so they are recorded here rather than pursued separately:

| Alternative | Effect |
|---|---|
| **Offline domain join** (`djoin.exe` with a pre-computed blob) | The answer file carries a one-time-use, machine-specific blob instead of a reusable credential. A leaked blob is worth far less than a leaked service account password. Adds a step that must generate the blob per build and get it to the guest. |
| **Do not join at build time** | Already implied by option A above: "the domain join and the domain build account could leave the build entirely; Packer would connect with a temporary local account." The image ships unjoined and identity is assigned at deployment. Removes the credential from the build completely, and removes stale AD computer objects as a side effect. |

The second is not an independent option so much as a consequence of option A that
has not been costed. If option A is chosen, the credential should leave the build
with it, and the cleanup step becomes belt-and-braces rather than the control.

PROPOSED: decide this with the sealing choice, not before it.

## Decision

**Option B: the master image stays domain-joined and is not generalized. Sysprep does not
run.** Accepted 2026-10-01 (STORY-10).

**Citrix stakeholders providing the input: the Citrix stakeholders.** Their answers,
received 2026-10-01:

| Question | Answer |
|---|---|
| How are desktops created from the image? | **Machine Creation Services (MCS)** |
| Generalized or domain-joined master? | Domain-joined, no sysprep (agreed) |
| What does MCS consume? | A master **VM plus a snapshot**, not a vSphere template (confirmed). [ADR 0005](0005-publish-form-and-image-identity.md) is revised to match |
| Persistent or non-persistent desktops? | **Persistent.** Stated by the image-build owner on 2026-10-05; not from the 2026-10-01 answers. To reconcile and confirm with the Citrix stakeholders: the one catalog OU they gave as an example (below) is Site B's `NON_PERSISTENT` one. INFERRED, not verified: persistence decides the MCS catalog type and how a new master version reaches desktops that already exist, so it bears on the retention rule in ADR 0005 |
| The Citrix agent (VDA) | Installed in the image as a catalog package through the ADR 0003 contract; pointed at the Delivery Controllers by Group Policy, not by a value baked into the image (confirmed) |
| OUs and Group Policy | A dedicated OU for masters and an OU per catalog for the desktops MCS creates (agreed). The OU the stakeholders supplied was Site B's, as an example: `<site_b_domain>/Workstations/Virtual/NonPersistent/Production/<machine_name>`. That is where Site B's non-persistent production desktops live, so it is an example of a **catalog (desktop) OU**; no masters OU was given. **DEFERRED in the lab, 2026-10-01:** these OUs do not exist in the lab domain (stated by the image-build owner; not checked against the directory), so OU placement is not implemented or proven there. The masters OU and the catalog OUs are supplied in Site B, and the answer file needs the masters OU as a distinguished name (`OU=…,DC=…`), not in this slash form |

Why B, given MCS:

- MCS gives each desktop its own name, Active Directory computer account and machine
  password, and has its own image-preparation step. Generalizing the master first is
  unnecessary and can interfere with that step.
- **The shared machine SID is not a problem.** The Options table says every clone "would
  otherwise share the master's SID". Clones do share the master's *local* machine SID, and
  Microsoft's position since 2009 is that duplicate local SIDs do not matter. What must be
  unique is the domain computer account, and MCS creates one per desktop.
- A domain-joined master is built under the same Group Policy its desktops run under.

What option B costs is what the Options section warned of: nothing is cleaned up for us. The
requirements below are that cost, written down.

### What option B requires of the build

1. **The build must complete Windows first-run setup (OOBE).** Today it stops at the account
   page (Context). With no sysprep, every MCS desktop boots the master's disk as it is, so
   desktops would come up in OOBE. The answer file's `oobeSystem` pass already hides the
   setup screens; it lacks a `TimeZone` and any account to finish with. It needs both: the
   time zone, and one local administrator with a password generated per build, no
   auto-logon, which the seal step then disables or removes.

   **Time zone, decided 2026-10-01: the image is set to UTC**, and each user's own time zone
   is applied to their session by Citrix policy rather than baked into the image. INFERRED,
   to confirm with the Citrix stakeholders: that policy (client time zone redirection) is
   configured on the delivery side.

   Sequencing, agreed 2026-10-01: this is the first slice of STORY-03, on its own branch
   cut from `main` after the STORY-04 branch merges, because both change the Packer
   template and `Remove-BuildArtifact.ps1`.

   **Done and proved 2026-10-02** (CI job 3859, commit `e9ae3bc`). The answer file's `oobeSystem` pass sets
   `TimeZone` and defines one local administrator (`pkr-setup` by default) whose password
   the template generates per build; there is no auto-logon. Until a seal step exists,
   `Remove-BuildArtifact.ps1` does the removal: it deletes that account and `defaultuser0`,
   and fails the build if OOBE has not finished (`OOBEInProgress` under `HKLM\SYSTEM\Setup`
   is not 0), if the setup account was never created, if either account survives, or if the
   time zone is not the expected one. The outcome is in `cleanup-result.json` under
   `first_run_setup`. OBSERVED in job 3859: `OOBEInProgress` 0, `ImageState`
   `IMAGE_STATE_COMPLETE`, time zone `UTC`; `pkr-setup` and `defaultuser0` both existed and
   both were removed, with no account or profile error; the Panther scan still found no
   `<Password>` element in 7 XML files, so the second password is covered by the existing
   cleanup. OBSERVED by the image-build owner afterwards: the VM, powered back on, comes up at the
   sign-in screen and not the account page. That confirms what the registry value was
   taken to mean. Not shown: a desktop made from this master by MCS, which is the catalog
   proof below. A failed build now also leaves this second password in the answer
   file on the floppy and under `C:\Windows\Panther`, the same known gap as the domain-join
   password (STORY-02); it is random per build and its account dies with the VM.
2. **A seal step replaces sysprep**, as the build's last provisioner, inside the shutdown
   step because the WinRM channel must survive until the final command. It removes, by name,
   everything on the pre-seal list in Context: the WinRM listeners and their firewall rules,
   the build certificate, the `VDI_BUILD_ADMINS` mapping (by SID, never by clearing the group),
   `LocalAccountTokenFilterPolicy`, `defaultuser0`, the build-time local administrator and
   the build identity's profile. The credential cleanup in `Remove-BuildArtifact.ps1` stays.

   **Written and proved 2026-10-08** (`packer/provisioners/Invoke-ImageSeal.ps1`; proof at
   the end of this item). Two stories share it. **STORY-19** owns what is removed and how
   removal is verified. **STORY-03** owns running it as the build's last act, the power-off
   and the snapshot (taken by the publish step since 2026-10-08, job 4330; ADR 0005). (Until 2026-10-08 this record and the code cited
   STORY-03 for all of it.) Decisions taken with it, by the image-build owner on 2026-10-08:

   - **Off by default.** A template variable, `seal_image`, set through `SEAL_IMAGE=true` on
     the build job. A sealed VM has no WinRM, so the staging harness cannot use it again.
     The default flips once sealing is proved and publishing exists (ADR 0005).
   - **Remote management goes back to the Windows default**, which is more than the list
     above: both listeners (the build's HTTPS one and `Enable-PSRemoting`'s HTTP one on
     5985), the built-in Windows Remote Management firewall rules disabled, the remoting
     endpoints disabled, the WinRM service manual and stopped. This settles the open point
     in ADR 0001.
   - **The two local accounts stay where they are removed today.** The table in
     Consequences said their removal would move into the seal. It did not:
     `Remove-BuildArtifact.ps1` removes them and that is proved (job 3859). The seal
     refuses to run while either exists, and checks again at the end.

   How it works. Two stages, because the seal removes the channel Packer uses:

   - *Prepare*, a normal provisioner after the cleanup step. It takes an inventory of
     every item by name and fails if one the bootstrap creates is missing, since that
     means a name drifted and the seal would remove nothing and report success. It removes
     the two items that do not affect the channel (`LocalAccountTokenFilterPolicy` and the
     legacy 5985 rule), registers a scheduled task that runs as SYSTEM with no trigger,
     and writes `seal-prepare-result.json`, which the build downloads.
   - *Final*, run by that task, which the shutdown command starts in place of
     `shutdown.exe`. It removes the rest, re-reads every item, checks local
     `Administrators` (the build's group gone by SID; the built-in `Administrator` and
     `Domain Admins` present; no other local user), and shuts down **only if the image is
     sealed**. Otherwise it leaves the machine on, Packer fails on its shutdown timeout,
     and the VM is kept.

   How the final result leaves the guest, with no network channel. **OBSERVED 2026-10-08**
   on `packer-build-002` (from job 4280), with `govc` 0.56.0 from the workstation:

   - The build account can run a program in the guest through VMware Tools guest
     operations (`govc guest.run`), with no listener involved.
   - A value the guest sets with `vmtoolsd --cmd "info-set guestinfo.…"` is readable from
     vCenter while the VM is on, both by `govc vm.info -e` and in `config.extraConfig`.
     Values of 12, 1,000 and 6,000 characters all came back whole.
   - **After power-off the values are gone.** A value set from inside the guest lives only
     as long as the VM is running.

   So the Final stage sets its result as `guestinfo.imagefactory.seal.result` (base64 JSON, about
   1,600 characters), then holds the machine on for `seal_hold_seconds` (120 by default)
   before shutting down. `scripts/runner/verify-seal.sh watch`, started before Packer,
   polls vCenter and saves the result for this execution id as
   `seal-result-<execution id>.json`; `verify-seal.sh check` then fails the job unless that
   file exists and says sealed. No result is a failure. The fallback considered and not
   needed was a result file left inside the image.

   Verified on the workstation only: both stages in dry-run mode under Windows PowerShell
   5.1, the checker against sealed, unsealed and missing results, and `packer validate`
   for the template and the harness with sealing on and off. The WinRM listener reading
   could not be exercised there (it needs elevation). To prove in a guest: the harness
   with `HARNESS_SEAL_IMAGE=true`, the same with a forced failure, and one full sealed
   build.

   **Proved 2026-10-08** (OBSERVED from the job logs and the seal results, commit `c177a0c`):

   - **The harness, job 4288**, against the VM from job 4280. Prepare found every item the
     bootstrap creates, removed `LocalAccountTokenFilterPolicy` and registered the task.
     The runner captured `seal-result-4288.json` from vCenter about a minute after the
     task started: `sealed: true`, all ten removals `done`, nothing still present, and
     local `Administrators` holding exactly `EXAMPLE\Domain Admins` and the built-in
     `Administrator`. OBSERVED by the image-build owner afterwards: the VM powered itself off,
     and powered back on it reaches the sign-in screen.
   - **A full sealed build, job 4294** (27m27s, `SEAL_IMAGE=true` set for the pipeline).
     The guest cleanup ran first, then Prepare; Packer ran the shutdown command, which
     started the task; the runner captured `seal-result-4294.json` 55 seconds later
     (`sealed: true`); the VM powered off about three minutes after the command, and
     Packer finished normally. `verify-seal.sh check` then passed, and the evidence index
     holds 13 files, the two seal results among them. A sealed build takes about two
     minutes longer than an unsealed one, which is the hold.

   Also proved 2026-10-08, on commit `1f7729b`:

   - **The default, unsealed build, job 4301** (25m27s, no seal variable). Prepare printed
     "not requested (SEAL_IMAGE is not true). Nothing was changed", its `skipped` result
     was downloaded, the build shut down in the usual 40 seconds, and the runner made no
     seal check. This is the path every build takes unless asked to seal.
   - **The failure path, harness job 4302**, against the VM from job 4301, with the forced
     failure. The seal did its work and then reported failure, as the knob makes it. The
     runner captured `seal-result-4302.json` (`sealed: false`, "forced by
     SEAL_FORCE_FAILURE"), the check failed and so did the job. OBSERVED from vCenter: the VM was still `poweredOn` at 21:36Z, eight minutes after it reported, where a sealed guest powers off within three.

   **A finding from that check, not about the seal.** vCenter logged "Your guest has entered a standby sleep state" at 21:33:54Z, 15 minutes after the VM was powered on and 6 after the harness last touched it. So the image's power plan lets an idle guest go to standby. A build never sees this, because Packer keeps the guest busy and then shuts it down. A desktop made from the master would, unless Group Policy or the Citrix VDA's own optimisation turns sleep off. OPEN: whether the image should disable standby itself (`powercfg /change standby-timeout-ac 0`), to confirm with the Citrix stakeholders with the other delivery-side settings.

   Where the result differs from the wording of STORY-19's acceptance criteria, each for a
   reason recorded above. PROPOSED: reword the criteria to match.

   | The story says | What was built | Why |
   |---|---|---|
   | Extend `Remove-BuildArtifact.ps1`; do not start a parallel script | A second script, `Invoke-ImageSeal.ps1`, for the items that cut the channel and for the items `Enable-PSRemoting` adds | Those removals cannot run in a provisioner that still has to report back over WinRM |
   | `cleanup-result.json` records every item as removed, retained-with-justification or failed | Three files: `cleanup-result.json` (credentials, leftovers, accounts), `seal-prepare-result.json` and `seal-result-<execution id>.json`; outcomes are `done` or `failed` | The final result cannot be downloaded, so it has its own file; nothing is retained, so there is no such status |
   | The certificate is removed by thumbprint | By its friendly name, `Packer WinRM build certificate` | The thumbprint is new every build; the name is what the bootstrap sets and the seal can know in advance |
   | A residue check of the sealed master, on a clone or with a revert (AC4) | The sealed guest re-reads every item itself before it shuts down, and the runner captures that | **Not built as written.** A check from outside needs an account that can still sign in to a sealed machine, and the seal removes the build's. **Decided 2026-10-08 (the image-build owner):** the in-guest check is the control and the criterion is to be reworded; the MCS catalog proof's scan of a desktop is the independent confirmation |

   Not yet shown, and not claimed:

   - **A failed seal inside a full build.** The harness shows the guest stays on and the
     runner's check fails. In a full build the same failure would also make Packer wait
     out its 15 minute `shutdown_timeout` and fail; that wait has not been run.
   - **That a desktop made from a sealed master is clean.** That is the MCS catalog proof
     below. The seal's own check and its result are the evidence until then.
3. **The build joins into a dedicated masters OU** (`MachineObjectOU` in the answer file),
   closing the "No `MachineObjectOU`" risk, with a join account delegated only on that OU and
   separate from the WinRM administrative account.
   **DEFERRED in the lab, 2026-10-01:** the lab has no masters OU, so the build there keeps
   joining into the default computers container. The OU is not mocked: an OU name that does
   not exist fails the domain join, and the lab has no desktop Group Policy to keep off the
   master, so a stand-in would prove nothing. PROPOSED: the template takes the masters OU as
   an optional variable, empty by default, and renders `MachineObjectOU` only when it is
   set; the lab leaves it empty and Site B supplies its OU with no template change. The join
   account's delegation on that OU is deferred with it.
4. **A policy for the master's computer object.** Builds reuse the name `pkr-build-002`. Since
   Microsoft's October 2022 domain-join hardening (KB5020276), a join that reuses an existing
   computer account fails when a different account created it; it works today because the
   same service account created it each time (INFERRED; to verify in this domain). Either
   delete the object before each build, or pre-create it and grant the join account rights
   on it.
5. **The VDA installer's restart codes.** INFERRED from Citrix documentation, to verify for
   the VDA version in use (`Citrix_Virtual_Apps_and_Desktops_7_2507_LTSR_CU1.iso` is on the
   intake share): exit 3 means "succeeded, restart required" and exit 8 means "restart
   required, installation continues after it". ADR 0003's C3 anticipates only 3010, so the
   VDA's package definition must list these as restart codes, and code 8 means the build
   restarts and runs the installer again. To raise with the `package-runner` owner: recorded
   as question 9 in ADR 0003's owner table (2026-10-02), not yet put to her.

The original proposed path, kept as history: prove a package survives generalization in a
throwaway sysprep build, confirm with the Citrix owners, then choose. The Citrix input came
first and made the sysprep proof unnecessary; the working assumption had been option A.

## What generalization does not do

Sysprep resets machine identity. It does not remove what the build added on
purpose, so the pre-seal cleanup list applies to both options. Sysprep also
keeps device drivers, so VMware paravirtual drivers and VMware Tools survive.

## Evidence required: the MCS catalog proof

With option B accepted, the proof is no longer a sysprep pass. It is a small MCS catalog
built from a sealed master:

- A two-machine catalog is created from the master VM's versioned snapshot.
- Both desktops register with the Delivery Controller.
- Each has its own Active Directory computer account, in the catalog's configured OU (the
  default computers container in the lab, which has no catalog OU).
- A machine-wide package installed in the master works on a desktop.
- A scan of a desktop finds none of the build artifacts on the pre-seal list.
- Local `Administrators` on a desktop matches the expected table (the check below).
- A desktop boots to the logon screen, not into OOBE.

The items below were written for the sysprep proof. Those about sysprep itself no longer
apply; the time zone, the `Administrators` check and the `defaultuser0` check still do.

- ~~OBSERVED (to be gathered): the sysprep pass completes, and its logs are kept
  in `evidence/`.~~ Not applicable under option B.
- ~~**Sysprep from the build's OOBE state.**~~ **Not applicable under option B:** sysprep
  does not run, and since 2026-10-02 the build completes OOBE. Kept as history: The build VM
  never completes OOBE (see Context). INFERRED, untested: sysprep may refuse to run while OOBE is still in
  progress. Test it from that state in the throwaway proof, and keep the result
  and sysprep logs in `evidence/`. If it refuses, options include a temporary
  local account with a one-time auto-logon in the answer file (which adds a
  password to the answer file and to `C:\Windows\Panther\`, both of which the
  pre-seal cleanup must then remove) or completing OOBE another way. Decide
  after the test, not before.
- **Time zone.** The `oobeSystem` pass sets none. ~~Decide the time zone (and,
  with it, the locale settings) explicitly for the template, and record the
  decision here.~~ **Decided 2026-10-01: UTC in the image**, with the user's zone applied
  per session by Citrix policy (see "What option B requires of the build"). The locale
  settings stay `en-US`, as the answer file already sets them.
- ~~Two clones of the generalized VM have different machine SIDs.~~ Not applicable under
  option B: nothing is generalized, shared local SIDs do not matter, and MCS gives each
  desktop its own domain computer account (Decision).
- The package works on a clone after first boot.
- A scan of a clone finds none of the build artifacts listed above.
- **Local `Administrators` on a clone.** Run
  `Get-LocalGroupMember -Group 'Administrators' | Select-Object Name,PrincipalSource,SID`
  and compare against the four-row table in Context. `VDI_BUILD_ADMINS` must be
  gone; `Domain Admins` and the built-in `Administrator` must remain;
  `defaultuser0` must be gone. Cheap to run and it catches a cleanup step that
  removed the wrong SID, which a passing build would not.
- ~~**`defaultuser0` enabled state**, on a retained build VM, before the sealing
  decision: `Get-LocalUser defaultuser0 | Select-Object Enabled`.~~ Done and overtaken: it
  was `Enabled: True` on 2026-09-23 (Context), the decision is made, and since 2026-10-02 the
  build deletes the account and fails if it survives.
- ~~Known Windows 11 failure to guard: sysprep fails when a Store app was updated
  for a user but not provisioned for all users. Builds commonly disable Store
  auto-updates to avoid it.~~ Not applicable under option B: sysprep does not run.

## Consequences

Current state against the accepted future state (option B), for the three areas STORY-10
asked about and the two that follow from them:

| Area | Current state (OBSERVED) | Future state (option B) |
|---|---|---|
| **Sysprep** | Never runs. The build ends with `shutdown.exe` | **Does not run.** MCS assigns each desktop's identity. A seal step replaces it |
| **OU placement** | Build VMs join into the default Computers container, under different Group Policy from production | The master joins into a **dedicated masters OU** (`MachineObjectOU`). MCS creates desktops in **an OU per catalog**. DEFERRED in the lab, where these OUs do not exist: the build keeps the current state there, and the OUs are supplied in Site B |
| **Domain cleanup** | Each build reuses the computer object `pkr-build-002`; nothing manages it | The master's computer object is intended and kept. One policy for its reuse: delete before each build, or pre-create with rights for the join account (KB5020276) |
| **Guest cleanup** | Only credential material and build leftovers are removed (`Remove-BuildArtifact.ps1`) | The seal step removes everything on the pre-seal list, by name. A missed item ships in every desktop |
| **First-run setup** | **Done 2026-10-02 (job 3859):** the build completes OOBE with the time zone set to UTC and one build-time local administrator, removed by the guest cleanup. Before that it stopped at the OOBE account page | The same, with the account's removal moved into the seal step. **Not moved (2026-10-08):** the guest cleanup keeps removing it, and the seal checks it is gone |

Also:

- The shared service account, the domain join and the credential in the answer file all
  **remain** build concerns: option A would have removed them, option B does not. The
  credential cleanup stays the control, the account split (a join account separate from the
  WinRM administrative account) is now required rather than proposed, and offline domain
  join (`djoin`) is worth costing as a way to drop the reusable password.
- The build's shutdown step becomes the seal step. The WinRM channel must remain until the
  last command, so removing the listener happens inside that step.
- Publishing changes form: MCS takes a VM and a snapshot, so ADR 0005's vSphere template is
  replaced by the powered-off master VM with a versioned snapshot.
- Implementation is STORY-03 (the sealing workflow: first-run setup, running the teardown at shutdown, the power-off and the snapshot) and STORY-19 (what the teardown removes and how that is verified).
