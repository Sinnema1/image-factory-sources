# ADR 0004: Where ISOs live, and what qualifies them

- **Status:** Accepted for the lab (2026-09-23). The datastore decision reflects what is
  already running; the two-stage qualification below is new and partly unimplemented — see
  Consequences.
- **Date:** 2026-09-23
- **Scope:** where the build's ISOs come from, what makes one qualified, and what the build
  is entitled to assume about the bytes it boots

Evidence labels follow the repository engineering rules: `OBSERVED`, `INFERRED`,
`PROPOSED`, `BLOCKED`, `DEFERRED`.

## Context

The build attaches two ISOs: Windows, and VMware Tools. Both are read from a vSphere
datastore, because ESXi hosts cannot read a UNC path — an ISO has to be on storage the
hosts can reach. That part was never really a choice.

What was a choice, and was made implicitly, is what qualifies them.

- **OBSERVED:** the qualification record `packer/sources/windows/windows-11.json` recorded a
  SHA-256 for a copy of the Windows ISO on the file share
  (`\\fileshare\shared\image-factory\…`). The build boots a *different* copy on the
  datastore (`[datastore-01] image-factory/iso/…`). Nothing compared them. The
  recorded hash therefore said nothing about the bytes any VM actually booted.
- **OBSERVED:** these are two copies, not one filesystem seen twice. The path depths differ,
  and a since-deleted second record (`packer/manifests/iso-metadata.json`, removed in
  `3cd3ffc`) stated outright: *"Hash computed from share copy."*
- **OBSERVED:** the VMware Tools ISO had **no qualification record at all** — no hash, no
  size, no provenance — while `packer/unattended/enable-winrm.ps1` runs `setup.exe` from it
  as SYSTEM during specialize. It was the one build input executed in the guest with no
  integrity checking of any kind.
- **OBSERVED:** Content Library was never rejected on merit. `docs/requirements/vsphere-discovery.md:26`
  records it as **Blocked**: `GET /api/content/library` returns 404 for lack of permissions.
  (Re-checked 2026-09-28: now `403`, traced to the role being granted on a VM folder rather
  than globally — see [ADR 0005](0005-publish-form-and-image-identity.md).)
  The pivot to datastore paths (2026-08-18) was a workaround for that, not a preference.

## Decision

**1. The datastore is the ISO library.** In the lab environment the datastore is used *as
if it were a Content Library*: it is the authoritative location an ISO is published to and
consumed from. Content Library remains DEFERRED, blocked on permissions rather than
suitability, and would be a management improvement rather than an integrity one.

**2. The qualification record describes the datastore item.** `datastore` and
`datastorePath` are required; the intake location is kept as an optional `originPath`. It is
explicitly not what the build boots. (Corrected 2026-09-30: this said nothing locates a file
by `originPath`, but stage 1, `verify-iso.sh`, reads it to find the intake copy unless
`--source-path` overrides it. An ISO that arrived inside a vendor archive under another name
records its provenance in the optional `origin` block instead; see the VMware Tools record.)

`datastore` and `datastorePath` are stored separately rather than as `[DS] path`, so nothing
has to parse or escape brackets; Packer's bracket form is composed where needed.

**3. Qualification is a two-stage chain against one hash.**

| Stage | What is checked | By |
|---|---|---|
| 1 | The intake copy, at a filesystem path | `scripts/runner/verify-iso.sh` |
| 2 | The published copy, on the datastore | `scripts/runner/verify-datastore-iso.sh` |

There is exactly one `sha256` in the record. Both copies are verified against that same
value, which is what makes the chain meaningful: it proves the published copy is the
qualified one, rather than merely that each copy is internally consistent.

**4. Publishing is verified, not controlled.** Copying an ISO from intake to the datastore
stays a manual step. This decision does **not** prevent a bad publish — stage 2 catches one
afterwards. That is a deliberate trade: automating an upload into vSphere is more surface
than the problem justifies today, and a verified manual step is auditable where an unchecked
one is not.

**5. Every ISO the build attaches has a record.** Including VMware Tools. An ISO mounted
into a build VM without a qualification record is a defect, not an omission.

## Consequences

- **OBSERVED 2026-09-23: the Windows ISO's datastore copy matches its record.** Stage 2 was
  run for the first time and passed — 8,514,439,168 bytes streamed from
  `[datastore-01] image-factory/iso/…` in 190 seconds, hashing to the recorded
  `01234567…f11bc`. Evidence: `iso-datastore-verify-20260923-220557Z.json`.

  So the chain has held: every image built to date booted the qualified media. That was not
  guaranteed — the record described the intake copy and nothing had ever compared the two.
  It is now measured rather than assumed, which is the point of this ADR.
