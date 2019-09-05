<#
.NOTES
    Created on:   09/05/2019
    Created by:   Andy Simmons
    Organization: St. Luke's Health System
    FileName:     Repair-ImprivataDumpsterFire.ps1

.SYNOPSIS
    Script written to help troubleshoot issues specific to the Imprivata One-Sign
    go-live. Sessions will hang at the "Welcome" screen shown during initial login,
    and we needed an automated way to detect that, run some diagnostics, and reboot.
#>
using namespace System.Management.Automation 
#Requires -Version 5

[CmdletBinding()]
param (
    [string[]]
    $SnapIn = @('Citrix.Broker.Admin.V2', 'Citrix.Host.Admin.V2'),

    [string[]]
    $AdminAddress = @('ctxddc01', 'sltctxddc01'),

    [string]
    $DesktopGroupName = "XD*P10SLHS",

    [IO.FileInfo]
    $ScriptPath = ".\Repair-ImprivataDumpsterFire.ps1",

    [IO.FileInfo]
    $OutFile = "D:\Diagnostics\PROCESSNAME_YYMMDD_HHMMSS.dmp",

    [int]
    $TimeOut = 30
)

#region classes
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
    [string] $User
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
            $this.User = $this.BrokerSession.UserUPN
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
                    $this.DebugInfo += "UpdateSuggestedAction(): Job started. Suggest RefreshJob()."
                    $this.SuggestedAction = [DebugAction]::RefreshJob
                }
                'RefreshJob' {
                    $this.RefreshJob()
                    if ($this.JobState -eq [JobState]::Failed) {
                        if ($this.Job.HasMoreData) { 
                            
                            $this.DebugInfo += "UpdateSuggestedAction(): Job failed or timed out. Suggest ReceiveJob()."
                            $this.SuggestedAction = [DebugAction]::ReceiveJob 
                        }
                        else { 
                            $this.DebugInfo += "UpdateSuggestedAction(): Job failed and produced no output. Suggest Restart()."
                            $this.SuggestedAction = [DebugAction]::Restart 
                        }
                    }
                    elseif ($this.Job.PSEndTime) {
                        $this.DebugInfo += "UpdateSuggestedAction(): Job is done. Suggest ReceiveJob()."
                        $this.SuggestedAction = [DebugAction]::ReceiveJob
                    }
                }
                'ReceiveJob' {
                    $this.DebugInfo += "UpdateSuggestedAction(): Job received. Suggest Restart()."
                    $this.SuggestedAction = [DebugAction]::Restart
                }
                'Restart' {
                    $this.DebugInfo += "UpdateSuggestedAction(): Restart was requested. Nothing more to do."
                    $this.SuggestedAction = [DebugAction]::Ignore
                    $this.DebuggingComplete = $true
                }
            }
        }
        else {
            # session is hung and we haven't touched it yet, suggest starting a diagnostics job
            $this.SuggestedAction = [DebugAction]::StartJob
            $this.DebugInfo += "UpdateSuggestedAction(): ActionLog was empty. Suggest StartJob()."
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
            
            # deserializer messes with properties/methods available to the remote job
            $of = $this.OutFile
            $dir = $this.OutFile.Directory
            $icmParams = @{
                ComputerName = $this.BrokerSession.DNSName
                AsJob        = $true
                ErrorAction  = 'Stop'
                ScriptBlock  = {
                    $of = ${using:of}
                    $dir = ${using:dir}
                    try {
                        if (-not (Test-Path -Path $dir)) {
                            New-Item -ItemType Directory -Path $dir -ErrorAction 'Stop' | Out-Null
                        }
                        
                        # remove old dumps before creating another
                        Remove-Item -Path "$dir\*.dmp" -Confirm:$false -Force
                        C:\Tools\Monitors\procdump64.exe -accepteula -W -ma ssomanhost64 "$of"
                    }
                    catch {
                        # export and log the exception before throwing it back to the job invoker
                        $of = '{0}\ERROR.json' -f $dir
                        ConvertTo-Json -Depth 5 -InputObject $_ | Out-File -FilePath $of
                        throw $_
                    }
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
#endregion classes

#region functions

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

function ConvertTo-FlatObject {
    param
    (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [object[]] $InputObject,
        
        [String] 
        $Delimiter = "`n"   
    )
  
    process {
        $InputObject | ForEach-Object {

            $flatObject = New-Object PSObject

            # Loop through each property on the input object
            foreach ($property in $_.PSObject.Properties) {
                # If it's a collection, join everything into a string.
                if ($property.TypeNameOfValue -match '\[\]$') {
                    $flatValue = $property.Value -Join $Delimiter
                }
                else { $flatValue = $property.Value }

                $addMemberParams = @{
                    InputObject = $flatObject
                    MemberType  = 'NoteProperty'
                    Name        = $property.Name
                    Value       = $flatValue
                }
                Add-Member @addMemberParams
            }

            $flatObject
        }
    }
}

function Repair-Session {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [SessionDebug[]]
        $Session,

        [MailAddress[]]
        $MailTo = 'simmonsa@slhs.org',

        [MailAddress]
        $MailFrom = 'SessionDebug_DoNotReply@slhs.org',

        [string]
        $MailServer = 'mailgate.slhs.org',

        [int]
        $TimeOut = (${script:TimeOut} + 10)
    )

    process {
        foreach ($s in $Session) {
            $endBy = (Get-Date).AddSeconds($TimeOut)
            $s.Refresh()

            do {
                $s.StartSuggestedAction()
                Start-Sleep -Seconds 5
                [void] $s.Refresh()
            }
            until ($s.DebuggingComplete -or ((Get-Date) -gt $endBy))

            # if we timed out, try one last action before bailing
            if (-not $s.DebuggingComplete) {
                $s.StartSuggestedAction()
                [void] $s.Refresh()
            }
        }
        $mailProps = @('DNSName', 'User', 'AdminAddress', 'LooksHung', 'RestartIssued', 'SessionUid',
            'DebuggingComplete', 'JobReceived', 'JobState', 'ActionLog', 'ActionResult', 'OutFile', 'DebugInfo')
        $mailBody = $s | Select-Object -Property $mailProps | ConvertTo-FlatObject | Out-String

        $smmParams = @{
            From       = $MailFrom
            To         = $MailTo
            SmtpServer = $MailServer
            Subject    = "Hung Session Repair Attempt: $($s.DNSName)"
            Body       = $mailBody
        }
        Send-MailMessage @smmParams
    }
}

#endregion functions

#region main

# load snapins
try { Add-PSSnapin -Name $SnapIn -ErrorAction 'Stop' -PassThru }
catch {
    Write-Error "Couldn't load one or more required snap-ins. Bailing."
    throw $_.Exception
}

# look for hung sessions
$hungSession = @(Get-HungSession -AdminAddress $AdminAddress -DesktopGroupName $DesktopGroupName)

# debug and repair hung sessions
if ($hungSession) {
    $sessionDebug = $hungSession.ForEach({[SessionDebug]::new($_.ControllerDNSName, $_.SessionUid, $OutFile, $TimeOut)})
    $sessionDebug | Repair-Session
}
else { "No hung sessions found." }
