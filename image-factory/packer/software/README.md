# Software lock

The lock for a build that installs real software, as opposed to the test fixture in
[`../fixtures/software/`](../fixtures/software/). Added 2026-10-12 for STORY-17. No installer
binaries belong in this repository: the lock names a file on the package share.

```text
windows-11-lab.lock.yaml          one package: PuTTY 0.83.0, a machine-wide MSI
windows-11-lab.lock.yaml.sha256   its expected SHA-256: the trust anchor, and the sidecar
```

Nothing uses it by default. First installed in a full build on 2026-10-12 (job 4408). A build installs it when the pipeline is started with these two
variables:

| Variable | Value |
|---|---|
| `PACKAGE_LOCK` | `packer/software/windows-11-lab.lock.yaml` |
| `PACKAGE_SOURCE_ROOT` | `/mnt/image-factory/package-content` |

The install engine is the `package-runner` 1.0.0 release, the default since 2026-10-19
([`../package-runner/`](../package-runner/README.md)). Before that a third variable,
`PACKAGE_RUNNER`, selected a trial build of it; jobs 4408 and 4441 below used that trial build.

## The lock

- **Hand-written**, in the owner's current shape and in JSON syntax, for the reasons given in
  the [fixture README](../fixtures/software/README.md#the-lock). Generating it with
  `package-runner resolve` in this repository's pipeline is the owner's direction and is
  DEFERRED (ADR 0003, "The owner's review").
- **Copied from the owner's resolved entry** for PuTTY (`package-runner`,
  `out/windows-vm.lock.yaml`, read 2026-10-12), with two changes:
  - `filename` has no leading slash. The owner's has one; both tools tolerate it, and this
    lock does not rely on that.
  - The arguments are `/qn /norestart` only. The owner's also write an MSI log to
    `./evidence/putty/install.log`, a path relative to wherever the runner was started, and
    the template does not bring that file back. The installer's exit code and the validation
    are recorded in `install-result.json`.
- `sha256` and `sizeBytes` are the owner's values for the file on the share.
  `download-packages` checks the staged copy against them on the runner, and the trial
  `package-runner` checks it again in the guest.
- The validation is that `C:\Program Files (x86)\PuTTY\putty.exe` exists, the path in
  the owner's lock. OBSERVED 2026-10-12 (job 4408): the MSI installs there, and the trial
  runner recorded the file as PuTTY suite 0.83.0.0, before and after the restart check.

## Changing it

After any edit, regenerate the committed hash, then run a build:

```bash
cd packer/software
sha256sum windows-11-lab.lock.yaml | sed -E 's/^([0-9a-f]{64}) \*/\1  /' > windows-11-lab.lock.yaml.sha256
```

`.gitattributes` marks this folder `-text`, so the bytes and the hash are the same on a
Windows checkout and on the runner. Do not let an editor convert line endings.
