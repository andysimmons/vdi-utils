[CmdletBinding()]
param(
    [string]$OutFile = "C:\Temp\NoHomeDriveUsers.csv"
)

# Progress trackers
$startDate = Get-Date
$i = 0
$homelessCount = 0

# Clean up stale CSV if we have one
if (Test-Path $OutFile) 
{
    Remove-Item $OutFile -Force -ErrorAction Stop
}

# Build some collections we can use to perform some analysis without re-querying remote resources again
Write-Verbose "[$(Get-Date)] Querying AD users (this might take a minute)..."

# Run the long/slow AD queries in parallel (as background jobs)
Get-Job -Name "HOMECHECK*" | Remove-Job -Force
Start-Job -Name 'HOMECHECK-GeneralUsers' { $generalUsers = Get-ADUser -SearchBase "OU=General Users,OU=Testing User GPOs,OU=SL1 Users,DC=SL1,DC=STLUKES-INT,DC=ORG" -Filter * } > $null
Start-Job -Name 'HOMECHECK-Contractors' { $contractors = Get-ADUser -SearchBase "OU=Contractors,OU=Testing User GPOs,OU=SL1 Users,DC=SL1,DC=STLUKES-INT,DC=ORG" -Filter * } > $null
Get-Job -Name "HOMECHECK*" | Wait-Job | Remove-Job

Write-Verbose "[$(Get-Date)] Enumerating home drives..."
$homeFolderNames = (Get-ChildItem "\\home.slhs.org\home\" -ErrorAction Stop).Name
        
# Get members of the SLB and SLT VDI site-affinity groups (DN strings only, super fast)
Write-Verbose "[$(Get-Date)] Retrieving VDI group membership..."
$vdiMembers += (Get-ADGroup -Properties Members -Identity "VDI-SLBUser_GG_CX" -ErrorAction Stop).Members
$vdiMembers += (Get-ADGroup -Properties Members -Identity "VDI-SLTUser_GG_CX" -ErrorAction Stop).Members

$summary = @"
Discovered objects summary:
     General Users: $($generalUsers.Count)
       Contractors: $($contractors.Count)
      Home Folders: $($homeFolderNames.Count)
 VDI Group Members: $($vdiMembers.Count)
"@

# if any of these collections are empty, bail out
if (!($generalUsers -and $contractors -and $homeFolderNames -and $vdiMembers))
{
    Write-Warning $summary
    throw "Collection initialization failed. Aborting."
}
else
{
    Write-Verbose $summary
}

$adUsers = $generalUsers + $contractors
Write-Verbose "[$(get-date)] Analyzing $($adUsers.length) users..."


foreach ($adUser in $adUsers)
{
    $i++
    $progressParams = @{
        Activity = "Checking VDI home drives"
        Status = "${i}/$($adUsers.Length) (${homelessCount} homeless users found so far)"
        PercentComplete = 100 * $i / $adUsers.Length
    }
    Write-Progress @progressParams

    $userCN = $adUser.SamAccountName    # Helps for determining UNC path
    $userDN = $adUser.DistinguishedName # Helps for determining VDI group membership

    # If they're in a VDI Group and don't have a home drive...
    If (($userDN -in $vdiMembers) -and ($userCN -notin $homeFolderNames))
    {
        $homelessCount++
        $adUser | Select-Object -Property SamAccountName,Enabled,Name,ObjectClass,DistinguishedName | 
            Export-Csv $OutFile -Append -NoTypeInformation #Add the user's details to the report 
    }
}
Write-Progress -Activity "Checking VDI home drives" -Completed

If (Test-Path $OutFile) #If a report was created (or, rather, if any users w/o home drives were found)
{
    #Send an email to the proper staff via the EXMBX1 mail/SMTP server.  Can only be run on RES AM Agent Servers that are whitelisted with Exchange.
    #Send-MailMessage -From "HomeDriveChecker@slhs.org" -To "schneial@slhs.org" -Subject "VDI Users Without Home Drives - Report Attached" -Body "See attached CSV file." -Attachments "C:\Temp\NoHomeDriveUsers.csv" -SmtpServer MAILGATE.SLHS.ORG
    
    # Andy testing something..
    Invoke-Item $OutFile
    
    #Delete the report for the next script pass so an email won't be unnecessarily sent with an old list
    #Remove-Item $OutFile -Force
}

$endDate = Get-Date
$duration = $endDate - $startDate
Write-Verbose "[$(Get-Date)] Execution Completed (Duration: $duration)"
