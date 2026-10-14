# Build evidence

Every diagnostic build produces an evidence package that shows what was built, from which
commit, what was validated, and how the build ended. This page says where the evidence is,
how it is structured, and how it is produced.

## Where it is

| Where | What |
|-------|------|
| CI job artifacts | The `packer-build-diagnostic` and `staging-harness` jobs both upload the whole `evidence/` folder, even when the job fails. Artifacts expire after **30 days**. Download them from the job page (Download or Browse). |
| `evidence/` in a local checkout | The same files for runs made on a workstation. The folder is gitignored; only `evidence/.gitkeep` is tracked. |

## How it is structured

`evidence/` is one flat folder. **Start with `index.json`**: it lists every other file.

| File | Role | Produced by | What it shows |
|------|------|-------------|---------------|
| `index.json` | index | `scripts/runner/collect-evidence.sh` | Run metadata and every evidence file with its role, size and SHA-256. |
| `SHA256SUMS` | integrity | `collect-evidence.sh` | `sha256sum -c` format hashes of the files above. |
| `packer-console-<ts>.log` | `build-log` | `scripts/runner/build-diagnostic.sh` | What Packer printed during the build. |
| `packer-build-<ts>.log` | `debug-log` | `build-diagnostic.sh` (`PACKER_LOG=1`) | Packer's full debug log. Contains environment details such as addresses, datastore and ISO paths. Treat it as internal. |
| `packer-provenance-<ts>.txt` | `provenance` | `build-diagnostic.sh` | Commit, CI ref, dirty-file count, Packer and plugin versions, and a SHA-256 of the variable file (never its content). |
| `packer-validate-<ts>.log` | `validation` | `build-diagnostic.sh` | Result of `packer validate` for this build's exact inputs. |
| `package-stage-<ts>.json` | `validation` | `scripts/runner/stage-packages.sh` | Runner-side check of what the build transfers. The lock and the `package-runner` binary, each with the SHA-256 committed beside it and the SHA-256 computed. Since 2026-10-07 (`schema_version` 2) also `packages`: the exit code of `download-packages`, and the path, size and SHA-256 of every file it staged, hashed by this script because that tool writes no record of its own. Plus the execution id, and pass or fail. |
| `package-download-<ts>.log` | `validation` | `download-packages`, captured by `stage-packages.sh` | The staging tool's own output: each package copied from the source root and checked against the lock. Kept so a failure there can be read. |
| `package-verify-<ts>.json` | `validation` | `verify-package.sh` (deleted 2026-10-07) | **No longer produced (since 2026-10-07).** The interim fixture check, replaced by `download-packages`. The role pattern stays so older artifacts still classify. |
| `install-result.json` | `install` | `package-runner install` in the guest, downloaded by the template | The install (ADR 0003, C4): execution id, runner version, the lock's SHA-256, outcome, exit code, and per package its status, exit code, duration, the SHA-256 **computed** for each staged file, and the validation result. Downloaded whether the install passed or failed with a contract exit code (10, 11, 12), **before** the build fails on it. `runner_version: standin-1` means the stand-in wrote it, not `package-runner`. With the trial executable (ADR 0003, "Trial of a `package-runner` build") the file has the same top-level and per-package fields, plus `restart_required` and `lock_sidecar` at the top level; `validation` holds `passed` and `results`, one full evidence record per validator, where the stand-in writes a shorter `checks` list; and installer output is kept in the guest as `stdout.log` and `stderr.log`. |
| `install-result-verify.json` | `install` | `package-runner verify` in the guest, downloaded by the template | The post-restart check: each package's installed-state validation, run read-only after the install and after the restart if one was needed. Gives a package that reported `restart_required` its final status. |
| `communicator-result.json` | `communicator` | `packer/provisioners/Test-GuestCommunicator.ps1`, downloaded by the template | Sanitized proof that Packer's WinRM session ran as the expected administrative account: VM and computer name, communicator, transport, authentication method, and booleans for authentication, command result, identity match and administrative access. Contains no account name, password or other authentication material. Only present when the check passed. |
| `communicator-result-harness.json`, `install-result-harness.json`, `install-result-verify-harness.json` | `communicator`, `install` | the `staging-harness` job | The same guest steps, run against a retained VM. Deliberately named apart from the build's files so a harness run cannot overwrite a real build's evidence in the same folder. The `-harness` suffix keeps them matching `collect-evidence.sh`'s existing globs. |
| `cleanup-result.json` | `cleanup` | `packer/provisioners/Remove-BuildArtifact.ps1`, downloaded by the template | What the guest cleanup removed, and the result of scanning `C:\Windows\Panther` for a surviving `<Password>` element. `passed: false` means credential material survived, or the scan could not read a path it had to check (listed in `panther_scan.unreadable_paths`), and the build failed. Records file names, never file contents. Since 2026-10-01 (`schema_version` 2) it also carries `first_run_setup`: whether Windows first-run setup (OOBE) had finished, the time zone against the expected one, and the removal of the two build-time local administrators (the setup account and `defaultuser0`); any of those failing also sets `passed: false`. Build only; the harness deliberately does not clean up. |
| `seal-prepare-result.json` | `seal` | `packer/provisioners/Invoke-ImageSeal.ps1` (Prepare), downloaded by the template | The first stage of the seal (ADR 0002). Always present: `status` is `skipped` when the build was not asked to seal, which is the default. Otherwise the inventory of every item on the pre-seal list by name, what was removed while WinRM still worked, and whether the task for the final stage was registered. |
| `seal-result-<execution id>.json` | `seal` | `Invoke-ImageSeal.ps1` (Final) in the guest, read from vCenter by `scripts/runner/verify-seal.sh` | Only for a sealed build. The final stage cannot be downloaded from, because it removes WinRM; it reports through VMware Tools and the runner saves what it reads. `sealed`, the reason if not, each removal and its outcome, what is still present, and the members of local `Administrators`. A sealed build with no such file fails. |
| `image-snapshot-<version>.json` | `publish` | `scripts/runner/publish-image.sh` | Only for a published build. The snapshot taken after the seal was verified: the VM's name, path and instance UUID, the snapshot's name, id and creation time, and the seal result it followed. |
| `image-reference.json` | not indexed | `scripts/runner/image-reference.sh write` | Only for a published build, and **the one file a consumer reads** (ADR 0005, STORY-11). Which VM and snapshot the image is, the version, the build (with the job's address and the branch, which is the default branch for anything but a test image), the ISO records with the datastore check each passed in the same job, the seal result, and `evidence_index_sha256`, the SHA-256 of `index.json`. It is not a hash of the image. It is written after the last collection and is deliberately not listed in the index it hashes. |
| `image-lookup-1.json`, `image-lookup-2.json` | not indexed | `scripts/runner/image-reference.sh lookup` | Only for a published build. What vCenter returned when asked for the recorded instance UUID and snapshot id, twice, and whether each matched the record. Made from the record, so they are outside the index too. They are scanned for secrets with everything else. |
| `enable-winrm-bootstrap.log` | `bootstrap-log` | the guest, downloaded by the template | Transcript of `enable-winrm.ps1` during the specialize pass — VMware Tools, the WinRM listener and certificate, the firewall rule, and the administrative group mapping. None of this reaches the Packer console, so this is the only record of what the bootstrap did. Guest output, not runner output. Collected immediately before the cleanup step deletes it. |
| `iso-metadata-<record>-<ts>.json` | `validation` | `scripts/runner/validate-iso-metadata.sh` | The ISO qualification record checked against the `required` list in its schema, plus SHA-256 shape and a positive size. Reads only files in this repository, so it runs in CI — `packer-validate` produces one every pipeline. |
| `iso-verify-<record>-<ts>.json` | `validation` | `scripts/runner/verify-iso.sh` | **Stage 1.** The *intake* copy's filename, size and SHA-256 against the record. **Not produced in CI**: it needs the software share mounted on the runner, which it is not. |
| `iso-datastore-verify-<record>-<ts>.json` | `validation` | `scripts/runner/verify-datastore-iso.sh` | **Stage 2, and the one that matters.** The copy on the vSphere datastore — the bytes a build actually boots — streamed and hashed against the same record. Produced in CI by the manual `verify-iso-datastore` job since 2026-09-30, when `runner-image` `0.1.0` shipped `govc`; also produced by a workstation run. The job is manual, so the file exists only for pipelines where someone ran it. See ADR 0004. |
| `validate-<ts>.log`, `validate-*-<ts>.log` | `validation` | `scripts/runner/validate.sh` | Workstation runs of `make validate`. Not produced in CI: it needs the mounted share. |
| `preflight-<ts>.log` | `preflight` | `scripts/runner/preflight.sh` | Workstation runner and repository checks. Needs `govc`. |
| `vm-list-<ts>.log` | `inventory` | `scripts/runner/check-vm-name.sh` | Candidate test VMs, from `make list-vms`. Workstation only. |

`package-vars.pkrvars.hcl` is **not** evidence. It is a build input derived at runtime, written
to `build/`, so it is never indexed or uploaded.

The ISO evidence filenames carry the record name as well as the timestamp. CI validates
every record in a loop that finishes inside one second, and `ts_file` has second
resolution — without the record name the second run silently overwrote the first's
evidence, which is how it was found in CI on 2026-09-24.

Timestamps in filenames are UTC and carry a trailing `Z` (`20260922-141530Z`), matching the UTC
timestamps inside the JSON files. They were previously in different zones, which made a file
impossible to correlate with its own recorded time.

A full build job produces **one** `package-stage-<ts>.json` and one `package-download-<ts>.log`,
from `build-diagnostic.sh`. The `packer-validate` job produces its own when it runs
`make validate-packer`.

`staging-result.json` is no longer produced (since 2026-10-01, STORY-04). It came from
`Test-StagedPackage.ps1` (deleted 2026-10-07), which re-verified the staged files in the guest on
`package-runner`'s behalf; the install step now does that against the lock, and the hashes it
computed are in `install-result.json`. The `staging-result*.json` role pattern stays so older
artifacts still classify.

Any file whose name matches no pattern gets the role `other`.

### `index.json`

```json
{
  "schema_version": 1,
  "generated_at": "2026-09-21T16:00:00Z",
  "outcome": "success",
  "run": { "commit": "<full sha>", "ref": "<branch>", "pipeline_id": "<id>", "job_id": "<id>" },
  "secret_scan": { "status": "ran", "variables_scanned": 2 },
  "files": [
    { "name": "packer-console-<ts>.log", "role": "build-log", "size_bytes": 1234, "sha256": "<hex>" }
  ],
  "withheld": []
}
```

`outcome` is `success`, `failed` or `unknown`. `withheld` lists files that were deleted
because they contained a secret (see below); it is normally empty.

**Check `secret_scan.status` before trusting an artifact.** `ran` means the scan happened.
`skipped-no-secrets-in-env` means the secret variables were not in the environment, so nothing
could be matched and the evidence is unverified — not clean. `failed` means the scan itself
errored. Only `ran` is a pass.

## How it is produced

1. `build-diagnostic.sh` verifies the install inputs on the runner (`stage-packages.sh`): the
   lock and the `package-runner` binary against their committed hashes, then the package
   files. A failure stops the job before Packer starts, and the result is still recorded. The
   CI job does not call `make validate-packer` first: `build-diagnostic.sh` already does both,
   so each step would run twice.
2. It validates the template and keeps the output.
3. Packer builds. The install provisioners upload the lock, its sidecar, the binary and the
   package files, run `package-runner install`, and download `install-result.json`; only then
   does a failed install fail the build. On exit code 3010 the build restarts the guest. The
   post-restart check then runs and `install-result-verify.json` is downloaded.
4. When the script ends, pass or fail, it runs `collect-evidence.sh` to write `index.json` and
   `SHA256SUMS`. The CI job's `after_script` runs it again, so the evidence is indexed even if
   the job was cancelled or timed out. It is safe to run more than once.

To index evidence by hand: `make collect-evidence`. To list it: `make list-evidence`.

## Secret guard

`collect-evidence.sh` scans every evidence file for the values of the secret variables
(`VCENTER_PASSWORD`, `ADMIN_SERVICE_ACCOUNT_PASSWORD`). A file that contains one is deleted,
its name is listed in `withheld`, and the script exits 1. The value is never printed.

It matches both the raw value and its XML-escaped form, because the answer file carries the
escaped form of the admin password (see `admin_service_account_password_xml` in the template)
and a literal match on the raw value would miss it. Other encodings would still not be found.

The scan is **fail-closed**: if the secret variables are absent from the environment there is
nothing to match on, and that is recorded as `skipped-no-secrets-in-env` rather than passing
silently. This matters because a GitLab `after_script`'s exit code does not fail the job and
`artifacts: when: always` uploads regardless — so `secret_scan.status` in `index.json`, not the
exit code, is what tells you whether an artifact was checked.

Withheld filenames are appended to `evidence/.withheld`, which is excluded from the index.
`collect-evidence.sh` runs twice in a build job (once from `build-diagnostic.sh`'s exit trap and
once from the job's `after_script`); without that ledger the second run would find nothing left
to withhold and rewrite `index.json` with an empty list, erasing the record of the leak that the
first run cleaned up.

## Using the evidence

- Check integrity: `cd evidence && sha256sum -c SHA256SUMS`.
- Attach to a story: download the job's artifacts and attach the archive, or the files named
  in `index.json`.
- Add a new kind of evidence: write the file into `evidence/` and add its name pattern to
  `role_of` in `collect-evidence.sh`.

## Acceptance criteria map: Windows communicator (STORY-01)

Where the evidence for each criterion lives. All five criteria have been observed passing. AC1,
AC2, AC3 and AC5 were observed in both the staging harness (against an already-running VM) and a
full CI build (through a fresh reboot); **AC4's failure paths were observed in the harness only**,
since deliberately failing a two-hour build to watch it time out is not worth the runner time.

| AC | Status | Evidence | Where |
|----|--------|----------|-------|
| **AC1** communicator configured | **Met** | `communicator = "winrm"` (NTLM over HTTPS on 5986) replaces `none`. The username comes from `ADMIN_SERVICE_ACCOUNT` with `AD_NETBIOS_DOMAIN`, and the password from `ADMIN_SERVICE_ACCOUNT_PASSWORD`, all read from the environment at runtime (a masked CI variable for the password). | The template's communicator block; `communicator`, `transport` and `authentication` in `communicator-result.json` (full build, 2026-09-22) |
| **AC2** credential handling | **Met** | No literal password in tracked files. The variable files and pipeline YAML hold variable names only. The build's secret guard finds no password in any evidence file (`withheld` is empty and the job did not fail). The password is marked `sensitive`, so Packer masks it. The guest check prints no account name or credential. **Scoped to the repository and its artifacts, not to the guest:** Windows Setup does cache the domain-join password in plaintext in `C:\Windows\Panther\unattend-original.xml` (OBSERVED 2026-09-23, ADR 0002). The build now removes it and fails unless a scan confirms it is gone, so this reads Met for a successful build; a **failed** build retains its VM with the password still on disk. | `git grep`; `withheld` in `index.json`; `cleanup-result.json`; the console log |
| **AC3** guest communication proven | **Met** | The first provisioner runs a non-destructive check in the guest and fails the build unless the session is the expected account with administrative access. | `communicator-result.json` (`authenticated_by_inference`, `remote_command_result`, `identity_matches_expected`, `is_administrator`) from the full build, and `communicator-result-harness.json` from the harness run; the console line `Guest communicator check: identity_matches_expected=True is_administrator=True computer_name=<name>` (harness run and full build, 2026-09-22) |
| **AC4** failure is explicit | **Met** | An invalid credential and an unavailable communicator both fail the build after the bounded `winrm_timeout` (45m by default; the harness uses 2m). Staging cannot start, because provisioners only run once the communicator connects. Shown with the `staging-harness` job: an unreachable address, and `HARNESS_INVALID_CREDENTIAL=true` (a made-up account, so the real shared account can never be locked out). At the console level both end the same way (`Timeout waiting for WinRM.`); the debug log's per-attempt errors (401 vs. i/o timeout) distinguish them if needed. | The job log: `Timeout waiting for WinRM.`, no `Provisioning` lines after it (harness runs, 2026-09-22) |
| **AC5** sanitized evidence | **Met** | See the next table. | `index.json`, `communicator-result.json`, `packer-provenance-<ts>.txt`, console log (full build, 2026-09-22) |

| AC5 record | Source |
|------------|--------|
| Tested Git commit | `run.commit` in `index.json`; `git commit` in the provenance file |
| Temporary VM identity | `vm_name` and `computer_name` in `communicator-result.json` |
| Communicator type | `communicator`, `transport` and `authentication` in `communicator-result.json` |
| Authentication result | `authenticated_by_inference` in `communicator-result.json`. **Inferred, not measured**: the script runs inside the authenticated session, so its own execution is the evidence — if authentication had failed, no result file would exist. The measured checks are the three fields below. |
| Remote command result | `remote_command_result` in `communicator-result.json` |
| Administrative-access result | `is_administrator` and `identity_matches_expected` in `communicator-result.json` |
| Packer result | `outcome` in `index.json`; the console log |

Notes:

- **Invalid credentials and account lockout.** The communicator retries every few seconds for the
  whole timeout. A wrong password for the real shared service account could therefore lock it out
  for every build. `HARNESS_INVALID_CREDENTIAL=true` uses a made-up account and password so it
  cannot. When a credential change is suspected, run with a short `WINRM_TIMEOUT`.
- **What identifies the failed stage.** Packer's own message names the WinRM stage. There is no
  separate structured "failed stage" field in `index.json`.
- **Verified, 2026-09-23:** Windows Setup keeps two copies of the answer file in
  `C:\Windows\Panther\`. It scrubs `unattend.xml` and leaves `unattend-original.xml`
  unscrubbed, so the domain-join password is readable there. `Remove-BuildArtifact.ps1`
  now deletes both and fails the build unless a recursive scan finds no surviving
  `<Password>` element; `cleanup-result.json` records the outcome. Checking only
  `unattend.xml` shows a scrubbed file and hides the problem.

## Known limits

- **A job that fails at "Getting source" must have no evidence.** Until 2026-10-07 the
  runner's reused project directory still held the previous job's `evidence/` at that
  point, and it was uploaded as the failed job's artifacts (OBSERVED twice that day: 6
  files from jobs that ran no script). The pipeline now sets `GIT_STRATEGY: clone`, which
  empties the directory before fetching. Proved the same day by repeating the failure on
  purpose: a `verify-iso-datastore` job on a pipeline whose branch had been deleted failed
  at "Getting source", Git reported `Initialized empty Git repository` where it used to say
  `Reinitialized existing`, and the upload step reported `evidence/: no matching files`. Whatever the cause, an archive is only that job's
  evidence if `run.job_id` and `run.commit` in its `index.json` match the job; a mismatch
  means the files came from somewhere else.
- The install step's evidence is downloaded before the build fails, but only for the exit
  codes the contract defines (0, 10, 11, 12, 3010). Any other ending — a crash, a missing
  binary, no result file written — fails the build at once, and whatever exists stays in
  `C:\Packer\evidence` on the retained VM. The installer's own output is kept there too
  (`<name>-<version>-stdout.log`, `-stderr.log`) and is never downloaded.
- `communicator-result.json` behaves the same way: the guest writes it on failure as well as on
  success, but the download provisioner only runs once the check has passed, so a failed run
  leaves it on the retained VM too.
- The debug log is not scrubbed beyond the secret guard, so do not share it outside the team.
- Nothing records an identity for the finished image yet. [ADR 0005](decisions/0005-publish-form-and-image-identity.md)
  decides it: the master VM's instance UUID and its versioned snapshot (revised 2026-10-01;
  first written as a template's instance UUID), not a hash of the image, and the SHA-256 of this
  `index.json` as the reference's provenance checksum, in a field named
  `evidence_index_sha256`. It is the hash of the **final** `index.json`, after the last
  collection (`collect-evidence.sh` rewrites it on every run), and the reference record itself is
  written after that collection and kept out of the index, which would otherwise be circular. `index.json` describes the build run,
  which is exactly why its hash ties the reference to the run. Not built: sealing was decided
  on 2026-10-01 (ADR 0002), and the record is written once the seal step and the snapshot
  exist (STORY-03, STORY-11).
