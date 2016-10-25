<#
.NOTES
	Name:    Stop-GhostSessions.ps1
	Author:  Andy Simmons
	Date:    10/24/2016
	URL:     https://github.com/andysimmons/vdi-utils/blob/master/Stop-GhostSessions.ps1
	Version: 1.0.7
	Requirements:
		- Citrix Broker and Host Admin snap-ins (installed w/ Citrix Studio)
		- User needs the following permissions on each site/farm:
			- View session details on all virtual desktops
			- Issue power actions to all virtual desktops

.SYNOPSIS
	Detects "ghost" VDI sessions and clears them out.

.DESCRIPTION
	Searches for sessions that have been in a "Connected" state for an
	unreasonably long time, and forcefully reboots the corresponding machines, 
	provided the machine only supports a single session.
	
	Working VDI sessions will normally either be "Disconnected" or "Active". 
	Sessions that show "Connected" for more than a minute or two are almost 
	certainly broken (at least in our environment).

.PARAMETER DDCs
	Desktop Delivery Controller name(s).

.PARAMETER ConnectionTimeoutMinutes
	Duration (in minutes) a session is allowed to remain in a "Connected" state, 
	before we assume it's broken.

.PARAMETER MaxSessions
	Maximum number of sessions to kill off in a single pass.

.EXAMPLE
	Stop-GhostSessions.ps1 -WhatIf -Verbose -DDCs 'yourddc1','yourddc2'
	
	This is the easiest way to see what this script does without any impact. It 
	essentially runs the script against a production XenDesktop environment, 
	reporting which actions would be taken against any ghost sessions.

.EXAMPLE
	Stop-GhostSessions.ps1 -DDCs 'siteA_ddc1','siteA_ddc2','siteB_ddc1','siteB_ddc2' -MaxSessions 10 -Verbose
	
	Search for ghost sessions across multiple sites, and kill a maximum of 10 sessions total.
#>
[CmdletBinding(ConfirmImpact = 'Medium', SupportsShouldProcess)]
param
(
	[Parameter(Mandatory)]
	[string[]]$DDCs,
	
	[ValidateScript({$_ -ge 0})]
	[int]$ConnectionTimeoutMinutes = 5,
	
	[ValidateScript({ $_ -ge 0 })]
	[int]$MaxSessions = [Int32]::MaxValue
)

#region Functions
#-----------------------------------------------------------------------------------
function Get-HealthyDDCs
{
	<#
	.SYNOPSIS
		Finds healthy Desktop Delivery Controllers (DDCs) from a list of candidates.
	
	.DESCRIPTION
		Inspects each of the DDC names provided, verifies the services we'll be leveraging are responsive, and picks one healthy DDC per site.
	
	.PARAMETER Candidates
		List of DDCs associated with one or more Citrix XenDesktop sites.
	#>
	[CmdletBinding()]
	[OutputType([string[]])]
	param
	(
		[Parameter(Mandatory = $true)]
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
		
		# Everything good?
		if (($brokerStatus -eq 'OK') -and ($hypStatus -eq 'OK'))
		{
			try   { $brokerSite = Get-BrokerSite -AdminAddress $candidate -ErrorAction Stop }
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
		
		# DDC is wonky. Skip it.
		else
		{
			Write-Warning "DDC '$candidate' broker service status: $brokerStatus, hypervisor service status: $hypStatus. Skipping."
		}
	}
	
	# Return the names of the healthy DDCs
	$siteLookup.Values
}

function Get-GhostMachines
{
	<#
	.SYNOPSIS
		Returns broker machines with a single ghost session.
	
	.DESCRIPTION
		Searches for broker machines that support a single session, which
		appear to currently be stuck in a "Connected" state.
	
	.PARAMETER AdminAddress
		Specifies the address of a XenDesktop controller.
	
	.PARAMETER ConnectionTimeoutMinutes
		Duration (in minutes) a session is allowed to remain in a "Connected" 
		state, before we assume it's broken.
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject[]])]
	param
	(
		[Parameter(Mandatory, ValueFromPipeline)]
		[string]$AdminAddress,
		
		[Parameter(Mandatory)]
		[ValidateScript({ $_ -ge 0 })]
		[int]$ConnectionTimeoutMinutes
	)
	
	begin
	{
		$cutoff = (Get-Date).AddMinutes(- $ConnectionTimeoutMinutes)
	}
	
	process
	{
		try
		{
			Write-Verbose "Pulling ghost session machines from ${AdminAddress}..."
			
			$ghostParams = @{
				AdminAddress   = $AdminAddress
				SessionState   = 'Connected'
				SessionSupport = 'SingleSession'
				MaxRecordCount = ([Int32]::MaxValue)
				Filter         = { SessionStateChangeTime -lt $cutoff }
				ErrorAction    = 'Stop'
			}
			
			# Return the ghosted machines after squirting in a custom 'AdminAddress' property we'll use later.
			Get-BrokerMachine @ghostParams | Select-Object -Property *, @{ n = 'AdminAddress'; e = { $AdminAddress } }
		}
		catch
		{
			Write-Warning "Error querying ${AdminAddress} for ghost sessions. Exception message:"
			Write-Warning $_.Exception.Message
		}
	}
}
#endregion Functions

