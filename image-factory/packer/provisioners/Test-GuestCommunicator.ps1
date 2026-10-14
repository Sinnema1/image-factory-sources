<#
    Proves that the WinRM session Packer uses is the expected administrative
    service account, and records a sanitized result.

    Runs as the first Packer provisioner, before any package staging. If it
    fails, the build stops and staging never starts.

    Inputs (environment variables):
      EXPECTED_IDENTITY  the account the session must run as (DOMAIN\account)
      RESULT_PATH        where to write the JSON result
      COMMUNICATOR       communicator type, recorded as given (for example winrm)
      TRANSPORT          transport, recorded as given (for example https)
      AUTHENTICATION     authentication method, recorded as given (for example ntlm)
      VM_NAME            name of the temporary VM, recorded as given

    How they arrive matters. This script is uploaded by a `file` provisioner and
    then called from a `powershell` inline block that sets each variable with a
    direct $env: assignment and ends with `exit $LASTEXITCODE`. It does NOT use
    Packer's environment_vars, which did not reach this script when it ran as
    the first command after a fresh reboot: the script executed, but
    EXPECTED_IDENTITY was empty inside it. Remove-BuildArtifact.ps1 runs later
    in the build and does use environment_vars.

    So this file depends on that invocation shape. Switching it to
    environment_vars, or dropping the `exit $LASTEXITCODE`, makes the exit code
    below stop failing the build. See the provisioner comments in
    packer/templates/windows-11-vsphere.pkr.hcl.

    The result and the console output contain no account name, password or
    other authentication material, only booleans, the computer name and the
    values above. A JSON result is written whether the check passes or fails,
    provided RESULT_PATH is set; if it is not, nothing is written and the
    template's download provisioner fails with a missing-file error rather than
    the real reason. Any failure exits with code 1.

    Windows PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$expectedIdentity = $env:EXPECTED_IDENTITY
$resultPath = $env:RESULT_PATH

$isAdministrator = $false
$identityMatches = $false
$passed = $false
$errorMessage = $null

try {
    foreach ($pair in @(
            @('EXPECTED_IDENTITY', $expectedIdentity),
            @('RESULT_PATH', $resultPath)
        )) {
        if ([string]::IsNullOrWhiteSpace($pair[1])) {
            throw ('Required environment variable {0} is not set.' -f $pair[0])
        }
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)

    $isAdministrator = $principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
    $identityMatches = [string]::Equals(
        $identity.Name,
        $expectedIdentity,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $identityMatches) {
        throw 'The session identity does not match the expected service account.'
    }

    if (-not $isAdministrator) {
        throw 'The session does not have administrative access.'
    }

    $passed = $true
}
catch {
    $errorMessage = $_.Exception.Message
}

Write-Host (
    'Guest communicator check: identity_matches_expected={0} is_administrator={1} computer_name={2}' -f
    $identityMatches, $isAdministrator, $env:COMPUTERNAME
)

if (-not [string]::IsNullOrWhiteSpace($resultPath)) {
    $result = [ordered]@{
        schema_version           = 1
        timestamp                = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        passed                   = $passed
        error                    = $errorMessage
        vm_name                  = $env:VM_NAME
        computer_name            = $env:COMPUTERNAME
        communicator             = $env:COMMUNICATOR
        transport                = $env:TRANSPORT
        authentication           = $env:AUTHENTICATION
        # Inferred, not measured. This script runs inside the authenticated WinRM
        # session, so its own execution is the evidence: if authentication had
        # failed, nothing here would run and no result file would exist at all.
        # Named to say so, because an auditor reading a bare `authenticated: true`
        # would take it for a check this script performed.
        authenticated_by_inference = $true
        remote_command_result    = if ($passed) { 'passed' } else { 'failed' }
        identity_matches_expected = $identityMatches
        is_administrator         = $isAdministrator
    }

    # UTF-8 without a byte order mark, so the runner's jq can read it.
    $json = $result | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText(
        $resultPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

if (-not $passed) {
    Write-Host ('Guest communicator check failed: {0}' -f $errorMessage)
    exit 1
}

Write-Host 'Guest communicator check passed.'
exit 0
