<#
.NOTES
    Name:   Get-ConnectionsByDeviceLocation.ps1
    Author: Andy Simmons
    Date:   3/6/2020

.SYNOPSIS
    Summarizes recent Citrix app/desktop connections, users, and endpoints over
    a given date range.

.DESCRIPTION
    Goal is to understand more about remote workers. Work in progress.

    Need to understand how many active users we have, where they're connecting 
    from, and what they're connecting to, and how they leverage roaming, all across
    multiple Citrix sites/farms.

.PARAMETER AdminAddress
    Citrix Delivery Controller hostname/FQDN(s). Specify exactly one per site.

.PARAMETER StartDateMin
    Filters out sessions that started before this date.

.PARAMETER StartDateMax
    Filters out sessions that started after this date.

.PARAMETER CAGPattern
    Pattern used to determine if the 'ConnectedViaHostName' property on a connection
    record matches a Citrix Access Gateway
.PARAMETER MaxHourPerQuery
    Maximum number of hours (timespan) when querying the DDCs. There's probably a better
    way to throttle/paginate, but this works until I figure that out.
#>
[CmdletBinding()]
param (
    [string[]]
    $AdminAddress = @('ctxddc01', 'sltctxddc01'),

    [datetime]
    $StartDateMin = (Get-Date).AddDays(-7),

    [datetime]
    $StartDateMax = (Get-Date),

    [regex]
    $CAGPattern = '^sl[bt]dmzvpx',

    [int]
    $MaxHoursPerQuery = '24'
)

function Invoke-JsonRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $Uri,

        [Net.ICredentials]
        $Credentials,

        [switch]
        $UseDefaultCredentials,

        [Microsoft.PowerShell.Commands.WebRequestMethod]
        $Method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Get
    )

    $result = $null
    $client = [System.Net.WebClient]::new()

    if ($Credentials) { $client.Credentials = $Credentials }
    elseif ($UseDefaultCredentials) {
        $client.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }

    $client.Headers.Add("Content-Type", "application/json;odata=verbose")
    $client.Headers.Add("Accept", "application/json;odata=verbose")
    $rawText = $client.DownloadString($Uri)
    $client.Dispose()

    $result = $rawText | ConvertFrom-Json -ErrorAction Stop
    $result
}

function Out-Header {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Header,

        [switch]$Double
    )
    process {
        $line = $Header -replace '.', '-'
        
        if ($Double) { '', $line, $Header, $line }
        else         { '', $Header, $line }
    }
}

