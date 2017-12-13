<#
.SYNOPSIS

.DESCRIPTION

.PARAMETER vDiskDrive

.PARAMETER TempFolderName

.PARAMETER TempFileName

.PARAMETER MinFree

.NOTES

#>
[CmdletBinding(SupportsShouldProcess)]
param (
	[string]
	$vDiskDrive = $env:SystemDrive,

	[string] $TempFolderName = 'Temp',

	[string] $TempFileName = "Unwritable$(Get-Date -Format 'yyyyMMddTHHmmss').Bandaid",

	[int64] $MinFree = 1GB,
    
	[string]
	$DiskPartScript = "select disk 0`nselect partition 1`nextend"
)

function New-LogEntry
{
	[CmdletBinding(SupportsShouldProcess)]
	param (
		[string]
		$LogServer = 'localhost',

		[string]
		$LogName = 'Application',

		[string]
		$Source = 'WCFreeSpaceSync',

		[Diagnostics.EventLogEntryType]
		$EntryType = 'Information',

		[int]
		$EventId,

		[Parameter(Mandatory)]
		[string]
		$Message
	)

	# Set some default event IDs based on severity, in case we start reporting/monitoring this
	if (!$EventId) { $EventId = 5432 + [int] $EntryType }

	if ($PSCmdlet.ShouldProcess("$LogName log", "new '$Source' $EntryType event"))
	{
		# Register the log source
		try
		{
			$nelParams = @{
				LogName      = $LogName
				Source       = $Source
				ComputerName = $LogServer
				ErrorAction  = 'Stop'
			}
			New-Eventlog @nelParams
			Write-Verbose "Registered $LogName log source '$LogSource' on $LogServer."
		}

		# If the log source already exists, redirect error message to verbose stream
		catch [InvalidOperationException] { Write-Verbose $_.Exception.Message }

		catch { throw $_.Exception }

		# Log the event
		try
		{
			$weParams = @{
				ComputerName = $LogServer
				LogName      = $LogName
				Source       = $Source
				EventId      = $EventId
				EntryType    = $EntryType
				Message      = $Message
				ErrorAction  = 'Stop'
			}

			Write-EventLog @weParams
		}
		catch { throw $_.Exception }
	}
}

$tempDir = "${vDiskDrive}\${TempFolderName}"
$tempFile = "${tempDir}\${TempFileName}"

Write-Verbose 'Checking PVS target device configuration'
try
{
	$pvsConfig = Get-ItemProperty 'HKLM:\System\CurrentControlSet\services\bnistack\PvsAgent' -ErrorAction 'Stop'
}
catch 
{
	$message = 'Registry is weird. You sure this is a PVS target?'
	New-LogEntry -Message $message -EntryType 'Error' -ErrorAction 'Continue'
	throw $message
}

$wcDrive = $pvsConfig.WriteCacheDrive
if (!$wcDrive)
{
	$message = "There doesn't appear to be a write-cache drive configured. Nothing to do."
	New-LogEntry -Message $message -EntryType 'Error' -ErrorAction 'Continue'
	throw $message
}

$cleanOnBoot = [int] $pvsConfig.CleanOnBoot
if (!$cleanOnBoot)
{ 
	$message = "PVS target device is in persistent mode. Bailing." 
	New-LogEntry -Message $message -EntryType 'Error' -ErrorAction 'Continue'
	throw $message
}

if (!(Test-Path -Path $tempDir))
{
	try { New-Item -ItemType 'Directory' -Path $tempDir -Force -ErrorAction 'Stop' }
	catch
	{
		$message = "Couldn't create temp directory '$tempDir'!"
		New-LogEntry -Message "$message`n$($_.Exception.Message)" -EntryType 'Error' -ErrorAction 'Continue'
		Write-Error $message
		throw $_.Exception
	}
}

