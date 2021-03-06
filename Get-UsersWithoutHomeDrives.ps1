[CmdletBinding()]
param (
    [IO.FileInfo]
    $OutFile = "C:\Temp\NoHomeDriveUsers.csv"
)

# Progress trackers
$startDate = Get-Date
$i = 0
$homelessCount = 0

# Clean up stale CSV if we have one
if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction Stop }

# Clean up any previous jobs
Get-Job -Name "HOMECHECK*" | Remove-Job -Force

# Run the long/slow queries in parallel (as background jobs)
Write-Verbose "[$(Get-Date -f G)] Querying AD users (this might take a minute)..."
Start-Job -Name 'HOMECHECK-GeneralUsers' { Get-ADUser -SearchBase "OU=General Users,OU=Testing User GPOs,OU=SL1 Users,DC=SL1,DC=STLUKES-INT,DC=ORG" -Filter * } > $null
Start-Job -Name 'HOMECHECK-Contractors' { Get-ADUser -SearchBase "OU=Contractors,OU=Testing User GPOs,OU=SL1 Users,DC=SL1,DC=STLUKES-INT,DC=ORG" -Filter * } > $null
Start-Job -Name 'HOMECHECK-HomeDirs' { (Get-ChildItem "\\home.slhs.org\home\" -ErrorAction Stop).Name } > $null

# Dump job output into collections we'll use to do analysis (without repeating expensive queries)
Get-Job -Name "HOMECHECK*" | Wait-Job
$generalUsers = Receive-Job -Name 'HOMECHECK-GeneralUsers'
$contractors = Receive-Job -Name 'HOMECHECK-Contractors'
$homeFolderNames = Receive-Job -Name 'HOMECHECK-HomeDirs'
Get-Job -Name "HOMECHECK*" | Remove-Job

# Get members of the SLB and SLT VDI site-affinity groups (DN strings only, super fast)
Write-Verbose "[$(Get-Date)] Retrieving VDI group membership..."
$vdiMembers = (Get-ADGroup -Properties Members -Identity "VDI-SLBUser_GG_CX" -ErrorAction Stop).Members
$vdiMembers += (Get-ADGroup -Properties Members -Identity "VDI-SLTUser_GG_CX" -ErrorAction Stop).Members

$summary = @"
Discovered objects summary:
     General Users: $($generalUsers.Count)
       Contractors: $($contractors.Count)
      Home Folders: $($homeFolderNames.Count)
 VDI Group Members: $($vdiMembers.Count)
"@

# if any of these collections are empty, bail out
if (!($generalUsers -and $contractors -and $homeFolderNames -and $vdiMembers)) {
    Write-Warning $summary
    throw "Collection initialization failed. Aborting."
}
else { Write-Verbose $summary }

$adUsers = $generalUsers + $contractors
Write-Verbose "[$(Get-Date -f G)] Analyzing $($adUsers.length) users..."

foreach ($adUser in $adUsers) {
    $i++
    $progressParams = @{
        Activity        = "Checking VDI home drives"
        Status          = "${i}/$($adUsers.Length) (${homelessCount} homeless users found so far)"
        PercentComplete = 100 * $i / $adUsers.Length
    }
    Write-Progress @progressParams

    $userCN = $adUser.SamAccountName    # Helps for determining UNC path
    $userDN = $adUser.DistinguishedName # Helps for determining VDI group membership

    # If they're in a VDI Group and don't have a home drive...
    If (($userDN -in $vdiMembers) -and ($userCN -notin $homeFolderNames)) {
        $homelessCount++
        $adUser | Select-Object -Property SamAccountName, Enabled, Name, ObjectClass, DistinguishedName | 
        Export-Csv $OutFile -Append -NoTypeInformation #Add the user's details to the report 
    }
}
Write-Progress -Activity "Checking VDI home drives" -Completed

If (Test-Path $OutFile) { 
    #If a report was created (meaning users w/o home drives were found)
    
    # Send an email to the proper staff via the EXMBX1 mail/SMTP server.  Can only be run on RES AM Agent Servers 
    # that are whitelisted with Exchange.
    $smmParams = @{
        From        = 'HomeDriveChecker@slhs.org'
        To          = 'schneial@slhs.org'
        Subject     = 'VDI Users Without Home Drives - Report Attached'
        Body        = 'See attached CSV file.'
        Attachments = $OutFile
        SmtpServer  = 'mailgate.slhs.org'
    }
    Send-MailMessage @smmParams
    
    Remove-Item $OutFile -Force
}

$endDate = Get-Date
$duration = $endDate - $startDate
Write-Verbose "[$(Get-Date -f G)] Execution Completed (Duration: $duration)"
