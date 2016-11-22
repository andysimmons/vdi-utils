<#	
.NOTES
	 Created on:   	11/17/2016 4:36 PM
	 Created by:   	Andy Simmons
	 Organization: 	St. Luke's Health System
	 Filename:      Start-VDiskUpdateCleanupTasks.ps1

.SYNOPSIS
	Assists with clearing out Citrix sessions on stale vDisks following an update.

.DESCRIPTION
	Stops disconnected sessions on stale vDisks, and generates prompts for users
	on active sessions to log off.

.PARAMETER AdminAddress
	One or more delivery controllers.

.PARAMETER NagTitle
	Title of the nag message box.

.PARAMETER NagText
	Content of the nag message box.

.PARAMETER DeliveryGroup
	Pattern matching the delivery group name(s).

.PARAMETER RegistryKey
	Registry key (on the broker machine) containing a property that 
	references the vDisk version in use.

.PARAMETER RegistryProperty
	Registry key property to inspect.

.PARAMETER AllVersionsPattern
	A pattern matching the naming convention for ANY version of the vDisk being updated.

.PARAMETER TargetVersionPattern
	A pattern describing the specific name of the target (updated) vDisk version.

.PARAMETER MaxSessionsPerSite
	Maximum number of sessions to inspect per site.

.PARAMETER TimeOut
	Timeout (sec) for querying vDisk information

.PARAMETER ThrottleLimit
	Max number of concurrent remote operations.

.PARAMETER MaxHoursIdle
	Maximum number of hours a session can be inactive before we forcefully shut it down.

.EXAMPLE
	Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,ctxddc02,sltctxddc01,sltctxddc02 -Verbose -WhatIf

	This would invoke the script against both of our production VDI sites with the default options, and
	describe in detail what would happen.

.EXAMPLE
	Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,sltctxddc01,ctxddc02,sltctxddc02 -Verbose -DeliveryGroup "XD*T07GCD" -Confirm:$false

	This would invoke the script against both of our VDI sites, targeting only the test delivery groups,
	and bypass confirmation prompts for any recommended actions
	

#>
#Requires -Version 5
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
	[Parameter(Mandatory)]
	[string[]]$AdminAddress,
	
	[string]$NagTitle = 'RESTART REQUIRED',
	
	[string]$NagText  = "Your system must be restarted to apply the latest Epic update.`n`n" +
	                    "Please save your work, then click 'Start' -> 'Log Off', and then wait`n" +
	                    'for the logoff operation to complete.',
	
	[string]$DeliveryGroup       = "*",
	
	[string]$RegistryKey         = 'HKLM:\System\CurrentControlSet\services\bnistack\PvsAgent',
	
	[string]$RegistryProperty    = 'DiskName',
	
	[regex]$AllVersionsPattern   = "XD[BT]?P07GCD-\d{6}.vhd",
	
	[regex]$TargetVersionPattern = "XD[BT]?P07GCD-161117.vhd",
	
	[int]$MaxSessionsPerSite     = ([int32]::MaxValue),
	
	[int]$ThrottleLimit = 32,
	
	[int]$TimeOut       = 120,
	
	[int]$MaxHoursIdle  = 2
)
$scriptStart        = Get-Date
$nagCounter         = 0
$nagFailCounter     = 0
$restartCounter     = 0
$restartFailCounter = 0

enum UpdateStatus {
	Ineligible
	Unknown
	RestartRequired
	UpdateCompleted
}

enum ProposedAction {
	None
	Nag
	Restart
}


#region Functions

<# 
.SYNOPSIS
	Generates a simple text header.
#>
function Out-Header
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[string]$Header,
		
		[switch]$Double
	)
	begin 
	{
		$line = $Header -replace ".", "-"
	}

	process 
	{
		if ($Double) { "`n$line`n$Header`n$line" }
		else         { "`n$Header`n$line" }
	}
}

