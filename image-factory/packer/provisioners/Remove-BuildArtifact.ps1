<#
    Removes build artifacts from the guest, then proves the credential material
    is gone.

    Runs as the last Packer provisioner, after every evidence download and
    before the shutdown command.

    WHY THIS EXISTS. Windows Setup caches the answer file in C:\Windows\Panther.
    It scrubs the working copy (unattend.xml) but keeps an UNSCRUBBED original
    beside it (unattend-original.xml), so the domain-join service account
    password is on disk in plaintext on every VM this build produces, and would
    ship in any template or clone made from one. OBSERVED on a retained build
    VM, 2026-09-23. See docs/decisions/0002-master-image-identity-and-sealing.md.

    SCOPE. This removes credential material and cheap build leftovers. It is NOT
    the pre-seal cleanup: the WinRM listener, the build certificate, the firewall
    rule and the administrative group mapping are deliberately left alone. ADR
    0002 requires listener removal to happen inside the step that also shuts the
    machine down, because the WinRM channel has to survive until the last
    command, and that work belongs with the sealing decision. Since 2026-10-08
    that step is packer/provisioners/Invoke-ImageSeal.ps1, which runs after
    this script and only when the build is asked to seal.

    KNOWN GAP, ACCEPTED FOR THE LAB. A failed build retains its VM (-on-error=abort)
    and never reaches this provisioner, so it leaves the password on disk here
    and, on the build floppy, on the datastore (OBSERVED 2026-09-28). Accepted by
    owner override (AGENT_HANDOFF.md, Key Design Decision 8; STORY-02). Remove
    retained VMs promptly with scripts/windows/Remove-PackerTestVm.ps1.

    Inputs (environment variables set by the template):
      STAGING_DIR   package staging directory to remove, recursively
      RESULT_PATH   where to write the JSON result

    Optional:
      GUEST_EVIDENCE_DIR  the directory package-runner wrote its evidence to,
                          removed recursively once the template has downloaded it

    Optional, and set by the template. With SETUP_ACCOUNT unset the first-run
    setup step below is skipped and recorded as skipped, so the file deletions
    can be exercised on a workstation without touching its accounts:
      SETUP_ACCOUNT       the local administrator the answer file created to
                          finish first-run setup (OOBE); deleted here
      EXPECTED_TIME_ZONE  the Windows time zone ID the image must be set to

    Optional, and defaulted to the real guest paths. They exist so the deletion
    logic can be exercised against a scratch directory instead of a live
    C:\Windows, and the template does not set them:
      PANTHER_DIR     default C:\Windows\Panther
      GUEST_TEMP_DIR  default C:\Windows\Temp

    The result records every path it tried to remove and whether it succeeded,
    plus the outcome of the Panther scan. It contains no credential material:
    the scan reports counts and file names, never file contents.

    Exit 1 if any credential material survives, or if the scan could not read a
    path under Panther and so cannot say it is clean. A non-credential leftover that
    could not be removed is recorded but does not fail the build, because a
    locked temporary file should not fail an otherwise good build.

    FIRST-RUN SETUP. The master is domain-joined and never generalized (ADR
    0002), so this step also proves the build left Windows past OOBE and removes
    the two local administrators OOBE leaves behind: the setup account and
    defaultuser0. Exit 1 if OOBE has not finished, if the setup account was
    never created, if either account survives, or if the time zone is not the
    expected one. An enabled local administrator would otherwise ship on every
    desktop made from the master.

    Windows PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$stagingDir = $env:STAGING_DIR
$resultPath = $env:RESULT_PATH

$pantherDir = if ([string]::IsNullOrWhiteSpace($env:PANTHER_DIR)) {
    'C:\Windows\Panther'
} else {
    $env:PANTHER_DIR
}

$guestTempDir = if ([string]::IsNullOrWhiteSpace($env:GUEST_TEMP_DIR)) {
    'C:\Windows\Temp'
} else {
    $env:GUEST_TEMP_DIR
}

# Credential-bearing. Failing to remove any of these fails the build.
# unattend-original.xml is the unscrubbed one and the reason this script exists;
# unattend.xml is scrubbed but is still build input that should not ship.
$credentialPaths = @(
    (Join-Path -Path $pantherDir -ChildPath 'unattend-original.xml'),
    (Join-Path -Path $pantherDir -ChildPath 'unattend.xml')
)

# Build leftovers. Worth removing, not worth failing a build over.
$leftoverPaths = @(
    (Join-Path -Path $guestTempDir -ChildPath 'Test-GuestCommunicator.ps1'),
    (Join-Path -Path $guestTempDir -ChildPath 'communicator-result.json'),
    (Join-Path -Path $guestTempDir -ChildPath 'enable-winrm-bootstrap.log')
)

# defaultuser0 is the account OOBE itself runs under. Windows is meant to delete
# it once OOBE finishes and does not always: it was found enabled and in local
# Administrators on a build VM (ADR 0002).
$oobeAccount = 'defaultuser0'

