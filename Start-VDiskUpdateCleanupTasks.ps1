<#
.NOTES
     Created on:   3/16/2016
     Created by:   Andy Simmons
     Organization: St. Luke's Health System
     Filename:     Start-VDiskUpdateCleanupTasks.ps1

.SYNOPSIS
    Assists with clearing out Citrix sessions on stale vDisks following an update.

.DESCRIPTION
    Stops disconnected sessions on stale vDisks, and generates prompts for users
    on active sessions to log off.

.PARAMETER AdminAddress
    One or more delivery controllers.

.PARAMETER SearchScope
    Specifies which types of machines are in scope:

        AvailableMachines:
            Limit search to machines in an "Available" state.

        MachinesWithSessions:
            Limit search to machines associated with sessions.

        Both:
            Default option. Searches first for available machines, and if those
            are all up-to-date, looks for sessions on outdated vDisks.

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

.PARAMETER MaxRecordCount
    Maximum number of results per search, per site.

.PARAMETER MaxActionsTaken
    Specifies the max number of total actions (restarts + nags) that can occur during script execution
    across all sites.

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
    and bypass confirmation prompts for any recommended actions.

.EXAMPLE
    Start-VDiskUpdateCleanupTasks.ps1 -AdminAddress ctxddc01,ctxddc02,sltctxddc01,sltctxddc02 -Verbose -DeliveryGroup "*PVS Shared Desktop" -MaxActionsTaken 10

    This would invoke the script against both of our sites, targeting any Delivery Groups ending with the string "PVS Shared Desktop",
    and perform actions (with confirmation prompts) against a maximum of 10 machines/sessions total.
#>
#Requires -Version 5
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory)]
    [string[]]
    $AdminAddress,

    [string]
    [ValidateSet('AvailableMachines','MachinesWithSessions','Both')]
    $SearchScope = 'Both',

    [string]
    $NagTitle = 'RESTART REQUIRED',

    [string]
    $NagText = "Your system must be restarted to apply the latest Epic update.`n`n" +
               "Please save your work, then click 'Start' -> 'Log Off', and then wait`n" +
               'for the logoff operation to complete.',

    [string]
    $DeliveryGroup = "*",

    [string]
    $RegistryKey = 'HKLM:\System\CurrentControlSet\services\bnistack\PvsAgent',

    [string]
    $RegistryProperty = 'DiskName',

    [regex]
    $AllVersionsPattern = "XD[BT]?P07GCD-\d{6}.vhd",

    [regex]
    $TargetVersionPattern = "XD[BT]?P07GCD-170206.vhd",

    [int]
    $MaxRecordCount = ([int32]::MaxValue),

    [int]
    $MaxActionsTaken = 30,

    [int]
    $ThrottleLimit = 32,

    [int]
    $TimeOut = 120,

    [int]
    $MaxHoursIdle = 2
)

$scriptStart        = Get-Date
$nagCounter         = 0
$nagFailCounter     = 0
$restartCounter     = 0
$restartFailCounter = 0

enum UpdateStatus
{
    Ineligible
    Unknown
    RestartRequired
    UpdateCompleted
}

enum ProposedAction
{
    None
    Nag
    Restart
}

#region Functions
<#
.SYNOPSIS
    Pulls vDisk version information for a list of computers.

.DESCRIPTION
    Takes a list of computer names, checks which vDisk each one is currently running,
    and returns a hashtable with the results.

.PARAMETER ComputerName
    The NetBIOS name, the IP address, or the fully qualified domain name of one or more computers.

