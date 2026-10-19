# Software fixtures

A small fixture used to prove the software install flow end to end
(`docs/decisions/0003-package-install-contract.md`, STORY-04). It is **not a real package**:
it is one script, `install.ps1`, that writes a marker file to `C:\Program Files\testpkg\`, so
that a completed machine-wide install leaves something a validation can check. No installer
binaries belong in this repository.

```text
windows-vm-fixture.lock.yaml          the fixture as a package-runner lock, in the shape the
                                      owner's tools read today (ADR 0003, "Interim lock shape")
windows-vm-fixture.lock.yaml.sha256   its expected SHA-256: the trust anchor, and the sidecar
packages/                             the source root download-packages reads from
  testpkg/1.0.0/
    install.ps1                       the package: its one file, run by the powershell handler
```

Builds install this fixture with the `package-runner` 1.0.0 release in
[`../../package-runner/`](../../package-runner/README.md), the default since 2026-10-19. The
stand-in in [`../package-runner/`](../package-runner/) is kept only for the staging harness's
forced-exit tests. The trial build that preceded the release was removed the same day.

`.gitattributes` marks `packer/fixtures/` `-text` so the bytes, and therefore the hashes, are
identical on Windows checkouts and on the Linux runner. Do not let an editor convert line
endings.

## The lock

`scripts/runner/stage-packages.sh` checks the lock against the committed `.sha256` before the
build starts, then hands it to `download-packages`, which stages and verifies the package
file. The template uploads the lock and its sidecar. This repository never parses the lock;
the tools that own the format do.

- **In the owner's current shape, not the agreed one.** Since 2026-10-07 each package is one
  file: `artifact.filename`, `artifact.sha256` and `artifact.sizeBytes`, under
  `artifact.repository` and `artifact.path`. That is what `download-packages` and
  `package-runner` read today. The shape agreed in ADR 0003 (C1: `files[]`, `entryPoint`,
  `installScope`) is still the target; this lock moves to it when the owner's tools do.
- **Written in JSON syntax, deliberately.** JSON is valid YAML, so `download-packages` (`yq`)
  and `package-runner` read it as the YAML it is named for, and the stand-in can read it with
  Windows PowerShell 5.1, which has no YAML parser. The cost is that the file cannot carry
  comments, so they are here.
- **Hand-written.** Nothing resolved it from a recipe. It carries no `lockHash`: the integrity
  anchor is the committed `.sha256` beside it (ADR 0003, C1), which does not depend on the
  lock's shape.
- `repository` is `packages`, the value the owner's lock uses. `download-packages` ignores it
  (D4); `package-runner` uses it as a folder name.
- `path` is `./testpkg/1.0.0`, relative to the source root, so the file is found at
  `<source root>/testpkg/1.0.0/install.ps1` and staged to
  `<artifact root>/testpkg/1.0.0/install.ps1`.

## Changing the fixture

Every hash is established before runtime, so a change means regenerating them in order:

```bash
cd packer/fixtures/software/packages/testpkg/1.0.0
sha256sum < install.ps1
wc -c < install.ps1
```

1. Put the new `sha256` and `sizeBytes` into the package's `artifact` in
   `windows-vm-fixture.lock.yaml`.
2. Regenerate the lock's committed hash:
   ```bash
   cd packer/fixtures/software
   sha256sum windows-vm-fixture.lock.yaml | sed -E 's/^([0-9a-f]{64}) \*/\1  /' > windows-vm-fixture.lock.yaml.sha256
   ```
3. Run `bash scripts/runner/stage-packages.sh`. It needs `download-packages` and `yq`, which
   are in the runner image; on a workstation it exits 2 without them.

The second step applies to `../package-runner/package-runner.ps1` and its `.sha256` after any
edit to the stand-in.

## Replacing it with catalog packages

Three things change, and the template does not. All three were tried together on 2026-10-12
with the lock in [`../../software/`](../../software/README.md): PuTTY 0.83.0 from the share,
installed by the trial executable (jobs 4408 and 4441; ADR 0003, "First real package
installed"). The first two are set per pipeline; the default lock is still this fixture. The
third is done.

1. `PACKAGE_LOCK` names the vendored, resolved lock, with its expected SHA-256 committed beside
   it.
2. `PACKAGE_SOURCE_ROOT` names the package share as mounted in the job
   (`/mnt/image-factory/package-content`). Nothing else: `stage-packages.sh` already calls
   `download-packages`.
3. **Done 2026-10-19.** The default runner is the tagged `package-runner` 1.0.0 release, with
   its SHA-256 committed beside it (D18 closed). The release contains the two proposal
   branches tried in jobs 4245, 4408 and 4441. The stand-in was kept, not deleted, for the
   harness's forced-exit tests.