$passed = $false
$errorMessage = $null
$removalResults = @()
$pantherScan = $null
$firstRunSetup = [ordered]@{ checked = $false }

function Remove-LocalAccount {
    param(
        [string] $Name
    )

    $existedBefore = $false
    $removalError = $null
    $profileError = $null

    try {
        $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
        if ($user) {
            $existedBefore = $true

            # The profile first, through the profile service: deleting the
            # folder alone leaves its ProfileList entry behind. The setup
            # account never signs in and so normally has no profile.
            try {
                Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID = '{0}'" -f $user.SID.Value) |
                    Remove-CimInstance
            }
            catch {
                $profileError = $_.Exception.Message
            }

            Remove-LocalUser -Name $Name
        }
    }
    catch {
        $removalError = $_.Exception.Message
    }

    [ordered]@{
        name           = $Name
        existed_before = $existedBefore
        exists_after   = [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
        error          = $removalError
        profile_error  = $profileError
    }
}

function Remove-TargetPath {
    param(
        [string] $Path,
        [string] $Category
    )

    $existedBefore = Test-Path -LiteralPath $Path
    $removalError = $null

    if ($existedBefore) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        catch {
            $removalError = $_.Exception.Message
        }
    }

    [ordered]@{
        path           = $Path
        category       = $Category
        existed_before = $existedBefore
        exists_after   = [bool](Test-Path -LiteralPath $Path)
        error          = $removalError
    }
}

