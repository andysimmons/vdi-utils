<#
.NOTES
    Name:    Get-PolicyMappings.ps1
    Author:  Andy Simmons
    Date:    08/24/2016
    Version: 1.0.0
    URL:     https://github.com/andysimmons/vdi-utils/
.SYNOPSIS
	Summarizes the relationship between Delivery Groups and
	Entitlement Policies.

.DESCRIPTION
	Written to help deal with delivery group renames.

.PARAMETER AdminAddress
	DDC address

.PARAMETER DeliveryGroupName
	Optionally specify an individual delivery group.

.EXAMPLE
	PS C:\> Get-PolicyMappings -AdminAddress 'ctxddc01'
#>
function Get-PolicyMappings {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[string]$AdminAddress,

		[string]$DeliveryGroupName = "*"
	)

	process {
		$entitlementPolicies = @(Get-BrokerEntitlementPolicyRule -AdminAddress $AdminAddress)
		foreach ($entitlementPolicy in $entitlementPolicies) {
			$deliveryGroup = Get-BrokerDesktopGroup -Uid $entitlementPolicy.DesktopGroupUid -AdminAddress $AdminAddress
			New-Object -TypeName System.Management.Automation.PSObject -Property @{
				DeliveryGroupName     = $deliveryGroup.Name
				DeliveryGroupUid      = $deliveryGroup.Uid
				EntitlementPolicyName = $entitlementPolicy.Name
				EntitlementPolicyUid  = $entitlementPolicy.Uid
			} | Select-Object DeliveryGroupName,DeliveryGroupUid,EntitlementPolicyName,EntitlementPolicyUid
		}
	}
}
