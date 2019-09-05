using namespace System.Management.Automation 
#Requires -Version 5

[CmdletBinding()]
param (
    [string]
    $DesktopGroupName = "XD*P10SLHS",

    [IO.FileInfo]
    $OutFile = "D:\Diagnostics\PROCESSNAME_YYMMDD_HHMMSS.dmp",

    [int]
    $TimeOut = 30
)

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
    RefreshJob
    ReceiveJob
    Restart
    Ignore
}

# helper class to debug VMs/sessions
class SessionDebug {

    # properties
    [Citrix.Broker.Admin.SDK.Machine] $BrokerMachine
    [Citrix.Broker.Admin.SDK.Session] $BrokerSession
    [SessionState] $SessionState
    [string] $AdminAddress
    [string] $DNSName
    [bool] $LooksHung
    [bool] $RestartIssued
    [bool] $DebuggingComplete
    [bool] $JobReceived
    [int] $TimeOut
    [int] $SessionUid
    [Job] $Job
    [JobState] $JobState
    [object[]] $ActionResult
    [IO.FileInfo] $OutFile
    [string] $SuggestedAction
    [string[]] $ActionLog
    [string[]] $DebugInfo
    
    # constructors
    SessionDebug ([string] $AdminAddress, [int] $SessionUid) {
        $this.Initialize( 
            $AdminAddress, 
            $SessionUid, 
            "D:\Diagnostics\PROCESSNAME_YYMMDD_HHMMSS.dmp",
            30
        )
    }

    SessionDebug ([string] $AdminAddress, [int] $SessionUid, [IO.FileInfo] $OutFile, [int] $TimeOut) {
        $this.Initialize($AdminAddress, $SessionUid, $OutFile, $TimeOut)
    }

    # methods
    hidden [void] Initialize ([string] $AdminAddress, [int] $SessionUid, [IO.FileInfo] $OutFile, [int] $TimeOut) {
        $this.AdminAddress = $AdminAddress
        $this.SessionUid = $SessionUid
        $this.OutFile = $OutFile
        $this.TimeOut = $TimeOut
        $this.LooksHung = $false
        $this.RestartIssued = $false
        $this.JobState = [JobState]::NotStarted
        $this.JobReceived = $false
        
        # Pull session/machine info from DDCs, refresh job info, and suggested actions
        $this.Refresh()

        if ($this.BrokerSession) {
            $this.DNSName = $this.BrokerSession.DNSName
        }
        
        if ($this.LooksHung) {
            $this.DebuggingComplete = $false
            $this.StartSuggestedAction()
        }
        else { $this.DebuggingComplete = $true }
    }

    [SessionDebug] Refresh() {
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
                $this.DebuggingComplete = $true
            }
            
            $this.LooksHung = ($tbm.LastConnectionFailure -in (Get-ValidFailureReason)) -and
                ($tbm.IsPhysical -eq $false)        -and
                ($tbm.InMaintenanceMode -eq $false) -and
                ($tbm.SessionsEstablished -eq 1)
            
            # DELETE THIS LATER - having trouble hanging sessions on purpose to troubleshoot
            if ($tbm.AssociatedUserUPNs -contains 'simmonsa@slhs.org' -and $tbm.SessionsEstablished -eq 1) {
                $this.LooksHung = $true
                $this.DebuggingComplete = $false
            }