function Send-Nag
{
<#
	.SYNOPSIS
		Nag a VDI user.
	
	.DESCRIPTION
		Generates a dialog box inside a VDI session.
	
	.PARAMETER AdminAddress
		Controller address.
	
	.PARAMETER HostedMachineName
		Hosted machine name associated with the session we're going to nag.
	
	.PARAMETER Message
		Message to be displayed.
	
	.PARAMETER MessageStyle
		Message dialog icon style.
#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param
	(
		[Parameter(Mandatory)]
		[string]$AdminAddress,
		
		[Parameter(Mandatory)]
		[string]$HostedMachineName,
		
		[Parameter(Mandatory)]
		[int]$SessionUID,
		
		[Parameter(Mandatory)]
		[string]$Text,
		
		[Parameter(Mandatory)]
		[string]$Title,
		
		[ValidateSet('Critical', 'Exclamation', 'Information', 'Question')]
		[string]$MessageStyle = 'Exclamation'
	)
	
	if ($PSCmdlet.ShouldProcess($HostedMachineName, "NAG USER"))
	{

		try 
		{
			$session = Get-BrokerSession -AdminAddress $AdminAddress -Uid $SessionUID -ErrorAction Stop
		}
		catch 
		{
			Write-Warning "Couldn't retrieve session ${AdminAddress}: ${SessionUID}"
			return
		}

		$nagParams = @{
			AdminAddress = $AdminAddress
			InputObject  = $session
			Title        = $Title
			Text         = $Text
			MessageStyle = $MessageStyle
			ErrorAction  = 'Stop'
		}
		
		try   
		{ 
			Send-BrokerSessionMessage @nagParams 
		}
		catch 
		{ 
			Write-Warning $_.Exception.Message
			$nagFailCounter++
		}

		$script:nagCounter++
	}
}


function Get-HealthyDDC
{
<#
.SYNOPSIS
	Finds healthy Desktop Delivery Controllers (DDCs) from a list of candidates.

.DESCRIPTION
	Inspects each of the DDC names provided, verifies the services we'll be leveraging are 
	responsive, and picks one healthy DDC per site.

.PARAMETER Candidates
	List of DDCs associated with one or more Citrix XenDesktop sites.
#>
	[CmdletBinding()]
	[OutputType([string[]])]
	param
	(
		[Parameter(Mandatory)]
		[string[]]$Candidates
	)
	
	$siteLookup = @{ }
	foreach ($candidate in $Candidates)
	{
		# Check service states
		try   { $brokerStatus = (Get-BrokerServiceStatus -AdminAddress $candidate -ErrorAction Stop).ServiceStatus }
		catch { $brokerStatus = 'BROKER_OFFLINE' }
		
		try   { $hypStatus = (Get-HypServiceStatus -AdminAddress $candidate -ErrorAction Stop).ServiceStatus }
		catch { $hypStatus = 'HYPERVISOR_OFFLINE' }
		
		# If it's healthy, check the site ID.
		if (($brokerStatus -eq 'OK') -and ($hypStatus -eq 'OK'))
		{
			try { $brokerSite = Get-BrokerSite -AdminAddress $candidate -ErrorAction Stop }
			catch { $brokerSite = $null }
			
			# We only want one healthy DDC per site
			if ($brokerSite)
			{
				$siteUid = $brokerSite.BrokerServiceGroupUid
				
				if ($siteUid -notin $siteLookup.Keys)
				{
					Write-Verbose "Using DDC $candidate for sessions in site $($brokerSite.Name)."
					$siteLookup[$siteUid] = $candidate
				}
				
				else
				{
					Write-Verbose "Already using $($siteLookup[$siteUid]) for site $($brokerSite.Name). Skipping $candidate."
				}
			}
		}
		
		else
		{
			Write-Warning "DDC '$candidate' broker service status: $brokerStatus, hypervisor service status: $hypStatus. Skipping."
		}
	} # foreach
	
	# Return only the names of the healthy DDCs from our site lookup hashtable
	Write-Output $siteLookup.Values
}

#endregion Functions


#region Initialization

Write-Verbose "$(Get-Date): Starting '$($MyInvocation.Line)'"

Write-Verbose 'Loading required Citrix snap-ins...'
[Collections.ArrayList]$missingSnapinList = @()
$requiredSnapins = @(
	'Citrix.Host.Admin.V2',
	'Citrix.Broker.Admin.V2'
)

