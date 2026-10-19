# package-runner release

The guest-side install engine the build uploads and runs (ADR 0003). Owned by the package
tooling owner in the `package-runner` repository. This folder pins the release the build
uses; **the binary itself is not in this repository.**

```text
package-runner.exe.source   where the release is published, as the CI job sees it
package-runner.exe.sha256   its expected SHA-256: the trust anchor
```

`scripts/runner/stage-packages.sh` copies the file named in `package-runner.exe.source` into
`build/package-runner/` (git-ignored), checks it against `package-runner.exe.sha256`, and stops
the build if it does not match. The repository holds the identity and the store holds the bytes,
as for packages (the lock) and ISOs (the qualification records).

**Why not commit the binary.** Site B's GitLab refuses `.exe` files, and a push rule checks every
commit pushed, not only the latest. A binary committed here would block moving the repository to
Site B (STORY-30). The earlier trial build was committed between 2026-10-07 and 2026-10-19 and is
still in this repository's history, so the move has to be a fresh import of the current files,
not a push of the history.

| | |
|---|---|
| Release | `1.0.0`, tag `1.0.0` on `package-runner` `main` at `7d49d76`, built 2026-10-17 by the owner's GoReleaser pipeline |
| Published at | `/mnt/image-factory/artifacts/package-runner/1.0.0/package-runner_windows_amd64_v1/package-runner.exe`, on the share mounted in CI jobs |
| SHA-256 | `92daa2c332ac5d44c01eaec5772898dbb8b9c9f83e08a55bb109f981aabb3647`, the same value as the release's own `package-runner_1.0.0_checksums.txt` |
| Contents | The contract changes from the `proposal/build-contract` proposal, the owner's release pipeline and registry validator, and builds for other platforms |

**It reports its version as `dev`.** The release does not stamp its version (D39), so
`package-runner version` and the `runner_version` field of `install-result.json` say `dev`,
not `1.0.0`. The SHA-256 is what identifies the binary: every build records it, with the path it
was copied from, in `package-stage-*.json`.

**The store can be overwritten.** The owner's publish script replaces a version that already
exists. If that happens the copy no longer matches the committed hash and the build stops; it
cannot run a different binary unnoticed.

## Outside CI

A workstation has no share mounted. Point `PACKAGE_RUNNER_SOURCE` at a local copy of the release;
it is checked against the same committed hash.

## Changing the release

1. Find the Windows binary of the new release in the store, and check its SHA-256 against the
   release's checksums file.
2. Put its path in `package-runner.exe.source` and its hash in `package-runner.exe.sha256`, in
   `sha256sum` format naming `package-runner.exe`.
3. Update the table above, and run one full build.

`.gitattributes` marks this folder `-text`, so the hash file's bytes are the same on every
checkout.

The stand-in in [`../fixtures/package-runner/`](../fixtures/package-runner/) is kept only for the
staging harness's forced-exit tests, because the release cannot be made to fail on demand. It is
a script, not an executable, so it stays in the repository.
