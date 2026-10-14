<#
    Seals the master image: removes, by name, what the build added to reach the
    guest, and returns Windows remote management to its default (off).

    STORIES. What is removed and how removal is verified is STORY-19. Running it
    as the build's last act, inside the shutdown step, is STORY-03.

    WHY THIS EXISTS. The master stays domain-joined and is never generalized
    (docs/decisions/0002-master-image-identity-and-sealing.md), so nothing cleans
    the image for us. Every desktop Citrix MCS creates boots the master's disk as
    it is. Without this step every desktop would ship with the build's WinRM
    listeners, its certificate, its firewall rule, the build's administrative
    group in local Administrators, and the build identity's profile.

    TWO STAGES, because the seal removes the channel Packer uses.

      Prepare  A normal provisioner, run while WinRM still works. It takes an
               inventory, removes the two items that do not affect the channel,
               copies this script to a fixed path, and registers a scheduled
               task that runs the Final stage as SYSTEM. Its result is
               downloaded as evidence.

      Final    Run by that task, which the template's shutdown command starts.
               It removes the rest, re-checks every item, reports the result,
               and shuts the machine down ONLY if everything checked out. On a
               failure it leaves the machine running, so Packer fails on its
               shutdown timeout and the VM is kept for diagnosis.

    HOW THE FINAL RESULT LEAVES THE GUEST. There is no WinRM by then. The result
    is set as guestinfo.imagefactory.seal.result through VMware Tools, base64-encoded,
    and scripts/runner/verify-seal.sh reads it from vCenter. A value the guest
    sets is readable from outside only while the VM is powered on (OBSERVED
    2026-10-08), so this stage holds the machine on for HOLD_SECONDS after
    reporting and before shutting down.

    THE LIST. What this removes, the header of packer/unattended/enable-winrm.ps1,
    ADR 0001's Consequences and ADR 0002 are the same contract. Change them
    together.

    Inputs for Prepare (environment variables set by the template):
      SEAL_IMAGE       'true' to seal. Anything else: do nothing, and say so in
                       the result. Packer cannot make a provisioner conditional.
      ADMIN_GROUP_SID  the administrative group the bootstrap mapped into local
                       Administrators; removed by SID, never by clearing the group
      EXECUTION_ID     stamped into both results
      RESULT_PATH      where to write the Prepare result
    Optional:
      SETUP_ACCOUNT        the build-time local administrator; checked absent
      SEAL_HOLD_SECONDS    how long Final keeps the machine on after reporting
                           (default 120)
      SEAL_DRY_RUN         '1' reports what would be done and changes nothing
      SEAL_FORCE_FAILURE   '1' makes Final report a failure after doing its
                           work. Test knob for the harness.

    Final takes its inputs from the configuration file Prepare wrote, because a
    scheduled task does not inherit the provisioner's environment.

    Nothing here is credential material, and neither result contains any.

    Windows PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Final')]
    [string] $Stage = 'Prepare',

    # Final only. Where Prepare left the configuration.
    [string] $ConfigPath = 'C:\Windows\Temp\image-seal-config.json'
)

$ErrorActionPreference = 'Stop'

# Names shared with packer/unattended/enable-winrm.ps1. If one changes there it
# must change here, or Prepare fails on a missing item.
$httpsFirewallRuleName = 'Packer WinRM HTTPS 5986'
$legacyHttpFirewallRuleName = 'Packer WinRM HTTP 5985'
$buildCertificateFriendlyName = 'Packer WinRM build certificate'

# The rules Windows ships for remote management. Enable-PSRemoting enables
# them; the Windows default is disabled. Matched by rule name, which is not
# localized, unlike the display group.
$builtInWinRMRulePattern = 'WINRM-HTTP-In-TCP*'

$listenerRegistryKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Listener'

$tokenFilterKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$tokenFilterName = 'LocalAccountTokenFilterPolicy'

$administratorsSid = 'S-1-5-32-544'
$oobeAccount = 'defaultuser0'

