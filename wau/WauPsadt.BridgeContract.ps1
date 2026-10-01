# Read-only WAU compatibility contract shared by the installer and the diagnostics entry points.
#
# These values and checks decide whether an installed Winget-AutoUpdate build is supported. They are
# read-only and define nothing else, so loading them never changes a machine.

$script:SupportedWauVersion = '2.12.0'
$script:UpdateAppBackupName = 'Update-App.ps1.pre-bridge'
# Normalized SHA-256 of Winget-AutoUpdate v2.12.0 Sources/Winget-AutoUpdate/functions/Update-App.ps1
$script:SupportedWauUpdateAppSha256 = 'a7d73f2258a963d0b529a3a3bc35827313fbfa00ebce9953c95fc58a33a7b2ba'

function Get-InstalledWauLocation {
    param([string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.TrimEnd('\', '/')
    }

    $registryPaths = @(
        'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate',
        'HKLM:\SOFTWARE\WOW6432Node\Romanitho\Winget-AutoUpdate'
    )
    foreach ($registryPath in $registryPaths) {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        $locationProperty = $item.PSObject.Properties['InstallLocation']
        if (-not $locationProperty) { continue }
        $location = [string]$locationProperty.Value
        if (-not [string]::IsNullOrWhiteSpace($location)) {
            return $location.TrimEnd('\', '/')
        }
    }

    $fallback = Join-Path ${env:ProgramFiles} 'Winget-AutoUpdate'
    if (Test-Path -LiteralPath $fallback -PathType Container) {
        return $fallback
    }
    return $null
}

function Get-NormalizedSha256 {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $raw = [System.IO.File]::ReadAllText($LiteralPath)
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }
    $normalized = ($raw -replace "`r`n", "`n") -replace "`r", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-WauInstalledVersion {
    param([Parameter(Mandatory)][string]$WauRoot)

    foreach ($registryPath in @(
            'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate',
            'HKLM:\SOFTWARE\WOW6432Node\Romanitho\Winget-AutoUpdate'
        )) {
        $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($name in @('ProductVersion', 'WAUVersion', 'Version')) {
            $property = $item.PSObject.Properties[$name]
            if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return ([string]$property.Value).Trim()
            }
        }
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $displayName = [string]$item.DisplayName
                if ($displayName -notmatch 'Winget-AutoUpdate') { continue }
                if (-not [string]::IsNullOrWhiteSpace([string]$item.DisplayVersion)) {
                    return ([string]$item.DisplayVersion).Trim()
                }
            }
            catch { }
        }
    }

    foreach ($name in @('Version.txt', 'version.txt')) {
        $versionFile = Join-Path $WauRoot $name
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            $text = (Get-Content -LiteralPath $versionFile -TotalCount 1 -ErrorAction SilentlyContinue)
            if (-not [string]::IsNullOrWhiteSpace([string]$text)) { return ([string]$text).Trim() }
        }
    }
    return $null
}

function Test-WauUpdateAppContainsHandoff {
    param([string]$LiteralPath)

    if (-not $LiteralPath -or -not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $false }
    return ((Get-Content -LiteralPath $LiteralPath -Raw) -match 'Submit-WauPsadtUpdate')
}

function Test-WauOriginalUpdateAppBackup {
    param([string]$LiteralPath)

    if (
        -not $LiteralPath -or
        -not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)
    ) {
        return $false
    }

    if (Test-WauUpdateAppContainsHandoff -LiteralPath $LiteralPath) {
        return $false
    }

    try {
        return (
            (Get-NormalizedSha256 -LiteralPath $LiteralPath) -eq
            $script:SupportedWauUpdateAppSha256
        )
    }
    catch {
        return $false
    }
}