- **`govc` was installed on the workstation on 2026-09-23** (v0.56.0, from the govmomi
  release binary — there is no winget package, and `go install` fails because the govc
  module carries `replace` directives). It is still **not** in the CI runner image.

  This also unblocks `make preflight` and `make list-vms`, which have required `govc` since
  they were written and had never been runnable by anyone. Note `make` itself is not
  installed on the workstation, so those targets still have to be invoked as scripts.
- **A domain-qualified `VCENTER_USERNAME` cannot be sourced from `.env` unquoted.** OBSERVED:
  `DOMAIN\user` loses its backslash to bash's escape handling, and vCenter rejects the
  resulting account with "incorrect user name or password" — which reads as a credential
  problem rather than a quoting one. CI is unaffected because GitLab injects the variable
  directly without shell parsing, which is why builds worked while the first workstation
  consumer of `.env` did not. Quote the value, or use the UPN form (`user@domain`), which
  has no backslash to lose.
- ~~**Stage 2 cannot run in CI**~~ **`govc` shipped in `runner-image` `0.1.0`, 2026-09-30.** The
  verifier exits 2 rather than 1 when `govc` is absent — "could not run" rather than
  "failed" — so it was wired into a pipeline unchanged: the manual `verify-iso-datastore`
  job checks every record, and `govc` is now a required tool in the smoke test. Both ISOs
  re-verified from the workstation on 2026-09-30 with the job's own loop.
  OBSERVED 2026-10-07, job 4038 on `main` at `19b8b30`, in the `runner-image` `0.2.1` image: both
  records passed stage 2 in CI (Windows ISO streamed in 166 s, VMware Tools in 3 s).
