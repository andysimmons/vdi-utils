<#	
.NOTES
	Name:    Stop-GhostSessions.ps1
	Author:  Andy Simmons
	Date:    10/24/2016
	Version: 1.0.0.0
	Requirements: 
		- Citrix Broker admin PS snap-in
		- User needs the following permissions on each Citrix site:
			- View and stop sessions on all virtual desktops
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
	The time (in minutes) a session is allowed to remain in a "Connected" state. This is where GPOs process, etc,
	so anything over 1 minute is unusual.

.PARAMETER MaxSessions
	Maximum number of sessions to kill off in a single pass.

.EXAMPLE
	Stop-GhostSessions.ps1 -WhatIf -Verbose
	
	This is the easiest way to see what this script does without any impact. It essentially runs the script against
	our production VDI environment, reporting in detail which actions would be taken against any ghosted sessions.
.EXAMPLE

#>
#Requires -PSSnapin Citrix.Broker.Admin.V2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
	[string[]]$DDCs = @('siteA-ddc01','siteB-ddc01'),
	[int]$ConnectionTimeoutMinutes = 5,
	[int]$MaxSessions = [Int32]::MaxValue
)

#region Functions
#-----------------------------------------------------------------------------------------------

# Load dependencies
function Initialize-Dependencies {
	Write-Verbose 'Loading Citrix Broker Admin Snap-In'
	try   { Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop }
	catch {	throw $_.Exception.Message }
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

# Find ghost sessions
$ghostSessions = @($DDCs | Get-GhostSessions -ConnectionTimeoutMinutes $ConnectionTimeoutMinutes) 
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
