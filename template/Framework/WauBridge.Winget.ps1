function Get-WauBridgeWingetDetectAppId {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace([string]$WauBridgeConfig.PackageId)) {
        return [string]$WauBridgeConfig.PackageId
    }

    return $null
}

function Get-WauBridgeWingetExecutablePath {
    [CmdletBinding()]
    param()

    $command = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return [string]$command.Source }
    $userPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $userPath -PathType Leaf) { return $userPath }
    $windowsAppsRoot = Join-Path (Get-WauBridgeNativeProgramFiles) 'WindowsApps'
    if (Test-Path -LiteralPath $windowsAppsRoot -PathType Container) {
        $candidate = Get-ChildItem -LiteralPath $windowsAppsRoot -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' -Directory -ErrorAction Stop |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'winget.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($candidate) { return [string]$candidate }
    }
    throw 'winget.exe is unavailable in the current execution context.'
}

function Get-WauBridgeWingetExportPackages {
    [CmdletBinding()]
    param([switch]$IncludeVersions)

    $wingetExecutable = Get-WauBridgeWingetExecutablePath
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ('WauBridge-Winget-Export-{0}.json' -f ([guid]::NewGuid().ToString('N')))
    try {
        $exportArgs = @(
            'export'
            '--output'
            $tempFile
        )
        if ($IncludeVersions) { $exportArgs += '--include-versions' }
        $exportArgs += @(
            '--source'
            'winget'
            '--accept-source-agreements'
            '--disable-interactivity'
        )
        Write-WauBridgeLog -Message ("Invoking winget export includeVersions=[{0}]." -f [bool]$IncludeVersions)
        $output = @(& $wingetExecutable @exportArgs 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "winget export failed with ExitCode [$exitCode]: $((@($output) | Select-Object -Last 5) -join ' ')"
        }
        if (-not (Test-Path -LiteralPath $tempFile -PathType Leaf)) {
            throw "winget export did not create [$tempFile]."
        }
        $export = Get-Content -LiteralPath $tempFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return @($export.Sources | ForEach-Object { $_.Packages })
    }
    finally {
        if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
            try { Remove-Item -LiteralPath $tempFile -Force -ErrorAction Stop }
            catch { Write-WauBridgeLog -Message ("Temporary Winget export could not be removed: {0}" -f $_.Exception.Message) -Severity 2 }
        }
    }
}

function Test-WauBridgeWingetPackagePresent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)

    $packages = Get-WauBridgeWingetExportPackages
    return @($packages | Where-Object { [string]$_.PackageIdentifier -ieq $AppId }).Count -gt 0
}

function Get-WauBridgeWingetUpgradeArgumentList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)

    return @(
        'upgrade'
        '--id'
        $AppId
        '--exact'
        '--source'
        'winget'
        '--scope'
        'machine'
        '--silent'
        '--disable-interactivity'
        '--accept-package-agreements'
        '--accept-source-agreements'
    )
}

function Get-WauBridgeWingetInstalledVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)

    $packages = Get-WauBridgeWingetExportPackages -IncludeVersions
    $matches = @($packages | Where-Object { [string]$_.PackageIdentifier -ieq $AppId })
    if ($matches.Count -eq 0) { return $null }

    $versions = foreach ($package in $matches) {
        ConvertTo-Version ([string]$package.Version)
    }
    $parsed = @($versions | Where-Object { $_ })
    if ($parsed.Count -eq 0) { return $null }
    return ($parsed | Sort-Object -Descending | Select-Object -First 1)
}

function Invoke-WauBridgeWingetUpgrade {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppId)

    $wingetExecutable = Get-WauBridgeWingetExecutablePath
    $upgradeArgs = Get-WauBridgeWingetUpgradeArgumentList -AppId $AppId
    Write-WauBridgeLog -Message ("Invoking winget upgrade for exact package [{0}]." -f $AppId)
    $output = @(& $wingetExecutable @upgradeArgs 2>&1)
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    Write-WauBridgeLog -Message ("winget upgrade completed with ExitCode [{0}]: {1}" -f $exitCode, ((@($output) | Select-Object -Last 3) -join ' '))
    return [int]$exitCode
}
