[CmdletBinding(SupportsShouldProcess)]
param (
    [string[]]
    $ComputerName = @(
        'sltprint-hp1',
        'sltprint-other1',
        'sltprint-xerox1',
        'sltprinthp2',
        'sltprinthp3',
        'sltprinttstxrx1',
        'sltprintxerox2',
        'sltprintxerox3',
        'sltprintother2',
        'print-hp1',
        'printhp2',
        'printhp3',
        'printhp4',
        'print-xerox1',
        'printxerox2',
        'printxerox3',
        'printxerox4',
        'printxerox3320',
        'sltprint1',
        'printtstxrx1',
        'print-other1',
        'printother2'
    ), 

    [int]
    $retryLimit = 5,

    [int]
    $RetryDelaySec = 10,

    [IO.FileInfo]
    $LogFile = "${env:USERPROFILE}\badPrinters.txt"
)

# overriding $WhatIfPreference so we can test transcription
Start-Transcript -Path $LogFile -WhatIf:$false
Start-Sleep -Seconds 1

function Get-BadPrinter {
    [CmdletBinding()]
    param (
        [string[]] 
        $ComputerName = $script:ComputerName
    )
    # return any bad printers
    (Get-Printer).Where({$_.ComputerName -in $ComputerName})
}

$retryCounter = 0
$badPrinter = Get-BadPrinter

if ($badPrinter) {

    Write-Warning "Found the following stale printers:"
    $badPrinter | Out-String -Stream | Write-Warning

    if ($PSCmdlet.ShouldProcess("$($badPrinter.Count) stale printer(s)", "Remove")) {
        Remove-Printer -Name $badPrinter.Name -Verbose

        if (Get-BadPrinter) {
            do {
                $retryCounter++
                Write-Output "Couldn't clear out all of the printers. Retry $retryCounter/$retryLimit in $RetryDelaySec seconds..."
                Start-Sleep -Seconds $RetryDelaySec
                Remove-Printer -Name (Get-BadPrinter).Name -Verbose
            } while ((Get-BadPrinter) -and ($retryCounter -lt $retryLimit))

            if (Get-BadPrinter) {
                Write-Warning "REMOVAL_FAILED Couldn't remove the following stale printers:"
                Get-BadPrinter | Out-String -Stream | Write-Warning
            }
        }        
    }
}
else { Write-Output "Printers look good! Nothing to do." }

Stop-Transcript
