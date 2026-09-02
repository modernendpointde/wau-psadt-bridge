function Invoke-WauBridgeInstall {
    [CmdletBinding()]
    param(
        [ValidateSet('Upgrade')]
        [string]$Operation
    )

    $wingetAppId = Get-WauBridgeWingetDetectAppId
    if ([string]::IsNullOrWhiteSpace($wingetAppId)) {
        throw 'Campaign Winget ID is missing.'
    }

    $exitCode = Invoke-WauBridgeWingetUpgrade -AppId $wingetAppId
    if ($exitCode -notin @($WauBridgeConfig.SuccessExitCodes + $WauBridgeConfig.RebootExitCodes)) {
        throw "Winget upgrade failed. ExitCode: $exitCode"
    }

    $installedVersion = Get-WauBridgeWingetInstalledVersion -AppId $wingetAppId
    if (-not $installedVersion -or $installedVersion -lt $WauBridgeConfig.TargetVersion) {
        throw ("Winget postcondition not met: InstalledVersion [{0}] < TargetVersion [{1}]." -f $installedVersion, $WauBridgeConfig.TargetVersion)
    }

    return (ConvertTo-WauBridgeResult `
        -InputObject ([pscustomobject]@{ ExitCode = $exitCode }) `
        -Operation 'Upgrade' `
        -SuccessExitCodes $WauBridgeConfig.SuccessExitCodes `
        -RebootExitCodes $WauBridgeConfig.RebootExitCodes `
        -Adapter 'WingetScript')
}
