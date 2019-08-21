#Requires -Version 5
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string[]]
    $AdminAddress,

    [string]
    $DesktopGroupName = "XD*P10SLHS"
)

# because "#requires" won't auto-load snapins and Citrix doesn't provide modules.
Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop

enum DiagnosticStatus {
    NotStarted
    Requested
    Running
    Completed
    Aborted
}
enum SessionState {
    Active
    Connected
    Destroyed
    MiraculousRecovery
    QUERY_FAILED
}

class SessionDebug {

    # properties
    [string] $AdminAddress
    [int] $SessionUid
    [SessionState] $SessionState
    [bool] $LooksHung
    [Citrix.Broker.Admin.SDK.Machine] $BrokerMachine
    [Citrix.Broker.Admin.SDK.Session] $BrokerSession
    [DiagnosticStatus] $DiagnosticStatus
    
    # constructors
    SessionDebug ([string] $AdminAddress, [int] $SessionUid) {
        $this.Initialize($AdminAddress, $SessionUid)
    }

    # methods
    hidden [void] Initialize ( [string] $AdminAddress, [int] $SessionUid ) {
        $this.AdminAddress = $AdminAddress
        $this.DiagnosticStatus = 'NotStarted'
    }

    [void] Refresh() {
        # refresh session
        $gbsParams = @{
            AdminAddress = $this.AdminAddress
            Uid          = $this.SessionUid
            ErrorAction  = 'Stop'
        }
        try { $this.BrokerSession = Get-BrokerSession @gbsParams }
        catch { 
            if ($_.CategoryInfo.Category -eq 'ObjectNotFound') {
                $this.SessionState = [SessionState]::Destroyed
            }
            else { $this.SessionState = [SessionState]::QUERY_FAILED }

            $this.BrokerSession = $null 
        }

        # refresh machine
        $gbmParams = @{
            AdminAddress = $this.AdminAddress
            SessionUid = $this.SessionUid
            ErrorAction = 'Stop'
        }
        try { $this.BrokerMachine = Get-BrokerMachine @gbmParams }
        catch { $this.BrokerMachine = $null }

        if ($this.BrokerMachine.LastConnectionFailure -eq 'None') {
            # if this happens, we're probably not correctly diagnosing sessions 
            # as "hung" in the first place
            $this.SessionState = [SessionState]::MiraculousRecovery
        }
        
        $hungNow = $this.BrokerMachine.LastConnectionFailure -in (Get-ValidFailureReason) -and
            

    }
}

# returns failure reasons we typically only see on hung sessions
function Get-ValidFailureReason {
    return ('SessionPreparation', 'RegistrationTimeout', 'ConnectionTimeout')
}

function Get-HungSession {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]]
        $AdminAddress,

        [string]
        $DesktopGroupName = ${script:DesktopGroupName},

        [Parameter(HelpMessage = 'Connection failure reason(s) associated with hung sessions.')]
        [string[]]
        $FailureReason = (Get-ValidFailureReason)
    )

    # these params will grab "hung" VMs with an established session in relevant delivery group(s)
    $gbmParams = @{
        Filter              = { LastConnectionFailure -in $FailureReason }
        IsPhysical          = $false
        ErrorAction         = 'Stop'
        AdminAddress        = $a
        MaxRecordCount      = [int]::MaxValue
        DesktopGroupName    = $DesktopGroupName
        InMaintenanceMode   = $false
        SessionsEstablished = 1
    }
    foreach ($a in $AdminAddress) {
        $gbmParams.AdminAddress = $a
        try {
            Get-BrokerMachine @gbmParams | 
            Select-Object *, @{ n = 'AdminAddress'; e = $a }
        }
        catch {
            Write-Warning "Encountered an error looking for inaccessible broker machines on $a."
            Write-Warning $_.Exception.Message
        }
        
    }
}
