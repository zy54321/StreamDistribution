function Test-YesAnswer {
    param(
        [string]$Answer,
        [string[]]$LegacyAccepted = @()
    )

    if ($Answer -eq 'Y') {
        return $true
    }
    foreach ($legacy in $LegacyAccepted) {
        if ($Answer -eq $legacy) {
            return $true
        }
    }
    return $false
}

function Confirm-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $false
    }

    $message = $Prompt
    if (-not $message.EndsWith(' ')) {
        $message += ' '
    }

    # choice.exe /M does not show when this script is started from the BAT.
    Write-Host $message -NoNewline
    & "$env:SystemRoot\System32\choice.exe" /C YN /N
    if ($LASTEXITCODE -eq 2) {
        return $false
    }
    if ($LASTEXITCODE -eq 1) {
        return $true
    }
    return $false
}