function Get-ConnectionsByDeviceLocation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]]
        $AdminAddress,

        [Parameter(Mandatory)]
        [datetime]
        $StartDateMin,
    
        [Parameter(Mandatory)]
        [datetime]
        $StartDateMax,
    
        [Parameter(Mandatory)]
        [regex]
        $CAGPattern,

        [Parameter(Mandatory)]
        [int]
        $MaxHoursPerQuery
    )

    $batchStart = $StartDateMin
    $batchStop = $StartDateMax
    $totalHours = [math]::Round(($batchStop - $batchStart).TotalHours, 1)
    if ($totalHours -gt $MaxHoursPerQuery) {
        Write-Warning "Date range specified is $totalHours hours. Splitting into $MaxHoursPerQuery hour batches."
        $batchStop = $batchStart.AddHours($MaxHoursPerQuery)
    }

    while ($batchStart -le $startDateMax) {
        # OData query setup
        $dtFormat = 'yyyy\-MM\-dd\THH\:mm\:ss'
        [string] $startDateMinUtc = Get-Date -Date $batchStart.ToUniversalTime() -Format $dtFormat
        [string] $startDateMaxUtc = Get-Date -Date $batchStop.ToUniversalTime() -Format $dtFormat

        $select = @(
            'CreatedDate'
            'ClientName'
            'ConnectedViaHostName'
            'SessionKey'
            'Session/StartDate'
            'Session/User/UserName'
            'Session/Machine/HostedMachineName'
            'Session/Machine/HostingServerName'
            'Session/Machine/DesktopGroup/Name'
        ) -join ','
    
        $filter = @(
            "(CreatedDate gt datetime'$StartDateMinUtc')"
            "(CreatedDate le datetime'$StartDateMaxUtc')"
        ) -join ' and '
        
        $expand = @(
            'Session'
            'Session/User'
            'Session/Machine'
            'Session/Machine/DesktopGroup'
        ) -join ','
            
        # query each DDC
        foreach ($ddc in $AdminAddress) {
            try {
                $root = "http://$ddc/Citrix/Monitor/Odata/v3/Data/Connections()"
                [Uri] $uri = '{0}?$filter={1}&$select={2}&$expand={3}' -f $root, $filter, $select, $expand
                Write-Verbose "URI: $uri"

                $response = Invoke-JsonRequest -Uri $uri -UseDefaultCredentials -ErrorAction 'Stop'
            }
            catch { Write-Error "Barfed checking connections on $ddc. This report is likely incomplete." }

            # extract interesting info from each record
            foreach ($r in $response.d) {

                if ($r.ConnectedViaHostName -match $CAGPattern) { $epLocation = 'EXTERNAL' }
                else { $epLocation = 'INTERNAL' }
        
                [pscustomobject] [ordered] @{
                    UserName             = $r.Session.User.UserName
                    CreatedDate          = $r.CreatedDate.ToLocalTime()
                    EndpointLocation     = $epLocation
                    EndpointName         = $r.ClientName
                    ConnectedViaHostName = $r.ConnectedViaHostName
                    SessionStart         = $r.Session.StartDate.ToLocalTime()
                    DeliveryGroup        = $r.Session.Machine.DesktopGroup.Name
                    VMName               = $r.Session.Machine.HostedMachineName
                    VMHost               = $r.Session.Machine.HostingServerName
                    SessionKey           = $r.SessionKey
                    DDC                  = $ddc
                }
            }
        }

        # set date range for next batch
        $batchStart = $batchStart.AddHours($MaxHoursPerQuery)
        $batchStop = $batchStop.AddHours($MaxHoursPerQuery)
        if ($batchStop -gt $StartDateMax) { $batchStop = $startDateMax }
    }
}

Write-Output "[$(Get-Date -f G)] Retrieving connections from $StartDateMin - $StartDateMax ..."
$gcbdlParams = @{
    AdminAddress     = $AdminAddress
    StartDateMin     = $StartDateMin
    StartDateMax     = $StartDateMax
    CAGPattern       = $CAGPattern
    MaxHoursPerQuery = $MaxHoursPerQuery
}
$connections = Get-ConnectionsByDeviceLocation @gcbdlParams
Write-Output "[$(Get-Date -f G)] Analyzing connections..."

# this speeds up subsequent 'sort -unique' operations
$connections = $connections | Sort-Object -Property 'UserName', 'SessionKey', 'CreatedDate'

# eventually feed this into PowerBI, just getting some quick info
Out-Header -Double "VDI Connections: $StartDateMin - $StartDateMax"
[pscustomobject] [ordered] @{
    TotalConnections = $connections.Count
    TotalSessions    = ($connections.SessionKey | Sort-Object -Unique).Count
    TotalUsers       = ($connections.UserName | Sort-Object -Unique).Count
} | Format-List

Out-Header 'Connections by Endpoint Location'
$connections | Group-Object -Property 'EndpointLocation' -NoElement | Format-Table -AutoSize

# this is really inefficient but I need data ASAP, fix later
foreach ($location in ($connections.EndpointLocation | Sort-Object -Unique)) {
    $locConnections = $connections.Where({$_.EndpointLocation -eq $location})
    $locUsers = $locConnections.UserName | Sort-Object -Unique
    Out-Header "Total $location users: $($locUsers.Count)" -Double

    Out-Header "SESSIONS accessed via $location connections by Delivery Group"
    $connections.where({ $_.EndpointLocation -eq $location }) | 
        Sort-Object -Property 'SessionKey' -Unique |
        Group-Object -Property 'DeliveryGroup' -NoElement | 
        Sort-Object -Property 'Count' -Descending |
        Format-Table -AutoSize
}