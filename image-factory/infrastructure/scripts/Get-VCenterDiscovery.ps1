<#
.SYNOPSIS
Performs read-only discovery of a vCenter environment.

.DESCRIPTION
Authenticates to vCenter using environment variables (VCENTER_HOST, VCENTER_USERNAME, VCENTER_PASSWORD),
lists key inventory objects (datacenters, clusters, etc.), and writes sanitized output to a caller-supplied path.
Useful for validating connectivity and gathering input for Packer templates.

Workstation only, and run by hand. Nothing in the Makefile or CI calls it, by
design: it needs pwsh and VMware PowerCLI, neither of which is on the runner
image. Values it discovers are transcribed into configs/ by a person, not
consumed programmatically.

.PARAMETER EnvPath
Optional path to a .env file. Defaults to ".env" relative to the CURRENT
DIRECTORY, not to the repository root, so running this script from its own
directory finds nothing and falls through to the ambient environment. Run it
from the repository root, or pass the path explicitly.

Parsing it sets those variables for the whole process, including
VCENTER_PASSWORD. The parser does not skip comment lines and does not strip
surrounding quotes, so a quoted value in .env yields a password with literal
quote characters and an authentication failure that looks nothing like a
quoting problem.

.PARAMETER EvidencePath
Optional path to write discovery evidence (must resolve outside the public repository).
If not provided, no evidence file is written.
.EXAMPLE
# Use default .env file (repo root), no evidence written:
./Get-VCenterDiscovery.ps1

.EXAMPLE
# Use custom .env file:
./Get-VCenterDiscovery.ps1 -EnvPath "path/to/.env"

.EXAMPLE
# Write evidence to a private path:
./Get-VCenterDiscovery.ps1 -EvidencePath "C:\private\evidence\vcenter-discovery.json"

.NOTES
Requires PowerShell 7 and VMware PowerCLI (VMware.VimAutomation.Core), plus
network reachability to vCenter. Read-only: it creates and changes nothing.

Unlike the Packer scripts here, this does not set $ErrorActionPreference =
'Stop'. The Get-* calls below are therefore non-terminating, so a cmdlet that is
unavailable or fails leaves its section empty rather than stopping the script —
an empty contentLibraries array reads as "there are none" either way.
#>
param (
    [Parameter(Mandatory=$false)]
    [string]$EnvPath = ".env",
    [Parameter(Mandatory=$false)]
    [string]$EvidencePath
)

# Load .env file (if it exists)
if (Test-Path -Path $EnvPath) {
    Get-Content -Path $EnvPath | ForEach-Object {
        if ($_ -match '^\s*([^=]+)=(.*)') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            Set-Item -LiteralPath "Env:$key" -Value $value
        }
    }
}

# Validate required environment variables
$requiredVars = @("VCENTER_HOST", "VCENTER_USERNAME", "VCENTER_PASSWORD")
foreach ($var in $requiredVars) {
    $value = [Environment]::GetEnvironmentVariable($var)
    if ([string]::IsNullOrEmpty($value)) {
        throw "Environment variable $var is not set. Check $EnvPath or set it manually."
    }
}

$Server = [Environment]::GetEnvironmentVariable("VCENTER_HOST")
$Username = [Environment]::GetEnvironmentVariable("VCENTER_USERNAME")
$Password = [Environment]::GetEnvironmentVariable("VCENTER_PASSWORD")

# Create a secure string for the password
$securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential -ArgumentList @($Username, $securePassword)

# 1. Load VMware PowerShell module (fail if missing)
if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
    throw "VMware.VimAutomation.Core module not found. Install with: Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force"
}

# 2. Authenticate to vCenter
try {
    Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop | Out-Null
    Write-Output "Connected to vCenter: $Server"
}
catch {
    throw "Failed to authenticate to vCenter: $_"
}

# 3. Discover inventory
$discovery = @{
    timestamp   = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    server      = $Server
    datacenters = @()
    clusters    = @()
    datastores  = @()
    networks    = @()
    folders     = @()
    vms         = @()
    contentLibraries = @()
}

# Helper: trim whitespace from an inventory name.
#
# Despite where it is used, this performs no sanitization and removes nothing
# sensitive. What keeps site inventory out of the repository is the path guard
# at the end of this script, not this function.
function Format-Name {
    param([string]$Name)
    return $Name.Trim()
}

# 4. List Datacenters
$discovery.datacenters = (Get-Datacenter | Select-Object -Property @{Name="name"; Expression={Format-Name $_.Name}})

# 5. List Clusters
$discovery.clusters = (Get-Cluster | Select-Object -Property @{Name="name"; Expression={Format-Name $_.Name}})

# 6. List Datastores
$discovery.datastores = (Get-Datastore | Select-Object -Property @{Name="name"; Expression={Format-Name $_.Name}}, @{Name="type"; Expression={$_.Type}})

# 7. List Networks
$discovery.networks = (Get-VirtualPortGroup | Select-Object -Property @{Name="name"; Expression={Format-Name $_.Name}})

# 8. List Folders
$discovery.folders = (Get-Folder -Type VM | Select-Object -Property @{Name="path"; Expression={Format-Name $_.Name}})

# 9. List VMs (basic info only)
$discovery.vms = (Get-VM | Select-Object -Property @{Name="name"; Expression={Format-Name $_.Name}}, PowerState)

# 10. List Content Libraries (for ISO publication)
$discovery.contentLibraries = (Get-ContentLibrary | Select-Object -Property @{Name="name"; Expression={Format-Name $_.Name}}, @{Name="id"; Expression={$_.Id}})

# 11. Disconnect
Disconnect-VIServer -Server $Server -Confirm:$false

# 12. Write evidence only if EvidencePath is provided and resolves outside the
# repository.
#
# The discovery output names datacenters, clusters, datastores, networks and
# VMs. That is site inventory, and this repository is shared, so writing it
# anywhere inside the working tree is refused outright rather than relying on
# .gitignore. This block is the only thing enforcing that.
if ($EvidencePath) {
    # Determine repository root (prefer Git, fallback to script location)
    # The fallback encodes this script's depth in the tree, so moving the file
    # weakens the guard rather than breaking it visibly.
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if (-not $repoRoot) {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    }

    # Both paths are normalised to end with exactly one separator before the
    # comparison below. That trailing separator is the whole point: without it
    # "C:\repo-evidence" starts with "C:\repo" and the guard lets a sibling
    # directory through. It looks like redundant string fiddling and is not.
    # GetUnresolvedProviderPathFromPSPath is used because the path need not
    # exist yet.
    $repoRootCanonical = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($repoRoot).TrimEnd('\', '/') + '\'

    $evidencePathCanonical = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidencePath).TrimEnd('\', '/') + '\'

    # Check if EvidencePath is inside the repository (case-insensitive)
    if ($evidencePathCanonical.ToLower().StartsWith($repoRootCanonical.ToLower())) {
        throw "EvidencePath resolves inside the public repository. Provide a path outside the repository."
    }

    # Ensure the directory exists
    $evidenceDir = Split-Path -Path $evidencePathCanonical -Parent
    if (-not (Test-Path -Path $evidenceDir -PathType Container)) {
        New-Item -Path $evidenceDir -ItemType Directory -Force | Out-Null
    }

    # Write the file with UTF-8 encoding
    $discovery | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $evidencePathCanonical.TrimEnd('\') -Encoding utf8
    Write-Output "vCenter discovery evidence written to $($evidencePathCanonical.TrimEnd('\'))"
}

