# ADR 0001: Use WinRM over HTTPS for the Packer communicator

- **Status:** Accepted
- **Date:** 2026-09-21
- **Scope:** `packer/templates/windows-11-vsphere.pkr.hcl`, `packer/unattended/enable-winrm.ps1`

Evidence labels follow the repository engineering rules: `OBSERVED` (seen in a
log or run output), `INFERRED` (reasoned from observations or source), and
`PROPOSED` / `DEFERRED` for follow-up work.

## Context

Packer builds installed Windows, joined the domain, ran the bootstrap script,
and reported a guest IP address. They then failed with `Timeout waiting for
WinRM` after the 45-minute `winrm_timeout`. The guest Security log showed
repeated successful network logons for the build service account, yet Packer
never obtained a shell.

The communicator was configured for HTTP on TCP 5985 with NTLM
(`winrm_use_ssl = false`, `winrm_use_ntlm = true`). Nothing in the repository
sets `AllowUnencrypted`, so the Windows default (`false`) applied.

### Evidence before the change

- OBSERVED: the failed run's debug log had 485 WinRM connection errors. Nine
  were `i/o timeout` while the guest was still rebooting from specialize. The
  other 476 were `http response error: 401 - invalid content type`, repeated
  without variation for 40 minutes until the timeout.
- OBSERVED: the domain join, the secure channel, the admin group mapping and the
  service account's membership in that group were each verified on the guest.
- INFERRED (from upstream source, not checked against the pinned versions):
  Packer's NTLM client completes the NTLM handshake but does not sign, seal or
  encrypt WinRM messages, and the WinRM client library turns any response that
  is not a SOAP content type into `invalid content type`.
- INFERRED: the leading explanation is that the service rejected each
  unencrypted request with a 401 that had no SOAP body, because
  `AllowUnencrypted` is `false`, and Packer treated that as "not ready" and
  retried until the timeout. The exact HTTP failure mechanism was not proven.

## Decision

Use WinRM over HTTPS on TCP 5986 with NTLM authentication. TLS protects the
messages, so the WinRM service keeps its defaults (`AllowUnencrypted = false`,
Basic authentication off).

- The guest bootstrap creates a per-build self-signed certificate
  (RSA 2048, SHA-256, non-exportable key, 30-day validity) and an HTTPS
  listener bound to it. It verifies the listener's port, state and certificate
  binding, and completes a TLS handshake that must present that certificate.
- A firewall rule scoped to the Packer runner's source address allows TCP 5986.
  The earlier rule for 5985 is removed.
- The template sets `winrm_port = 5986`, `winrm_use_ssl = true` and
  `winrm_insecure = true`. Packer connects by IP address to a self-signed
  certificate, so it cannot verify the server certificate.
- `winrm_timeout` is a variable (default `45m`) so diagnostic runs can shorten
  it.

## Confirmation

The first build with this configuration succeeded on the first attempt.

- OBSERVED: Packer connected over 5986 with NTLM, ran its shutdown command
  (exit code 0), and the build finished in 19 minutes 27 seconds. The retained
  VM powered off as expected.