try {
    foreach ($pair in @(
            @('STAGING_DIR', $stagingDir),
            @('RESULT_PATH', $resultPath)
        )) {
        if ([string]::IsNullOrWhiteSpace($pair[1])) {
            throw ('Required environment variable {0} is not set.' -f $pair[0])
        }
    }

    foreach ($path in $credentialPaths) {
        $removalResults += Remove-TargetPath -Path $path -Category 'credential'
    }

    # The staging directory holds the lock, the package-runner binary and the
    # package files; the evidence directory holds the guest copies of the install
    # results, already downloaded as evidence.
    $removalResults += Remove-TargetPath -Path $stagingDir -Category 'leftover'

    if (-not [string]::IsNullOrWhiteSpace($env:GUEST_EVIDENCE_DIR)) {
        $removalResults += Remove-TargetPath -Path $env:GUEST_EVIDENCE_DIR -Category 'leftover'
    }

    foreach ($path in $leftoverPaths) {
        $removalResults += Remove-TargetPath -Path $path -Category 'leftover'
    }

    # State is read before the accounts are removed, and the failures are
    # raised further down, after the credential checks, so one failed assertion
    # here cannot hide a surviving password.
    if (-not [string]::IsNullOrWhiteSpace($env:SETUP_ACCOUNT)) {
        # OOBEInProgress is 1 from the start of the oobeSystem pass until OOBE
        # finishes. A build that stops at the account page never clears it.
        $oobeInProgress = (
            Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -Name 'OOBEInProgress' -ErrorAction SilentlyContinue
        ).OOBEInProgress
        $imageState = (
            Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name 'ImageState' -ErrorAction SilentlyContinue
        ).ImageState

        $firstRunSetup = [ordered]@{
            checked            = $true
            oobe_in_progress   = $oobeInProgress
            image_state        = $imageState
            time_zone          = (Get-TimeZone).Id
            expected_time_zone = $env:EXPECTED_TIME_ZONE
            accounts           = @(
                (Remove-LocalAccount -Name $env:SETUP_ACCOUNT),
                (Remove-LocalAccount -Name $oobeAccount)
            )
        }
    }

    # The assertion that actually closes the finding. Removing the two known
    # filenames only fixes what we happened to look at; this catches a copy
    # anywhere else under Panther, including one a future Windows build puts
    # somewhere new. File names are recorded so a failure is actionable; file
    # contents never are.
    #
    # SCOPE: *.xml only, and deliberately so. This assertion fails the build, so
    # it has to be precise. Scanning every file under Panther would include
    # setupact.log, which logs answer-file processing and can legitimately
    # contain the literal string '<Password>' even when the value is scrubbed —
    # that would fail good builds on a log line, which is worse than the gap it
    # closes.
    #
    # The gap is that credential material cached under some other extension
    # would not be seen. OBSERVED 2026-09-23, on a VM built by this template: an
    # unfiltered scan of every file under Panther found no '<Password>' at all,
    # so the .xml scope is not currently hiding anything. Re-check that by hand
    # if Windows Setup's behavior changes.
    #
    # If this is ever widened, make the broader scan informational — record it
    # in the result — and leave the build-failing assertion scoped to *.xml.
    #
    # UNREADABLE MEANS NOT PROVEN CLEAN. Both the directory walk and the file
    # read used to run with -ErrorAction SilentlyContinue, so a subdirectory the
    # scan could not enter, or a file it could not open (locked, access denied),
    # was silently counted as free of credentials: a fail-open path in the one
    # check that exists to fail closed (STORY-02). Every such path is now
    # recorded in unreadable_paths and fails the build. Select-String reads
    # UTF-16 files that carry a byte order mark, which is how Windows writes the
    # windlp.state*.xml files found under Panther.
    $offenders = @()
    $unreadable = @()

    if (Test-Path -LiteralPath $pantherDir -PathType Container) {
        $walkErrors = @()
        $xmlFiles = @(
            Get-ChildItem -LiteralPath $pantherDir -Recurse -Filter '*.xml' -Force -ErrorAction SilentlyContinue -ErrorVariable walkErrors
        )
        foreach ($walkError in $walkErrors) {
            $unreadable += if ($walkError.TargetObject) { [string]$walkError.TargetObject } else { $walkError.Exception.Message }
        }

        foreach ($xmlFile in $xmlFiles) {
            try {
                if (Select-String -LiteralPath $xmlFile.FullName -Pattern '<Password>' -Quiet -ErrorAction Stop) {
                    $offenders += $xmlFile.FullName
                }
            }
            catch {
                $unreadable += $xmlFile.FullName
            }
        }

        $pantherScan = [ordered]@{
            directory_present = $true
            xml_files_scanned = $xmlFiles.Count
            files_with_password_element = @($offenders)
            unreadable_paths = @($unreadable)
        }
    }
    else {
        $pantherScan = [ordered]@{
            directory_present = $false
            xml_files_scanned = 0
            files_with_password_element = @()
            unreadable_paths = @()
        }
    }

    if ($offenders.Count -gt 0) {
        throw (
            'Credential material survives in {0}: {1} file(s) still contain a <Password> element.' -f
            $pantherDir,
            $offenders.Count
        )
    }

    if ($unreadable.Count -gt 0) {
        throw (
            'The Panther scan could not read {0} path(s), so they are not proven free of credential material: {1}' -f
            $unreadable.Count,
            ($unreadable -join ', ')
        )
    }

    $survivingCredentialPaths = @(
        $removalResults | Where-Object { $_.category -eq 'credential' -and $_.exists_after }
    )

    if ($survivingCredentialPaths.Count -gt 0) {
        throw (
            'Credential material could not be removed: {0}' -f
            (($survivingCredentialPaths | ForEach-Object { $_.path }) -join ', ')
        )
    }

    if ($firstRunSetup.checked) {
        if ($firstRunSetup.oobe_in_progress -ne 0) {
            throw (
                'Windows first-run setup (OOBE) has not finished: OOBEInProgress is {0}, ImageState is {1}.' -f
                $firstRunSetup.oobe_in_progress,
                $firstRunSetup.image_state
            )
        }

        # No setup account means the answer file's UserAccounts was not applied,
        # so whatever ended OOBE was not this build's doing.
        if (-not $firstRunSetup.accounts[0].existed_before) {
            throw ('The setup account {0} was never created.' -f $env:SETUP_ACCOUNT)
        }

        $survivingAccounts = @($firstRunSetup.accounts | Where-Object { $_.exists_after })

        if ($survivingAccounts.Count -gt 0) {
            throw (
                'Build-time local account(s) could not be removed: {0}' -f
                (($survivingAccounts | ForEach-Object { $_.name }) -join ', ')
            )
        }

        if (-not [string]::IsNullOrWhiteSpace($env:EXPECTED_TIME_ZONE) -and
            $firstRunSetup.time_zone -ne $env:EXPECTED_TIME_ZONE) {
            throw (
                'The time zone is {0}, expected {1}.' -f
                $firstRunSetup.time_zone,
                $env:EXPECTED_TIME_ZONE
            )
        }

        Write-Host (
            'First-run setup: OOBE finished, time zone {0}, build-time local accounts removed.' -f
            $firstRunSetup.time_zone
        )
    }
    else {
        Write-Host 'First-run setup: not checked (SETUP_ACCOUNT is not set).'
    }

    $passed = $true

    $survivingLeftovers = @(
        $removalResults | Where-Object { $_.category -eq 'leftover' -and $_.exists_after }
    )

    if ($survivingLeftovers.Count -gt 0) {
        Write-Host (
            'Build cleanup: credential material removed; {0} non-credential leftover(s) remain and are recorded.' -f
            $survivingLeftovers.Count
        )
    }
    else {
        Write-Host (
            'Build cleanup: all targets removed. Panther scan found no <Password> element in {0} XML file(s).' -f
            $pantherScan.xml_files_scanned
        )
    }
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Host ('Build cleanup failed: {0}' -f $errorMessage)
}

# Written after the deletions above, so this file is not removed by its own step.
if (-not [string]::IsNullOrWhiteSpace($resultPath)) {
    $result = [ordered]@{
        schema_version  = 2
        timestamp       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        passed          = $passed
        error           = $errorMessage
        computer_name   = $env:COMPUTERNAME
        removals        = $removalResults
        panther_scan    = $pantherScan
        first_run_setup = $firstRunSetup
    }

    # UTF-8 without a byte order mark, so the runner's jq can read it.
    $json = $result | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText(
        $resultPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

if (-not $passed) {
    exit 1
}

exit 0