$taskName = 'Packer image seal'
$installedScriptPath = 'C:\Windows\Temp\Invoke-ImageSeal.ps1'
$finalLogPath = 'C:\Windows\Temp\image-seal.log'
$vmToolsDaemon = 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe'
$guestInfoKey = 'guestinfo.imagefactory.seal.result'

function Write-SealMessage {
    param([string] $Message)
    Write-Host ('Image seal: {0}' -f $Message)
}

function Get-WinRMListener {
    # Read from the registry, where WinRM keeps its listeners, and not through
    # the WSMan provider: the provider needs the service running, and the final
    # check is made after the service has been stopped. A stopped service with
    # a listener still configured would start listening again the next time
    # anything started it.
    if (-not (Test-Path -LiteralPath $listenerRegistryKey)) {
        return @()
    }
    return @(
        Get-ChildItem -LiteralPath $listenerRegistryKey | ForEach-Object {
            # The key is named <address>+<transport>, for example *+HTTPS.
            $address, $transport = $_.PSChildName -split '\+', 2
            [ordered]@{
                Address   = $address
                Transport = $transport
                Port      = (Get-ItemProperty -LiteralPath $_.PSPath).Port
            }
        }
    )
}

function Get-BuildCertificate {
    return @(
        Get-ChildItem -Path 'Cert:\LocalMachine\My' |
            Where-Object { $_.FriendlyName -eq $buildCertificateFriendlyName }
    )
}

function Get-TokenFilterValue {
    $item = Get-ItemProperty -Path $tokenFilterKey -Name $tokenFilterName -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$tokenFilterName
}

function Get-AdministratorsMember {
    # By the group's well-known SID, so the name of the group does not matter.
    return @(
        Get-LocalGroupMember -SID $administratorsSid |
            ForEach-Object {
                [ordered]@{
                    name   = [string] $_.Name
                    sid    = [string] $_.SID.Value
                    source = [string] $_.PrincipalSource
                    class  = [string] $_.ObjectClass
                }
            }
    )
}

function Get-BuildProfile {
    param([string] $Sid)
    if ([string]::IsNullOrWhiteSpace($Sid)) { return $null }
    return Get-CimInstance -ClassName Win32_UserProfile -Filter ("SID = '{0}'" -f $Sid) -ErrorAction SilentlyContinue
}