#>
function Get-VDiskInfo
{

    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]
        [string[]]
        $ComputerName
    )

    # The PVS management snap-in is pretty awful at the time of this writing, so we'll use PS remoting
    # to reach out to each virtual desktop, have them check a registry entry, and return an object
    # containing the HostedMachineName and its current VHD.
    [scriptblock]$getDiskName = {
        [pscustomobject]@{
            DiskName = (Get-ItemProperty -Path $using:RegistryKey -ErrorAction SilentlyContinue).$using:RegistryProperty
        }
    }

    # Get as much info as we can within the timeout window.
    $vDiskJob = Invoke-Command -ComputerName $ComputerName -ScriptBlock $getDiskName -AsJob -JobName 'vDiskJob'
    Wait-Job -Job $vDiskJob -Timeout $TimeOut > $null
    $vDisks = Receive-Job -Job $vDiskJob -ErrorAction SilentlyContinue
    Get-Job -Name 'vDiskJob' | Remove-Job -Force -WhatIf:$false

    # Create a hashtable mapping the computer name to the vDisk name
    Write-Progress -Activity "Comparing $($sessions.Length) desktops against $($vDisks.Length) vDisk results." -Status $controller
    $vDiskLookup = @{ }
    foreach ($vDisk in $vDisks)
    {
        $vDiskLookup[$vDisk.PSComputerName] = $vDisk.DiskName
    }

    # Return the lookup table
    $vDiskLookup
}

<#
.SYNOPSIS
    Determines the update status of a given vDisk.

.PARAMETER AllVersionsPattern
    A pattern matching the naming convention for ANY version of the vDisk being updated.

.PARAMETER TargetVersionPattern
    A pattern describing the specific name of the target (updated) vDisk version.

.PARAMETER DiskName
    The name of the vDisk.
#>
function Get-UpdateStatus
{
    [CmdletBinding()]
    [OutputType([UpdateStatus])]
    param(
        [string]$DiskName,

        [regex]$AllVersionsPattern,

        [regex]$TargetVersionPattern
    )

    if ($DiskName)
    {
        # and it's a vDisk we're updating
        if ($DiskName -match $AllVersionsPattern)
        {
            # See if we're on the target version
            if ($DiskName -match $TargetVersionPattern)
            {
                $updateStatus = [UpdateStatus]::UpdateCompleted
            }
            else
            {
                $updateStatus = [UpdateStatus]::RestartRequired
            }
        }
        # this vDisk isn't in scope
        else
        {
            $updateStatus = [UpdateStatus]::Ineligible
        }
    }

    # no disk name provided
    else
    {
        $updateStatus = [UpdateStatus]::Unknown
    }

    # return result
    $updateStatus
}

<#
.SYNOPSIS
    Generates a simple text header.
