<#PSScriptInfo
.VERSION 1.1
.GUID 00000000-0000-0000-0000-000000000000
.AUTHOR Example Labs
.DESCRIPTION Deletes one Packer test VM, including its files, from vSphere.
#>

<#
.SYNOPSIS
    Deletes one Packer test VM from vSphere, including its files on the datastore.

.DESCRIPTION
    Removes exactly one VM, identified by its exact name. Wildcards are rejected,
    the name must contain 'packer-', and the script stops if the name matches
    more than one VM. A powered-on VM is powered off first.

    Deletion is permanent: the VM is removed from inventory and from disk.
    The script asks for confirmation unless -Force is given. Use -WhatIf to see
    what would be deleted without changing anything.

    The build floppy is deleted too, explicitly. Remove-VM -DeletePermanently
    does not delete a floppy image the VM has attached: OBSERVED 2026-09-28,
    packer-build-001 was deleted and packer-5494682361.flp stayed in its
    datastore folder, as it had in six earlier build folders. That image holds
    the rendered answer file, which contains the domain-join password, so
    leaving it behind leaves the credential on the datastore (STORY-02).
    Only images in the VM's own folder and named like Packer's are deleted;
    anything else attached is reported and left alone.

    This does not remove the computer object that the domain join created in
    Active Directory. Remove that separately, or use a new computer name for the
    next build.

    Requires VMware PowerCLI and the VCENTER_HOST, VCENTER_USERNAME and
    VCENTER_PASSWORD environment variables.

    Workstation only. The CI runner image has no pwsh and no PowerCLI, so no
    pipeline job calls this; a failed build's VM is retained deliberately
    (-on-error=abort) and removed by hand afterwards.

.PARAMETER VMName
    The exact name of the VM to delete. Wildcard characters are rejected rather
    than expanded, because Get-VM -Name would otherwise treat the value as a
    pattern and could match VMs that were not meant to be deleted.

    The name must contain 'packer-'. Note this is a substring test, so any VM
    whose name happens to contain that string qualifies; it is a guard against
    obvious mistakes, not an authorization check.

.PARAMETER Force
    Skip the confirmation prompt. Implemented by setting $ConfirmPreference in
    script scope rather than by passing -Confirm:$false, because ConfirmImpact
    is High: with a High impact the prompt is driven by the preference, and
    -Confirm:(-not $Force) would not suppress it. Do not "simplify" this.

    Note that `make clean-vm` invokes pwsh without -NonInteractive, so a prompt
    that is not suppressed blocks the caller rather than failing.

.EXAMPLE
    make clean-vm VM_NAME=packer-win11-001

    The normal entry point. Asks for confirmation.

.EXAMPLE
    make clean-vm VM_NAME=packer-win11-001 FORCE=1

    The same, without the prompt.

.EXAMPLE
    pwsh -File scripts/windows/Remove-PackerTestVm.ps1 -VMName packer-win11-001 -WhatIf

    Shows what would be deleted without changing anything. The Makefile does not
    forward -WhatIf, so run the script directly for a dry run.

.NOTES
    List candidate VMs first with `make list-vms`.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $VMName,

    # Skip the confirmation prompt.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Get-VM -Name treats the value as a wildcard pattern, so reject patterns and
# names that do not look like Packer test VMs before connecting anywhere.
if ($VMName -match '[\*\?\[\]]') {
    throw "VMName must be an exact VM name. Wildcards are not allowed: $VMName"
}

if ($VMName -notlike '*packer-*') {
    throw "Refusing to delete '$VMName'. Packer test VM names must contain 'packer-'."
}

foreach ($variableName in 'VCENTER_HOST', 'VCENTER_USERNAME', 'VCENTER_PASSWORD') {
    if (-not (Test-Path -Path "env:$variableName")) {
        throw "The $variableName environment variable is not set."
    }
}

if (-not (Get-Module -ListAvailable -Name 'VMware.VimAutomation.Core')) {
    throw 'VMware PowerCLI is not installed (module VMware.VimAutomation.Core).'
}

if ($Force) {
    $ConfirmPreference = 'None'
}

try {
    $securePassword = ConvertTo-SecureString -String $env:VCENTER_PASSWORD -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new($env:VCENTER_USERNAME, $securePassword)

    Connect-VIServer -Server $env:VCENTER_HOST -Credential $credential | Out-Null

    # SilentlyContinue turns "no such VM" into an empty result so the friendly
    # message below can handle it. It also swallows connection and permission
    # errors, which then read as "VM not found" and exit 0 — a fail-open path in
    # a repository that is otherwise fail-closed. Acceptable only because the
    # consequence is failing to delete something, never deleting the wrong thing.
    $matchingVms = @(Get-VM -Name $VMName -ErrorAction SilentlyContinue)

    if ($matchingVms.Count -eq 0) {
        Write-Host "VM not found: $VMName"
        # Returns through the finally block below, so this exits 0. Deleting an
        # already-absent VM is treated as success, which makes the target safe
        # to re-run.
        return
    }

    if ($matchingVms.Count -gt 1) {
        throw "Found $($matchingVms.Count) VMs named '$VMName'. Refusing to delete; remove the extra VMs manually."
    }

    $vm = $matchingVms[0]

    # Collected before deletion: once the VM is gone nothing records which
    # image it had attached. Paths are "[datastore] folder/file".
    $vmFolder = ($vm.ExtensionData.Config.Files.VmPathName -replace '/[^/]*$', '')
    $floppyImages = @()
    foreach ($imagePath in @(Get-FloppyDrive -VM $vm | ForEach-Object { $_.FloppyImagePath } | Where-Object { $_ })) {
        if ($imagePath -match '^(.*)/packer-\d+\.flp$' -and $Matches[1] -eq $vmFolder) {
            $floppyImages += $imagePath
        }
        else {
            Write-Warning "Not deleting attached floppy image outside the VM's folder or not named by Packer: $imagePath"
        }
    }
    # Resolved now for the same reason: Get-Datacenter -VM needs the VM to exist.
    $datacenterRef = (Get-Datacenter -VM $vm).ExtensionData.MoRef

    $action = 'Power off if needed and delete permanently, including files on disk'
    if ($floppyImages.Count -gt 0) {
        $action += " and floppy image(s) $($floppyImages -join ', ')"
    }

    if ($PSCmdlet.ShouldProcess($vm.Name, $action)) {
        if ($vm.PowerState -eq 'PoweredOn') {
            Write-Host "Powering off VM: $($vm.Name)"
            Stop-VM -VM $vm -Confirm:$false | Out-Null
        }

        Write-Host "Deleting VM and its files: $($vm.Name)"
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false
        Write-Host "Deleted VM: $VMName"

        # After Remove-VM, because the image cannot be deleted while attached.
        # A failure here throws: the VM is already gone, and a surviving image
        # is exactly the credential exposure this step exists to close.
        if ($floppyImages.Count -gt 0) {
            $fileManager = Get-View (Get-View ServiceInstance).Content.FileManager
            foreach ($imagePath in $floppyImages) {
                $fileManager.DeleteDatastoreFile($imagePath, $datacenterRef)
                Write-Host "Deleted floppy image: $imagePath"
            }
        }
    }
}
finally {
    # -Server * closes every PowerCLI session in this process, not only the one
    # opened above. Harmless for a one-shot script; surprising if you dot-source
    # it into a session that already had connections open.
    Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
}
