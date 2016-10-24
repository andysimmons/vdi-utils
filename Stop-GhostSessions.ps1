<#	
.NOTES
	Name:    Stop-GhostSessions.ps1
	Author:  Andy Simmons
	Date:    10/24/2016
	URL:     https://github.com/andysimmons/vdi-utils/blob/master/Stop-GhostSessions.ps1
	Version: 1.0.0.0
	Requirements: 
		- Citrix Broker Admin snap-in
		- User needs the following permissions on each Citrix site:
			- View session details on all virtual desktops
			- Issue power actions to all virtual desktops
.SYNOPSIS
	Detects "ghost" (empty and stuck) VDI sessions and clears them out.

.DESCRIPTION
	Searches for sessions that have been in a "Connected" state > 5 mins and forcefully reboots them.

	"Disconnected"" and "Active" are normal states, "Connected" is not in our environment (not for more than 
	a few mintues, tops).

.PARAMETER DDCs
	Citrix DDC(s) to use.

.PARAMETER ConnectionTimeoutMinutes
	Duration (in minutes) a session is allowed to remain in a "Connected" state. This is where GPOs process, etc,
	so anything over 1 minute is unusual in our environment.

.PARAMETER MaxSessions
	Maximum number of sessions to kill off in a single pass.

.EXAMPLE
	Stop-GhostSessions.ps1 -WhatIf -Verbose
	
	This is the easiest way to see what this script does without any impact. It essentially runs the script against
	our production VDI environment, reporting which actions would be taken against any ghosted sessions.

.EXAMPLE
	Stop-GhostSessions.ps1 -DDCs 'siteA_ddc1','siteA_ddc2','siteB_ddc1','siteB_ddc2' -MaxSessions 10

	This would pick one healthy DDC from each site, and kill off a maximum of 10 ghost sessions total.
#>
#Requires -PSSnapin Citrix.Broker.Admin.V2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
	[string[]]$DDCs = @('ctxddc01','sltctxddc01'),
	[int]$ConnectionTimeoutMinutes = 5,
	[int]$MaxSessions = [Int32]::MaxValue
)

#region Functions
#-----------------------------------------------------------------------------------------------

# Load dependencies
function Initialize-Dependencies {
	[CmdletBinding()]
	param()

	Write-Verbose 'Loading Citrix Broker Admin Snap-In'
	try   { Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop }
	catch {	throw $_.Exception.Message }
}

# Loop through a list of DDCs, make sure the services we depend on are healthy, and grab exactly
# one healthy DDC from each site.
function Get-HealthySiteControllers {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[string[]]$DDCs
	)

	$siteLookup = @{}
	foreach ($candidate in $DDCs) {
		
		# Check service states
		try   { $brokerStatus = (Get-BrokerServiceStatus -AdminAddress $candidate -ErrorAction Stop).ServiceStatus.ToString() }
		catch { $brokerStatus = 'BROKER_OFFLINE' }
		
		try   { $hypStatus = (Get-HypServiceStatus -AdminAddress $candidate -ErrorAction Stop).ServiceStatus.ToString() }
		catch { $hypStatus = 'HYPERVISOR_OFFLINE' }
		
		# Everything good? Make sure we don't already have a healthy DDC in this site...
		if (($brokerStatus -eq 'OK') -and ($hypStatus -eq 'OK')) {
			try   { $brokerSite = Get-BrokerSite -AdminAddress $candidate -ErrorAction Stop }
			catch { $brokerSite = $null }
			
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
			$warnCount++
			Write-Warning "DDC '$candidate' broker service status: $brokerStatus, hypervisor service status: $hypStatus. Skipping."
		}
	}

	# Return the hashtable
	$siteLookup
}


# Retrieve "ghost" sessions from a DDC
function Get-GhostSessions {
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
		$ghostParams = @{
			AdminAddress = $AdminAddress
			SessionState = 'Connected'
			Filter = { SessionStateChangeTime -lt $cutoff }
			ErrorAction = 'Stop'
		}

		try {
			Write-Verbose "Pulling ghost sessions from ${AdminAddress}..."
			Get-BrokerSession @ghostParams | Select-Object -Property *,@{ n = 'AdminAddress'; e = {$AdminAddress} }
		}
		catch {
			Write-Warning "Error querying ${AdminAddress} for ghosted sessions. Exception message:"
			Write-Warning $_.Exception.Message
		}
	}
}
#endregion Functions

#region Main
#-----------------------------------------------------------------------------------------------

Write-Verbose "$(Get-Date): Starting '$($MyInvocation.Line)'"
Initialize-Dependencies

# Validate DDCs (just want one per site, and need at least 1 to continue).
$controllers = @($(Get-HealthySiteControllers -DDCs $DDCs).Values)
if (!$controllers.Length) {
	throw 'No healthy DDCs found.'
}

# Find ghost sessions
$ghostSessions = @($controllers | Get-GhostSessions -ConnectionTimeoutMinutes $ConnectionTimeoutMinutes) 
$totalGhosts   = $ghostSessions.Length
$ghostSessions = $ghostSessions | Select-Object -First $MaxSessions

# Initialize a few counters
$i              = 0
$attemptCounter = 0
$stopCounter    = 0
$failCounter    = 0

# Any ghost sessions?
if ($ghostSessions) {
	"Killing off $($ghostSessions.Length) ghost sessions."
	foreach ($ghostSession in $ghostSessions) {
		$i++
		$pctComplete = 100 * $i / [Math]::Max($ghostSessions.Length, 1)
		$friendlyName = "$($ghostSession.AdminAddress): $($ghostSession.HostedMachineName)"
		Write-Progress -Activity "Busting ghosts" -Status $friendlyName -PercentComplete $pctComplete
		
		# There's no native -WhatIf support on New-BrokerHostingPowerAction, so we'll add it here.
		if ($PSCmdlet.ShouldProcess($friendlyName, 'Force Reset')) {
			$attemptCounter++
			try {
				$killParams = @{
					Action = 'Reset'
					AdminAddress = $ghostSession.AdminAddress
					MachineName = $ghostSession.MachineName
					ErrorAction = 'Stop'
				}
				New-BrokerHostingPowerAction @killParams > $null
				$stopCounter++
			}
			catch {
				Write-Warning "Error restarting session '$friendlyName'. Exception message:"
				Write-Warning $_.Exception.Message
				$failCounter++
			}
		}
	}

	"Attempted to stop ${attemptCounter} ghost sessions across $($DDCs.Length) DDC(s)."
	if ($MaxSessions -lt ([int32]::MaxValue)) {
		"Total Ghosts: ${totalGhosts}"
		"Kill Limit:   ${MaxSessions}"
	}
	"Stopped:      ${stopCounter}"
	"Failed:       ${failCounter}"
	""
	"Note: Hosting power actions are throttled."
	"It may take a few minutes for these tasks to carry out. See XenDesktop hosting connection(s) configuration for details."
}
else {
	"No ghosts found."
}

Write-Verbose "$(Get-Date): Finished execution."
#endregion Main
