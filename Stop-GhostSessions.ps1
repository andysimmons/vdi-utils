<#	
.NOTES
	Name:    Stop-GhostSessions.ps1
	Author:  Andy Simmons
	Date:    10/24/2016
	URL:     https://github.com/andysimmons/vdi-utils/blob/master/Stop-GhostSessions.ps1
	Version: 1.0.4
	Requirements: 
		- Citrix Broker Admin snap-in (installed w/ Citrix Studio)
		- User needs the following permissions on each site/farm:
			- View session details on all virtual desktops
			- Issue power actions to all virtual desktops
.SYNOPSIS
	Detects "ghost" VDI sessions and clears them out.

.DESCRIPTION
	Searches for sessions that have been in a "Connected" state for an unreasonably long time, and forcefully
	reboots the corresponding machines, provided the machine only supports a single session.

	Working VDI sessions will normally either be "Disconnected" or "Active". Sessions that show "Connected" for more than
	a minute or two are almost certainly broken (at least in our environment).

.PARAMETER DDCs
	Citrix DDC(s) to use.

.PARAMETER ConnectionTimeoutMinutes
	Duration (in minutes) a session is allowed to remain in a "Connected" state, before we assume it's broken.

.PARAMETER MaxSessions
	Maximum number of sessions to kill off in a single pass.

.EXAMPLE
	Stop-GhostSessions.ps1 -WhatIf -Verbose -DDCs 'yourddc1','yourddc2'
	
	This is the easiest way to see what this script does without any impact. It essentially runs the script against
	a production XenDesktop environment, reporting which actions would be taken against any ghost sessions.

.EXAMPLE
	Stop-GhostSessions.ps1 -DDCs 'siteA_ddc1','siteA_ddc2','siteB_ddc1','siteB_ddc2' -MaxSessions 10 -Verbose

	Search for ghost sessions across multiple sites, and kill a maximum of 10 sessions total.
#>
#Requires -PSSnapin Citrix.Broker.Admin.V2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
	[Parameter(Mandatory)]
	[string[]]$DDCs,

	[int]$ConnectionTimeoutMinutes = 5,
	
	[int]$MaxSessions = [Int32]::MaxValue
)

#region Functions
#=========================================================================
# Loop through an array of Desktop Delivery Controller (DDC) names, make sure the services 
# we'll be leveraging are responsive, and pick the first healthy DDC from each site.
#-------------------------------------------------------------------------
function Get-HealthyDDCs {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[string[]]$Candidates
	)

	$siteLookup = @{}
	foreach ($candidate in $Candidates) {
		
		# Check service states
		try   { $brokerStatus = (Get-BrokerServiceStatus -AdminAddress $candidate -ErrorAction Stop).ServiceStatus.ToString() }
		catch { $brokerStatus = 'BROKER_OFFLINE' }
		
		try   { $hypStatus = (Get-HypServiceStatus -AdminAddress $candidate -ErrorAction Stop).ServiceStatus.ToString() }
		catch { $hypStatus = 'HYPERVISOR_OFFLINE' }
		
		# Everything good?
		if (($brokerStatus -eq 'OK') -and ($hypStatus -eq 'OK')) {
			try   { $brokerSite = Get-BrokerSite -AdminAddress $candidate -ErrorAction Stop }
			catch { $brokerSite = $null }
			
			# We only want one healthy DDC per site
			if ($brokerSite) {
				$siteUid = $brokerSite.BrokerServiceGroupUid
				
				if ($siteUid -notin $siteLookup.Keys) {
					Write-Verbose "Using DDC $candidate for sessions in site $($brokerSite.Name)."
					$siteLookup[$siteUid] = $candidate
				}
				else {
					Write-Verbose "Already using $($siteLookup[$siteUid]) for site $($brokerSite.Name). Skipping $candidate."
				}
			}
		}

		# DDC is wonky. Skip it.
		else {
			Write-Warning "DDC '$candidate' broker service status: $brokerStatus, hypervisor service status: $hypStatus. Skipping."
		}
	}

	# Return the names of the healthy DDCs
	$siteLookup.Values
}

