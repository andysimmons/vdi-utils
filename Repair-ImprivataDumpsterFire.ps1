using namespace System.Management.Automation 
#Requires -Version 5
#Requires -PSSnapin Citrix.Broker.Admin.V2

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string[]]
    $AdminAddress,

    [string]
    $DesktopGroupName = "XD*P10SLHS",

    [IO.FileInfo]
    $OutFile = "D:\diag\ProcDump-$(Get-Date -Format 'yyyyMMddHHmmss').json"
)

# TODO: probably need this in a wrapper since the SessionDebug class will depend
# on it, and '#requires' won't auto-load snapins.
Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop

enum SessionState {
    Unknown
    Hung
    Destroyed
    MiraculousRecovery
    QUERY_FAILED
}

# helper class to debug hung VMs/sessions
class SessionDebug {

    # properties
    [string] $AdminAddress
    [int] $SessionUid
    [bool] $LooksHung
    [SessionState] $SessionState
    [Management.Automation.JobState] $Diagnostics
    [Citrix.Broker.Admin.SDK.Session] $BrokerSession
    [Citrix.Broker.Admin.SDK.Machine] $BrokerMachine
    hidden [int] $JobId

    # constructors
    SessionDebug ([string] $AdminAddress, [int] $SessionUid) {
        $this.Initialize($AdminAddress, $SessionUid)
    }
    
    SessionDebug ([string] $UidAtAddress) {
        ([int] $SessionUid, [string] $AdminAddress) = $UidAtAddress -split '@'
        $this.Initialize($AdminAddress, $SessionUid)
    }

    # methods
    hidden [void] Initialize ( [string] $AdminAddress, [int] $SessionUid ) {
        $this.AdminAddress = $AdminAddress
        $this.DiagnosticStatus = [JobState]::NotStarted
        $this.JobId = -1
        $this.Refresh()
    }

    [void] Refresh() {
        $this.SessionState = [SessionState]::Unknown

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
            SessionUid   = $this.SessionUid
            ErrorAction  = 'Stop'
        }
        try { $this.BrokerMachine = Get-BrokerMachine @gbmParams }
        catch { $this.BrokerMachine = $null }

        
        # see if it looks like it's still hung
        if ($this.BrokerMachine) {
            $tbm = $this.BrokerMachine
            if ($tbm.LastConnectionFailure -eq 'None') {
                # if this happens, we're probably not correctly diagnosing sessions 
                # as "hung" in the first place
                $this.SessionState = [SessionState]::MiraculousRecovery
            }
            
            $this.LooksHung = ($tbm.LastConnectionFailure -in (Get-ValidFailureReason)) -and
            ($tbm.IsPhysical -eq $false) -and
            ($tbm.InMaintenanceMode -eq $false) -and
            ($tbm.SessionsEstablished -eq 1)
            
            if ($this.LooksHung) { $this.SessionState = [SessionState]::Hung }
        }

        # start diagnostics, if we haven't yet.
        if (($this.Diagnostics = [JobState]::NotStarted) -and ($this.JobId -eq -1)) {
            $this.RunDiagnostics($script:OutFile)
        }
    }

    [void] RunDiagnostics([IO.FileInfo] $OutFile) {
        # if we don't KNOW where to invoke this, immediately fail the job
        if (-not $this.BrokerSession.DNSName) {
            $this.Diagnostics = [JobState]::Failed
        }
        elseif ($this.JobId -eq -1) {
            # no job running yet, so fire it off
            $icmParams = @{
                ComputerName = $this.BrokerSession.DNSName
                AsJob        = $true
                ErrorAction  = 'Stop'
                ScriptBlock  = {
                    # export running processes to a json file
                    $of = ${using:OutFile}
                    try {
                        if (-not (Test-Path $of.Directory)) {
                            New-Item -ItemType Directory -Path $of.Directory -ErrorAction 'Stop' | Out-Null
                        }
                        Get-Process -IncludeUserName -ErrorAction 'Stop' |
                            ConvertTo-Json -Depth 5 |
                            Out-File -FilePath ${using:$OutFile}
                        
                    }
                    catch {
                        # log the exception before throwing it back to the job invoker
                        $of = '{0}\{1}_ERROR.{2}' -f $of.Directory, $of.BaseName, $of.Extension
                        ConvertTo-Json -Depth 5 -InputObject $_ | Out-File -FilePath $of
                        throw $_
                    }

                    # proc dumps can be huge, so we'll try to zip it
                    if (Test-Path $of) {
                        $outZip = '{0}\{1}.zip' -f $of.Directory, $of.BaseName
                        try {
                            Compress-Archive -Path $of -DestinationPath $outZip -Update -ErrorAction 'Stop'
                            Remove-Item -Path $of -ErrorAction 'Stop'
                            Get-Item 
                        } 
                        catch { Write-Warning $_.Exception.Message }
                    }
                }
            }
            $job = Invoke-Command @icmParams
            $this.JobId = $job.Id
            $this.Diagnostics = $job.State
        }
        else {
            # nonono, split refresh and run into separate methods. Gotta go though.
            # Might make sense to just make the job itself a property?
            $this.Diagnostics = Get-Job -Id 
        }
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