- **OBSERVED 2026-09-23: the VMware Tools ISO now has a record**
  (`packer/sources/windows/vmware-tools.json`), measured from the datastore copy —
  142,280,704 bytes, `d273728766…394f65`. It carries no `originPath`: this ISO predates the
  intake process and its provenance before the datastore is not recorded. The field is
  optional precisely so a record can say "not known" rather than invent a path.

  **Provenance found and verified, 2026-09-30 (STORY-08).** The ISO came from the Broadcom
  support portal as `VMware-Tools-windows-13.1.0.0.25218885-25294452.zip` (kept in
  `vendor-archives` on the intake share), whose `vmtools/windows.iso` was renamed when
  published to the datastore. That member, read straight from the zip, hashes to the
  record's `d273728766…394f65` (OBSERVED), so the datastore copy is the vendor ISO, not merely
  an unchanged one. It cannot use `originPath`, because stage 1 requires the intake copy's
  name to equal `filename`; the record's new optional `origin` block holds the archive, its
  SHA-256 (`588e878b…`, to compare with the portal's published checksum), the member path,
  version 13.1.0 and build 25218885. Both records also gained `qualifiedOn` (2026-09-23).

  **Vendor authenticity verified, 2026-10-05.** The step above showed the datastore copy
  equals the ISO inside the archive. This one shows that ISO is Broadcom's, using the
  vendor's own signatures, read from the archive on the intake share. Nothing from the
  archive was executed.

  | Check | Result (OBSERVED 2026-10-05) |
  |---|---|
  | Archive on the share | 134,831,201 bytes, SHA-256 `588e878b…7574`, equal to the record's `archiveSha256`. Written to the share 2026-08-25; its twelve members are all dated 2026-03-19 |
  | `vmtools/windows.iso` | 142,280,704 bytes, SHA-256 `d2737287…4f65`, equal to the record and so to the datastore copy |
  | `vmtools/version.txt`, `buildNumber.txt` | `13.1.0`, `25218885`, equal to the record |
  | The installer the build runs, `setup.exe` at the ISO's root | Authenticode signature **Valid**, signer `CN=Broadcom Inc, O=Broadcom Inc, L=San Jose, S=California, C=US`, issued by DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, certificate thumbprint `CE4458CC481945B6C80C6A5C02807E07C452C154`, DigiCert timestamp; file version 13.1.0.0 |
  | `VMwareToolsUpgrader.exe` | The same signer and certificate, Valid; product "VMware Tools 13.1.0 build-25218885" |
  | The vendor's signed hash list, `vmtools/windows.iso.sha` | "A VMware External Hashdata File": a 512-byte header and one SHA-256 for each 2,048-byte block. **All 69,473 blocks of the ISO match.** Flipping one byte of a scratch copy made exactly one block fail |
  | `vmtools/windows.iso.sig` | A PKCS#7 signature that verifies over `windows.iso.sha` (not over the ISO directly). Signer `CN=VMware Certified VIB Signing, O=VMware, Inc.` |

  What this proves: `setup.exe`, which `enable-winrm.ps1` runs as SYSTEM, carries a valid
  Broadcom signature that Windows validates to a public certificate authority, so it is the
  vendor's binary and has not been altered since signing. That does not depend on where the
  archive came from. Every block of the ISO also matches the vendor's own signed hash list.

  What it does not prove, and why that is acceptable:
  - The `VMware Certified VIB Signing` certificate is self-signed. The signature over the
    hash list verifies against the certificate carried in the file, but that certificate was
    not checked against a copy obtained from the vendor independently. It is supporting
    evidence; the Authenticode result is the anchor.
  - The archive as a whole was not compared with a checksum published on the Broadcom
    portal. That would add assurance for the members the build does not use (the `floppies/`
    folder). OPTIONAL: compare `archiveSha256` with the portal's value if one is published.
  - How the archive reached the share is stated, not observed: the lab administrators
    downloaded it from Broadcom and placed it there (the image-build owner, 2026-10-05), and it was
    copied from the share to the datastore.

  To repeat the check: hash the archive and its `vmtools/windows.iso`; mount that ISO
  read-only and run `Get-AuthenticodeSignature` on `setup.exe`; verify
  `windows.iso.sig` over `windows.iso.sha` with `openssl cms -verify -binary -noverify`; and
  compare the SHA-256 of each 2,048-byte block of the ISO with the entries after the hash
  list's 512-byte header.
- **OBSERVED 2026-09-30: the Windows record's `originPath` pointed where the file is not.**
  The intake copy is in `…\image-factory\windows-iso\`, not at the folder's top level. Stage
  1 against that copy matched (8,514,439,168 bytes), and only then was `originPath` corrected;
  the hash was not touched. Stage 1 from `originPath` alone had also never worked for a
  Windows path: `sha256sum` prefixes its output with `\` when a path contains a backslash, so
  `verify-iso.sh` reported a matching file as a mismatch. It now hashes from stdin, and stage 1
  from the corrected `originPath` passes with no override.

  This closes the gap where the one build input executed in the guest as SYSTEM had no
  identity or integrity of any kind. Note what it does and does not buy: the ISO is now
  qualified, so `verify-datastore-iso.sh` will detect it changing. Nothing verifies it at
  the moment `enable-winrm.ps1` runs `setup.exe` from the mounted disc — that would mean
  hashing a mounted ISO's contents in the guest, which is a different and harder problem.
  Qualifying the attached media is the proportionate control.
- Stage 2 streams the whole ISO — roughly 8.5 GB — through the machine running it. That is
  the cost of checking the real bytes rather than a proxy for them.
- ~~The datastore paths now live in **both** the qualification records and the untracked
  Packer variable file.~~ **Resolved 2026-09-24.** The template derives `iso_paths` from
  the two records with `jsondecode(file(...))` (which records, per environment, is set by
  `windows_iso_record` and `vmware_tools_iso_record` since 2026-09-30; both default to
  the lab's, and accept only a file name in `packer/sources/windows/`), composing Packer's `[datastore] path` form
  from `datastore` and `datastorePath`, and `iso_source_path` and `vmware_tools_iso_path`
  are deleted. The record is now the only place an ISO path is written, so the item stage 2
  qualifies and the item the build attaches are the same by construction.

  It had been DEFERRED because it changes the variable-file contract. OBSERVED with
  Packer 1.16.0: a variable file that still sets the two removed names is accepted with an
  "Undefined variable" warning and exit 0, and the values are ignored. So the existing
  `PACKER_VARS_FILE` keeps working unchanged. The two lines should still be removed from it
  so nobody edits them expecting an effect. Also OBSERVED: the derived strings equal, byte
  for byte, the last values ever tracked in git (`0e9558b`), and a record missing
  `datastorePath` fails `packer validate`. OBSERVED 2026-09-28: the values in the CI file
  variable matched the derived paths exactly, so the change did not alter which ISOs a build
  attaches; the two lines were then removed from the variable.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep qualifying the intake copy only | It is not what the build boots. This is the status quo the decision exists to end. |
| Qualify the datastore copy only, drop intake | Simpler, but the record would then say nothing about where the bytes came from. The two-stage chain costs one extra field and one extra script. |
| vSphere Content Library | BLOCKED on permissions (404). Would improve lifecycle and versioning; whether it would give an integrity guarantee for ISO items is unverified and should not be assumed. Revisit in Phase 2. |
| Automate publishing | More surface, and it writes to vSphere. Verification catches the same failures after the fact, which is sufficient while publishing is rare and deliberate. |