# One reading of everything on the pre-seal list. Each entry says whether the
# item is still present; "present" always means "would ship in the image".
function Get-SealInventory {
    param(
        [string] $AdminGroupSid,
        [string] $BuildAccountSid,
        [string] $SetupAccount
    )

    $listenersUnreadable = $null
    try {
        $listeners = Get-WinRMListener
    }
    catch {
        # Only a dry run may carry on without this reading: it is how the rest
        # of the inventory is exercised from a shell that is not elevated. A
        # real run that cannot read the listeners cannot say they are gone.
        if (-not $script:dryRun) { throw }
        $listeners = @()
        $listenersUnreadable = $_.Exception.Message
    }
    $service = Get-Service -Name 'WinRM' -ErrorAction SilentlyContinue
    $serviceStartType = if ($service) { [string] $service.StartType } else { 'absent' }
    $serviceStatus = if ($service) { [string] $service.Status } else { 'absent' }
    $members = Get-AdministratorsMember
    $userProfile = Get-BuildProfile -Sid $BuildAccountSid
    $tokenFilter = Get-TokenFilterValue
    $enabledBuiltInRules = @(
        Get-NetFirewallRule -Name $builtInWinRMRulePattern -ErrorAction SilentlyContinue |
            Where-Object { [string] $_.Enabled -eq 'True' }
    )

    $localAccounts = @($oobeAccount)
    if (-not [string]::IsNullOrWhiteSpace($SetupAccount)) { $localAccounts += $SetupAccount }
    $survivingAccounts = @(
        $localAccounts | Where-Object { Get-LocalUser -Name $_ -ErrorAction SilentlyContinue }
    )

    $items = [ordered]@{
        token_filter_policy  = [ordered]@{
            present = ($null -ne $tokenFilter -and [int] $tokenFilter -ne 0)
            detail  = if ($null -eq $tokenFilter) { 'not set' } else { [string] $tokenFilter }
        }
        legacy_http_rule     = [ordered]@{
            present = [bool] (Get-NetFirewallRule -DisplayName $legacyHttpFirewallRuleName -ErrorAction SilentlyContinue)
            detail  = $legacyHttpFirewallRuleName
        }
        https_rule           = [ordered]@{
            present = [bool] (Get-NetFirewallRule -DisplayName $httpsFirewallRuleName -ErrorAction SilentlyContinue)
            detail  = $httpsFirewallRuleName
        }
        builtin_winrm_rules  = [ordered]@{
            present = ($enabledBuiltInRules.Count -gt 0)
            detail  = ('{0} enabled' -f $enabledBuiltInRules.Count)
        }
        listeners            = [ordered]@{
            present = ($listeners.Count -gt 0)
            detail  = if ($listenersUnreadable) {
                'unreadable in this dry run: {0}' -f $listenersUnreadable
            }
            else {
                @($listeners | ForEach-Object { '{0}:{1}' -f $_.Transport, $_.Port }) -join ','
            }
        }
        build_certificate    = [ordered]@{
            present = ((Get-BuildCertificate).Count -gt 0)
            detail  = $buildCertificateFriendlyName
        }
        winrm_service        = [ordered]@{
            # The Windows 11 default is a manual-start service that is not running.
            present = ($serviceStartType -ne 'Manual' -or $serviceStatus -ne 'Stopped')
            detail  = ('{0}, {1}' -f $serviceStartType, $serviceStatus)
        }
        admin_group_mapping  = [ordered]@{
            present = [bool] ($members | Where-Object { $_.sid -eq $AdminGroupSid })
            detail  = $AdminGroupSid
        }
        build_profile        = [ordered]@{
            present = ($null -ne $userProfile)
            detail  = if ($userProfile) { ('{0}, loaded={1}' -f $userProfile.LocalPath, $userProfile.Loaded) } else { 'none' }
        }
        build_local_accounts = [ordered]@{
            present = ($survivingAccounts.Count -gt 0)
            detail  = ($survivingAccounts -join ',')
        }
    }

    return [ordered]@{
        items          = $items
        administrators = $members
    }
}

# What local Administrators must look like on a sealed image (ADR 0002): the
# build's group gone, the built-in Administrator and Domain Admins still
# there, and no other local user. Other domain principals are recorded and
# allowed: a production domain may add its own by Group Policy.
function Test-AdministratorsMembership {
    param(
        [object[]] $Members,
        [string] $AdminGroupSid
    )

    $problems = @()
    if ($Members | Where-Object { $_.sid -eq $AdminGroupSid }) {
        $problems += 'the build administrative group is still a member'
    }
    if (-not ($Members | Where-Object { $_.sid -match '-500$' })) {
        $problems += 'the built-in Administrator is missing'
    }
    if (-not ($Members | Where-Object { $_.sid -match '-512$' })) {
        $problems += 'Domain Admins is missing'
    }
    $extraLocalUsers = @(
        $Members | Where-Object { $_.source -eq 'Local' -and $_.class -eq 'User' -and $_.sid -notmatch '-500$' }
    )
    if ($extraLocalUsers.Count -gt 0) {
        $problems += ('unexpected local user(s): {0}' -f (@($extraLocalUsers | ForEach-Object { $_.name }) -join ', '))
    }
    return $problems
}

function Write-JsonFile {
    param([string] $Path, [object] $Value)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # UTF-8 without a byte order mark, so the runner's jq can read it.
    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 6),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

