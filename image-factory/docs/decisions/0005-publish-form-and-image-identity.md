# ADR 0005: Publish form and image identity

- **Status:** Accepted for the lab (2026-09-28, STORY-13); clarified 2026-09-29 after review;
  **publish form revised 2026-10-01** (STORY-10): a master VM with a versioned snapshot,
  replacing the vSphere template, because the consumer is Citrix MCS
- **Date:** 2026-09-28
- **Scope:** what form the finished image is published in, what identifies it, and what a
  "checksum" in the image reference means

Evidence labels follow the repository engineering rules: `OBSERVED`, `INFERRED`,
`PROPOSED`, `BLOCKED`, `DEFERRED`.

"Identity" here means the **artifact's** identity — how a consumer finds and trusts the
published image. It is not the Windows machine identity (computer name, domain join, SID)
that [ADR 0002](0002-master-image-identity-and-sealing.md) is about.

## Context

The build ends with a powered-off VM (`convert_to_template = false`); nothing publishes it and
nothing records an identity for it. Phase 2 (Terraform, Citrix) needs both. Three questions
were open:

1. **Publish form.** A vSphere template in the project folder, or a Content Library item. The
   Content Library was set aside on 2026-08-18 after `GET /api/content/library` returned 404
   (`docs/requirements/vsphere-discovery.md:26`).