foreach ($requiredSnapin in $requiredSnapins)
{
	Write-Verbose "Loading snap-in: $requiredSnapin"
	try { Add-PSSnapin -Name $requiredSnapin -ErrorAction Stop }
	catch { $missingSnapinList.Add($requiredSnapin) > $null }
}

if ($missingSnapinList)
{
	Write-Error -Category NotImplemented -Message "Missing $($missingSnapinList -join ', ')"
	exit 1
}

Write-Verbose "Assessing DDCs: $($AdminAddress -join ', ')"
$controllers = @(Get-HealthyDDC -Candidates $AdminAddress)
if (!$controllers.Length)
{
	Write-Error -Category ResourceUnavailable -Message 'No healthy DDCs found.'
	exit 1
}

#endregion Initialization


#region Main

# Loop through the eligible controllers (one per site), analyze them to see what automated action
# should be taken, and store that report in a collection.
[array]$sessionReport = foreach ($controller in $controllers)
{
	$analysisStart = Get-Date
	Write-Verbose "Analyzing sessions and vDisks on $($controller.ToUpper()) (this may take a minute)..."
	
	$sessionParams = @{
		AdminAddress     = $controller
		DesktopGroupName = $DeliveryGroup
		DesktopKind      = 'Shared'
		MaxRecordCount   = $MaxSessionsPerSite
	}
	
	Write-Progress -Activity 'Pulling session list' -Status $controller
	$sessions = Get-BrokerSession @sessionParams
	Write-Progress -Activity 'Pulling session list' -Completed
	
	if ($sessions)
	{
		Write-Progress -Activity "Querying $($sessions.Length) desktops for vDisk information (${TimeOut} sec timeout)." -Status $controller
		
		# The PVS management snap-in is pretty awful at the time of this writing, so we'll use PS remoting 
		# to reach out to each virtual desktop, have them check a registry entry, and return an object 
		# containing the HostedMachineName and its current VHD.
		[scriptblock]$getDiskName = {
			[pscustomobject]@{
				DiskName = (Get-ItemProperty -Path $using:RegistryKey -ErrorAction SilentlyContinue).$using:RegistryProperty
			}
		}
		
		# Get as much info as we can within the timeout window.
		$vDiskJob = Invoke-Command -ComputerName $sessions.HostedMachineName -ScriptBlock $getDiskName -AsJob -JobName 'vDiskJob'
		Wait-Job -Job $vDiskJob -Timeout $TimeOut > $null
		$vDisks = Receive-Job -Job $vDiskJob
		Get-Job -Name 'vDiskJob' | Remove-Job -Force -WhatIf:$false
		
		# Create a hashtable mapping the computer name to the vDisk name
		Write-Progress -Activity "Comparing $($sessions.Length) desktops against $($vDisks.Length) vDisk results." -Status $controller
		$vDiskLookup = @{ }
		foreach ($vDisk in $vDisks)
		{
			$vDiskLookup[$vDisk.PSComputerName] = $vDisk.DiskName
		}
		
		# Now we can loop through the sessions and handle them accordingly
		foreach ($session in $sessions)
		{
			try   { $vDisk = $vDiskLookup[$session.HostedMachineName] }
			catch { $vDisk = $null }
			
			### -- Determine update status
			
			# If we have vDisk info
			if ($vDisk)
			{
				# and it's a vDisk we're updating
				if ($vDisk -match $AllVersionsPattern)
				{
					# See if we're on the target version
					if ($vDisk -match $TargetVersionPattern)
					{
						$updateStatus = [UpdateStatus]::UpdateCompleted
					}
					else
					{
						$updateStatus = [UpdateStatus]::RestartRequired
					}
				}
				# wrong vDisk
				else
				{
					$updateStatus = [UpdateStatus]::Ineligible
				}
			}
			# no vDisk info returned
			else
			{
				$updateStatus = [UpdateStatus]::Unknown
			}
			
			### - Set proposed action
			switch ($updateStatus)
			{
				'RestartRequired' {
					$isInactive = $session.SessionState -ne 'Active'
					$hasntChangedInAWhile = $session.SessionStateChangeTime -lt (Get-Date).AddHours(-$MaxHoursIdle)
					
					if ($isInactive -and $hasntChangedInAWhile)
					{
						# Needs a restart, and they aren't using it
						$proposedAction = [ProposedAction]::Restart
					}
					else
					{
						# Needs a restart, but they could be using it
						$proposedAction = [ProposedAction]::Nag
					}
				}
				
				default
				{
					# No action needed (or not enough info to propose an action)
					$proposedAction = [ProposedAction]::None
				}
			}
			
			# Summarize this session
			[pscustomobject]@{
				HostedMachineName      = $session.HostedMachineName
				DiskName               = $vDisk
				UpdateStatus           = $updateStatus
				ProposedAction         = $proposedAction
				SessionState           = $session.SessionState
				SessionStateChangeTime = $session.SessionStateChangeTime
				Uid                    = $session.Uid
				AdminAddress           = $controller.ToUpper()
			}
		}
	}
	else
	{
		Write-Verbose "No interesting sessions found on $($controller.ToUpper())."
	}
	$elapsed = [int]((Get-Date) - $analysisStart).TotalSeconds
	Write-Verbose "Completed $($controller.ToUpper()) session analysis in ${elapsed} seconds."
}