# ---------------------------------------------------------------------------
# Prepare
# ---------------------------------------------------------------------------
if ($Stage -eq 'Prepare') {
    $resultPath = $env:RESULT_PATH
    $dryRun = ($env:SEAL_DRY_RUN -eq '1')
    $requested = ($env:SEAL_IMAGE -eq 'true')

    $result = [ordered]@{
        schema_version = 1
        stage          = 'prepare'
        timestamp      = Get-UtcTimestamp
        execution_id   = $env:EXECUTION_ID
        computer_name  = $env:COMPUTERNAME
        status         = 'skipped'
        dry_run        = $dryRun
        error          = $null
        inventory      = $null
        removed        = @()
        task           = $null
    }

    if (-not $requested) {
        Write-SealMessage 'not requested (SEAL_IMAGE is not true). Nothing was changed.'
        Write-JsonFile -Path $resultPath -Value $result
        exit 0
    }

    try {
        $adminGroupSid = $env:ADMIN_GROUP_SID
        if ([string]::IsNullOrWhiteSpace($adminGroupSid)) {
            throw 'Required environment variable ADMIN_GROUP_SID is not set.'
        }

        # The WinRM session runs as the build identity, so this is its SID.
        $buildAccountSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

        $holdSeconds = 120
        if (-not [string]::IsNullOrWhiteSpace($env:SEAL_HOLD_SECONDS)) {
            $holdSeconds = [int] $env:SEAL_HOLD_SECONDS
        }

        $inventory = Get-SealInventory -AdminGroupSid $adminGroupSid -BuildAccountSid $buildAccountSid -SetupAccount $env:SETUP_ACCOUNT
        $result.inventory = $inventory

        # Everything the bootstrap creates must be here now. A missing item
        # means a name drifted between the bootstrap and this script, and the
        # Final stage would then "remove" nothing and report success.
        $mustBePresent = @('https_rule', 'listeners', 'build_certificate', 'winrm_service', 'admin_group_mapping', 'build_profile')
        $missing = @($mustBePresent | Where-Object { -not $inventory.items[$_].present })
        if ($missing.Count -gt 0 -and -not $dryRun) {
            throw ('Expected build artifact(s) not found, so the seal cannot be trusted to remove them: {0}' -f ($missing -join ', '))
        }
        if ($inventory.items.build_local_accounts.present) {
            throw ('Build-time local account(s) still exist: {0}. Remove-BuildArtifact.ps1 removes them and must run first.' -f $inventory.items.build_local_accounts.detail)
        }

        # The two items that do not affect the channel: the build connects with
        # a domain account, which the token filter never applies to.
        $removed = @()
        if ($inventory.items.token_filter_policy.present) {
            if (-not $dryRun) {
                Remove-ItemProperty -Path $tokenFilterKey -Name $tokenFilterName -Force
            }
            $removed += 'token_filter_policy'
        }
        if ($inventory.items.legacy_http_rule.present) {
            if (-not $dryRun) {
                Remove-NetFirewallRule -DisplayName $legacyHttpFirewallRuleName
            }
            $removed += 'legacy_http_rule'
        }
        $result.removed = $removed

        $config = [ordered]@{
            execution_id      = $env:EXECUTION_ID
            admin_group_sid   = $adminGroupSid
            build_account_sid = $buildAccountSid
            setup_account     = $env:SETUP_ACCOUNT
            hold_seconds      = $holdSeconds
            dry_run           = $dryRun
            force_failure     = ($env:SEAL_FORCE_FAILURE -eq '1')
        }

        if ($dryRun) {
            $result.task = 'would register'
            Write-SealMessage ('dry run. Would remove now: {0}. Would register the task "{1}".' -f $(if ($removed.Count) { $removed -join ', ' } else { 'nothing' }), $taskName)
        }
        else {
            # A fixed path: Packer deletes its own uploaded copy of this script
            # when the provisioner ends, and the task runs after that.
            Copy-Item -LiteralPath $PSCommandPath -Destination $installedScriptPath -Force
            Write-JsonFile -Path $ConfigPath -Value $config

            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
                '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Stage Final -ConfigPath "{1}"' -f
                $installedScriptPath, $ConfigPath
            )
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            # No trigger: it runs only when the shutdown command starts it. It
            # must never run by itself on a desktop made from this image.
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

            if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
                throw ('The scheduled task "{0}" was not registered.' -f $taskName)
            }
            $result.task = 'registered'
            Write-SealMessage ('prepared. Removed now: {0}. Task "{1}" registered; the shutdown command starts it.' -f $(if ($removed.Count) { $removed -join ', ' } else { 'nothing' }), $taskName)
        }

        $result.status = 'prepared'
    }
    catch {
        $result.status = 'failed'
        $result.error = $_.Exception.Message
        Write-SealMessage ('prepare failed: {0}' -f $result.error)
    }

    Write-JsonFile -Path $resultPath -Value $result
    if ($result.status -eq 'failed') { exit 1 }
    exit 0
}

