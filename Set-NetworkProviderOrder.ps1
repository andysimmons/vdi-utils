<#	
.NOTES
    Created on:   2/10/2017
    Created by:   Andy Simmons
    Organization: St. Luke's Health System
    Filename:     Set-NetworkProviderOrder.ps1

.SYNOPSIS
    Moves one of the network provider registry entries to the front of the line.

.DESCRIPTION
    Not sure if this will fix anything, but it'll make a diagnostic pass for one
    of our vendors, so we can continue troubleshooting accordingly.

.LINK
    https://github.com/andysimmons/vdi-utils/blob/master/Set-NetworkProviderOrder.ps1

.PARAMETER RegistryKey
    Path to the registry key where the network provider order is defined.

.PARAMETER KeyProperty
    The specific property defining the network provider order.

.PARAMETER PriorityElement
    Specifies the element (provider) that should be moved to the front of the list.

.EXAMPLE
    Set-NetworkProviderOrder.ps1 -WhatIf -Verbose

    Explains what would happen if the script were run with the default parameters, but
    does not make any changes.

.EXAMPLE
    Set-NetworkProviderOrder.ps1

    Runs the script with the default parameters, and attempts to sort elements accordingly.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RegistryKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkProvider\order',
    [string]$KeyProperty = 'ProviderOrder',
    [string]$PriorityElement = 'PnSson'
)


Write-Verbose "Looking for registry key: ${RegistryKey}..."
if (!(Test-Path $RegistryKey))
{
    Write-Error -Category ObjectNotFound "Couldn't find registry key '${RegistryKey}'. Aborting."
    exit 1
}


Write-Verbose "Verifying '${KeyProperty}' property exists on that key..."
try 
{
    $currentValue = (Get-ItemProperty $RegistryKey -Name $KeyProperty -ErrorAction Stop).$KeyProperty
    Write-Verbose "${KeyProperty}: ${currentValue}" 
}
catch 
{
    Write-Error "Error reading property '${KeyProperty}' on key '${RegistryKey}'. Aborting."
    throw $_
}


[Collections.ArrayList]$elements = $currentValue -split ','
if ($elements -contains $PriorityElement)
{
    Write-Verbose "Moving element '${PriorityElement}' to the front of the line."
    $elements.Remove($PriorityElement)
    $elements.Insert(0, $PriorityElement)
    $newValue = $elements -join ','

    Write-Verbose "Current Order: $currentValue"
    Write-Verbose "Correct Order: $newValue"

    # Overriding the native Set-ItemProperty -WhatIf/-Confirm behavior to make the intention clear.
    if ($PSCmdlet.ShouldProcess("${RegistryKey}\${KeyProperty}", "Sort Elements"))
    {
        $setItemParams = @{
            Path     = $RegistryKey
            Name     = $KeyProperty
            Value    = $newValue
            Force    = $true
            PassThru = $true
            WhatIf   = $false
            Confirm  = $false
        }
        Set-ItemProperty @setItemParams
    }
}

else
{
    Write-Verbose "Element '${PriorityElement}' not found. Nothing to do."
}
