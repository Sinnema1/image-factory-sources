<#
    VMware Tools and WinRM bootstrap for the Packer communicator.

    Runs during the specialize pass as SYSTEM, invoked from autounattend.xml.

    Transport: HTTPS on TCP 5986 with a per-build self-signed certificate.
    TLS provides message protection, so the WinRM service keeps its default
    AllowUnencrypted = false. Packer's NTLM client authenticates but does not
    encrypt WinRM messages, so it cannot use the HTTP listener on 5985.

    This script records, but never changes, WinRM service settings such as
    AllowUnencrypted, Basic authentication, CbtHardeningLevel, or anything
    enforced by Group Policy.

    Build artifacts the pre-seal cleanup stage must remove. This list, the one in
    ADR 0002 and the one in ADR 0001 are the same contract and must not disagree;
    check all three when any changes
    (docs/decisions/0002-master-image-identity-and-sealing.md). Since 2026-10-08
    there is a fourth copy, and it is the one that acts:
    packer/provisioners/Invoke-ImageSeal.ps1 removes these BY THE NAMES DEFINED
    BELOW and fails if it cannot find them, so a renamed rule or certificate
    here must be renamed there:
      - Certificate in Cert:\LocalMachine\My with FriendlyName
        'Packer WinRM build certificate'
      - WinRM listener Address=*, Transport=HTTPS
      - Firewall rule 'Packer WinRM HTTPS 5986'
      - The administrative group mapped into local Administrators at the end of
        this script. It grants standing access to every clone of the image.
        Remove it by SID; do not clear the group, which also holds Domain Admins.
      - LocalAccountTokenFilterPolicy. Nothing here sets it by name, but
        Enable-PSRemoting below sets it to 1 (OBSERVED 2026-09-28).
      - defaultuser0, an enabled local administrator left by the unfinished OOBE
        pass. Removed for free under ADR 0002 option A; a manual entry under B.
        (Removed by Remove-BuildArtifact.ps1 since 2026-10-02.)
      - Everything else Enable-PSRemoting turns on, since the decision on
        2026-10-08 that a sealed image has remote management at the Windows
        default: the default HTTP listener on 5985, the built-in Windows Remote
        Management firewall rules (disabled, not deleted), the remoting
        endpoints, and the WinRM service set back to manual and stopped.
      - The build identity's profile under C:\Users.

    Already handled, so NOT on the list above: the cached answer files in
    C:\Windows\Panther (both copies, one of which holds the join password in
    plaintext), C:\Packer\staging, and this script's own transcript. The build's
    last provisioner removes those — see packer/provisioners/Remove-BuildArtifact.ps1.
    It deliberately stops short of the items above, because the WinRM channel has
    to survive until the shutdown command.
#>

[CmdletBinding()]
param(
    # IPv4 address of the Packer runner. The HTTPS firewall rule is scoped to it,
    # so the guest accepts WinRM from the runner and from nowhere else.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $PackerRunnerSourceIp,

    # SID of the domain group to map into local Administrators, as a string.
    #
    # A SID rather than a name for an observed reason, not a precaution: during
    # specialize, Add-LocalGroupMember -Member 'DOMAIN\GROUP' failed with "the
    # principal could not be found", and the same VM resolved the same name
    # successfully once it had progressed into OOBE. The group existed and the
    # domain join was healthy; name resolution simply is not reliably available
    # this early. The SID sidesteps that timing dependency.
    #
    # This is the value that does the work. AdminGroupName below is only used in
    # log messages.
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^S-1-5-21-(\d+-){3}\d+$')]
    [string] $AdminGroupSid,

    # Display name of that group, for the build log only. Nothing resolves it.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $AdminGroupName
)

$bootstrapLog = 'C:\Windows\Temp\enable-winrm-bootstrap.log'
$transcriptStarted = $false