# ---------------------------------------------------------------------------
# Final
# ---------------------------------------------------------------------------
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$dryRun = [bool] $config.dry_run
$actions = @()
$errorMessage = $null
$sealed = $false
$after = $null

function Add-SealAction {
    param([string] $Name, [string] $Outcome)
    $script:actions += [ordered]@{ item = $Name; outcome = $Outcome }
    if (-not $dryRun) {
        Add-Content -LiteralPath $finalLogPath -Value ('{0} {1}: {2}' -f (Get-UtcTimestamp), $Name, $Outcome)
    }
}

# Runs one removal. A failure is recorded and the rest still run, so one result
# reports everything that is wrong.
function Invoke-SealAction {
    param([string] $Name, [scriptblock] $Action)
    if ($dryRun) {
        Add-SealAction -Name $Name -Outcome 'would run'
        return
    }
    try {
        & $Action
        Add-SealAction -Name $Name -Outcome 'done'
    }
    catch {
        Add-SealAction -Name $Name -Outcome ('failed: {0}' -f $_.Exception.Message)
    }
}

try {
    if (-not $dryRun) {
        # Let the shutdown command that started this task return to Packer
        # before its session is taken away.
        Start-Sleep -Seconds 15
    }

    # Order matters: the endpoints and listeners need the service running, so
    # they go first, and the service is stopped after them.
    Invoke-SealAction -Name 'remoting_endpoints' -Action {
        Disable-PSRemoting -Force -WarningAction SilentlyContinue
    }
    Invoke-SealAction -Name 'listeners' -Action {
        foreach ($listener in (Get-WinRMListener)) {
            Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{
                Address   = $listener.Address
                Transport = $listener.Transport
            }
        }
    }
    Invoke-SealAction -Name 'winrm_service' -Action {
        Stop-Service -Name 'WinRM' -Force
        Set-Service -Name 'WinRM' -StartupType Manual
    }
    Invoke-SealAction -Name 'https_rule' -Action {
        Remove-NetFirewallRule -DisplayName $httpsFirewallRuleName -ErrorAction SilentlyContinue
    }
    Invoke-SealAction -Name 'legacy_http_rule' -Action {
        Remove-NetFirewallRule -DisplayName $legacyHttpFirewallRuleName -ErrorAction SilentlyContinue
    }
    Invoke-SealAction -Name 'builtin_winrm_rules' -Action {
        Get-NetFirewallRule -Name $builtInWinRMRulePattern -ErrorAction SilentlyContinue | Disable-NetFirewallRule
    }
    Invoke-SealAction -Name 'build_certificate' -Action {
        Get-BuildCertificate | Remove-Item -Force
    }
    Invoke-SealAction -Name 'token_filter_policy' -Action {
        if ($null -ne (Get-TokenFilterValue)) {
            Remove-ItemProperty -Path $tokenFilterKey -Name $tokenFilterName -Force
        }
    }
    Invoke-SealAction -Name 'admin_group_mapping' -Action {
        # By SID, and only this SID. Clearing the group would also remove
        # Domain Admins, which is a property of domain membership and not a
        # build artifact. The string form is what the bootstrap found to work.
        $member = Get-LocalGroupMember -SID $administratorsSid |
            Where-Object { $_.SID -and $_.SID.Value -eq $config.admin_group_sid }
        if ($member) {
            Remove-LocalGroupMember -SID $administratorsSid -Member $config.admin_group_sid
        }
    }
    Invoke-SealAction -Name 'build_profile' -Action {
        # The profile stays loaded until the last process of the build identity
        # has gone, which stopping WinRM brings about. Wait for that, bounded.
        $deadline = (Get-Date).AddSeconds(120)
        do {
            $userProfile = Get-BuildProfile -Sid $config.build_account_sid
            if (-not $userProfile -or -not $userProfile.Loaded) { break }
            Start-Sleep -Seconds 5
        } while ((Get-Date) -lt $deadline)

        if ($userProfile) {
            if ($userProfile.Loaded) {
                throw 'the profile is still loaded after 120 seconds'
            }
            Remove-CimInstance -InputObject $userProfile
        }
    }

    # Re-read everything. The result is what is there now, not what the steps
    # above believe they did.
    $after = Get-SealInventory -AdminGroupSid $config.admin_group_sid -BuildAccountSid $config.build_account_sid -SetupAccount $config.setup_account

    $problems = @()
    if (-not $dryRun) {
        $problems += @($after.items.Keys | Where-Object { $after.items[$_].present } | ForEach-Object { '{0} is still present ({1})' -f $_, $after.items[$_].detail })
        $problems += @(Test-AdministratorsMembership -Members $after.administrators -AdminGroupSid $config.admin_group_sid)
        $problems += @($actions | Where-Object { $_.outcome -like 'failed*' } | ForEach-Object { '{0} {1}' -f $_.item, $_.outcome })
    }
    if ([bool] $config.force_failure) {
        $problems += 'forced by SEAL_FORCE_FAILURE'
    }

    if ($problems.Count -gt 0) {
        $errorMessage = ($problems | Select-Object -Unique) -join '; '
    }
    else {
        $sealed = (-not $dryRun)
    }
}
catch {
    $errorMessage = $_.Exception.Message
}