if ($DiskPartScript -and $PSCmdlet.ShouldProcess($wcDrive, 'expand volume'))
{
	Write-Verbose "Verifying write-cache volume fills the entire disk."
	$scriptFile = "${tempDir}\diskpart.txt"
	$DiskPartScript | Out-File -FilePath $scriptFile -Encoding 'ascii'
    
    $diskPartOut = diskpart.exe /s "$scriptFile"
    
	if ($diskPartOut -join ' ' -match 'There is not enough usable free space .* to extend the volume.')
	{
		$diskPartOut = 'Write cache volume already at maximum size. No expansion necessary.'
    }
    else { $diskPartOut = $diskPartOut -join "`n" }

	Remove-Item -Path $scriptFile -Force -ErrorAction 'SilentlyContinue'
}

Write-Verbose 'Checking free space'
# Many of these targets are older (Win7) and don't have Get-Volume, just grabbing via .Net
$drives    = [IO.DriveInfo]::GetDrives()
$vDiskFree = [int64] ($drives | Where-Object { $_.Name -eq "${vDiskDrive}\" }).TotalFreeSpace
$wcFree    = [int64] ($drives | Where-Object { $_.Name -eq "${wcDrive}\" }).TotalFreeSpace

Write-Verbose "vDisk ($vDiskDrive) free space: $vDiskFree bytes"
Write-Verbose "Write-Cache ($wcDrive) free space: $wcFree bytes"

if (!($vDiskFree -and $wcFree))
{
	$message = "vDisk and/or write cache is already full. I was too late."
	New-LogEntry -Message $message -EntryType 'Error' -ErrorAction 'Continue'
	throw $message
}

if ($vDiskFree -le $wcFree)
{
	$message = 'Write cache looks good! Nothing to fix.'
	New-LogEntry -Message $message -ErrorAction 'Continue'
	Write-Verbose $message
	exit
}

$unwritableFree = $vDiskFree - $wcFree

Write-Warning "$vDiskDrive has $unwritableFree bytes of unwritable 'free' space!"
if ($wcFree -lt $minFree)
{
	$message = "Write cache volume ($wcDrive) is already below the minimum free space threshold of $MinFree bytes! Aborting."
	New-LogEntry -Message $message -EntryType 'Error' -ErrorAction 'Continue'
	throw $message
}
elseif ($PSCmdlet.ShouldProcess($vDiskDrive, "allocate unwritable free space"))
{
	if (Test-Path $tempFile)
	{
		try { Remove-Item -Path $tempFile -Force -ErrorAction 'Stop' }
		catch
		{
			$message = "File '$tempFile' already exists! I can't delete it, either."
			New-LogEntry -Message "$message`n$($_.Exception.Message)" -EntryType 'Error' -ErrorAction 'Continue'
			Write-Error $message
			throw $_.Exception
		}
	}

	# Make a big, empty, hidden, read-only file to allocate the unwritable "free" space
	# Unfortunately, we can't do it natively, so error handling gets a little sketchy...
	$fsutilOut = (fsutil.exe file createnew "$tempFile" $unwritableFree) -join "`n"
    
	if ($fsutilOut -match '^File .* is created$') { $entryType = 'Information' }
	elseif ($fsutilOut -match 'Error')            { $entryType = 'Error' }
	else                                          { $entryType = 'Warning' }

	$tempFile = Get-Item -Path $tempFile -Force
	if ($tempFile)
	{
		$tempFile.Attributes = 'ReadOnly, Hidden'
		$tempFileInfo = Get-Item -Path $tempFile -Force | Out-String
	}
	else
	{
		$tempFileInfo = "Looks like temp file creation failed. Hope there was some useful info above!"
		if ($EntryType -eq 'Information') { $entryType = 'Warning' }
	}
	$message = "Found $unwritableFree bytes of unwritable free space on $vDiskDrive!`n" + $diskPartOut + $fsutilOut + $tempFileInfo
	New-LogEntry -Message $message -EntryType $entryType -ErrorAction 'Continue'

	switch ($entryType) 
	{
		'Information' { $message }
		'Warning'     { Write-Warning $message }
		'Error'       { Write-Error $message }
	}
}