2. **A checksum conflict between two stories.** STORY-11 ("Produce approved image reference
   output") AC2 requires the image reference to contain an image identifier, version,
   **checksum** and publication location. STORY-12 ("Generate image artifact continuity
   evidence") intentionally avoids "assumptions regarding a portable SHA-256 checksum of a
   native vSphere image artifact".
3. **Whether those two stories should be one.**

### What was observed on 2026-09-28

Read-only checks with the account the builds use:

- **The Content Library block is a permission, not a missing service.** A REST session is
  created (`201`) and inventory reads succeed (`GET /api/vcenter/folder` → `200`), but
  `GET /api/content/library`, `GET /api/content/local-library` and `govc library.ls` all return
  **`403 Forbidden`** — no longer the 404 of 08-18. A library exists regardless: its backing
  folder `contentlib-00000000-0000-0000-0000-000000000000` is on `datastore-01`.
- **The role already carries the privileges.** The account's effective role on
  `/dc-01/vm/Projects/image-factory` is **`vdi-pilot-role`**, granted to
  `EXAMPLE.TEST\PROJ_image_factory` with propagation. Of its 161 privileges, it includes every
  `ContentLibrary.*` privilege and `VirtualMachine.Provisioning.MarkAsTemplate`,
  `CreateTemplateFromVM`, `DeployTemplate` and `CloneTemplate`.
- INFERRED, from the vSphere permission model and consistent with the above: Content Library
  privileges are checked against the library object, which is not under any VM folder, so a
  role granted on a VM folder never reaches it. The same role granted globally, or on the
  library, would.
- **The grant reaches the build through one person.** The builds authenticate as
  `VCENTER_USERNAME`, which is the named personal account `EXAMPLE.TEST\builduser`, not a
  service identity (retrospective, section 7). It holds `vdi-pilot-role` only through
  membership of `PROJ_image_factory`. Publishing therefore depends on one person's group
  membership. (Clarified 2026-09-29.)

## Decision

**1. Publish form: the master VM, powered off, with a versioned snapshot, in the project
folder** (`/dc-01/vm/Projects/image-factory`). Revised 2026-10-01.

The consumer is Citrix Machine Creation Services, confirmed by the Citrix
stakeholders on 2026-10-01 (ADR 0002). MCS takes a master **VM and a snapshot**; a
vSphere template is not a valid input. So the build keeps `convert_to_template = false` and
takes a snapshot instead (`create_snapshot = true`, with a `snapshot_name` that carries the
version). It needs no new permission: the build account's role on that folder includes
`VirtualMachine.State.CreateSnapshot` (OBSERVED 2026-10-01).

Superseded, 2026-09-28 to 2026-10-01: *a vSphere template in the project folder, produced
with `convert_to_template = true`.* That was decided before the consumer was known. Nothing
was built on it: `convert_to_template` was never turned on.

The Content Library is **not pursued in the lab**. Revisit it only if a later requirement
needs what it adds — versioned items, OVF export, subscription across vCenters. Nothing yet
says any later environment will use it. (Clarified 2026-09-29; the first wording said
"deferred to Site B", which assumed that.) If it is revisited, the precondition is now precise
rather than an unexplained 404: a vCenter administrator grants
`EXAMPLE.TEST\PROJ_image_factory` a global permission (or one on the library) carrying the
Content Library privileges, and `govc library.ls` then succeeds.

**2. The checksum conflict: STORY-12's position wins, and STORY-11 AC2 is updated.** A
SHA-256 of a native vSphere template is not a portable identity:

- A template is a set of files (`.vmx`, one or more `.vmdk`, `.nvram`), not one artifact.
- Storage migration, cloning, a Content Library import, or converting back to a VM rewrite
  or re-encode those files, so a disk hash identifies one copy in one place, not the image.
  INFERRED from how vSphere stores disks; it is the reason STORY-12 gives.
- Nothing downstream would verify it: Terraform clones a template by name or UUID.
- It costs a full stream of the disk (18 GB or more) per build.

The same reasoning holds for the master VM and its snapshot (revised 2026-10-01): a snapshot
adds delta and state files, MCS copies the snapshot's disk into its own base disk, and
neither MCS nor the Citrix Terraform provider checks a disk hash.

So in the image reference:

- **The image's identity** is the master VM's vCenter **instance UUID** together with the
  **snapshot's name and ID**, plus the VM's name, folder, datacenter and version (revised
  2026-10-01; first written for a template). The VM and snapshot are what the Citrix
  Terraform provider's machine catalog takes. Continuity (STORY-12 AC3) is proven by
  repeated lookups resolving to the same instance UUID and snapshot.
- **"Checksum" means the SHA-256 of the build's evidence index**, `evidence/index.json`,
  which already hashes every evidence file of the run (ISO qualification, package verification,
  provenance, logs). It ties the reference to the exact build that produced it. It is
  explicitly **not** a checksum of the image, so the field is named
  **`evidence_index_sha256`**, never `checksum` (clarified 2026-09-29).
- **Which `index.json`, and when** (clarified 2026-09-29). `collect-evidence.sh` rewrites
  `index.json` on every run with a fresh `generated_at` (`collect-evidence.sh:172`), and a
  build runs it twice — from the exit trap and from the CI `after_script` — so the index's
  hash changes between the runs. The hash recorded is that of the **final** `index.json`,
  after the last collection. And because the script indexes every file in `evidence/`
  except `index.json` and `SHA256SUMS` (`:154`), a reference record inside the index it
  hashes would be circular. So the reference record is **written after the last collection
  and excluded from the index**; it is the one evidence file the index does not cover, and
  it points at the index rather than the other way round.

A true artifact checksum becomes meaningful only when the image is exported as an OVF, whose
manifest carries a SHA-256 per file — that is, with the Content Library, not pursued above.

**3. STORY-11 and STORY-12 are merged.** They record the same facts (identifier, location,
build ID, metadata) at the same point in the pipeline. STORY-11 defines the output Terraform
consumes; STORY-12 proves that output points at the artifact that was built. Kept apart,
they would produce two records of the same facts that could drift. The merged story produces
**one image-reference record**; the continuity evidence is the proof that it resolves
consistently. **STORY-11 is the surviving story; STORY-12 was invalidated and merged into
it** (2026-09-29), and its continuity ACs are carried into STORY-11.

## Consequences

- **Publishing waits for the seal step.** The snapshot is what every desktop is created from,
  so it must not be taken before the seal step exists.
  [ADR 0002](0002-master-image-identity-and-sealing.md) decided sealing on 2026-10-01 (a
  domain-joined master, no sysprep); the seal step that removes the WinRM listener, the
  build certificate, the admin group mapping, `LocalAccountTokenFilterPolicy`,
  `defaultuser0` and the rest of that list is STORY-19, run at shutdown by STORY-03
  (built and proved 2026-10-08, off by default). Turning on `create_snapshot`
  belongs with that work, after the seal, not before it.
- **A master is published only from qualified ISOs** (required 2026-10-05; an acceptance
  criterion for STORY-11, not a separate story). Publication is allowed only if stage 2 ISO
  qualification (`verify-datastore-iso.sh`, [ADR 0004](0004-iso-library-and-qualification.md))
  has passed for every ISO record the build used, against the records as committed, and the
  result is in that build's evidence. Stage 2 exists today as the manual
  `verify-iso-datastore` job, and ordinary diagnostic builds stay as they are: the check
  streams the whole Windows ISO, about three minutes, which is worth paying before
  publishing and not on every build. This answers what should trigger stage 2
  automatically: publishing does.
- **Published masters must be versioned.** The build's `vm_name` is fixed today
  (`packer-build-002`), and each build creates a new VM, so a published master with a
  fixed name would block the next build. STORY-11 settles the VM and snapshot naming and
  the version scheme. **Settled 2026-10-08:** see "The publish step" below.
- **Published masters are retained by count, and removed deliberately** (decided
  2026-10-02 by the image-build owner, on the usual current-plus-previous practice for golden
  images; to confirm with the Citrix stakeholders, since rollback is theirs to use).
  - **Keep two:** the current published master and the one before it, so a bad image can be
    rolled back without a rebuild. Anything older is removed.
  - **Never remove a master a catalog still uses.** MCS copies the snapshot's disk into its
    own base disk, but a catalog update or rollback names the master's snapshot, so removal
    is checked against the catalogs first, not assumed safe from age alone.
  - **Removal is a recorded step, not a side effect.** It is done by the image factory's
    owner with a script (the cleanup script, extended; STORY-11), which deletes the VM,
    its snapshots and its files, and writes what it removed to `evidence/`. A build never
    deletes an older master on its own.
  - **A master's evidence outlives CI's default.** Job artifacts expire after 30 days
    (`docs/evidence.md`), which is shorter than a published master's life. The evidence
    package and the image-reference record of a published build must be kept for as long as
    that master exists; STORY-11 sets how (for example, keeping those artifacts
    indefinitely, or copying them to the share).
  - Unpublished build VMs are not covered by this rule: they are removed after use, as today.
- **To verify on the first real published master (INFERRED today):** that the instance UUID
  and the snapshot ID stay stable across repeated lookups, and that MCS accepts the
  snapshot. STORY-11's continuity AC (carried from STORY-12) rests on it.
- **The image-reference record's exact fields are STORY-11's to define**, within this
  decision: identity by instance UUID plus name, folder, datacenter and version;
  `evidence_index_sha256`; the build ID and a reference to the evidence package. It is
  written into `evidence/` **after** the last evidence collection and is excluded from
  `index.json` (see decision 2); `collect-evidence.sh` needs that exclusion added when the
  record is built.
- **Publishing depends on one person's account** until the builds use a service identity
  (see Context). Moving the vCenter credential to a service account must carry the
  `PROJ_image_factory` membership, or an equivalent grant, with it.
- **Phase 2's input changes shape.** `AGENT_HANDOFF.md` described the approved image identity
  as "SHA-256 + metadata"; it is now the master VM's instance UUID and snapshot plus
  metadata, with the evidence-index hash as provenance.

## The publish step (written 2026-10-08, STORY-11 and STORY-03)

**Proved 2026-10-08** by a full run, job 4330; the proof is at the end of this section.

Decisions, by the image-build owner on 2026-10-08:

| Question | Decision |
|---|---|
| The version scheme | The UTC date of the build and the pipeline job id that ran it: `2026.10.08-4294`. Unique per build without a counter to keep, it sorts by date, and the job id leads straight to the evidence. The VM is `image-master-<version>` and the snapshot `sealed-<version>` |
| How recent the ISO check must be | **The same job.** STORY-11's AC5 allowed "a recorded run no older than" some age; no age is allowed. The publish job runs the datastore check for every ISO record itself, before the build. It takes about three minutes, needs no clock arithmetic, and cannot be stale |
| Which builds seal | **A publish build always seals.** `packer-build-diagnostic` stays unsealed by default, for inspection and the harness |
| Where a master may be published from | **The default branch only**, unless a run is explicitly marked as a test (added on review of the first record; see the end of this section) |
| The residue check of STORY-19 AC4 | The sealed guest's own re-read, captured by the runner, is the control (ADR 0002). The independent confirmation is the MCS catalog proof's scan of a desktop. No check is made on a clone: it would need an account that can sign in to a sealed machine, and the seal removes the build's |

`scripts/runner/publish-image.sh`, run by the manual job `packer-build-publish`, is the only
thing that publishes. Eight steps, each failing closed:

1. **Version and names.** It refuses to start if a VM of that name exists.
2. **The ISO gate**: `verify-datastore-iso.sh` for every record in `packer/sources/windows/`.
   A failure stops here, before the build, with no record.
3. **Build and seal**: `build-diagnostic.sh` with `SEAL_IMAGE=true` and the versioned name,
   which already fails unless the seal's result was captured and says sealed.
4. **Snapshot**, taken by the runner with `govc` and not by Packer's `create_snapshot`.
   Packer would take it before the runner had confirmed the seal; taken here, a snapshot
   cannot exist unless the seal was verified. This replaces the `create_snapshot = true`
   the Decision above expected.
5. **The last evidence collection.** The index it writes is final.
6. **The image-reference record**, `evidence/image-reference.json`, whose shape is
   `packer/schemas/image-reference.schema.json`. It carries the final index's SHA-256, the
   ISO records with the datastore check each passed in this job, and the seal result. It is
   written a second time through the gate: an ISO record with no passing check in this
   build's evidence, for the hash the record carries now, stops it.
7. **Continuity**: the VM is found by the recorded instance UUID alone, the snapshot by the
   recorded id, twice. Both lookups must match the record and each other.
8. **The record and the lookups are scanned for secrets.**

A failure after the record is written takes the record away again. An image with no record
is not published.

**The index can be final.** `collect-evidence.sh` used to rewrite `index.json` on every run,
and CI runs it once more from `after_script`, after the job's script. Once
`image-reference.json` exists it now scans every file, the record and the lookups included,
and checks the index against the record's hash without rewriting it. The record and the
lookup files are the only evidence files the index does not list.

**OBSERVED 2026-10-08**, on `packer-build-002`, with `govc` 0.56.0:

- A snapshot's id is its vCenter managed object id, `snapshot-37751` in the run observed.
  It is also numbered within the VM (`id: 1`); the record carries the managed object id.
- The VM's `snapshot` property gives the name, the id and the creation time, and it is
  empty when the VM has no snapshot.
- The instance UUID differs from the BIOS UUID, and a VM is found by it both with
  `govc find -config.instanceUuid` and with `govc vm.info -vm.uuid`.
- Two lookups in a row returned the same path, name, instance UUID and snapshot id.

**Proved 2026-10-08** (OBSERVED from the job logs, commit `4d1315e`):

- **The default build is unchanged, job 4329.** `packer-build-diagnostic` built
  `packer-build-002` with no version, no gate and no snapshot, and the evidence index
  was rewritten by `after_script` as it always was.
- **A full publish, job 4330** (about 31 minutes). In order:
  1. Version `2026.10.08-4330`; VM `image-master-2026.10.08-4330`, snapshot
     `sealed-2026.10.08-4330`.
  2. Both ISOs passed the datastore check in the job (163 and 3 seconds).
  3. The build ran under the versioned name and was sealed: `seal-result-4330.json`,
     `sealed: true`, captured from vCenter; Packer finished after 28m14s.
  4. The snapshot was taken after that: id `snapshot-37754`, on instance UUID
     `502124a2-1ddf-ef07-e559-adc184bf3418`.
  5. The final index listed 16 files.
  6. The record was written with `evidence_index_sha256`
     `7ddbb95ae331d694332d682afdd42fa476966ae6198e3758e5bc15aaab81b85c`.
  7. Two lookups matched the record and each other.
  8. The record and lookups were scanned; the index was left alone.

  Then `after_script` ran the collection once more and printed "Evidence index is final …
  Not rewritten", which is the case the final-index rule exists for.
- **A third lookup, from another machine**, by the image-build owner's workstation two minutes after the
  job: the instance UUID resolved to the same VM in the same folder, powered off, with the
  one snapshot `sealed-2026.10.08-4330`, id `snapshot-37754`. This is the "to verify on the
  first real published master" item under Consequences: the identity is stable across
  lookups. Not yet shown: that it stays stable over days, or across a vCenter restart.

**What this master is, and is not.** It is the first image published by the mechanism, and
it proves the mechanism. It is not an image for anyone to use: its software is the test
fixture, installed by the stand-in for `package-runner` (ADR 0003), and no MCS catalog has
been made from it (ADR 0002, the catalog proof).

**Three changes made on review of the first record, 2026-10-08** (the image-build owner; after job 4330,
before the merge). Verified on the workstation; the next publish is the first to show them.

- **Publishing is refused from any branch but the default one**, so a master always comes
  from reviewed code. `publish-image.sh` checks this first, before it contacts vCenter.
  `PUBLISH_FROM_BRANCH=true` lifts it for one run, to prove a change to the publish step
  before it merges; the record's `build.ref` then names the branch, which marks the image
  as a test. **By that rule the first master, `image-master-2026.10.08-4330`, is a test
  image:** it was published from `feat/publish-step-2026-10-08`, before the rule existed.
- **The record no longer copies the ISO record's `description`.** It is a note for whoever
  maintains the ISO record, and for VMware Tools it ran to a paragraph. The file name and
  the hash identify the media.
- **The record names the job by address**: `build.project` and `build.job_url`. A job id
  alone means nothing outside the project. The address can outlive the artifacts it points
  at, which expire.

The record from job 4330 has the older shape (a `description` per ISO, no `project` or
`job_url`). It still passes the check; these fields are not required.

**The first publish from the default branch, job 4362** (OBSERVED from the job log,
2026-10-08 local, 2026-10-09 UTC; `main` at `c4bec34`). All eight steps passed:
version `2026.10.09-4362`, VM `image-master-2026.10.09-4362`, snapshot
`sealed-2026.10.09-4362` (`snapshot-37873`), instance UUID
`502164cc-a6a4-31de-9b53-e0eaa02bdb6d`, a 16-file final index with SHA-256
`0361da3c9ff37b589af6ab36603f7e98e723992b385242667274219f2eb60a89`, two matching lookups,
and `after_script` left the index alone.

- **The branch rule let `main` through**: the log has no "publishing from" warning and the
  job went on to step 2.
- **Both masters resolve from another machine.** Four minutes after the job, a lookup from
  the workstation by instance UUID found `image-master-2026.10.09-4362` with its one
  snapshot, and still found `image-master-2026.10.08-4330` with `snapshot-37754`, about 100
  minutes after that one was published.
- **The record shows the three review changes** (read from the job's artifact):
  `build.ref` is `main`; `build.project` is `image-factory-group/image-factory` and
  `build.job_url` is the job's address; the two ISO entries carry the record name, the
  file name, the hash and the datastore check from this job, and no description. Its
  `evidence_index_sha256` equals the value in the log.

There are now two masters. `image-master-2026.10.09-4362` is the first published from
reviewed code on `main`. `image-master-2026.10.08-4330` is the test image from the feature
branch. **Both carry the test fixture, not real software, and neither is for use.**

Not yet shown:

- **The gate stopping a publish in CI.** A failed or mismatched ISO check stops the record
  writer in the workstation tests; a publish job stopped at step 2 by a wrong ISO record
  has not been run.
- **That MCS accepts the snapshot.**

Not settled here, and recorded so it is not lost:

- **Two masters share one Windows computer name.** Each build joins the domain as
  `pkr-build-002`, so a second published master takes over the first one's computer account.
  Desktops made by MCS have their own accounts and are unaffected, but the older master
  would show a broken trust if it were started. ADR 0002, requirement 4.
- **Evidence expires before the master does.** Job artifacts last 30 days. The record names
  the job that holds them. Keeping them is STORY-18's. **Closed 2026-10-19:** see "Retention
  and the evidence store".
- **Nothing removes an older master.** Versioned names never collide, so masters
  accumulate until someone removes them. Also STORY-18's. **Closed 2026-10-19:** `masters.sh
  retire`, played by a person.

## Retention and the evidence store (written 2026-10-12, STORY-18)

This section builds the retention rule decided above ("Published masters are retained by
count, and removed deliberately") and closes the two items the publish step left open:
evidence that expires before the master does, and nothing removing an older master. It was
written on 2026-10-12 and proved in CI on 2026-10-19 ("Proved in CI" below).

### The evidence store

A published master's evidence is copied, once, to a store outside CI:

```text
/mnt/image-factory/artifactory/image-factory-group/image-factory/masters/
  <version>/                  the evidence folder of the publish job
  <version>.retired.json      added when that master is retired
```

- **Where, and why there.** The share is where this organisation already publishes build
  outputs (`ci-platform` writes container images and scripts under the same
  root). The path and write access were agreed with the share's owner on 2026-10-12, and
  OBSERVED the same day: the folder above `masters` is visible and writable from this
  project's jobs, on a read-write `cifs` mount. GitLab's package registry was the other
  candidate. It is enabled, and a job can list it with certificate checks on when it uses
  the runner's own certificate authority (the image's does not trust GitLab). Uploading
  was not tried. The share was kept (decided 2026-10-12 by the image-build owner): it was agreed
  and built, it is how build outputs are already published here, and the store sits behind
  one script, so moving later changes `evidence-store.sh` and nothing else.
- **Evidence outlives the master** (decided 2026-10-12 by the image-build owner). The decision above
  said evidence is kept "for as long as that master exists". That is the minimum, and the
  wrong end to stop at: desktops made from a master outlive it, and questions about an
  image come after it has been used. Retiring a master therefore never removes its
  evidence. Nothing in this repository deletes from the store.
- **Written once.** `evidence-store.sh put` refuses a version that is already there. It
  checks the folder first (the record is valid and for this version, `index.json` is the
  index the record names, every file matches the index), copies to `<version>.partial`,
  checks the copy the same way, and only then renames it. The share cannot enforce
  write-once, so this is a control in the script, not in the storage.
- **What is copied.** The files the index lists, `index.json`, `SHA256SUMS`, the record and
  the lookups made from it. Nothing else.
- **Published means stored.** `packer-build-publish` gained a ninth step that stores its own
  evidence. A master is listed as published only when its record is in the store. If the
  ninth step fails, the record is removed and the build is not published, as for any
  failure after the seal. The image itself would be sound, so this costs a rebuild; it is
  the price of there being no second way into the store (next item).
- **Earlier masters are not in the store** (decided 2026-10-12 by the image-build owner). The two
  masters that existed before this change, `2026.10.09-4362` and `2026.10.12-4441`, were
  published without it. A job to store an earlier publish job's evidence from its artifacts
  was written and removed the same day: OBSERVED 2026-10-12 (jobs 4489 and 4492), GitLab
  answers HTTP 404 when a job asks for another job's artifacts with its own token, for
  jobs whose artifacts exist. INFERRED: this instance does not allow a job token on that
  endpoint. The alternatives were a project access token, which is a credential to keep,
  or a copy made by hand from a workstation; neither was thought worth it for two proof
  images. So `masters.sh list` shows those two as unpublished VMs, the first master
  published after this change is the first it counts, and the two older VMs are removed by
  hand when they are no longer wanted. Their evidence is in job artifacts until about
  2026-11-08 and 2026-11-11; job 4441's archive is also attached to STORY-17.

### Listing and the retention rule

`masters.sh list` joins the store with vCenter. Each version is looked up by the recorded
instance UUID and snapshot id, the same lookup the publish step uses, and given one state.

| State | Meaning |
|---|---|
| `current`, `previous` | The newest masters built from the default branch, up to `MASTER_RETAIN_COUNT` (2). Kept |
| `beyond-retention` | Older than the rule keeps. May be retired |
| `test` | Built from another branch. Never counted as current or previous. May be retired at any time |
| `retired` | Removed by `masters.sh retire`. Its evidence remains |
| `missing` | In the store, but vCenter has no VM with that instance UUID |
| `mismatch` | vCenter returns something the record does not describe: renamed, moved, powered on, or a different snapshot |

A VM named like a master with no record in the store is listed separately as unpublished.
A master outside the agreed folder, `/dc-01/vm/Projects/image-factory`, is flagged.
That folder is this project's choice; no other team has been asked to agree it.

### Retiring a master

`masters.sh retire`, played by a person through the `master-retire` job. A build never
calls it. It is a dry run unless told to execute, and it refuses unless all of these hold:

- the version is `beyond-retention` or `test`;
- its record resolves exactly in vCenter and the VM is powered off;
- no floppy image is attached (STORY-02);
- a catalog check is supplied.

**The catalog check in the lab is a person's statement.** The rule above is to check the
catalogs before removing a master. Example Labs has no Citrix site, so there is nothing to
query. `CATALOG_USE_STATEMENT` must say how the person knows no catalog uses the master;
the statement and the GitLab login of whoever played the job are written into the
retirement record. Without it nothing is removed. When a site exists, a query replaces the
statement at the same point in the script. DEFERRED until then.

On success the VM, its snapshot and its files are removed, vCenter is asked again to
confirm the instance UUID is gone, the VM's datastore folder is listed for anything left
behind (names only), and `master-retired-<version>.json` is written to the job's evidence
and beside the version in the store.

`Remove-PackerTestVm.ps1` is unchanged and still refuses any name without `packer-`. The
decision above expected that script to be extended; a separate, stricter path was built
instead, because removing a master needs checks a test VM does not.

### Proved in CI (2026-10-19)

| Job | Ref | What it showed |
|---|---|---|
| 4500 | branch | `masters-list` reads an empty store and lists the two older masters as not published |
| 4643 | branch | A test master published from the branch; step 9 stored 21 files under `masters/2026.10.19-4643/`, checked after the copy |
| 4644 | branch | `masters-list` listed it as `test` |
| 4645 | branch | `master-retire` dry run: named the VM by instance UUID, the snapshot, the datastore files and where the evidence stays; removed nothing |
| 4647 | branch | `master-retire` executed (with `MASTER_RETIRE_FROM_BRANCH=true`): VM, snapshot and files removed; vCenter confirmed the UUID gone; nothing left in the datastore folder; `master-retired-2026.10.19-4643.json` written to the job and beside the evidence in the store |
| 4648 | branch | `masters-list` listed it as `retired`, its evidence still in the store |
| 4655 | `main` (`ecfde3b9`) | The first master published from `main` with its evidence in the store: `image-master-2026.10.19-4655`, snapshot `sealed-2026.10.19-4655` (`snapshot-40038`), 21 files stored. Also the first published master built with the released `package-runner` |
| 4656 | `main` | `masters-list` listed `2026.10.19-4655` as `current` and `2026.10.19-4643` as `retired` |
| 4657 | `main` | `master-retire` on `2026.10.19-4655` refused: "is the current master. The retention rule keeps it; it is not removed." Nothing was removed |

All OBSERVED 2026-10-19. The refusal without a catalog statement, and the refusals for a
powered-on master, an attached floppy image and a run from a branch, were shown on the
workstation against a fake store and a fake `govc` (36 cases, 2026-10-12), not in CI. A
`previous` master and a `beyond-retention` one have not yet existed: the store holds one
master from `main`.

### Not settled

- **The count.** Two is this project's choice, to confirm with the Citrix stakeholders.
- **The real catalog check.** A Citrix query, when there is a site.
- **Signing.** The evidence is verifiable by hash, from the record down. It is not signed.
- **How long evidence is kept.** Indefinitely, for now. Nothing removes it.

## Alternatives considered

| Option | Why not |
|---|---|
| vSphere template in the project folder | The first decision (2026-09-28). MCS takes a VM and a snapshot, not a template, so it was replaced on 2026-10-01. |
| Content Library item now | Needs an admin grant first (the 403), and adds OVF packaging the lab consumer does not need. Not pursued in the lab. |
| SHA-256 of the template's disk file(s) | Location-bound rather than portable, never verified by the consumer, and an 18 GB+ stream per build. |
| No checksum at all in the reference | Loses the link from the reference to the exact build. The evidence-index hash provides that at no cost. |
| Keep the two stories separate | Two records of the same facts, maintained by two stories, that could drift. |