# Kept short: it travels as one guestinfo value. Item names and booleans only.
$final = [ordered]@{
    schema_version = 1
    stage          = 'final'
    timestamp      = Get-UtcTimestamp
    execution_id   = [string] $config.execution_id
    computer_name  = $env:COMPUTERNAME
    sealed         = $sealed
    dry_run        = $dryRun
    error          = $errorMessage
    still_present  = @(if ($after) { $after.items.Keys | Where-Object { $after.items[$_].present } })
    actions        = $actions
    administrators = @(if ($after) { $after.administrators | ForEach-Object { [ordered]@{ name = $_.name; sid = $_.sid } } })
}

if ($dryRun) {
    # Nothing was changed, so nothing is reported to vCenter and the machine is
    # left alone. The result goes beside the configuration for inspection.
    Write-JsonFile -Path ($ConfigPath -replace '\.json$', '-final-dry-run.json') -Value $final
    Write-SealMessage 'dry run of the final stage finished. Nothing was changed.'
    exit 0
}

# Base64, because a JSON string does not survive being passed as a native
# command argument in Windows PowerShell: its quotes are stripped.
$encoded = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes(($final | ConvertTo-Json -Depth 5 -Compress))
)
$reported = $false
try {
    & $vmToolsDaemon --cmd ('info-set {0} {1}' -f $guestInfoKey, $encoded) | Out-Null
    $reported = ($LASTEXITCODE -eq 0)
}
catch {
    Add-Content -LiteralPath $finalLogPath -Value ('{0} report failed: {1}' -f (Get-UtcTimestamp), $_.Exception.Message)
}

if (-not $sealed -or -not $reported) {
    # Fail closed: the machine stays on, Packer fails on its shutdown timeout,
    # and the task, this script and the log are left for whoever looks.
    Add-Content -LiteralPath $finalLogPath -Value ('{0} NOT SEALED (reported={1}): {2}' -f (Get-UtcTimestamp), $reported, $errorMessage)
    exit 1
}

# Sealed. Remove the seal's own traces, then give the runner time to read the
# result before the machine goes off and the value with it.
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ConfigPath, $finalLogPath, $installedScriptPath -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds ([int] $config.hold_seconds)
& shutdown.exe /s /t 0 /f /d p:4:1 /c 'Packer build complete: image sealed'
exit 0
