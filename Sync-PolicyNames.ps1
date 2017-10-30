<#
.NOTES
    Name:    Sync-PolicyNames.ps1
    Author:  Andy Simmons
    Date:    10/30/2017
    Version: 1.0.0
    URL:     https://github.com/andysimmons/vdi-utils/
    
.SYNOPSIS
    Synchronizes the names of entitlement policies with their
    associated delivery groups

.DESCRIPTION
    Written to help deal with delivery group renames, and make it
    easier to understand which entitlement policies are associated
    with which groups.

.PARAMETER AdminAddress
    DDC address

.PARAMETER DeliveryGroupName
    Optionally specify an individual delivery group.

.EXAMPLE
    .\Sync-PolicyNames.ps1 -AdminAddress 'ctxddc01' -WhatIf

    Simulates synchronizing policy names with delivery group names for all
    delivery groups on CTXDDC01.

.EXAMPLE
    .\Sync-PolicyNames.ps1 -AdminAddress 'ctxddc01' -DeliveryGroup "My Group" -Verbose

    Synchronizes the entitlement policy name for just the "My Group" delivery group.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param
(
    [Parameter(Mandatory)]
    [string]
    $AdminAddress,

    [string]
    $DeliveryGroupName = "*"	
)

function Get-PolicyMappings 
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $AdminAddress,

        [string]
        $DeliveryGroupName
    )

    $entitlementPolicies = @(Get-BrokerEntitlementPolicyRule -AdminAddress $AdminAddress)

    foreach ($entitlementPolicy in $entitlementPolicies) 
    {
        try
        { 
            $getParams = @{
                Uid          = $entitlementPolicy.DesktopGroupUid
                AdminAddress = $AdminAddress
                ErrorAction  = 'Stop' 
            }
            $deliveryGroup = Get-BrokerDesktopGroup @getParams
        }
        catch
        {
            Write-Warning "Delivery group lookup error for policy '$($entitlementPolicy.Name)'! Skipping."
            Write-Warning $_.Exception.Message
            continue
        }

        [psobject] [ordered] @{
            DeliveryGroupName     = $deliveryGroup.Name
            DeliveryGroupUid      = $deliveryGroup.Uid
            EntitlementPolicyName = $entitlementPolicy.Name
            EntitlementPolicyUid  = $entitlementPolicy.Uid
        }
    }
}

try   { Add-PSSnapin 'Citrix.Broker.Admin.V2' -ErrorAction 'Stop' }
catch { throw "Couldn't load Citrix broker cmdlets! Bailing out. $($_.Exception.Message)" }

$renameCounter = 0
$policyMappings = @(Get-PolicyMappings -AdminAddress $AdminAddress -DeliveryGroupName $DeliveryGroupName)

foreach ($policyMapping in $policyMappings) 
{
    $groupName  = $policyMapping.DeliveryGroupName
    $policyName = $policyMapping.EntitlementPolicyName

    # Citrix automatically creates entitlement policies when delivery groups are created 
    # using this format: 
    $autoName = "${groupName}_1"

    if ($autoName -match $policyName)
    {
        Write-Verbose "Delivery group '$groupName' entitlement policy already matches."
    }
    else
    {
        if ($PSCmdlet.ShouldProcess($policyName, "rename policy to: $autoName"))
        {
            try
            {
                $renameParams = @{
                    Name         = $policyName
                    NewName      = $autoName
                    AdminAddress = $AdminAddress
                    ErrorAction  = 'Stop'
                }
                Rename-BrokerEntitlementPolicyRule @renameParams

                $renameCounter++
            }
            catch
            {
                Write-Warning "Couldn't rename policy '$policyName' to match delivery group '$groupName'."
                Write-Warning $_.Exception.Message
            }
        }
    }
}

"All done! Renamed $renameCounter policies."