#>
function Out-Header
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Header,

        [switch]$Double
    )
    process
    {
        $line = $Header -replace '.', '-'
        if ($Double) { "`n$line`n$Header`n$line" }
        else         { "`n$Header`n$line" }
    }
}

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
function Send-Nag
{
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

<#
.SYNOPSIS
    Finds healthy Desktop Delivery Controllers (DDCs) from a list of candidates.

.DESCRIPTION
    Inspects each of the DDC names provided, verifies the services we'll be leveraging are
    responsive, and picks one healthy DDC per site.

.PARAMETER Candidates
    List of DDCs associated with one or more Citrix XenDesktop sites.
#>
function Get-HealthyDDC
{
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
    }

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


#region Analysis
$analysisStart = Get-Date

# Loop through the eligible controllers (one per site), analyze the AVAILABLE MACHINES on each to see
# what automated action should be taken, and store that report in a collection.
if ($SearchScope -eq 'MachinesWithSessions')
{
    # We're just targeting sessions this run, skip the available machine analysis.
    $availableReport = @()
}
else
{
    [array]$availableReport = foreach ($controller in $controllers)
    {
        Write-Verbose "Analyzing available machines' vDisks on $($controller.ToUpper()) (this may take a minute)..."

        $availableParams = @{
            AdminAddress     = $controller
            DesktopGroupName = $DeliveryGroup
            DesktopKind      = 'Shared'
            SummaryState     = 'Available'
            MaxRecordCount   = $MaxRecordCount
        }

        Write-Progress -Activity 'Pulling available machine list' -Status $controller
        $availableMachines = Get-BrokerMachine @availableParams
        Write-Progress -Activity 'Pulling available machine list' -Completed

        if ($availableMachines)
        {
            Write-Progress -Activity "Querying $($availableMachines.Length) desktops for vDisk information (${TimeOut} sec timeout)." -Status $controller

            $vDiskLookup = Get-VDiskInfo -ComputerName $availableMachines.HostedMachineName

            # Now we can loop through the sessions and handle them accordingly
            foreach ($availableMachine in $availableMachines)
            {
                try   { $vDisk = $vDiskLookup[$availableMachine.HostedMachineName] }
                catch { $vDisk = $null }

                $statusParams = @{
                    TargetVersionPattern = $TargetVersionPattern
                    AllVersionsPattern   = $AllVersionsPattern
                    DiskName             = $vDisk
                }
                $updateStatus = Get-UpdateStatus @statusParams

                # Propose an action based on update status
                switch ($updateStatus)
                {
                    'RestartRequired'
                    {
                        # Machine isn't in use, we should restart it.
                        $proposedAction = [ProposedAction]::Restart
                    }

                    default
                    {
                        # No action needed (or not enough info to propose an action)
                        $proposedAction = [ProposedAction]::None
                    }
                }

                # Summarize this machine
                [pscustomobject]@{
                    HostedMachineName      = $availableMachine.HostedMachineName
                    DiskName               = $vDisk
                    UpdateStatus           = $updateStatus
                    ProposedAction         = $proposedAction
                    SummaryState           = $availableMachine.SummaryState
                    Uid                    = $availableMachine.Uid
                    AdminAddress           = $controller.ToUpper()
                }
            }
        }
        else
        {
            Write-Verbose "No available machines found on $($controller.ToUpper())."
        }
        $elapsed = [int]((Get-Date) - $analysisStart).TotalSeconds
        Write-Verbose "Completed $($controller.ToUpper()) machine analysis in ${elapsed} seconds."
    }
    if ($availableReport)
    {
        Out-Header -Header 'Available Machine Summary' -Double
        $availableReport | Format-Table -AutoSize
    }
}

if ($SearchScope -eq 'AvailableMachines')
{
    # Sessions are out of scope for this pass
    $sessionReport = @()
}
else
{
    # Loop through the eligible controllers (one per site), analyze the MACHINES WITH SESSIONS to see what
    # automated action should be taken, and store that report in a collection.
    [array]$sessionReport = foreach ($controller in $controllers)
    {
        $oldAvailableMachines = @($availableReport | Where-Object { ($_.AdminAddress -eq $controller) -and ($_.ProposedAction -eq 'Restart') })

        if ($oldAvailableMachines)
        {
            Write-Warning "There are still at least $($oldAvailableMachines.Count) outdated and available machines reported by $($controller.ToUpper())."
            Write-Warning 'Skipping session analysis until available machines are all up-to-date.'
            $sessions = @()
        }
        else
        {
              Write-Verbose "Analyzing sessions and vDisks on $($controller.ToUpper()) (this may take a minute)..."

            $sessionParams = @{
                AdminAddress     = $controller
                DesktopGroupName = $DeliveryGroup
                DesktopKind      = 'Shared'
                MaxRecordCount   = $MaxRecordCount
            }

            Write-Progress -Activity 'Pulling session list' -Status $controller
            $sessions = Get-BrokerSession @sessionParams
            Write-Progress -Activity 'Pulling session list' -Completed
        }

        if ($sessions)
        {
            Write-Progress -Activity "Querying $($sessions.Length) desktops for vDisk information (${TimeOut} sec timeout)." -Status $controller

            $vDiskLookup = Get-VDiskInfo -ComputerName $sessions.HostedMachineName

            # Now we can loop through the sessions and handle them accordingly
            foreach ($session in $sessions)
            {
                try   { $vDisk = $vDiskLookup[$session.HostedMachineName] }
                catch { $vDisk = $null }

                $statusParams = @{
                    TargetVersionPattern = $TargetVersionPattern
                    AllVersionsPattern   = $AllVersionsPattern
                    DiskName             = $vDisk
                }

                $updateStatus = Get-UpdateStatus @statusParams

                # Propose an action based on update status
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

    if ($sessionReport)
    {
        'Session Summary' | Out-Header -Double
        $sessionReport | Format-Table -AutoSize
    }
}
#endregion Analysis


#region Actions
# Restart available outdated machines
foreach ($availableInfo in $availableReport)
{
    switch ($availableInfo.ProposedAction)
    {
        'Restart'
        {
            # Make sure the machine is still available before we reboot it.
            $refreshParams = @{
                AdminAddress = $availableInfo.AdminAddress
                HostedMachineName = $availableInfo.HostedMachineName
            }
            $currentMachine = Get-BrokerMachine @refreshParams

            if ($currentMachine.SummaryState -ne 'Available')
            {
                Write-Warning "$($currentMachine.HostedMachineName) is no longer available ($($currentMachine.SummaryState)). Skipping."
            }
            else
            {
                if (($restartCounter + $nagCounter) -lt $MaxActionsTaken)
                {
                    if ($PSCmdlet.ShouldProcess("$($availableInfo.HostedMachineName) (Available: No Session)", 'RESTART MACHINE'))
                    {
                        $restartParams = @{
                            AdminAddress = $availableInfo.AdminAddress
                            MachineName  = $currentMachine.MachineName
                            Action       = 'Restart'
                            ErrorAction  = 'Stop'
                        }
                        try
                        {
                            New-BrokerHostingPowerAction @restartParams > $null
                        }
                        catch
                        {
                            Write-Warning $_.Exception.Message
                            $restartFailCounter++
                        }

                        $restartCounter++
                    }
                }
            }
        }
    }
}

# Restart and/or nag sessions on outdated machines
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
                if (($restartCounter + $nagCounter) -lt $MaxActionsTaken)
                {
                    if ($PSCmdlet.ShouldProcess("$($sessionInfo.HostedMachineName) (Inactive Session)", 'RESTART MACHINE'))
                    {
                        $restartParams = @{
                            AdminAddress = $sessionInfo.AdminAddress
                            MachineName  = $currentSession.MachineName
                            Action       = 'Restart'
                            ErrorAction  = 'Stop'
                        }
                        try
                        {
                            New-BrokerHostingPowerAction @restartParams > $null
                        }
                        catch
                        {
                            Write-Warning $_.Exception.Message
                            $restartFailCounter++
                        }

                        $restartCounter++
                    }
                }
            } # if inactive

            # It's active now, we'll nag instead.
            else
            {
                if (($restartCounter + $nagCounter) -lt $MaxActionsTaken)
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
        } # 'Restart'

        'Nag'
        {
            if (($restartCounter + $nagCounter) -lt $MaxActionsTaken)
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
}
#endregion Actions


#region Breakdown
'Final Summary' | Out-Header -Double

foreach ($property in 'UpdateStatus', 'ProposedAction', 'DiskName')
{
    Out-Header -Header $property
    $sessionReport + $availableReport | Group-Object -Property $property -NoElement |
        Select-Object -Property Count,@{ n = $property; e = { $_.Name } } |
        Sort-Object -Property 'Count' -Descending |
        Format-Table -HideTableHeaders
}

"Total Nags Sent: ${nagCounter} (${nagFailCounter} failed)"
"Total Restarts Requested: ${restartCounter} (${restartFailCounter} failed)"

$elapsed = [int]((Get-Date) - $scriptStart).TotalSeconds
"Script completed in ${elapsed} seconds."
#endregion Breakdown