# The three names below are the pre-seal cleanup contract: the sealing stage
# finds these artifacts by exactly these strings, and they are repeated in this
# file's header and in ADR 0001. Change one and all four places must change.
#
# The rule name embeds the port, so changing $winRMHttpsPort alone leaves a
# correctly scoped rule with a misleading name.
$winRMHttpsPort = 5986
$httpsFirewallRuleName = 'Packer WinRM HTTPS 5986'
$legacyHttpFirewallRuleName = 'Packer WinRM HTTP 5985'
$buildCertificateFriendlyName = 'Packer WinRM build certificate'
$httpsListenerSelector = @{
    Address   = '*'
    Transport = 'HTTPS'
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-HttpsListener {
    # Returns the HTTPS listener, or $null when none exists.
    try {
        return Get-WSManInstance `
            -ResourceURI 'winrm/config/Listener' `
            -SelectorSet $httpsListenerSelector `
            -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-TlsEndpointThumbprint {
    # Completes a TLS handshake with the endpoint and returns the thumbprint
    # of the certificate it presents. No authentication or HTTP request is
    # sent. Certificate trust is not evaluated; the caller compares the
    # thumbprint with the certificate it expects.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName,

        [Parameter(Mandatory = $true)]
        [int] $Port,

        [int] $TimeoutMilliseconds = 10000
    )

    $tcpClient = [System.Net.Sockets.TcpClient]::new()

    try {
        # Begin/WaitOne/EndConnect rather than the simpler Connect() because
        # TcpClient.Connect has no timeout parameter: on an unreachable port it
        # blocks for the OS default, which is long enough to look like a hang.
        # This is the only way to bound the wait, so do not simplify it.
        $connection = $tcpClient.BeginConnect($ComputerName, $Port, $null, $null)

        if (-not $connection.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            throw ('TCP connection to {0}:{1} timed out.' -f $ComputerName, $Port)
        }

        $tcpClient.EndConnect($connection)

        # Accepts any certificate on purpose. The point of this function is to
        # read back which certificate the listener presents so the caller can
        # compare thumbprints; validating the chain would reject the per-build
        # self-signed certificate before it could be inspected.
        $acceptAnyCertificate = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            return $true
        }

        $sslStream = [System.Net.Security.SslStream]::new(
            $tcpClient.GetStream(),
            $false,
            $acceptAnyCertificate
        )

        try {
            $sslStream.AuthenticateAsClient($ComputerName)

            $remoteCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $sslStream.RemoteCertificate
            )

            return $remoteCertificate.Thumbprint
        }
        finally {
            $sslStream.Dispose()
        }
    }
    finally {
        $tcpClient.Dispose()
    }
}

function Write-WinRMConfiguration {
    # Writes WinRM configuration to the transcript as evidence. Failures are
    # reported but never stop the bootstrap.
    param(
        [Parameter(Mandatory = $true)]
        [string] $Operation,

        [Parameter(Mandatory = $true)]
        [string] $ResourcePath
    )

    # Native-command stderr under ErrorActionPreference 'Stop' would
    # terminate the script, so relax it for this evidence-only capture.
    $ErrorActionPreference = 'Continue'

    Write-Host ('--- winrm {0} {1} ---' -f $Operation, $ResourcePath)

    $output = & winrm $Operation $ResourcePath 2>&1

    $output | ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        Write-Host (
            'winrm {0} {1} returned exit code {2}; continuing.' -f
            $Operation,
            $ResourcePath,
            $LASTEXITCODE
        )
    }
}

try {
    Start-Transcript -Path $bootstrapLog -Append -Force
    $transcriptStarted = $true
    Write-Host 'Starting VMware Tools and WinRM bootstrap.'

    # ------------------------------------------------------------------
    # VMware Tools
    # ------------------------------------------------------------------

    $toolsInstaller = $null

    Write-Host 'Searching attached optical media for VMware Tools.'

    # 60 attempts at 5s below is a five-minute bound: the Tools ISO is attached
    # at boot but the drive is not always enumerated by the time specialize runs.
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        # DriveType 5 is CD-ROM in Win32_LogicalDisk.
        $opticalDrives = Get-CimInstance Win32_LogicalDisk |
            Where-Object DriveType -eq 5

        foreach ($drive in $opticalDrives) {
            $driveRoot = "$($drive.DeviceID)\"
            $setupPath = Join-Path $driveRoot 'setup.exe'
            $upgraderPath = Join-Path $driveRoot 'VMwareToolsUpgrader.exe'
            $manifestPath = Join-Path $driveRoot 'manifest.txt'

            Write-Host (
                "Inspecting optical drive $driveRoot with volume label '$($drive.VolumeName)'."
            )

            # Two ISOs are attached (see iso_paths in the Packer template), and
            # both have a setup.exe at their root. Testing for setup.exe alone
            # would pick whichever drive enumerated first and then run Windows
            # Setup instead of the Tools installer. The second test is what
            # distinguishes them, so do not simplify this condition.
            if (
                (Test-Path $setupPath) -and (
                    (Test-Path $upgraderPath) -or
                    (Test-Path $manifestPath)
                )
            ) {
                $toolsInstaller = $setupPath
                break
            }
        }

        if ($toolsInstaller) {
            break
        }

        Start-Sleep -Seconds 5
    }

    if (-not $toolsInstaller) {
        throw 'VMware Tools setup.exe was not found on attached optical media.'
    }

    Write-Host "VMware Tools installer located at $toolsInstaller."

    # REBOOT=R suppresses the installer's automatic restart. A reboot here would
    # interrupt specialize and leave WinRM unconfigured, which is the same reason
    # autounattend.xml sets WillReboot Never on the command that runs this
    # script. Both halves of that contract must stay in step.
    #
    # Nested quoting is deliberate: /S is setup.exe's own silent switch, and
    # everything inside /v"..." is passed through to the MSI.
    $installerArguments = '/S /v"/qn REBOOT=R"'

    Write-Host 'Installing VMware Tools silently.'

    $startProcessParameters = @{
        FilePath     = $toolsInstaller
        ArgumentList = $installerArguments
        Wait         = $true
        PassThru     = $true
    }

    $installProcess = Start-Process @startProcessParameters

    Write-Host (
        'VMware Tools installer returned exit code {0}.' -f
        $installProcess.ExitCode
    )

    if ($installProcess.ExitCode -notin 0, 3010) {
        throw (
            'VMware Tools installation failed with exit code {0}.' -f
            $installProcess.ExitCode
        )
    }

    if ($installProcess.ExitCode -eq 3010) {
        Write-Host (
            'VMware Tools installed successfully and requested a Windows restart.'
        )
    }

    Write-Host 'Confirming the VMware Tools service is installed.'

    $toolsService = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue

    if (-not $toolsService) {
        throw (
            'VMware Tools installer completed, but the VMTools service was not found.'
        )
    }

    Set-Service -Name 'VMTools' -StartupType Automatic

    if ($toolsService.Status -ne 'Running') {
        Write-Host 'Starting the VMware Tools service.'

        Start-Service -Name 'VMTools'

        # Re-fetched, not redundant: a ServiceController's Status is a snapshot
        # taken when the object was created, so the variable above still reports
        # the pre-start state. The same applies to the re-fetch below.
        $toolsService = Get-Service -Name 'VMTools'

        $toolsService.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Running,
            [Timespan]::FromSeconds(60)
        )
    }

    $toolsService = Get-Service -Name 'VMTools'

    if ($toolsService.Status -ne 'Running') {
        throw 'The VMware Tools service is not running.'
    }

    Write-Host 'VMware Tools service is running.'

    # ------------------------------------------------------------------
    # WinRM service
    # ------------------------------------------------------------------

    Write-Host 'Configuring WinRM for the Packer communicator.'

    Set-Service -Name 'WinRM' -StartupType Automatic

    # Enable-PSRemoting also creates the default HTTP listener on 5985 and the
    # built-in Windows Remote Management firewall rules. Both are left as
    # Windows creates them; the HTTP listener still requires encrypted
    # messages, so Packer does not use it.
    #
    # -SkipNetworkProfileCheck because the NIC's profile is still Public at this
    # point in specialize: the domain join has happened but Windows has not yet
    # classified the network, and without the switch Enable-PSRemoting refuses.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck

    Start-Service -Name 'WinRM'

    $winRMService = Get-Service -Name 'WinRM'

    if ($winRMService.Status -ne 'Running') {
        throw 'The WinRM service is not running.'
    }

    # ------------------------------------------------------------------
    # Build certificate and HTTPS listener
    # ------------------------------------------------------------------

    if (Get-HttpsListener) {
        Write-Host 'Removing the existing WinRM HTTPS listener.'

        Remove-WSManInstance `
            -ResourceURI 'winrm/config/Listener' `
            -SelectorSet $httpsListenerSelector
    }

    $staleCertificates = @(
        Get-ChildItem -Path 'Cert:\LocalMachine\My' |
            Where-Object FriendlyName -eq $buildCertificateFriendlyName
    )

    foreach ($staleCertificate in $staleCertificates) {
        Write-Host (
            'Removing stale build certificate {0}.' -f
            $staleCertificate.Thumbprint
        )

        $staleCertificate | Remove-Item
    }

    # Packer connects by IP address with winrm_insecure = true, so the
    # certificate subject is informational only.
    $certificateDnsName = $env:COMPUTERNAME

    if (-not $certificateDnsName) {
        $certificateDnsName = 'localhost'
    }

    Write-Host (
        'Creating self-signed build certificate for {0}.' -f
        $certificateDnsName
    )

    $certificateParameters = @{
        DnsName           = $certificateDnsName
        CertStoreLocation = 'Cert:\LocalMachine\My'
        FriendlyName      = $buildCertificateFriendlyName
        KeyAlgorithm      = 'RSA'
        KeyLength         = 2048
        HashAlgorithm     = 'SHA256'
        KeyExportPolicy   = 'NonExportable'
        # Tolerate guest clock skew before VMware Tools time sync settles.
        NotBefore         = (Get-Date).AddDays(-1)
        NotAfter          = (Get-Date).AddDays(30)
    }

    $buildCertificate = New-SelfSignedCertificate @certificateParameters

    Write-Host (
        'Build certificate thumbprint: {0}.' -f
        $buildCertificate.Thumbprint
    )

    Write-Host 'Creating the WinRM HTTPS listener.'

    New-WSManInstance `
        -ResourceURI 'winrm/config/Listener' `
        -SelectorSet $httpsListenerSelector `
        -ValueSet @{ CertificateThumbprint = $buildCertificate.Thumbprint } |
        Out-Null

    $httpsListener = Get-HttpsListener

    if (-not $httpsListener) {
        throw 'The WinRM HTTPS listener was not found after creation.'
    }

    # WSMan returns these as strings, not as the types they look like, so the
    # casts are what make the comparisons work. Drop a [string] and the test
    # compares a string to a boolean or an integer, never matches, and the
    # bootstrap throws on a listener that is in fact correct.
    if ([string] $httpsListener.Enabled -ne 'true') {
        throw 'The WinRM HTTPS listener is not enabled.'
    }

    if ([string] $httpsListener.Port -ne [string] $winRMHttpsPort) {
        throw (
            'The WinRM HTTPS listener is on port {0}, expected {1}.' -f
            $httpsListener.Port,
            $winRMHttpsPort
        )
    }

    # .Trim() is required, not defensive: WSMan returns the thumbprint with
    # surrounding whitespace, so an untrimmed comparison never matches and this
    # throws on a correctly bound listener.
    if (
        ([string] $httpsListener.CertificateThumbprint).Trim() -ne
        $buildCertificate.Thumbprint
    ) {
        throw (
            'The WinRM HTTPS listener is bound to certificate {0}, expected {1}.' -f
            $httpsListener.CertificateThumbprint,
            $buildCertificate.Thumbprint
        )
    }

    Write-Host (
        'WinRM HTTPS listener is enabled on TCP {0} with the build certificate.' -f
        $winRMHttpsPort
    )

    # ------------------------------------------------------------------
    # Firewall
    # ------------------------------------------------------------------

    Write-Host (
        'Configuring the Packer WinRM HTTPS firewall rule for runner source {0}.' -f
        $PackerRunnerSourceIp
    )

    # Remove the rule created by the earlier HTTP-based bootstrap, if present.
    Remove-NetFirewallRule -DisplayName $legacyHttpFirewallRuleName -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName $httpsFirewallRuleName -ErrorAction SilentlyContinue

    $firewallParameters = @{
        DisplayName   = $httpsFirewallRuleName
        Direction     = 'Inbound'
        Action        = 'Allow'
        Protocol      = 'TCP'
        LocalPort     = $winRMHttpsPort
        RemoteAddress = $PackerRunnerSourceIp
        Profile       = 'Any'
    }

    New-NetFirewallRule @firewallParameters | Out-Null

    # ------------------------------------------------------------------
    # Readiness: TLS handshake on 5986 presents the build certificate
    # ------------------------------------------------------------------
    # What this proves: the listener is up and bound to the certificate this
    # script created, before the build hands control to Packer.
    #
    # What it does NOT prove: that the Packer runner can reach the guest. The
    # handshake is to 127.0.0.1, and loopback traffic never traverses the
    # firewall, so the RemoteAddress scoping on the rule created above is not
    # exercised here. A rule scoped to the wrong address passes this check and
    # then fails as a WinRM timeout on the runner. The runner's own connection
    # is the only test of reachability.
    #
    # 12 attempts at 5s is a one-minute bound. The listener is normally ready on
    # the first or second attempt; the loop covers the gap between the listener
    # being registered and the port accepting connections.

    $presentedThumbprint = $null
    $lastTlsError = $null

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            $presentedThumbprint = Get-TlsEndpointThumbprint `
                -ComputerName '127.0.0.1' `
                -Port $winRMHttpsPort

            break
        }
        catch {
            $lastTlsError = $_.Exception.Message

            Write-Host (
                'TLS readiness attempt {0} failed: {1}' -f
                $attempt,
                $lastTlsError
            )

            Start-Sleep -Seconds 5
        }
    }

    if (-not $presentedThumbprint) {
        throw (
            'The TLS readiness check on TCP {0} failed: {1}' -f
            $winRMHttpsPort,
            $lastTlsError
        )
    }

    if ($presentedThumbprint -ne $buildCertificate.Thumbprint) {
        throw (
            'TCP {0} presented certificate {1}, expected {2}.' -f
            $winRMHttpsPort,
            $presentedThumbprint,
            $buildCertificate.Thumbprint
        )
    }

    Write-Host (
        'WinRM HTTPS on TCP {0} completed a TLS handshake with the build certificate.' -f
        $winRMHttpsPort
    )

    # ------------------------------------------------------------------
    # Evidence: effective WinRM configuration (read-only)
    # ------------------------------------------------------------------

    Write-WinRMConfiguration -Operation 'enumerate' -ResourcePath 'winrm/config/listener'
    Write-WinRMConfiguration -Operation 'get' -ResourcePath 'winrm/config/service'
    Write-WinRMConfiguration -Operation 'get' -ResourcePath 'winrm/config/service/auth'

    # ------------------------------------------------------------------
    # Administrative group mapping
    # ------------------------------------------------------------------
    # Grants a domain group local administrator rights in the guest. This is a
    # pre-seal cleanup item: it survives into every clone of the image, so the
    # sealing stage must remove it (see the list at the top of this file).
    #
    # Both values come from the caller so the group is not baked into a tracked
    # script. They arrive from admin_group_sid / admin_group_name in the Packer
    # template, through autounattend.xml.

    $administrativeGroup = $AdminGroupName
    $administratorsGroup = 'Administrators'

    $administrativeGroupSid = [System.Security.Principal.SecurityIdentifier]::new(
        $AdminGroupSid
    )

    Write-Host (
        'Mapping {0} to local {1} by SID.' -f
        $administrativeGroup,
        $administratorsGroup
    )

    $existingMember = Get-LocalGroupMember -Group $administratorsGroup |
        Where-Object {
            $_.SID -and
            $_.SID.Value -eq $administrativeGroupSid.Value
        }

    if (-not $existingMember) {
        # .Value, not the SecurityIdentifier object: passing the object directly
        # failed parameter binding on Add-LocalGroupMember, so the string form is
        # what actually works here.
        $addGroupParameters = @{
            Group  = $administratorsGroup
            Member = $administrativeGroupSid.Value
        }

        Add-LocalGroupMember @addGroupParameters
    }

    $verifiedMember = Get-LocalGroupMember -Group $administratorsGroup |
        Where-Object {
            $_.SID -and
            $_.SID.Value -eq $administrativeGroupSid.Value
        }

    if (-not $verifiedMember) {
        throw (
            'Failed to map {0} to local {1}.' -f
            $administrativeGroup,
            $administratorsGroup
        )
    }

    Write-Host (
        '{0} is mapped to local {1}.' -f
        $administrativeGroup,
        $administratorsGroup
    )

    Write-Host 'VMware Tools and WinRM bootstrap completed successfully.'
}
catch {
    Write-Host 'VMware Tools and WinRM bootstrap failed.'
    Write-Host $_.Exception.Message

    $_ |
        Format-List * -Force |
        Out-String |
        Write-Host

    throw
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript
        }
        catch {
            # The transcript may already be stopped during Windows shutdown.
        }
    }
}