# Example Labs proof of concept: closeout

**Closed out 2026-10-19**, against `image-factory` `main` at `9979eef` and the adjacent
repositories as fetched that day. Phase 1, the image factory. Internal use only: like the rest
of this repository, it must not be copied into the public repository or any external
document.

This is the starting point for the Site B work (PI4, FEATURE-01 and FEATURE-02). It says what the lab
proved, what was accepted only because the lab is a lab, what was never shown, and what Site B has
to change. The detail behind every line is in the ADRs, the
[retrospective](image-factory-retrospective.md) and its defect register, and
[`AGENT_HANDOFF.md`](../AGENT_HANDOFF.md).

## Verdict

The proof of concept is **complete for the image factory**: from qualified media to a sealed,
published, versioned Windows 11 master with retained evidence, run from GitLab CI with no
manual step after the trigger, using the owners' released tools on both sides of the software
install. Each stage below was proved in CI.

**One assumption is not proved: that Citrix MCS accepts the master.** No catalog has been
created from a master, because Example Labs has no Citrix site. PROPOSED (2026-10-19, for the
image factory's owner to decide): declare it out of the lab's scope, and carry it into Site B as an
explicit proof with an owner. STORY-29 in PI4 checks the master against MCS requirements but
does not create a catalog, so as planned nobody would make the first desktop.

## What the lab proved

| Stage | Proved by | Where it is described |
|---|---|---|
| ISO qualification: each ISO's record, its intake copy and its datastore copy hash-chained; the build reads its ISO paths from the records | Job 4038 (both ISOs), and again in every publish since 2026-10-08 | ADR 0004 |
| Unattended Windows 11 build on vSphere, connected over WinRM HTTPS, with proof of the account it ran as | Every build since 2026-09-21; STORY-01 | ADR 0001 |
| Windows first-run setup completed, time zone UTC, temporary accounts removed | Job 3859 | ADR 0002 |
| Software staged on the runner from the package share and checked against a reviewed lock | Every build; PuTTY from the share in jobs 4408 and 4441 | ADR 0003 |
| Software installed in the guest by the released `package-runner` 1.0.0, re-checked in the guest, validated, re-validated after the restart step | Jobs 4592, 4608, 4655 (test package); PuTTY with the same code as a trial build, jobs 4408 and 4441 | ADR 0003 |
| Install failure and restart handling: exit codes 10, 11, 12 and 3010 | Harness, 2026-10-01 (jobs 3835, 3837, 3838, 3839), with the stand-in | ADR 0003 |
| Build credentials removed, and their absence checked | Every successful build | ADR 0002 |
| The seal: build-time access removed in the guest, checked by the guest itself, result read from vCenter; the build fails without it | Jobs 4288, 4294, 4302 (forced failure, harness), and every publish | ADR 0002 |
| Publish: versioned VM name and snapshot, image-reference record, two continuity lookups, the ISO gate in the same job | Jobs 4330, 4362, 4441, 4643, 4655 | ADR 0005 |
| Evidence indexed, scanned for passwords, and kept beyond the 30-day artifact expiry | Every build; the evidence store since job 4643 | ADR 0005, `docs/evidence.md` |
| Masters listed and retired deliberately, the current and previous ones protected, evidence kept after retirement | Jobs 4643 to 4648 and 4655 to 4657 | ADR 0005 |
| End to end, one job: datastore ISOs, build, real package, validation, seal, publish | Job 4441 (STORY-17) | `docs/demonstrations/story-17-integrated-build.md` |

## Built, but not shown in CI

These work in parts, by hand, or against test doubles. None changes the verdict.

| Not shown | What was shown instead |
|---|---|
| A tampered staged file stopping the released engine in a guest (exit 11) | The same check in the 1.0.0 release's own tests (`preflight_test.go`), and exit 11 forced through the stand-in |
| A failed seal stopping a full build | The forced failure in the harness (job 4302) |
| The ISO gate stopping a publish | The gate's checks run, and pass, in every publish |
| `master-retire` refusing a powered-on master, an attached floppy image, a run from a branch, or no catalog statement | 36 workstation tests against a fake store and fake `govc` |
| A `previous` or `beyond-retention` master | The store has held only one master from `main` |
| More than one package, an install order, an installer that needs a restart, a per-user installer | One package at a time |

## Accepted only because the lab is a lab

Each of these is a decision recorded for the lab, not a design for Site B. The PI4 story that
replaces it is given where one exists.

| In the lab | Site B needs | PI4 |
|---|---|---|
| vCenter certificate checks are off: the runner image does not trust the internal certificate authority | The authority in the CI image, and checks on | STORY-22, STORY-25 |
| Credentials are shared CI variables | Separate identities from CyberArk | STORY-26, STORY-31 |
| A failed build keeps its VM with the domain-join password in the guest and on the floppy image (owner's override) | Cleanup on failure | STORY-23 |
| Every build is named `PKR-BUILD-002`, so masters share one computer account | A unique name per build, from the naming standard | STORY-24, STORY-32 |
| Masters join the default computers container; no masters OU exists | The masters OU, and knowing which Group Policy applies during the build | STORY-32 |
| WinRM accepts one hard-coded runner address | The agreed runner range | STORY-27 |
| How the domain-join credential reaches the guest | An approved pattern or an approved exception | STORY-21, STORY-33 |
| The lock is hand-written | Generated by `package-runner resolve` in the pipeline, or a decision not to | STORY-28 |
| The package share and evidence store are folders on the lab share | Site B's storage decision | STORY-20 |
| The catalog check before retiring a master is a person's statement | A Citrix query, once there is a site | — |
| Retention keeps two masters | Confirmation from Citrix | — |

## Known defects carried forward

From the [defect register](image-factory-retrospective.md#45-defect-register). All are in the
package tooling owner's repositories.

- **D39:** `package-runner` 1.0.0 reports its version as `dev`, so `runner_version` in every
  install result says `dev`. A three-line release-configuration fix; to be fixed before Site B.
  The binary is identified by its SHA-256 meanwhile.
- **D38:** the engine's console timestamps print the wrong year (`19196` on 2026-10-19). Cosmetic.
- **D31, D35:** `download-packages` accepts paths that leave its folders, and treats a lock
  entry with no hash as verified. Both are reachable only through a lock this repository
  reviewed, which its committed hash protects.
- Release hygiene: a release tag was moved, and the publish script overwrites an existing
  version on the share. The build pins the engine by hash, so neither can change what runs
  without the build failing.

## Open with other teams

| Question | Who |
|---|---|
| Does MCS accept the master and produce working desktops? (see Verdict) | Citrix, and the image factory's owner for the scope decision |
| Is "keep the current and the previous master" the right retention rule? | Citrix |
| Which VDA version, and what are its restart codes? | Citrix, then package tooling |
| Are desktops persistent, and how does a new master reach existing ones? | Citrix |
| Is client time zone redirection configured on the delivery side? | Citrix |
| A built master goes into standby after 15 idle minutes. Should its power plan change? | Citrix |
| What should the build do with a package that installs per user? (PROPOSED: fail) | Image build |
| Where the lock comes from: `resolve` in this pipeline, as the package tooling owner suggested | Package tooling and image build |

## Moving the repository to Site B (STORY-30)

- **Import the current files, not the history.** A trial `package-runner.exe` was committed
  between 2026-10-07 and 2026-10-19 and is still in this repository's history. Site B's GitLab
  refuses `.exe` files, and a push rule checks every commit pushed. Since 2026-10-19 no binary
  is committed: the engine is copied from where its release is published and checked against a
  committed hash.
- Commit references in the ADRs and evidence records point at the lab's history; keep the lab
  repository readable for as long as those references matter.
- Environment values live in CI variables and `configs/*.pkrvars.hcl` (git-ignored), not in
  code, but several documents name the lab hosts and paths. They describe the lab and should stay as
  history, not be edited to look like Site B.

## State of the lab at closeout

| What | State |
|---|---|
| Current published master | `image-master-2026.10.19-4655`, snapshot `sealed-2026.10.19-4655`, evidence in the store |
| Other masters | `image-master-2026.10.12-4441` (PuTTY; STORY-17's evidence) and `image-master-2026.10.09-4362`, both published before the store existed; listed as not published and removed by hand when no longer wanted |
| Evidence store | `/mnt/image-factory/artifactory/image-factory-group/image-factory/masters/`: `2026.10.19-4643` (retired) and `2026.10.19-4655` |
| Install engine | `package-runner` 1.0.0, SHA-256 `92daa2c3…3647`, from the share |
| Runner image | `runner-image` 0.2.1, pinned by digest, on the shared runner `runner-01` |
| Wiki | Published from `main` on 2026-10-19 |
