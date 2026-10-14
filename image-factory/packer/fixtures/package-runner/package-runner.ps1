<#
    TEST DOUBLE for package-runner. Not an install engine, and not a fork of one.

    WHY THIS EXISTS. ADR 0003 gives the guest install step to package-runner, and
    STORY-04 builds this repository's side of that seam: transfer, invocation,
    exit-code handling, evidence download, restart and the post-restart check.
    On 2026-10-01 package-runner (branch init, 8e538aa) implements none of the
    agreed contract terms and has no release, so there is nothing to invoke.
    This script speaks the agreed command line (C3) and writes the agreed
    evidence (C4) for the fixture lock, so the build side can be exercised now.

    LOCK SHAPE. Since 2026-10-07 it reads the shape the owner's tools read today
    (ADR 0003, "Interim lock shape"): one file per package, named by
    artifact.filename with artifact.sha256 and artifact.sizeBytes, staged by
    download-packages at <artifact-root>\<name>\<version>\<filename>. That one
    file is what the powershell handler runs. The agreed C1 shape (files[],
    entryPoint, installScope) stays the target and is not read here. Stricter
    than the owner's tools in one way, on purpose: a package with no sha256 is
    an integrity failure, not a skipped check.

    RETIRE IT when a tagged package-runner release meets C1-C4: point the
    PACKAGE_RUNNER variable of scripts/runner/stage-packages.sh at the release
    binary, commit its SHA-256 beside it, and delete this folder. Do not extend
    it to real packages: it runs the "powershell" handler and the "file"
    validator and nothing else, and anything else in a lock is a failure.
    install.arguments and install.workingDirectory are not read.

    Commands:
      install --lock <file> --artifact-root <dir> --evidence-dir <dir> --execution-id <id>
          writes <evidence-dir>\install-result.json
      verify  (same flags)
          The post-restart check: read-only, runs each package's validation and
          writes <evidence-dir>\install-result-verify.json. The command name is
          this repository's assumption; ADR 0003 carried it into implementation.

    Exit codes (C3): 0 installed correctly; 10 a package failed; 11 integrity or
    lock failure; 12 not elevated; 3010 installed, and a restart is needed.
    Exit 1 means the result file could not be written, or the arguments are wrong.

    The lock must be written in JSON syntax. JSON is valid YAML, so the real
    tools read the same file, and Windows PowerShell 5.1 has no YAML parser.

    Test knob, used only by packer/tests/staging-provisioners.pkr.hcl:
      PACKAGE_RUNNER_STANDIN_FORCE_EXIT_CODE = 10 | 11 | 12 | 3010
    makes `install` end with that code, so the build's handling of each code can
    be proved without contriving the real condition. 3010 installs normally and
    then reports that a restart is required.

    Windows PowerShell 5.1 compatible.
#>

$ErrorActionPreference = 'Stop'

$runnerVersion = 'standin-2'
$supportedApiVersion = 'image.example/v1alpha1'

$command = $null
$options = @{}
$i = 0
while ($i -lt $args.Count) {
    $token = [string]$args[$i]
    if ($token -in @('--lock', '--artifact-root', '--evidence-dir', '--execution-id')) {
        if ($i + 1 -ge $args.Count) {
            Write-Host ('package-runner stand-in: {0} needs a value.' -f $token)
            exit 1
        }
        $options[$token] = [string]$args[$i + 1]
        $i += 2
    }
    elseif ($null -eq $command) {
        $command = $token
        $i += 1
    }
    else {
        Write-Host ('package-runner stand-in: unexpected argument: {0}' -f $token)
        exit 1
    }
}

if ($command -eq 'version') {
    Write-Host $runnerVersion
    exit 0
}

if ($command -notin @('install', 'verify')) {
    Write-Host 'package-runner stand-in: the command must be install, verify or version.'
    exit 1
}

foreach ($name in @('--lock', '--artifact-root', '--evidence-dir', '--execution-id')) {
    if ([string]::IsNullOrWhiteSpace($options[$name])) {
        Write-Host ('package-runner stand-in: {0} is required.' -f $name)
        exit 1
    }
}

$lockPath = $options['--lock']
$artifactRoot = $options['--artifact-root']
$evidenceDir = $options['--evidence-dir']
$executionId = $options['--execution-id']

$resultName = if ($command -eq 'install') { 'install-result.json' } else { 'install-result-verify.json' }
$forcedExitCode = if ($command -eq 'install') { $env:PACKAGE_RUNNER_STANDIN_FORCE_EXIT_CODE } else { $null }

$startedAt = (Get-Date).ToUniversalTime()
$lockSha256 = $null
$packageResults = @()

