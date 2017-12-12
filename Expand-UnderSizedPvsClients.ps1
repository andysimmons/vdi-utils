#requires -Version 4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param
(
    [string[]] 
    $VIServer = @('slbvdivc2', 'sltvdivc2'),

    [string] 
    $VMFolder = 'PVSClients',

    [int] 
    $NumDisks = 1,

    [string] 
    $WriteCacheDisk = 'Hard Disk 1',

    [int[]] 
    $ExpectedSizeGB = 12..16,

    [int]
    $NewSizeGB = 22,

    [ValidateScript({$_ -gt 0})]
    [int]
    $MaxBatchSize = 10
)

try
{
    Add-PSSnapin VMWare.VimAutomation.Core -ErrorAction 'Stop'
    Connect-VIServer -Server $VIServer -ErrorAction 'Stop'
}
catch
{
    Write-Error "Couldn't connect to one or more vCenter instances."
    throw $_.Exception
}

try
{
    $location = Get-Folder -Name $VMFolder -ErrorAction 'Stop' -Server $VIServer

    # There's no great way to just query exactly what we need from vCenter, so we'll build
    # a collection as specifically as possible first, and then pare it down from there.
    Write-Verbose "Retrieving VMs from $($location.Count) folder(s)..."
    $vms = $location | Get-VM -ErrorAction 'Stop' | Where-Object { [int] $_.ProvisionedSpaceGB -in $ExpectedSizeGB }
}
catch
{
    Write-Error "Couldn't retrieve VMs for analysis."
    throw $_.Exception
}

# With relatively small batch sizes, it'll be faster to check one machine at a time until
# we hit the batch limit, vs analyzing everything at once and trimming the excess.
$targets = [Collections.ArrayList] @()
$vmsInspected = 0

foreach ($vm in $vms)
{
    if ($targets.Count -ge $MaxBatchSize)
    {
        $remainder = $vms.Count - $vmsInspected
        if ($remainder -gt 0)
        {
            Write-Warning "Hit batch limit of $MaxBatchSize VMs. $remainder may still be broken after this pass."
        }
        break 
    }

    try
    { 
        # Get-HardDisk is way too verbose in this case
        $wcDisk = $vm | Get-HardDisk -Name $WriteCacheDisk -ErrorAction 'Stop' -Verbose:$false
        $vmsInspected++
    }
    catch 
    {
        Write-Warning $_.Exception.Message 
        continue 
    }

    if ($wcDisk.CapacityGB -notin $ExpectedSizeGB) { continue }
    if ($wcDisk.StorageFormat -ne 'Thin') 
    {
        Write-Warning "'$wcDisk' on '$vm' isn't thin provisioned. Skipping."
        continue
    }

    $target = [pscustomobject] [ordered] @{
        VirtualMachine = $vm
        WriteCacheDisk = $wcDisk
    }
    [void] $targets.Add($target)
}

foreach ($t in $targets)
{	
    $approxSizeGB = [math]::Round($t.WriteCacheDisk.CapacityGB, 1)
    $targetName   = '{0}: {1} ({2} GB)' -f $t.VirtualMachine, $t.WriteCacheDisk, $approxSizeGB
    $targetAction = "expand to $NewSizeGB GB"

    # Overriding the native Set-HardDisk "-WhatIf/-Confirm" behavior for clarity
    if ($PSCmdlet.ShouldProcess($targetName, $targetAction)) 
    {
        try
        {
            # Opting not to use -ResizeGuestPartition here due to deprecation warnings. Will
            # address that with a login script.
            $shdParams = @{
                HardDisk    = $t.WriteCacheDisk
                CapacityGB  = $NewSizeGB
                ErrorAction = 'Stop'
                WhatIf      = $false
                Confirm     = $false
                Verbose     = $false
            }
            Set-HardDisk @shdParams
        }
        catch
        { 
            Write-Error "$targetName couldn't be expanded!"
            Write-Error $_.Exception.Message
        }	
    }
}