            if ($this.LooksHung) { 
                $this.SessionState = [SessionState]::Hung
            }
        }
        else { 
            # no machine tied to that session anymore, nothing to do
            $this.DebuggingComplete = $true 
        }

        # refresh job status
        $this.RefreshJob()

        # update debugging recommendations
        $this.UpdateSuggestedAction()

        return $this
    }

    hidden [void] RefreshJob () {

        if ($this.Job) {
            try {
                # update job-related properties
                $this.Job = Get-Job -Id $this.Job.Id -ErrorAction 'Stop'
                $this.JobState = $this.Job.State
            }
            catch {
                if ($_.CategoryInfo.Category -eq 'ObjectNotFound') {
                    # job appears to have been removed - update the JobState property
                    # to reflect the last known state of the job (if possible) and then
                    # clear the job property
                    if ($this.Job) { $this.JobState = $this.Job.State }
                    
                    $this.Job = $null
                }
                else {
                    $this.JobState = [JobState]::Failed 
                    $this.DebugInfo += "RefreshJob(): Get-Job exception: $($_.Exception.Message)"
                }
            }

            # check for job timeout
            if ($this.Job.PSBeginTime -and -not $this.Job.PSEndTime) {
                $expiration = $this.Job.PSBeginTime.AddSeconds($this.TimeOut)
                if ((Get-Date) -gt $expiration) {
                    # we're past our timeout, so consider the job "failed". We'll still leave
                    # the job alone in case it has a chance to finish before we reset the VM.
                    $this.JobState = [JobState]::Failed
                    $this.DebugInfo += "RefreshJob(): Job timed out."
                }
            }
        }
    }

    [void] UpdateSuggestedAction () {
        # only call this from Refresh()
        if ((-not $this.LooksHung) -or $this.DebuggingComplete) { 
            # nothing's wrong, or there's nothing we can do, so don't touch it
            $this.SuggestedAction = [DebugAction]::Ignore
            $this.DebuggingComplete = $true
        }
        elseif ($this.ActionLog) {
            # we just performed an action on a hung session. suggest the next one
            switch ($this.ActionLog[-1]) {    
                'Ignore' { }
                'StartJob' {
                    # just fired a job, so we'll watch for it to finish
                    $this.SuggestedAction = [DebugAction]::RefreshJob
                }
                'RefreshJob' {
                    $this.RefreshJob()
                    if ($this.JobState -eq [JobState]::Failed) {
                        if ($this.Job.HasMoreData) { 
                            # job failed or timed out, but has output we can receive
                            $this.SuggestedAction = [DebugAction]::ReceiveJob 
                        }
                        else { 
                            # job failed and produced no output, just restart it
                            $this.SuggestedAction = [DebugAction]::Restart 
                        }
                    }
                    elseif ($this.Job.PSEndTime) {
                        # job's done, receive it
                        $this.SuggestedAction = [DebugAction]::ReceiveJob
                    }
                }
                'ReceiveJob' {
                    $this.SuggestedAction = [DebugAction]::Restart
                }
                'Restart' {
                    $this.SuggestedAction = [DebugAction]::Ignore
                    $this.DebuggingComplete = $true
                }
            }
        }
        else {
            # session is hung and we haven't touched it yet, suggest starting a diagnostics job
            $this.SuggestedAction = [DebugAction]::StartJob
            $this.DebugInfo += "UpdateSuggestedAction(): ActionLog was empty. Suggesting StartJob."
        }
    }

    # Call all actions through this method so it gets logged accordingly
    [void] StartAction([DebugAction] $Action) {
        switch ($Action) {
            'StartJob' { $this.StartJob() }
            'RefreshJob' { $this.RefreshJob() }
            'ReceiveJob' { $this.ReceiveJob() } 
            'Restart' { $this.Restart() }
            'Ignore' { }
            default { 
                $this.DebugInfo += "StartAction(): $Action was passed, but I couldn't figure out what to do with it." 
                return
            }
        }
        $this.ActionLog += $Action
    }

    [void] StartSuggestedAction () {
        $action = $this.SuggestedAction
        if ($action) {
            $this.StartAction($action)
        }
        else { $this.DebugInfo += "StartSuggestedAction(): SuggestedAction was null." }
    }

    hidden [void] StartJob() {

        if (-not $this.BrokerSession.DNSName) {
            # if we don't know where to invoke this, pre-emptively fail the job
            $this.JobState = [JobState]::Failed
            $this.DebugInfo += "StartJob(): BrokerSession.DNSName was null."
            return
        }
        elseif ($this.Job -or ($this.JobState -eq [JobState]::Failed)) { 
            # there's either a job already, or it failed
            return 
        }
        else {
            # good to go -- set up remote diagnostics job
            $of = $this.OutFile
            $icmParams = @{
                ComputerName = $this.BrokerSession.DNSName
                AsJob        = $true
                ErrorAction  = 'Stop'
                ScriptBlock  = {
                    # export running processes to a json file for better detail
                    $of = ${using:of}
                    try {
                        if (-not $of.Directory.Exists) {
                            New-Item -ItemType Directory -Path $of.Directory -ErrorAction 'Stop' | Out-Null
                        }
                        <# just kidding -- need procdump.exe for this specific issue. Commenting for now
                        Get-Process -IncludeUserName -ErrorAction 'Stop' |
                            ConvertTo-Json -Depth 5 |
                            Out-File -FilePath $of
                        #>
                        Get-ChildItem -Path $of.Directory -Name "*.$($of.Extesnion)" | Remove-Item -Confirm:$false -Force
                        C:\Tools\Monitors\procdump64.exe -accepteula -W -ma ssomanhost64 "$of"
                    }
                    catch {
                        # export and log the exception before throwing it back to the job invoker
                        $of = '{0}\{1}_ERROR.json' -f ($of.Directory, $of.BaseName)
                        ConvertTo-Json -Depth 5 -InputObject $_ | Out-File -FilePath $of
                        throw $_
                    }

                    # this won't really work here since procdump.exe interprets parts of the filename
                    # we could work around it but I need to get this in sooner than later, it's low priority
                    # to compress the dump file (cuts the dump size in about half).
                    # if we ever use this for other reasons, 
                    <#if (Test-Path $of) {
                        $outZip = "$of" -replace '\.[^\.]+$','.zip'
                        try {
                            Compress-Archive -Path $of -DestinationPath $outZip -Update -ErrorAction 'Stop'
                            Remove-Item -Path $of -ErrorAction 'Stop'
                        } 
                        catch { Write-Warning $_.Exception.Message }
                    }#>
                }
            }

            # fire it off
            try {
                $this.Job = Invoke-Command @icmParams
                $this.JobState = $this.Job.State
            }
            catch { 
                $this.JobState = [JobState]::Failed 
                $this.DebugInfo += "StartJob(): $($_.Exception.Message)"
            }
        }
    }

    hidden [void] ReceiveJob () {
        if ($this.Job) {
            try {
                $rjParams = @{
                    InstanceId    = $this.Job.InstanceId
                    Wait          = $true
                    AutoRemoveJob = $true
                    ErrorAction   = 'Stop'
                }
                $this.ActionResult += Receive-Job @rjParams
                $this.JobReceived = $true
            }
            catch { $this.ActionResult += $_.Exception }
        }
        else {
            $this.DebugInfo += "ReceiveJob(): Job was null."
        }
    }

    hidden [void] Restart() {
        if ($this.BrokerMachine -and -not $this.RestartIssued) {
            # we have a machine, and we haven't tried restarting it yet
            try {
                $nbhpaParams = @{
                    AdminAddress = $this.AdminAddress
                    MachineName = $this.BrokerMachine.MachineName
                    Action = 'Reset'
                    ErrorAction = 'Stop'
                }
                $this.ActionResult += (New-BrokerHostingPowerAction @nbhpaParams | Format-List | Out-String)
            }
            catch { $this.ActionResult += $_.Exception }

            $this.RestartIssued = $true
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

        [Parameter(Mandatory)]
        [string]
        $DesktopGroupName,

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
    # debugging workaround since I can't easily simulate a hung session, so we'll
    # also consider any session I'm connected to as "hung", regardless of last connection result.
    $gbmParams.Filter = { AssociatedUserUPNs -contains 'simmonsa@slhs.org' }
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