function Get-Sha256 {
    param([string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Writes the result and exits. Every path out of the script goes through here, so
# a result file exists whether the run passed or failed (C4).
function Complete-Run {
    param(
        [int] $ExitCode,
        [string] $Outcome,
        [string] $ErrorMessage
    )

    $result = [ordered]@{
        schema_version       = 1
        command              = $command
        execution_id         = $executionId
        runner_version       = $runnerVersion
        lock_sha256          = $lockSha256
        started_at           = $startedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        finished_at          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        outcome              = $Outcome
        publication_eligible = ($ExitCode -eq 0)
        exit_code            = $ExitCode
        error                = $ErrorMessage
        packages             = @($packageResults)
    }

    try {
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        # UTF-8 without a byte order mark, so the runner's jq can read it.
        [System.IO.File]::WriteAllText(
            (Join-Path -Path $evidenceDir -ChildPath $resultName),
            ($result | ConvertTo-Json -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    catch {
        Write-Host ('package-runner stand-in: could not write {0}: {1}' -f $resultName, $_.Exception.Message)
        exit 1
    }

    if ($ErrorMessage) {
        Write-Host ('package-runner stand-in: {0}' -f $ErrorMessage)
    }
    Write-Host ('package-runner stand-in: {0} finished, outcome={1}, exit code {2}.' -f $command, $Outcome, $ExitCode)
    exit $ExitCode
}

function Test-Validation {
    param($Package)

    $checks = @()
    $passed = $true

    foreach ($spec in @($Package.validation)) {
        if ($null -eq $spec) { continue }
        $checkPassed = $false
        $detail = $null

        if ($spec.handler -eq 'file') {
            $checkPassed = [bool](Test-Path -LiteralPath $spec.parameters.path -PathType Leaf)
            $detail = $spec.parameters.path
        }
        else {
            # A validator that is not implemented is a failure, never a skip.
            $detail = 'validator not implemented by the stand-in'
        }

        if (-not $checkPassed) { $passed = $false }
        $checks += [ordered]@{ handler = $spec.handler; passed = $checkPassed; detail = $detail }
    }

    # A package that declares no validation cannot be shown to be installed.
    if ($checks.Count -eq 0) { $passed = $false }

    [ordered]@{ passed = $passed; checks = $checks }
}

# --- Elevation (exit 12), checked at startup. ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($forcedExitCode -eq '12' -or ($command -eq 'install' -and -not $elevated)) {
    Complete-Run -ExitCode 12 -Outcome 'failed' -ErrorMessage 'The session is not elevated.'
}

# --- The lock and every staged file (exit 11), before any handler runs. ---
$lock = $null
$stagedPackages = @()

try {
    if ($forcedExitCode -eq '11') { throw 'Forced by PACKAGE_RUNNER_STANDIN_FORCE_EXIT_CODE.' }

    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw ('The lock was not found: {0}' -f $lockPath) }
    $sidecarPath = $lockPath + '.sha256'
    if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) { throw ('The lock sidecar was not found: {0}' -f $sidecarPath) }

    $lockSha256 = Get-Sha256 -Path $lockPath
    $sidecarLine = [string](Get-Content -LiteralPath $sidecarPath -TotalCount 1)
    if ($sidecarLine -notmatch '^([0-9a-fA-F]{64})\s') { throw 'The lock sidecar is not in sha256sum format.' }
    if ($Matches[1].ToLowerInvariant() -ne $lockSha256) { throw 'The lock does not match its sidecar SHA-256.' }

    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ($lock.apiVersion -ne $supportedApiVersion) { throw ('Unsupported apiVersion: {0}' -f $lock.apiVersion) }
    if ($lock.kind -ne 'ImageRecipeLock') { throw ('Unsupported kind: {0}' -f $lock.kind) }

    foreach ($package in @($lock.packages | Sort-Object -Property installOrder)) {
        $packageDir = Join-Path -Path (Join-Path -Path $artifactRoot -ChildPath $package.name) -ChildPath $package.version
        $files = @()

        # One file per package (see LOCK SHAPE in the header). The owner's sample
        # lock writes a leading '/' on one filename and both of her tools
        # tolerate it, so it is dropped here too; anything else that is not a
        # plain file name is refused.
        $fileName = ([string]$package.artifact.filename) -replace '^[/\\]+', ''
        if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -match '[/\\:]' -or $fileName -eq '..') {
            throw ('{0} {1}: artifact.filename is not a plain file name: {2}' -f $package.name, $package.version, $package.artifact.filename)
        }
        # Checked for both commands: without an expected hash nothing can be
        # verified, and that is never a pass (the engineering rules; D35).
        if ([string]$package.artifact.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw ('{0} {1}: the lock carries no SHA-256 for {2}.' -f $package.name, $package.version, $fileName)
        }

        $filePath = Join-Path -Path $packageDir -ChildPath $fileName
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw ('{0} {1}: staged file is missing: {2}' -f $package.name, $package.version, $fileName)
        }

        $actualSize = (Get-Item -LiteralPath $filePath).Length
        $actualSha256 = Get-Sha256 -Path $filePath
        $files += [ordered]@{ path = $fileName; sha256 = $actualSha256; size_bytes = $actualSize }

        if ($command -eq 'install') {
            if ($actualSize -ne [long]$package.artifact.sizeBytes) {
                throw ('{0} {1}: size of {2} does not match the lock.' -f $package.name, $package.version, $fileName)
            }
            if ($actualSha256 -ne ([string]$package.artifact.sha256).ToLowerInvariant()) {
                throw ('{0} {1}: SHA-256 of {2} does not match the lock.' -f $package.name, $package.version, $fileName)
            }
        }

        if ($files.Count -eq 0) { throw ('{0} {1}: the lock lists no files.' -f $package.name, $package.version) }
        $stagedPackages += [pscustomobject]@{ Package = $package; Directory = $packageDir; Files = $files; FilePath = $filePath }
    }

    if ($stagedPackages.Count -eq 0) { throw 'The lock lists no packages.' }
}
catch {
    Complete-Run -ExitCode 11 -Outcome 'failed' -ErrorMessage $_.Exception.Message
}

# --- verify: validations only. Nothing is installed or changed. ---
if ($command -eq 'verify') {
    $allPassed = $true

    foreach ($staged in $stagedPackages) {
        $validation = Test-Validation -Package $staged.Package
        if (-not $validation.passed) { $allPassed = $false }
        $packageResults += [ordered]@{
            name       = $staged.Package.name
            version    = $staged.Package.version
            status     = $(if ($validation.passed) { 'success' } else { 'validation_failed' })
            validation = $validation
        }
    }

    if ($allPassed) { Complete-Run -ExitCode 0 -Outcome 'success' -ErrorMessage $null }
    Complete-Run -ExitCode 10 -Outcome 'failed' -ErrorMessage 'A package failed its installed-state validation.'
}

# --- install: in installOrder, stopping at the first failure. ---
$restartRequired = $false

foreach ($staged in $stagedPackages) {
    $package = $staged.Package
    $record = [ordered]@{
        name             = $package.name
        version          = $package.version
        status           = 'failed'
        exit_code        = $null
        duration_ms      = 0
        timed_out        = $false
        restart_required = $false
        files            = $staged.Files
        validation       = $null
        error            = $null
    }

    try {
        if ($forcedExitCode -eq '10') { throw 'Forced by PACKAGE_RUNNER_STANDIN_FORCE_EXIT_CODE.' }
        if ($package.install.handler -ne 'powershell') {
            throw ('Handler not implemented by the stand-in: {0}' -f $package.install.handler)
        }
        # A Go duration, as the owner's resolver writes it: 5m0s, 20m0s, 1h30m0s.
        # A single unit (5m) is accepted too.
        if ([string]$package.install.timeout -notmatch '^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$' -or [string]::IsNullOrEmpty([string]$package.install.timeout)) {
            throw ('Timeout is not a duration the stand-in reads (for example 5m0s): {0}' -f $package.install.timeout)
        }
        $timeoutMs = ([int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]) * 1000
        if ($timeoutMs -le 0) { throw ('Timeout must be longer than zero: {0}' -f $package.install.timeout) }

        # The package's one file is what the powershell handler runs.
        $entryPoint = $staged.FilePath

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        # Installer output stays in the guest and out of the result (C4: redacted
        # and size-capped, or omitted). A failed build retains its VM, so the
        # two logs are there to read; the guest cleanup removes them otherwise.
        New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        $logBase = Join-Path -Path $evidenceDir -ChildPath ('{0}-{1}' -f $package.name, $package.version)
        $process = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow -WorkingDirectory $staged.Directory `
            -RedirectStandardOutput ($logBase + '-stdout.log') -RedirectStandardError ($logBase + '-stderr.log') -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $entryPoint)
        )
        # Without touching Handle here, ExitCode is empty once the process has exited.
        $null = $process.Handle

        if (-not $process.WaitForExit($timeoutMs)) {
            $process.Kill()
            $record.timed_out = $true
            $record.duration_ms = $stopwatch.ElapsedMilliseconds
            throw ('The install did not finish within {0}.' -f $package.install.timeout)
        }

        $record.duration_ms = $stopwatch.ElapsedMilliseconds
        $record.exit_code = $process.ExitCode

        $succeeded = @($package.install.successExitCodes) -contains $process.ExitCode

        # restartExistCodes is the owner's spelling as her code reads it today
        # (D15); the agreed spelling is accepted as well.
        $restartCodes = @($package.install.restartExistCodes) + @($package.install.restartExitCodes)
        if ($restartCodes -contains $process.ExitCode -or ($succeeded -and $forcedExitCode -eq '3010')) {
            # Installed, not yet checked: the post-restart `verify` sets the final status.
            $record.status = 'restart_required'
            $record.restart_required = $true
            $restartRequired = $true
        }
        elseif ($succeeded) {
            $record.validation = Test-Validation -Package $package
            if ($record.validation.passed) {
                $record.status = 'success'
            }
            else {
                $record.status = 'validation_failed'
                throw 'The installed-state validation failed.'
            }
        }
        else {
            throw ('The install exited with code {0}.' -f $process.ExitCode)
        }
    }
    catch {
        $record.error = $_.Exception.Message
    }

    $packageResults += $record

    if ($record.error) {
        Complete-Run -ExitCode 10 -Outcome 'failed' -ErrorMessage ('{0} {1}: {2}' -f $package.name, $package.version, $record.error)
    }
}

if ($restartRequired) {
    Complete-Run -ExitCode 3010 -Outcome 'degraded' -ErrorMessage $null
}

Complete-Run -ExitCode 0 -Outcome 'success' -ErrorMessage $null
