[CmdletBinding()]
param (
    [string[]]
    $ComputerName = 'localhost',

    [string]
    $LogName = 'Application',

    [string]
    $Source = 'Citrix Automation',

    [string]
    $InstanceId = 2,

    [datetime]
    $Before = (Get-Date),

    [datetime]
    $After = ($Before.AddDays(-7)),

    [string]
    $Pattern = '^Hostname'
)

$gelParam = @{
    ComputerName = $ComputerName
    Source       = $Source
    LogName      = $LogName
    InstanceId   = $InstanceId
    Before       = $Before
    After        = $After
}
    
Write-Verbose "[$(Get-Date -f G)] Searching event logs using the following params:"
$gelParam | Out-String | Write-Verbose
    
$eventData = Get-EventLog @gelParam
Write-Verbose "[$(Get-Date -f G)] Analyzing $($eventData.Count) events..."

$totals = foreach ($event in $eventData) {
    [pscustomobject] @{
        Date         = $event.TimeGenerated
        ComputerName = $event.MachineName
        Matches      = (($event.Message -split "`n") -Match $Pattern).Count
    }
}
$totals
