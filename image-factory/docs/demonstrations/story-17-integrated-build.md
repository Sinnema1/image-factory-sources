# STORY-17: integrated build validation in Example Labs

**Result:** one pipeline job built a Windows 11 master from the datastore ISO, retrieved a
real software package from the package share, installed it, validated it, and published the
sealed image. Job 4441, 2026-10-12, on `main` at `0efc166`. It took about 33 minutes.

This page is the summary for the story. The evidence itself is the job's artifact archive,
attached with it. Everything below was read from the job log, and checked against two of
the artifacts, `image-reference.json` and `install-result.json` (OBSERVED 2026-10-12). The
other artifact files are named as the log names them.

## What was built

| | |
|---|---|
| Job | 4441, `packer-build-publish`, pipeline 1138, runner `runner-01` |
| Source | `image-factory` `main`, commit `0efc166b098d897a81a2de7d977d0b850acdbfd8` |
| Image version | `2026.10.12-4441` |
| Master VM | `image-master-2026.10.12-4441`, instance UUID `50215780-8dc4-66d9-cf2e-9ab1419a7467` |
| Snapshot | `sealed-2026.10.12-4441` (`snapshot-38593`) |
| Evidence index SHA-256 | `8d3c302288325c4965b5e2ab0958c19776dab5f62640787ec6b2e3c4b7d3cef1` (16 files) |

## The package

| | |
|---|---|
| Package | PuTTY 0.83.0, a machine-wide MSI |
| File | `putty/0.83.0/putty-0.83-installer.msi` on the package share, 3,508,736 bytes |
| SHA-256 | `d816fba5750e95ae5f845ad22bd165e19ebefbbf298f453abc1db2ef7655e4b8` |
| Lock | [`packer/software/windows-11-lab.lock.yaml`](../../packer/software/windows-11-lab.lock.yaml), SHA-256 `9a1d6671…e8fb`, committed beside it. The engine reported the same value for the lock it read in the VM |
| Staging tool | `download-packages`, from the `runner-image` `0.2.1` image |
| Install engine | `package-runner` `0.0.0-trial.2`, SHA-256 `b03b918af51bff3854df76a4817c924404664c70ef40fa79ec3bdb44d7a58051` |

## The workflow, step by step (AC3)

| Step | What happened in job 4441 | Evidence file |
|---|---|---|
| Datastore ISO | Both ISOs were read back from the datastore and matched their qualification records, before the build: Windows 11 25H2 (8,514,439,168 bytes, 174 s) and VMware Tools 13.1.0 | `iso-datastore-verify-example-labs-20261012-164545Z.json`, `iso-datastore-verify-vmware-tools-20261012-164839Z.json` |
| Build VM | Packer created the VM from that ISO, installed Windows unattended, and connected over WinRM as the expected administrative account. `Build 'vsphere-iso.windows-11' finished after 30 minutes 1 second.` | `packer-console-20261012-164842Z.log`, `communicator-result.json` |
| Package retrieval | `download-packages` read the lock and copied the MSI from the share mounted at `/mnt/image-factory/package-content` | `package-download-20261012-164842Z.log` |
| Package staging | The copy's size and SHA-256 matched the lock on the runner: `Package staging passed: lock windows-11-lab.lock.yaml, package-runner package-runner.exe, 1 file(s) staged`. The lock, the engine and the package were then uploaded to `C:\Packer\staging` | `package-stage-20261012-164842Z.json` |
| Software installation | `Starting MSI installation artifact=C:\Packer\staging\packages\putty\0.83.0\putty-0.83-installer.msi`, then `package-runner install exit code: 0` and `Software install accepted: package-runner exit code 0.` Before installing, the engine hashed the MSI again inside the VM and recorded the lock's value, `d816fba5…e4b8`. The result file records outcome `success`, no restart required | `install-result.json` |
| Validation | `Validation PASSED: file C:\Program Files (x86)\PuTTY\putty.exe`: product "PuTTY suite", file version 0.83.0.0, 1,151,080 bytes. Checked again in a separate run after the restart step: `package-runner verify exit code: 0`, `Installed-state check passed.` | `install-result.json`, `install-result-verify.json` |

The same job then went past what the story asks for: it removed the build credentials
(`cleanup-result.json`), sealed the image and verified the seal (`seal-result-4441.json`),
took the snapshot, and wrote the image reference (`image-reference.json`), which it looked
up twice in vCenter to confirm it resolves.

## Acceptance criteria

| AC | Met by |
|---|---|
| AC1, full build executed | Job 4441. Also job 4408 the same day, a routine build with the same package |
| AC2, at least one package passes validation | PuTTY 0.83.0: one `file` validation, passed twice in each job |
| AC3, end-to-end workflow proven | The table above: all six steps in one job and one evidence index |
| AC4, demonstration package | This page, the job log, and the job's artifact archive (23 files: logs, result files, the index and `SHA256SUMS`, the image reference) |

## What this does not show

- **A released install engine.** The engine is a trial build of changes proposed to its
  owner, reviewed and not yet merged. There is no release of `package-runner` to use.
- **The default build.** The real package and engine were selected for this pipeline by
  three variables (`PACKAGE_LOCK`, `PACKAGE_SOURCE_ROOT`, `PACKAGE_RUNNER`). Without them a
  build installs a test package with a stand-in.
- **A generated lock.** The lock was written by hand from the owner's entry for PuTTY. The
  intended design generates it in the pipeline.
- **More than one package**, an install order, an installer that needs a restart, or a
  per-user installer.
- **A desktop.** No Citrix catalog has been created from this master. The image is a proof,
  not an image for use.

## Where the evidence is

GitLab keeps job artifacts for 30 days. The archive attached to the story is the lasting
copy. `index.json` lists every file with its SHA-256, and `image-reference.json` records
the SHA-256 of that index, so the set can be checked for completeness later.
