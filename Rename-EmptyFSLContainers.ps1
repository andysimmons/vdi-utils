<#>
.NOTES
    Name:    Rename-EmptyFSLContainers.ps1
    Author:  Andy Simmons
    Date:    03/25/2020

.SYNOPSIS
    Super quick and dirty script to clear out 0-byte FSLogix containers (VHDX files).

    .PARAMETER ItemLimit
    Max number of containers to process in one batch. Specify -1 for unlimited.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string]
    $SearchRoot = 'C:\git\test',

    [string]
    $Append = "$(Get-Date -f 'yyyy-MM-dd_HHmmss').emptyContainer",

    [int]
    $ItemLimit = 1
)

<#
.SYNOPSIS
    Adds line(s) and whitespace before/after a string (for plain-text head "formatting")
#>
function Out-Header {
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Header,

        [switch]$Double
    )
    process {
        $line = $Header -replace '.', '-'
        
        if ($Double) { '', $line, $Header, $line }
        else         { '', $Header, $line }
    }
}

Write-Output "[$(Get-Date -f G)] Searching for empty FSLogix containers in $SearchRoot"
$gciParams = @{
    Path = $SearchRoot
    Filter = '*.vhdx'
    Recurse = $true
    Depth = 1
}
$emptyFSLContainer = (Get-ChildItem @gciParams).Where({ -not $_.Length })
$count = $emptyFSLContainer.Count

Write-Output "[$(Get-Date -f G)] Found $count empty containers."
if (($ItemLimit -ne -1) -and ($count -gt $ItemLimit)) {
    $remainder = $count - $ItemLimit
    Write-Warning "$count is greater than specified item limit ($ItemLimit). Ignoring $remainder of these."

    $emptyFSLContainer = $emptyFSLContainer | Select-Object -First $ItemLimit
    $count = $emptyFSLContainer.Count
}

if (-not $count) {
    Write-Output "[$(Get-Date -f G)] No empty containers $SerachRoot. Bye!"
    exit
}

if ($PSCmdlet.ShouldProcess("$count empty containers", 'RENAME')) {
    $renameCount = $errCount = 0
    foreach ($e in $emptyFSLContainer) {
        $newName = "$($e.Name).$Append"
        try {
            Rename-Item -Path $e.FullName -NewName $newName -ErrorAction 'Stop'
            $renameCount++
        }
        catch {
            Write-Warning "Couldn't rename empty container: $e"
            $errCount++
        }
    }
    Write-Output "[$(Get-Date -f G)] Renames complete! $renameCount containers renamed, $errCount skipped due to errors (possibly locked)."
    Out-Header "To find all files renamed in this batch, run the following command:"
    Write-Output "Get-ChildItem -Path '$SearchRoot' -Filter *.$Append -Recurse -Depth 1"
    Out-Header "To revert, run the following commands in order:"
    Write-Output "`$renames = Get-ChildItem -Path '$SearchRoot' -Filter *.$Append -Recurse -Depth 1"
    Write-Output '$renames.ForEach({ Rename-Item -Path $_.FullName -NewName $($_.Name -replace "\.vhdx\..*",".vhdx") })'
}
