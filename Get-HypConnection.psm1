<#
.NOTES

	Created on:   	8/9/2016 9:50 AM
	Created by:   	Andy Simmons
	Organization:	St. Luke's Health System
	Filename:     	Get-HypConnection.ps1

.SYNOPSIS
	Creates the Get-HypConnection function (maybe more later), which returns HypervisorConnection 
	objects using the Citrix Host SDK, or just their network address(es).
	
.DESCRIPTION
	There's no Citrix cmdlet to return a HypervisorConnection object with any useable address info, 
	if using vCenter/ESXi or SCVMM/Hyper-V. It's not usually desirable to bypass the Host service
	to manipulate objects on the hosting platform, but can be helpful for reporting, or could be 
	required in particular use cases.

	HypervisorConnection objects returned by the Broker SDK (Get-BrokerHypervisorConnection) provide
	name/UID that can be passed to this. There are various other places to see one of those two
	values, which can then be passed to this, to see the addresses or other conection info.

.PARAMETER AdminAddress
	DDC Address

.PARAMETER Connection
	Optionally specify a connection by UID (preferred) or Name.

.PARAMETER Parse
	When used with -Connection, parse the hypervisor address and return it as a string. Tested 
	with vCenter. Likely to work with all.

.EXAMPLE
	Get-HypConnection -AdminAddress 'ddc01' -Connection 'vcenter connection' -Parse

	Returns just the addresses from that 'vcenter connection' object on ddc01.

.EXAMPLE
	Get-HypConnection -AdminAddress 'ddc01' -Connection 'd8a9906c-798e-4ccb-9dad-ff558f01363f'

	Returns the matching Citrix.Host.Sdk.HypervisorConnection object.

.OUTPUTS
	object[], string[]
#>
function Get-HypConnection
{
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	[OutputType([object[]], ParameterSetName = 'Default')]
	[OutputType([string[]], ParameterSetName = 'Parse')]
	param
	(
		[Parameter(ParameterSetName = 'Default', Mandatory, Position = 0)]
		[Parameter(ParameterSetName = 'Parse', Mandatory, Position = 0)]
		[Alias('DDC')]
		[string]$AdminAddress,
		
		[Parameter(ParameterSetName = 'Default', Position = 1)]
		[Parameter(ParameterSetName = 'Parse', Mandatory, Position = 1)]
		[Alias('Name','UID')]
		[string]$Connection,
		
		[Parameter(ParameterSetName = 'Parse', Position = 2)]
		[switch]$Parse
	)


	Write-Verbose 'Loading Citrix Host Admin PS Snapin'
	try   { Add-PSSnapin -Name 'Citrix.Host.Admin.V2' -ErrorAction Stop }
	catch { throw $_ }
	
	Write-Verbose 'Retrieving connection objects from Host service datastore'
	try
	{
		Set-HypAdminConnection -AdminAddress $AdminAddress -ErrorAction Stop
		[array]$hypConnections = Get-ChildItem -Path 'XDHyp:\Connections' -ErrorAction Stop
	}
	catch { throw $_ }
	
	# If no connection UID/name was specified, return them all
	if (!$Connection) { return $hypConnections }
	
	else
	{
		# Try parsing the specified connection string as a GUID, otherwise we'll assume it's a name.
		try
		{
			[Guid]::Parse($Connection) > $null
			$isGuid = $true
		}
		catch { $isGuid = $false }

		if ($isGuid)
		{
			$hypConnection = $hypConnections | Where-Object { $_.HypervisorConnectionUid -eq $Connection }
		}
		else
		{
			$hypConnection = $hypConnections | Where-Object { $_.HypervisorConnectionName -eq $Connection }
		}
		
		if (!$hypConnection)
		{
			Write-Warning "No $AdminAddress hypervisor connection '$Connection'."
			return
		}
		
		# If we aren't parsing the address(es) out, return the matching connection object.
		elseif (!$Parse) { return $hypConnection }
		
		# Otherwise, try to parse connection address(es)
		else
		{
			[string[]]$hypAddresses = $hypConnection.HypervisorAddress
			if (!$hypAddresses)
			{
				Write-Warning "No address configured in $Connection."
				return
			}
			else
			{				
				[string[]]$parsedAddresses = foreach ($address in $hypAddresses)
				{
					try   { [uri]$address = $address }
					catch {	continue }
					
					if ($address.IsAbsoluteUri) { $address.DnsSafeHost    }
					else                        { $address.OriginalString }		
				}
				return $parsedAddresses
			}
		}
	}
}
Export-ModuleMember -Function Get-HypConnection
