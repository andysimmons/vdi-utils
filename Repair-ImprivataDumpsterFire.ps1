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
    $OutFile = "D:\Diagnostics\Get-Process_$(Get-Date -Format 'yyyyMMddHHmmss').json"
)

# TODO: probably need this in a wrapper since the SessionDebug class will depend
# on it, and '#requires' won't auto-load snapins.
Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop

# high-level session states we're interested in for debugging
enum SessionState {
    Unknown
    Hung
    Destroyed
    Working
    QUERY_FAILED
}

# remediation steps we may take
enum DebugAction {
    StartJob
    ReceiveJob
    Restart
    None
}

# helper class to debug VMs/sessions
class SessionDebug {

    # properties
    [Citrix.Broker.Admin.SDK.Machine] $BrokerMachine
    [Citrix.Broker.Admin.SDK.Session] $BrokerSession
    [SessionState] $SessionState
    [string] $AdminAddress
    [bool] $LooksHung
    [bool] $RestartIssued
    [int] $SessionUid
    [Job] $Job
    [JobState] $JobState
    [IO.FileInfo] $OutFile
    [DebugAction] $SuggestedAction
    [DebugAction[]] $ActionLog
    
    # constructors
    SessionDebug ([string] $AdminAddress, [int] $SessionUid) {
        $this.Initialize( 
            $AdminAddress, 
            $SessionUid, 
            "D:\Diagnostics\Get-Process_$(Get-Date -Format 'yyyyMMddHHmmss').json"
        )
    }

    SessionDebug ([string] $AdminAddress, [int] $SessionUid, [IO.FileInfo] $OutFile) {
        $this.Initialize($AdminAddress, $SessionUid, $OutFile)
    }

    # methods
    hidden [void] Initialize ([string] $AdminAddress, [int] $SessionUid, [IO.FileInfo] $OutFile) {
        $this.AdminAddress = $AdminAddress
        $this.SessionUid = $SessionUid
        $this.OutFile = $OutFile
        $this.LooksHung = $false
        $this.RestartIssued = $false
        $this.JobState = [JobState]::NotStarted
        $this.SuggestedAction = [DebugAction]::None
        
        # Pull session/machine info from DDCs
        $this.Refresh()
        
        if ($this.LooksHung) {
            # if it's hung, run some diagnostics
            $this.StartJob($OutFile)
        }
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

        
        # determine if session is working or hung
        if ($this.BrokerMachine) {
            $tbm = $this.BrokerMachine
            if ($tbm.LastConnectionFailure -eq 'None') {
                # if this happens, we're probably not correctly diagnosing sessions 
                # as "hung" in the first place
                $this.SessionState = [SessionState]::Working
            }
            
            $this.LooksHung = ($tbm.LastConnectionFailure -in (Get-ValidFailureReason)) -and
                ($tbm.IsPhysical -eq $false)        -and
                ($tbm.InMaintenanceMode -eq $false) -and
                ($tbm.SessionsEstablished -eq 1)
            
            if ($this.LooksHung) { $this.SessionState = [SessionState]::Hung }
        }

        # refresh job status
        if ($this.Job) {
            try { 
                $this.Job = Get-Job -Uid $this.Job.InstanceId -ErrorAction 'Stop'
                $this.JobState = $this.Job.State
            }
            catch { $this.JobState = [JobState]::Failed }
        }
    }

    [void] UpdateSuggestedAction () {
        if ($this.SuggestedAction -and ($this.SuggestedAction -eq $this.GetLastAction())) {

        }
        switch ($this.SuggestedAction) {
            # once we figure this out, probably want to end this with a default case and just return
            [DebugAction]::None { return }
            [DebugAction]::StartJob { }
            [DebugAction]::ReceiveJob { }
            [DebugAction]::Restart { }
            default { return }
        }
    }

    [DebugAction] GetLastAction () { return $this.ActionLog[-1] }

    [void] StartJob([IO.FileInfo] $OutFile) {
        if (-not $this.BrokerSession.DNSName) {
            # if we don't know where to invoke this, pre-emptively fail the job
            $this.JobState = [JobState]::Failed
            return
        }
        elseif ($this.Job -or ($this.JobState -eq [JobState]::Failed)) { 
            # there's either a job already, or it failed
            return 
        }
        else {
            # good to go -- set up remote diagnostics job
            $icmParams = @{
                ComputerName = $this.BrokerSession.DNSName
                AsJob        = $true
                ErrorAction  = 'Stop'
                ScriptBlock  = {
                    # export running processes to a json file for better detail
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
                        # export and log the exception before throwing it back to the job invoker
                        $of = '{0}\{1}_ERROR.{2}' -f $of.Directory, $of.BaseName, $of.Extension
                        ConvertTo-Json -Depth 5 -InputObject $_ | Out-File -FilePath $of
                        throw $_
                    }

                    # proc dumps get big, so we'll try to zip it
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

            # fire it off
            try {
                $this.Job = Invoke-Command @icmParams
                $this.JobState = $this.Job.State
            }
            catch { $this.JobState = [JobState]::Failed }
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
