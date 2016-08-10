<#
.NOTES

	Created on:   	8/9/2016 9:50 AM
	Created by:   	Andy Simmons
	URL:            https://github.com/andysimmons/vdi-utils
	Filename:     	Get-HypConnection.psm1

.SYNOPSIS
	Creates the Get-HypConnection function (maybe more later), which returns HypervisorConnection 
	objects using the Citrix Host SDK, or just their network address(es).
	
.DESCRIPTION
	There's no Citrix cmdlet to return a HypervisorConnection object with any useable address info, 
	if using vCenter/ESXi or SCVMM/Hyper-V. It's not usually desirable to bypass the Host service
	to manipulate objects directly on the hosting platform, but can be helpful for reporting, and
	if there's ever a need for direct interaction, this makes it easier.

	HypervisorConnection objects returned by the Broker SDK (e.g. with Get-BrokerHypervisorConnection) 
	provide at least a name and/or UID, and various Broker and Host SDK object properties reference them
	as well. This just sucks those in and spits out the address.

.PARAMETER AdminAddress
	DDC Address

.PARAMETER Connection
	Optionally specify a connection, either by UID (preferred) or Name.

.PARAMETER Parse
	When used with -Connection, parse the hypervisor address(es) and return it as a string/string[]. 
	Tested with vCenter, think it'll work with everything though.

.EXAMPLE
	Get-HypConnection -AdminAddress 'ddc01' -Connection 'vcenter connection' -Parse

	Returns just the address(es) from that 'vcenter connection' object on ddc01.

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


	# Dependency check
	$alMissingSnapin   = New-Object -TypeName System.Collections.ArrayList
	$arrRequiredSnapin = @('Citrix.Host.Admin.V2')

	foreach ($strRequiredSnapin in $arrRequiredSnapin)
	{
		Write-Verbose "Loading snap-in: $strRequiredSnapin"
		try   { Add-PSSnapin -Name $strRequiredSnapin -ErrorAction Stop }
		catch { $alMissingSnapin.Add($strRequiredSnapin) }
	}

	if ($alMissingSnapin)
	{
		Write-Error -Category NotImplemented "Missing $($alMissingSnapin -join ', ')"
		exit 1	
	}
	
	# Create an 'XDHyp' PSDrive to browse the Citrix Host Service datastore, then drop all of the
	# hypervisor connection objects into an array.
	try
	{
		Set-HypAdminConnection -AdminAddress $AdminAddress -ErrorAction Stop
		[object[]]$arrConnection = Get-ChildItem -Path 'XDHyp:\Connections' -ErrorAction Stop
	}
	catch { throw $_ }
	
	if (!$Connection) { return $arrConnection }
	
	else
	{
		# Try parsing the connection string as a GUID, otherwise we'll assume it's a name.
		try
		{
			[Guid]::Parse($Connection) > $null
			$boolGuid = $true
		}
		catch { $boolGuid = $false }

		if ($boolGuid)
		{
			[Citrix.Host.Sdk.HypervisorConnection]$hypConnection = $arrConnection | Where-Object {
				$_.HypervisorConnectionUid -eq $Connection 
			}
		}
		else
		{
			[Citrix.Host.Sdk.HypervisorConnection]$hypConnection = $arrConnection | Where-Object {
				$_.HypervisorConnectionName -eq $Connection	
			}
		}
		
		# Warn and bail if we didn't find any matches.
		if (!$hypConnection)
		{
			Write-Warning "No $AdminAddress hypervisor connection '$Connection'."
			return
		}
		
		# If we aren't parsing the address(es) out, return the connection object.
		elseif (!$Parse) { return $hypConnection }
		
		# Otherwise, try to parse connection address(es)
		else
		{
			[string[]]$arrAddress = $hypConnection.HypervisorAddress
			if (!$arrAddress)
			{
				Write-Warning "No address configured in $Connection."
				return
			}
			if ($arrAddress.Length -eq 1)
			{
				[uri]$uriAddress = $arrAddress[0]
				if ($uriAddress.DnsSafeHost) { return $uriAddress.DnsSafeHost    }
				else                         { return $uriAddress.OriginalString }
			}
			else
			{				
				[string[]]$arrParsed = foreach ($strAddress in $arrAddress)
				{
					[uri]$uriAddress = $strAddress
					if ($uriAddress.DnsSafeHost) { $uriAddress.DnsSafeHost    }
					else                         { $uriAddress.OriginalString }		
				}
				return $arrParsed
			}
		}
	}
}
Export-ModuleMember -Function Get-HypConnection