#region Init
#-----------------------------------------------------------------------------------
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
	try   { Add-PSSnapin -Name $requiredSnapin -ErrorAction Stop }
	catch { $missingSnapinList.Add($requiredSnapin) > $null }
}

if ($missingSnapinList)
{
	Write-Error -Category NotImplemented "Missing $($missingSnapinList -join ', ')"
	exit 1
}

Write-Verbose "Assessing DDCs: $($DDCs -join ', ')"
$controllers = @(Get-HealthyDDCs -Candidates $DDCs)
if (!$controllers.Length)
{
	throw 'No healthy DDCs found. Bailing out.'
}
#endregion Init

#region Main
#-----------------------------------------------------------------------------------
Write-Progress -Activity 'Finding ghost sessions' -Status $($controllers -join ', ')
$ghostMachines = @($controllers | Get-GhostMachines -ConnectionTimeoutMinutes $ConnectionTimeoutMinutes)
$totalGhosts   = $ghostMachines.Length

if ($MaxSessions -lt $totalGhosts)
{
	Write-Verbose "Found ${totalGhosts} total ghost sessions. Only killing the first ${MaxSessions}."
	$ghostMachines = @($ghostMachines | Select-Object -First $MaxSessions)
}
Write-Progress -Activity 'Finding ghost sessions' -Completed

# Find any?
if ($ghostMachines)
{
	$i = 0
	$attemptCounter = 0
	$stopCounter    = 0
	$failCounter    = 0
	
	# Loop through our ghost machines and kill them off
	foreach ($ghostMachine in $ghostMachines)
	{
		$i++
		$pctComplete  = 100 * $i / $ghostMachines.Length
		$friendlyName = "$($ghostMachine.AdminAddress): $($ghostMachine.HostedMachineName)"
		Write-Progress -Activity "Ghostbusting" -Status $friendlyName -PercentComplete $pctComplete
		
		# There's no native -WhatIf support on New-BrokerHostingPowerAction, so we'll add it here.
		if ($PSCmdlet.ShouldProcess($friendlyName, 'Force Reset'))
		{
			try
			{
				$forceResetParams = @{
					Action       = 'Reset'
					AdminAddress = $ghostMachine.AdminAddress
					MachineName  = $ghostMachine.MachineName
					ErrorAction  = 'Stop'
				}
				
				New-BrokerHostingPowerAction @forceResetParams > $null
				$stopCounter++
			}
			catch
			{
				Write-Warning "Error restarting session '$friendlyName'. Exception message:"
				Write-Warning $_.Exception.Message
				$failCounter++
			}
			finally
			{
				$attemptCounter++
			}
		}
	}
	
	$summary = "Ghost Sessions Found:   ${totalGhosts}`n"    +
	           "Force Resets Attempted: ${attemptCounter}`n" +
	           "Reset Tasks Queued:     ${stopCounter}`n"    +
	           "Reset Tasks Failed:     ${failCounter}"
	
	if ($attemptCounter)
	{
		$summary += "`n`nNote: Power actions are throttled. It may take a few minutes " + 
		            "for these tasks to make it to the hosting platform.`n`n"           +
		            'See the corresponding hosting connection(s) config in Citrix Studio for specific details.'
	}
}

# No ghosts.
else
{
	$summary = 'Nothing to do.'
}

# All done, spit out a summary.
$summary
Write-Verbose "$(Get-Date): Finished execution."
#endregion Main