- OBSERVED: the first build's debug log contains no `401`, `invalid content
  type`, TLS or certificate errors. There were 10 connection attempts and 9
  errors before the first success: 8 `i/o timeout` and 1 `connection refused`,
  consistent with the guest rebooting from specialize into OOBE.
- OBSERVED: WinRM connected about 5 minutes 14 seconds after Packer began
  waiting. The guest IP address had taken about 13 minutes after the boot
  command, as in the failed run.
- INFERRED: the account, group mapping and domain join were unchanged from the
  failed runs, and the communicator's transport is the only change to the
  communicator path. That makes a WinRM service access restriction,
  channel-binding enforcement and account authorization less likely causes, and
  it is consistent with the encryption explanation. It does not prove the
  mechanism.

What this does not show: no controlled HTTP-on-5985 run was made in the same
build, so the explanation is supported by exclusion and not by a direct A/B
test. The HTTP failure mechanism remains unproven.
It would be falsified if a later HTTPS build kept returning 401 responses on
5986 for the whole wait, as the HTTP builds did. In that case the WinRM
service's access list and channel-binding hardening level would be the first
things to check. An isolated 401 early in the wait is not that; see the
addendum.

## Alternatives considered

| Alternative | Outcome |
|---|---|
| Set `AllowUnencrypted = true` on the guest | Rejected. It sends provisioner traffic, including secrets, in plaintext and loosens the service's security posture to accommodate the client. |
| Enable Basic authentication | Rejected for the same reason. |
| Override Group Policy-controlled WinRM settings | Rejected. The failure was not a policy conflict, and the build must not weaken policy. |
| Disable the domain service account, or bypass the credential gate | Rejected. The account is shared across builds, and the gate fails safe. |
| Keep HTTP and change the client (for example a different WinRM client) | Not pursued. It adds a dependency on the governed runner, and HTTPS matches the existing reference design. |

## Consequences

- The build creates artifacts that must not ship in a sealed image. The pre-seal
  cleanup stage must remove: the certificate (friendly name `Packer WinRM build
  certificate` in `Cert:\LocalMachine\My`), the HTTPS listener
  (`Address=*`, `Transport=HTTPS`), and the firewall rule `Packer WinRM HTTPS
  5986`. `enable-winrm.ps1` documents this contract in its header. That header,
  this list and ADR 0002's are the same contract; change all three together.

  These three remain outstanding. They are deliberately excluded from the guest
  cleanup step the build now runs
  (`packer/provisioners/Remove-BuildArtifact.ps1`), because removing the listener
  would cut the channel Packer still needs for the shutdown command — ADR 0002
  records that listener removal has to happen inside the sealing step itself.
  The cleanup step covers only the cached answer files, the staging directory and
  the uploaded scripts.
- `Enable-PSRemoting` also leaves the default HTTP listener on 5985 and the
  built-in Windows Remote Management firewall rules. The cleanup stage should
  decide whether to remove those too.
  **Decided 2026-10-08 (the image-build owner):** yes. A sealed image has remote management at
  the Windows default: both listeners removed, the built-in rules disabled, the
  remoting endpoints disabled, and the WinRM service manual and stopped. Group
  Policy can turn it on where it is wanted. Implemented in
  `packer/provisioners/Invoke-ImageSeal.ps1` (ADR 0002, requirement 2).
- The connection uses `winrm_insecure = true` because the certificate is
  self-signed. This is acceptable for an isolated lab build and is not
  acceptable for production use.
- `enable-winrm.ps1` writes the effective WinRM listener, service and
  authentication configuration to the bootstrap transcript
  (`C:\Windows\Temp\enable-winrm-bootstrap.log`) as read-only evidence. It never
  changes those settings.

## Related changes made with this decision

- The XML-escaped service account password is a `sensitive` local, so Packer
  masks its escaped form in logs.
- The unattend template and floppy file paths use `abspath()`. A relative
  `path.root` (as when CI passes a relative template path) otherwise caused the
  unattend template to be looked up under the wrong directory.
- `scripts/runner/build-diagnostic.sh` runs with `-on-error=abort` so a failed
  build leaves the VM for inspection. It validates the template first, accepts
  an optional `WINRM_TIMEOUT`, and records a provenance file in `evidence/`.
- The `destroy = false` comment is corrected: it retains the VM only after a
  successful build.

## Follow-up (PROPOSED / DEFERRED)

- OBSERVED: after `Enable-PSRemoting` ran, the bootstrap output printed
  "Configured LocalAccountTokenFilterPolicy to grant administrative rights
  remotely to local users" (seen on the guest console during specialize).
- PROPOSED: add these to the pre-seal cleanup list: reverting the
  `LocalAccountTokenFilterPolicy` value, and removing the default 5985 listener
  and built-in firewall rules. ~~Not yet verified: that the registry value
  persists after that message.~~ OBSERVED 2026-09-28 on `packer-build-002`
  (job 3497, a successful build): `LocalAccountTokenFilterPolicy` is
  `REG_DWORD 0x1` under
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`. It persists,
  so it is on ADR 0002's pre-seal list.
- PROPOSED: for diagnostic builds, use `WINRM_TIMEOUT=15m`. The successful run
  connected about 5 minutes after Packer began waiting.
- OBSERVED, 2026-09-22: the `-on-error=abort` path has since been exercised. The
  build recorded in the addendum below failed at its first provisioner and the VM
  was retained, as intended. This supersedes the earlier note that it was untested.

