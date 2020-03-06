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
#>
[CmdletBinding()]
param (
    [string[]]
    $AdminAddress = @('ctxddc01', 'sltctxddc01'),

    [datetime]
    $StartDateMin = (Get-Date).AddDays(-1),

    [datetime]
    $StartDateMax = (Get-Date),

    [regex]
    $CAGPattern = '^sl[bt]dmzvpx'
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

        if ($Double) { 
            ''
            $line
            $Header
            $line 
        }
        else { 
            ''
            $Header
            $line
        }
    }
}

# OData query setup
$dtFormat = 'yyyy\-MM\-dd\THH\:mm\:ss'
[string] $startDateMinUtc = Get-Date -Date $StartDateMin.ToUniversalTime() -Format $dtFormat
[string] $startDateMaxUtc = Get-Date -Date $StartDateMax.ToUniversalTime() -Format $dtFormat

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
$connections = foreach ($ddc in $AdminAddress) {
    try {
        $root = "http://$ddc/Citrix/Monitor/Odata/v3/Data/Connections()"
        [Uri] $uri = '{0}?$filter={1}&$select={2}&$expand={3}' -f $root, $filter, $select, $expand
        Write-Verbose "URI: $uri"

        $response = Invoke-JsonRequest -Uri $uri -UseDefaultCredentials -ErrorAction 'Stop'
    }
    catch { Write-Error "Barfed checking connections on $ddc. This report is likely incomplete." }

    # extract interesting info from each record
    foreach ($r in $response.d) {

        if ($r.ConnectedViaHostName) {
            if ($r.ConnectedViaHostName -match $CAGPattern) { $epLocation = 'EXTERNAL' }
            else { $epLocation = 'INTERNAL' }
        } 
        else { $epLocation = 'UNKNOWN' }
        
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

$connections = $connections | Sort-Object -Property 'UserName', 'SessionKey', 'CreatedDate'

# eventually feed this into PowerBI, just getting some quick info
Out-Header -Double "VDI Connections: $StartDateMin - $StartDateMax"
[pscustomobject] [ordered] @{
    TotalConnections = $connections.Count
    TotalSessions    = ($connections.SessionKey | Sort-Object -Unique).Count
    TotalUsers       = ($connections.UserName | Sort-Object -Unique).Count
} | Format-List

Out-Header 'Connections by Endpoint Location'
$connections | Group-Object -Property 'EndpointLocation' -NoElement | Format-Table

foreach ($loc in ('INTERNAL', 'EXTERNAL', 'UNKNOWN')) {
    Out-Header "$loc Connections by Delivery Group"
    $connections.where({ $_.EndpointLocation -eq $loc }) | 
    Sort-Object -Property 'SessionKey' -Unique |
    Group-Object -Property 'DeliveryGroup' -NoElement | 
    Format-Table
}