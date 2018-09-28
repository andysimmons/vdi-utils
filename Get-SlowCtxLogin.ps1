[CmdletBinding()]
param (
    [string[]]
    $AdminAddress = @('ctxddc01','sltctxddc01'),

    [datetime]
    $StartDateMin = (Get-Date).AddDays(-7),

    [datetime]
    $StartDateMax = (Get-Date),

    [int64]
    $LogonThresholdMs = 60000
)

function Invoke-JsonRequest
{
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
	$client = New-Object System.Net.WebClient
	
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

# query setup
$dtFormat = 'yyyy\-MM\-dd\THH\:mm\:ss'
[string] $startDateMinUtc = Get-Date -Date $StartDateMin.ToUniversalTime() -Format $dtFormat
[string] $startDateMaxUtc = Get-Date -Date $StartDateMax.ToUniversalTime() -Format $dtFormat
$root = "http://$ddc/Citrix/Monitor/Odata/v3/Data/Sessions()"
$select = "StartDate,LogOnDuration,User/UserName,Machine/HostedMachineName,Machine/HostingServerName,Machine/DesktopGroup/Name"
$filter = @(
    "(StartDate gt datetime'$StartDateMinUtc')"
    "(StartDate le datetime'$StartDateMaxUtc')"
    "(LogOnDuration ge $LogonThresholdMs)"
)
$expand = 'User,Machine,Machine/DesktopGroup'

# query slow login info
$sessions = foreach ($ddc in $AdminAddress) {
    try {
        [Uri] $uri = $root + '?$filter=' + $($filter -join ' and ') + '&$select=' + $select + '&$expand=' + $expand
        Write-Verbose "URI: $uri"
        $response = Invoke-JsonRequest -Uri $uri -UseDefaultCredentials -ErrorAction 'Stop'
    }
    catch { Write-Error "Barfed checking for slowpokes on $ddc. This report will probably be missing folks." }

    foreach ($session in $response.d) {
        [pscustomobject] [ordered] @{
            UserName = $session.User.UserName
            LogonDurationSec = [int] ($session.LogonDuration / 1000)
            StartDate = $session.StartDate
            DeliveryGroup = $session.Machine.DesktopGroup.Name
            VMName = $session.Machine.HostedMachineName
            VMHost = $session.Machine.HostingServerName
            DDC = $ddc
        }
    }
}

$sessions | Sort-Object -Property "LogonDurationSec" -Descending | Out-GridView
