<#
.SYNOPSIS
    Work in progress...
.DESCRIPTION
    Creates a container for caching Exchange Online mailbox data on non-persistent machines.
.NOTES
Recreating behavior described here: https://docs.fslogix.com/display/20170529/Concurrent+Office+365+Container+Access

General notes: 
    - Local difference disks are stored in the local temp directory and are named %usersid%_ODFC.VHD(X).
    - Difference disks stored on the network are located next to the parent VHD(X) file and are named %computername%_ODFC.VHD(X).
    - When the difference disk is stored on the network, the merge operation can be safely interrupted and continued.  If one 
        client begins the merge operation and is interrupted (e.g. powered off), another client can safely continue and complete the merge.
    - Merge operations on an ReFS file system (where the difference disk and the parent are on the same ReFS volume) are nearly 
        instantaneous no matter how big the difference disk is.
    - Merge operations can only be done if there are no open handles to either the difference disk or the parent VHD(X).  Therefore 
        only the last session will be able to successfully merge its difference disk.
    - Per-session VHD(X) files are named ODFC-%username%-SESSION-<sessionnumber>.VHD(X) where sessionnumber is an integer from 0 - 9.
    - The maximum number of per-session VHD(X) files is 10.

VHD access mode behavior varies by parameter set:

    Normal (Default):
        Logon: 
            Client tries to directly attach the VHD(X) file.  No difference disks are used.
            If a concurrent access is attempted, it will fail with a sharing violation (error 20).
        Logoff:
            Client detaches the VHD(X).
    
    Network:
        Logon:
            - Client attempts to open the merge.vhd(x) difference disk with Read/Write access.  If it is successful, 
              it merges the difference disk to the parent.  If it completes the merge, the difference disk file is deleted.
            - Client attempts to remove any previous difference disk for this machine (%computername%_ODFC.VHD(X)) on the network share.
            - Client creates a new difference disk named %computername%_ODFC.VHD(X). This difference disk is created on the network share 
              next to the parent VHD(X) file.
            - Client attaches the difference disk as the O365 VHD.
        Logoff:
            - Client detaches the difference disk.
            - Client attempts to rename the difference disk to merge.vhd(x). If this rename is successful, the client attempts to merge 
              the difference disk. This will only succeed if this is the last session that is ending.
            - Client deletes the difference disk.

    Local:
        Logon:
            - Client attempts to remove any previous difference disk (%usersid%_ODFC.VHD(X)) for this user from the temp folder.
            - Client creates a new difference disk named %usersid%_ODFC.VHD(X). This difference disk is created in the temp directory.
            - Client attaches the difference disk as the O365 VHD.
        Logoff:
            - Client detaches the difference disk.
            - Client attempts to merge the difference disk. This will only succeed if this is the last session that is ending.
            - Client deletes the difference disk.
    
    Per-Session:
        Logon:
            - Client searches for a per session VHD(X) that is not currently in use
            - If one is found, it is directly attached and used
            - If one is not found, one will be created and used
            - If a new VHD is created and this results in a number of per-session VHDs greater than the number specified to 
              keep (NumSessionVHDsToKeep), this VHD(X) is marked for deletion and will be deleted on logoff.
        Logoff:
            - Client detaches the VHD(X)
            - If the VHD(X) is marked for deletion, it is deleted
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Normal')]
param 
(
    [Parameter(ParameterSetName = 'Network', Mandatory)]
    [switch] $Network,

    [Parameter(ParameterSetName = 'Local', Mandatory)]
    [switch] $Local,

    [Parameter(ParameterSetName = 'PerSession', Mandatory)]
    [switch] $PerSession,

    [Parameter(ParameterSetName = 'Normal')]
    [Parameter(ParameterSetName = 'Network')]
    [Parameter(ParameterSetName = 'Local')]
    [Parameter(ParameterSetName = 'PerSession')]
    [ValidateScript({ $_ -gt 500mb })]
    [int64] $DiskSize = 10gb,

    [Parameter(ParameterSetName = 'Normal')]
    [Parameter(ParameterSetName = 'Network')]
    [Parameter(ParameterSetName = 'Local')]
    [Parameter(ParameterSetName = 'PerSession')]
    [ValidateScript({ Test-Path -Path $_ })]
    [string] $VDisk = 'D:\VHDTest\Base.vhdx',

    [Parameter(ParameterSetName = 'Normal')]
    [Parameter(ParameterSetName = 'Network')]
    [Parameter(ParameterSetName = 'Local')]
    [Parameter(ParameterSetName = 'PerSession')]
    [string] $DifferenceDisk = "D:\VHDTest\Diff-${env:COMPUTERNAME}.vhdx",

    [string] $MergeDisk = 'D:\VHDTest\Merge.vhdx'
)


try 
{ 
    Get-VHD -Path $VDisk -ErrorAction Stop 
    Write-Verbose "Found usable virtual disk: $VDisk"
}
catch 
{
    if (Test-Path -Path $VDisk) 
    { 
        Write-Warning "Removing unusable virtual disk: $VDisk"
        Remove-Item -Path $VDisk -Force 
    }
    
    Write-Verbose "Creating and formatting new virtual disk: $VDisk"
    New-VHD -Path $VDisk -SizeBytes $DiskSize | 
        Mount-VHD -PassThru | 
        Initialize-Disk -PassThru |
        New-Partition -AssignDriveLetter -UseMaximumSize |
        Format-Volume -FileSystem NTFS -Confirm:$false -Force

    Dismount-VHD -Path $VDisk
}

New-VHD -ParentPath $VDisk -Path $DifferenceDisk -Differencing | Mount-VHD

Dismount-VHD -Path $DifferenceDisk -Confirm:$false
Merge-VHD -Path $DifferenceDisk -DestinationPath -$VDisk -ErrorAction Continue
Remove-Item -Path $DifferenceDisk -Force
