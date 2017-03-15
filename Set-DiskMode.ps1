<#
.NOTES
    Created on:   3/14/2017
    Created by:   Andy Simmons
    Organization: St. Luke's Health System
    Filename:     Set-DiskMode.ps1

.SYNOPSIS
    Sets the virtual disk mode en masse.

.DESCRIPTION
    XenDesktop Setup Wizard creates a write cache disk in "IndependentPersistent" mode,
    which breaks the ability to capture that disk in a snapshot, which breaks the option
    to Storage vMotion, which neuters Storage DRS.

    This script provides a workaround to remediate it, and should be run after creating
    additional machines from the XD Setup Wizard (not necessary if using the Streaming Wizard).

.PARAMETER VIServer
    One or more vCenter servers.

.PARAMETER VMPattern
    Regular expression used to match virtual machine names.

.PARAMETER Location
    VM folder name to use as the search root.

.PARAMETER TargetMode
    The desired disk mode (usually 'Persistent').

.PARAMETER MaxBatchSize
    Maximum number of machines to change at once.

.PARAMETER IncludeStragglerDetail
    Generates a report after the script runs with details about stragglers (can be slow).

.EXAMPLE
    Set-DiskMode.ps1 -VIServer ('slbvdivc2','sltvdivc2') -VMPattern 'XD[BT][PNDT]\d{2}' -TargetMode 'Persistent' -Location 'Non-Persistent VDI Desktops'

    This would find all virtual machines within either slbvdivc2 or sltvdivc2 inventories, nested somewhere inside the location specified,
    matching the pattern specified, and attempt to set the disk mode to 'Persistent' (which is implicitly dependent) on all powered-off VMs.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]
    $VIServer = ('slbvdivc2','sltvdivc2'),

    [regex]
    $VMPattern = "XD[BT][PNDT]\d{2}",

    [Parameter(Mandatory)]
    [ValidateSet('Persistent','IndependentPersistent','IndependentNonPersistent')]
    [string]
    $TargetMode,

    [string]
    $Location = 'Non-Persistent VDI Desktops',

    [int]
    $MaxBatchSize = [int]::MaxValue, 

    [switch]
    $IncludeStragglerDetail
)

Add-PSSnapin VMWare.VimAutomation.Core -ErrorAction Stop
Connect-VIServer -Server $VIServer -ErrorAction Stop

Write-Verbose "Getting '${Location}' VIContainer objects..."
$viContainers = Get-Folder -Server $VIServer -Name $Location -ErrorAction Stop

# Get-VM has no regex filter, so just grab all VMs that are somewhere inside $Location, 
# and pull matches from those results.
Write-Verbose "Getting '${VMPattern}' VMs..."
$vms = Get-VM -Location $viContainers | Where-Object {$_.Name -match $VMPattern}
$fixableVMs = @($vms | Where-Object {$_.PowerState -eq 'PoweredOff'})

# If any of those VMs are powered off, find and remediate any misconfigured disks.
if ($fixableVMs.Count -gt 0)
{
    Write-Verbose "Found $($fixableVMs.Count) powered-off VMs. Checking for misconfigured vDisks..."
    $fixableDisks = @(Get-HardDisk -VM $fixableVMs | Where-Object {$_.Persistence -ne $TargetMode})  
    
    if ($fixableDisks.Count -gt $MaxBatchSize) 
    {
        $fixableSurplus = $fixableDisks.Count - $MaxBatchSize
        Write-Warning "Found $($fixableDisks.Count) misconfigured disks in powered-off VMs, which is greater"
        Write-Warning "than the max allowed batch size of ${MaxBatchSize}. Skipping ${fixableSurplus} VMs."
        $fixableDisks = $fixableDisks | Select-Object -First $MaxBatchSize
    }

    Write-Verbose "Fixing $($fixableDisks.Count) misconfigured vDisks..."
    $fixableDisks | Set-HardDisk -Persistence $TargetMode 
}

# Summarize anything we might have missed due to VM power state.
$unfixableVMs = @($vms | Where-Object {$_.PowerState -eq 'PoweredOn'})
$unfixableDisks = @(Get-HardDisk -VM $unfixableVMs | Where-Object {$_.Persistence -ne $TargetMode})

if ($unfixableDisks.Count -gt 0)
{
    Write-Warning "Couldn't attempt remediation on $($unfixableDisks.Count) misconfigured vDisks, because the parent VM is currently powered-on."
    
    if ($IncludeStragglerDetail)
    {
        Write-Verbose "Generating straggler details... this might take a bit."
        $unfixableDisks | Select-Object Parent,Name,CapacityGB,Persistence,FileName | Format-Table | Out-String | Write-Warning
    }
}
