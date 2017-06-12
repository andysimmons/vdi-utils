#requires -Version 4
<#
.NOTES
    Created on:     6/12/2017
    Created by:     Andy Simmons
    Organization:   St. Luke's Health System
    Filename:       Get-SessionsByReceiverType.ps1

.SYNOPSIS
    Searches established sessions to determine users running a particular
    version of Citrix Receiver.

.PARAMETER AdminAddress
    One or more Desktop Delivery Controllers

.PARAMETER ReceiverType
    General type of Receiver client

.EXAMPLE
    'siteA-ddc1','siteB-ddc1' | Get-SessionsByReceiverType.ps1 -ReceiverType ReceiverForWeb

    Retrieves all sessions across two sites with users running Receiver for Web.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory, ValueFromPipeline)]
    [string[]] 
    $AdminAddress,

    [ValidateSet(
        'ReceiverForWeb',
        'Receiver',
        'ProprietaryReceiver',
        'All')]
    [Parameter(Mandatory)]
    [string]
    $ReceiverType
)

begin 
{
    Add-PSSnapin -Name Citrix.Broker.Admin.V2 -ErrorAction Stop

    # build a scriptblock to retrieve all sessions
    $getAllSessions = [scriptblock] {
        Get-BrokerSession -AdminAddress $_ -MaxRecordCount ([int]::MaxValue)
    }

    # build filters to infer Receiver type from session metadata
    $recieverForWeb = [scriptblock] {
        ($_.ConnectionMode -eq 'Undefined') -and
        ($_.ClientPlatform -ne 'Unknown')
    }

    $receiver = [scriptblock] {
        ($_.ConnectionMode -eq 'Brokered') -and
        ($_.ClientPlatform -ne 'Unknown')
    }

    $proprietaryReceiver = [scriptblock] {
        ($_.ClientPlatform -eq 'Unknown')
    }

    $all = [scriptblock] { $true }

    switch ($ReceiverType)
    {
        'ReceiverForWeb'      { $receiverFilter = $recieverForWeb }
        'Receiver'            { $receiverFilter = $receiver }
        'ProprietaryReceiver' { $receiverFilter = $proprietaryReceiver }
        'All'                 { $receiverFilter = $all }
    }
}

process
{
    $AdminAddress.ForEach($getAllSessions).Where($receiverFilter)
}