$sessionReport | Format-Table -AutoSize

# Loop through the items in our report, and take action on them accordingly
foreach ($sessionInfo in $sessionReport)
{
	switch ($sessionInfo.ProposedAction)
	{
		'Restart'
		{
			# Verify it's still inactive before restarting
			$refreshParams = @{
				AdminAddress = $sessionInfo.AdminAddress
				HostedMachineName = $sessionInfo.HostedMachineName
			}
			$currentSession = Get-BrokerSession @refreshParams
			
			if ($currentSession.SessionState -ne 'Active')
			{
				if ($PSCmdlet.ShouldProcess($sessionInfo.HostedMachineName, 'RESTART MACHINE'))
				{
					$restartParams = @{
						AdminAddress = $sessionInfo.AdminAddress
						MachineName  = $currentSession.MachineName
						Action       = 'Restart'
						ErrorAction  = 'Stop'
					}
					# Uncomment the following block comment after testing, and comment the warning. __RESTART_ACTION__
					try
					{ 
						New-BrokerHostingPowerAction @restartParams > $null
					}
					catch 
					{ 
						Write-Warning $_.Exception.Message
						$restartFailCounter++
					}

					# Write-Warning 'Andy forgot to uncomment the restart command. Find it by searching the script for "__RESTART_ACTION__"'
					$restartCounter++
				}
			}
			# It might not be inactive anymore. We'll nag instead.
			else
			{
				$nagParams = @{
					AdminAddress      = $sessionInfo.AdminAddress
					HostedMachineName = $sessionInfo.HostedMachineName
					SessionUID        = $sessionInfo.Uid
					Title             = $NagTitle
					Text              = $NagText
				}
				Send-Nag @nagParams
			}
		}
		
		'Nag'
		{
			$nagParams = @{
				AdminAddress      = $sessionInfo.AdminAddress
				HostedMachineName = $sessionInfo.HostedMachineName
				SessionUID        = $sessionInfo.Uid
				Title             = $NagTitle
				Text              = $NagText
			}
			Send-Nag @nagParams
		}
	}
}

'Session Breakdown' | Out-Header -Double

foreach ($property in 'UpdateStatus', 'ProposedAction', 'DiskName')
{
	$property | Out-Header
	$sessionReport | Group-Object -Property $property -NoElement |
	Select-Object -Property Count,@{ n = $property; e = { $_.Name } } |
	Sort-Object -Property 'Count' -Descending | Format-Table -HideTableHeaders
}

"Total Nags Sent: ${nagCounter} (${nagFailCounter} failed)"
"Total Restarts Requested: ${restartCounter} (${restartFailCounter} failed)"

$elapsed = [int]((Get-Date) - $scriptStart).TotalSeconds
"Script completed in ${elapsed} seconds."