# Retrieve all broker machines bound to a single broken ("ghost") session
#-------------------------------------------------------------------------
function Get-GhostMachines {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, ValueFromPipeline)]
		[string]$AdminAddress,

		[Parameter(Mandatory)]
		[int]$ConnectionTimeoutMinutes
	)

	begin {
		$cutoff = (Get-Date).AddMinutes(-$ConnectionTimeoutMinutes)
	}

	process {		
		try {
			Write-Verbose "Pulling ghost session machines from ${AdminAddress}..."
			
			$ghostParams = @{
				AdminAddress   = $AdminAddress
				SessionState   = 'Connected'
				SessionSupport = 'SingleSession'
				Filter         = { SessionStateChangeTime -lt $cutoff }
				ErrorAction    = 'Stop'
			}
			
			# Return the ghosted machines after squirting in a custom 'AdminAddress' property we'll use later.
			Get-BrokerMachine @ghostParams | Select-Object -Property *,@{ n = 'AdminAddress'; e = {$AdminAddress} }
		}
		catch {
			Write-Warning "Error querying ${AdminAddress} for ghost sessions. Exception message:"
			Write-Warning $_.Exception.Message
		}
	}
}
#endregion Functions

#region Main
#=========================================================================
Write-Verbose "$(Get-Date): Starting '$($MyInvocation.Line)'"

Write-Verbose 'Loading Citrix Broker Admin Snap-In'
try   { Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop }
catch {	throw $_.Exception.Message }

Write-Verbose "Assessing DDCs: $($DDCs -join ', ')"
$controllers = @(Get-HealthyDDCs -Candidates $DDCs)
if (!$controllers.Length) {
	throw 'No healthy DDCs found. Bailing out.'
}

Write-Progress -Activity 'Finding ghost sessions' -Status $($controllers -join ', ')
$ghostMachines = @($controllers | Get-GhostMachines -ConnectionTimeoutMinutes $ConnectionTimeoutMinutes) 
$totalGhosts   = $ghostMachines.Length

if ($MaxSessions -lt $totalGhosts) {
	Write-Verbose "Found ${totalGhosts} total ghost sessions. Only killing the first ${MaxSessions}."
	$ghostMachines = @($ghostMachines | Select-Object -First $MaxSessions)
}
Write-Progress -Activity 'Finding ghost sessions' -Completed


# Find any?
if ($ghostMachines) {
	$i              = 0
	$attemptCounter = 0
	$stopCounter    = 0
	$failCounter    = 0

	# Loop through our ghost machines and kill them off
	foreach ($ghostMachine in $ghostMachines) {
		$i++
		$pctComplete  = 100 * $i / $ghostMachines.Length
		$friendlyName = "$($ghostMachine.AdminAddress): $($ghostMachine.HostedMachineName)"
		Write-Progress -Activity "Ghostbusting" -Status $friendlyName -PercentComplete $pctComplete
		
		# There's no native -WhatIf support on New-BrokerHostingPowerAction, so we'll add it here.
		if ($PSCmdlet.ShouldProcess($friendlyName, 'Force Reset')) { 
			try {
				$forceResetParams = @{
					Action       = 'Reset'
					AdminAddress = $ghostMachine.AdminAddress
					MachineName  = $ghostMachine.MachineName
					ErrorAction  = 'Stop'
				}

				New-BrokerHostingPowerAction @forceResetParams > $null
				$stopCounter++
			}
			catch {
				Write-Warning "Error restarting session '$friendlyName'. Exception message:"
				Write-Warning $_.Exception.Message
				$failCounter++
			}
			finally {
				$attemptCounter++
			}
		}
	}

	$summary = "Ghost Sessions Found:   ${totalGhosts}`n"    +
	           "Force Resets Attempted: ${attemptCounter}`n" +
	           "Reset Tasks Queued:     ${stopCounter}`n"    +
	           "Reset Tasks Failed:     ${failCounter}"

	if ($attemptCounter) {
		$summary += "`n`nNote: Power actions are throttled. It may take a few minutes for these tasks to make it to the hosting platform.`n`n" +
	           'See the corresponding hosting connection(s) config in Citrix Studio for specific details.'
	}
}

# No ghosts.
else {
	$summary = 'Nothing to do.'
}

# All done, spit out a summary.
$summary
Write-Verbose "$(Get-Date): Finished execution."
#endregion Main
