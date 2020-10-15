[CmdletBinding()]
param (
    [string]
    $SiteA = 'ctxddc01',

    [string]
    $SiteB = 'sltctxddc01',

    [string]
    $DeliveryGroup = 'XD*P10SLHS*'
)
Add-PSSnapin -Name Citrix.Broker.Admin.V2 -ErrorAction 'Stop'

# there's definitey a better way to do this, this is just super quick and dirty
$gbsParams = @{
    AdminAddress     = $SiteA
    MaxRecordCount   = [int32]::MaxValue
    DesktopGroupName = $DeliveryGroup
}
$aUsers = (Get-BrokerSession @gbsParams).UserUPN

$gbsParams.AdminAddress = $SiteB
$bUsers = (Get-BrokerSession @gbsParams).UserUPN

$multiSiteUsers = $aUsers.Where( { ($_ -in $bUsers) -and ($null -ne $_) } )

$aSite = Get-BrokerSite -AdminAddress $SiteA
$bSite = Get-BrokerSite -AdminAddress $SiteB

'*** {0} users found with a "{1}" session in both the "{2}" and "{3}" sites ***' -f $multiSiteUsers.Count, $DeliveryGroup, $aSite.Name, $bSite.Name
$multiSiteUsers | Sort-Object
