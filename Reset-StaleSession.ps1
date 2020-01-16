[CmdletBinding(SupportsShouldProcess)]
param(
    [int]
    $TimeOutHrs = 13,

    [string]
    $DeliveryGroupFilter = "xdbp10slhs",

    [string]
    $AdminAddress = 'ctxddc01'
)

$now = Get-Date

# Get-BrokerSession params to retrieve relevant sessions that are disconnected
$gbsParams = @{
    AdminAddress = $AdminAddress
    DesktopGroupName = $DeliveryGroupFilter
    SessionState = 'Disconnected'
    MaxRecordCount = [int32]::MaxValue
}
$allDiscoSessions = Get-BrokerSession @gbsParams

# we just want sessions that have been disconnected for a while
$oldDiscoSessions = $allDiscoSessions.Where({$_.SessionStateChangeTime -lt ($now.AddHours(-$TimeOutHrs))})

if (-not $oldDiscoSessions.Count) {
    Write-Warning "No $DeliveryGroupFilter sessions found on $AdminAddress that have been disconnected more than $TimeOutHrs hours."
    exit
}
else {
    $targetSummary = "$($oldDiscoSessions.Count) disconnected '$DeliveryGroupFilter' sessions on '$AdminAddress' disconnected more than $TimeOutHrs hours"
    if ($PSCmdlet.ShouldProcess($targetSummary, "TERMINATE")) {
        $oldDiscoSessions | Stop-BrokerSession
    }
}