## Addendum, 2026-09-22: environment_vars unreliable as the first post-connect command

Adding a guest identity check (STORY-01) as the build's first provisioner surfaced an operational
issue with the communicator's PowerShell provisioning, not with the communicator itself.

- OBSERVED: a `powershell` provisioner using `script = ...` with `environment_vars` ran as the very
  first command after WinRM connected on a freshly rebooted VM. The script executed (its own
  output appeared), but the variable it read (`EXPECTED_IDENTITY`) was empty inside it, and the
  build failed with `Required environment variable EXPECTED_IDENTITY is not set.`
- INFERRED, not proven: this is specific to being the first command after a fresh reboot.
  `Test-StagedPackage.ps1` uses the identical `environment_vars` mechanism later in the same build
  and has worked correctly every time, including in this failed run's predecessor and in three
  harness runs. The exact mechanism inside Packer's WinRM provisioner was not investigated further.
- FIX: deliver the same inputs by uploading the script with a `file` provisioner, then setting them
  as direct `$env:` assignments in an `inline` block before invoking the script with `&`, the same
  pattern the working staging-directory step already used. This avoids `environment_vars` entirely
  for this step, rather than continuing to depend on unproven behavior.
- OBSERVED during the fix: `exit 1` inside a script invoked with `& 'path'` from an `inline` block
  does not by itself terminate the wrapping script. A local test confirmed that without an explicit
  `exit $LASTEXITCODE` after the call, a failing child script still returned exit code 0, which
  would have made a failed identity check pass silently. Adding `exit $LASTEXITCODE` fixed it,
  verified locally (`exit 0` → `0`, `exit 1` → `1`) and then against the real script.
- OBSERVED (harness run, then a full build, 2026-09-22): with the fix, the identity check passed
  both against an already-running VM (about 15 seconds) and in a fresh full build after the normal
  reboot (about 22 seconds), reporting `identity_matches_expected=True is_administrator=True`. The
  full build finished in 21 minutes 17 seconds, about a minute over the previous full build without
  the check.
- Applies to any future provisioner added as the *first* command after connect: prefer the
  `file` upload plus `inline` assignment pattern over `environment_vars` there, unless the
  mechanism is understood well enough to trust it in that position.
- DEFERRED: replace the self-signed certificate and `winrm_insecure` with a
  certificate from an internal certificate authority so Packer can verify the
  server.
- DEFERRED: rebuilds reuse a fixed VM name and a fixed computer name. A retained
  VM must be removed before the next build, and the domain computer object the
  join created is left behind. Whether a rebuild reuses or collides with that
  object has not been checked. This belongs with the planned build OU and
  cleanup design.

## Addendum, 2026-09-21: second build

A second build ran from CI after the variable file, the vCenter host and
username, and the runner source address moved to CI variables. It used the same
template, bootstrap script and transport.

- OBSERVED: the build connected over 5986 with NTLM, ran the shutdown command,
  and finished in 19 minutes 7 seconds. WinRM connected about 5 minutes 33
  seconds after Packer began waiting (first build: about 5 minutes 14 seconds).
  Two of two HTTPS builds have succeeded.
- OBSERVED: 11 connection attempts and 10 errors before the first success: 1
  `401 - invalid content type`, 8 `i/o timeout` and 1 `connection refused`. The
  401 was the response to the first attempt, seconds after Packer began
  waiting. It came over TLS, so the listener was reachable. The timeouts and
  the refusal followed, and later attempts succeeded with the same account and
  transport.
- INFERRED, not verified: the early 401 reflects the guest not yet being able to
  validate the domain account before its post-join reboot, which is when the
  domain join takes effect. A failed-logon event (4625) in the guest Security log
  around that time would confirm it.
- INFERRED: the build's connection succeeded with the same account after the
  reboot, so the 401 was not the persistent rejection seen on HTTP. That failure
  was a 401 on every attempt for 40 minutes. The explanation in this ADR is
  unchanged, and the mechanism is still unproven.
- OBSERVED: the build joined the domain with the same computer name as the
  first build. The log does not record whether the earlier computer object had
  been removed beforehand, so whether a rebuild reuses or collides with an
  existing object is still unchecked.
