#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,
    [string]$WauInstallLocation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

function Get-WauPsadtNativeProgramFiles {
    if ([Environment]::Is64BitOperatingSystem -and -not [string]::IsNullOrWhiteSpace([string]$env:ProgramW6432)) {
        return [string]$env:ProgramW6432
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:ProgramFiles)) {
        return [string]$env:ProgramFiles
    }
    return 'C:\Program Files'
}

$script:RepoRoot = $PSScriptRoot
$script:BridgeInstallRoot = Join-Path (Get-WauPsadtNativeProgramFiles) 'WauPsadtBridge'
$script:CatalogInstallPath = Join-Path $script:BridgeInstallRoot 'bridge.catalog.json'
$script:CatalogInstallDir = $script:BridgeInstallRoot
$script:GoldenInstallRoot = Join-Path $script:BridgeInstallRoot 'Template'
$script:WorkInstallRoot = Join-Path $script:BridgeInstallRoot 'Work'
$script:StatePath = Join-Path $script:CatalogInstallDir 'install-state.json'
$script:UpdateAppBackupName = 'Update-App.ps1.pre-bridge'
$script:SupportedWauVersion = '2.12.0'
# Normalized SHA-256 of Winget-AutoUpdate v2.12.0 Sources/Winget-AutoUpdate/functions/Update-App.ps1
$script:SupportedWauUpdateAppSha256 = 'a7d73f2258a963d0b529a3a3bc35827313fbfa00ebce9953c95fc58a33a7b2ba'

function Write-BridgeInstallLog {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

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

function Test-WauInstallLayout {
    param([Parameter(Mandatory)][string]$WauRoot)

    $upgrade = @(
        (Join-Path $WauRoot 'Winget-Upgrade.ps1'),
        (Join-Path $WauRoot 'winget-upgrade.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $functions = Join-Path $WauRoot 'functions'
    return ($upgrade -and (Test-Path -LiteralPath $functions -PathType Container))
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

function Assert-WauUpdateAppCompatible {
    param([Parameter(Mandatory)][string]$UpdateAppPath, [Parameter(Mandatory)][string]$WauRoot)

    if (-not (Test-Path -LiteralPath $UpdateAppPath -PathType Leaf)) {
        throw "WAU Update-App.ps1 was not found: [$UpdateAppPath]."
    }

    $installedVersion = Get-WauInstalledVersion -WauRoot $WauRoot
    if ($installedVersion) {
        $normalizedVersion = ($installedVersion -replace '^v', '').Trim()
        if ($normalizedVersion -cne $script:SupportedWauVersion) {
            throw "WAU $installedVersion is not supported. This bridge supports WAU $($script:SupportedWauVersion) with PSAppDeployToolkit 4.1.8."
        }
    }

    $text = Get-Content -LiteralPath $UpdateAppPath -Raw -ErrorAction Stop
    if ($text -match 'Submit-WauPsadtUpdate') {
        Write-BridgeInstallLog "Update-App.ps1 already contains the bridge handoff." 'Cyan'
        return
    }

    $hash = Get-NormalizedSha256 -LiteralPath $UpdateAppPath
    if ($hash -eq $script:SupportedWauUpdateAppSha256) {
        if (-not $installedVersion) {
            Write-BridgeInstallLog "WAU version not found in registry; Update-App.ps1 matches WAU $($script:SupportedWauVersion)." 'Cyan'
        }
        return
    }

    throw "Update-App.ps1 is not the supported WAU $($script:SupportedWauVersion) file (SHA-256 $hash). Aborting so an unknown WAU build is not overwritten."
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

function Install-BridgeDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        $null = $acl.RemoveAccessRule($rule)
    }
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $readExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagate = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($entry in @(
            @{ Sid = 'S-1-5-18'; Rights = $full },
            @{ Sid = 'S-1-5-32-544'; Rights = $full },
            @{ Sid = 'S-1-5-32-545'; Rights = $readExecute }
        )) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($entry.Sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid, $entry.Rights, $inherit, $propagate, $allow)
        $acl.SetAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Copy-BridgeTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $robocopy = Join-Path $env:WINDIR 'System32\Robocopy.exe'
    if (Test-Path -LiteralPath $robocopy -PathType Leaf) {
        $null = & $robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /NC /NS /NP /XD .git
        if ($LASTEXITCODE -ge 8) {
            throw "Robocopy failed with ExitCode [$LASTEXITCODE] from [$Source] to [$Destination]."
        }
        return
    }
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

function Save-BridgeInstallState {
    param([Parameter(Mandatory)][hashtable]$State)

    New-Item -ItemType Directory -Path $script:CatalogInstallDir -Force | Out-Null
    ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Read-BridgeInstallState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Install-WauPsadtBridgePayload {
    $templateRoot = Join-Path $script:RepoRoot 'template'
    $catalogSource = Join-Path $script:RepoRoot 'catalog\apps.json'
    $submitSource = Join-Path $script:RepoRoot 'wau\Submit-WauPsadtUpdate.ps1'
    $updateAppSource = Join-Path $script:RepoRoot 'wau\Update-App.ps1'

    foreach ($required in @(
            @{ Path = (Join-Path $templateRoot 'install.ps1'); Name = 'template/install.ps1' },
            @{ Path = $catalogSource; Name = 'catalog/apps.json' },
            @{ Path = $submitSource; Name = 'wau/Submit-WauPsadtUpdate.ps1' },
            @{ Path = $updateAppSource; Name = 'wau/Update-App.ps1' }
        )) {
        if (-not (Test-Path -LiteralPath $required.Path -PathType Leaf)) {
            throw "$($required.Name) is missing: [$($required.Path)]."
        }
    }

    $catalog = Get-Content -LiteralPath $catalogSource -Raw -Encoding UTF8 | ConvertFrom-Json
    if (
        [int]$catalog.schemaVersion -ne 1 -or
        $null -eq $catalog.apps -or
        $catalog.apps -isnot [pscustomobject]
    ) {
        throw "catalog/apps.json schema is invalid: [$catalogSource]."
    }

    $wauRoot = Get-InstalledWauLocation -Override $WauInstallLocation
    if (-not $wauRoot -or -not (Test-WauInstallLayout -WauRoot $wauRoot)) {
        throw 'Winget-AutoUpdate is not installed. Install the WAU MSI first, then run this script.'
    }
    $wauFunctions = Join-Path $wauRoot 'functions'
    $updateAppDest = Join-Path $wauFunctions 'Update-App.ps1'
    $submitDest = Join-Path $wauFunctions 'Submit-WauPsadtUpdate.ps1'
    $backupDest = Join-Path $wauFunctions $script:UpdateAppBackupName

    Assert-WauUpdateAppCompatible -UpdateAppPath $updateAppDest -WauRoot $wauRoot
    $destHasHandoff = Test-WauUpdateAppContainsHandoff -LiteralPath $updateAppDest
    $backupIsOriginal = Test-WauOriginalUpdateAppBackup -LiteralPath $backupDest
    if ($destHasHandoff -and -not $backupIsOriginal) {
        throw 'Cannot safely install because Update-App.ps1 already contains the bridge handoff and no valid original backup exists.'
    }

    Write-BridgeInstallLog "WAU:     $wauRoot (supported $($script:SupportedWauVersion))" 'Cyan'
    Write-BridgeInstallLog "Catalog: $script:CatalogInstallPath" 'Cyan'
    Write-BridgeInstallLog "Template: $script:GoldenInstallRoot" 'Cyan'
    Write-BridgeInstallLog "Work:     $script:WorkInstallRoot" 'Cyan'

    New-Item -ItemType Directory -Path $script:CatalogInstallDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Path $script:GoldenInstallRoot -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path $script:WorkInstallRoot -Force | Out-Null

    if (-not $destHasHandoff -and -not $backupIsOriginal) {
        Copy-Item -LiteralPath $updateAppDest -Destination $backupDest -Force
        $backupIsOriginal = $true
        Write-BridgeInstallLog "Backed up validated stock Update-App.ps1 -> $backupDest"
    }

    Copy-Item -LiteralPath $catalogSource -Destination $script:CatalogInstallPath -Force
    Copy-BridgeTree -Source $templateRoot -Destination $script:GoldenInstallRoot
    Copy-Item -LiteralPath $submitSource -Destination $submitDest -Force
    Copy-Item -LiteralPath $updateAppSource -Destination $updateAppDest -Force

    Install-BridgeDirectoryAcl -Path $script:CatalogInstallDir
    Install-BridgeDirectoryAcl -Path $script:GoldenInstallRoot
    Install-BridgeDirectoryAcl -Path $script:WorkInstallRoot

    $copiedUpdate = Get-Content -LiteralPath $updateAppDest -Raw
    if ($copiedUpdate -notmatch 'Submit-WauPsadtUpdate') {
        throw 'Installed Update-App.ps1 does not contain Submit-WauPsadtUpdate.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:GoldenInstallRoot 'install.ps1') -PathType Leaf)) {
        throw 'Installed template is missing install.ps1.'
    }

    Save-BridgeInstallState -State @{
        schemaVersion      = 1
        wauInstallLocation = $wauRoot
        updateAppBackup    = $backupDest
        catalogPath        = $script:CatalogInstallPath
        goldenRoot         = $script:GoldenInstallRoot
        installedUtc       = [datetime]::UtcNow.ToString('o')
    }

    Write-BridgeInstallLog 'Install completed. No additional scheduled task was created.' 'Green'
    Write-BridgeInstallLog 'Updates run through the existing task: \WAU\Winget-AutoUpdate' 'Green'
}

function Uninstall-WauPsadtBridgePayload {
    $state = Read-BridgeInstallState
    $wauRoot = Get-InstalledWauLocation -Override $WauInstallLocation
    if ($state -and $state.wauInstallLocation) {
        $wauRoot = [string]$state.wauInstallLocation
    }
    if (-not $wauRoot) {
        Write-BridgeInstallLog 'WAU location unknown; removing bridge files only.' 'Yellow'
    }
    else {
        $wauFunctions = Join-Path $wauRoot 'functions'
        $updateAppDest = Join-Path $wauFunctions 'Update-App.ps1'
        $submitDest = Join-Path $wauFunctions 'Submit-WauPsadtUpdate.ps1'
        $backupDest = if ($state -and $state.updateAppBackup) {
            [string]$state.updateAppBackup
        }
        else {
            Join-Path $wauFunctions $script:UpdateAppBackupName
        }

        $hasHandoff = Test-WauUpdateAppContainsHandoff -LiteralPath $updateAppDest
        $backupIsOriginal = Test-WauOriginalUpdateAppBackup -LiteralPath $backupDest
        if ($hasHandoff -and -not $backupIsOriginal) {
            throw 'Cannot safely uninstall because the original WAU Update-App.ps1 backup is missing. Reinstall/repair the supported WAU version before removing the bridge.'
        }

        if ($hasHandoff -and $backupIsOriginal) {
            Copy-Item -LiteralPath $backupDest -Destination $updateAppDest -Force
            Remove-Item -LiteralPath $backupDest -Force
            Write-BridgeInstallLog "Restored Update-App.ps1 from $backupDest"
        }
        elseif (-not $hasHandoff) {
            Write-BridgeInstallLog 'Update-App.ps1 no longer contains the bridge handoff; left the current file in place.' 'Yellow'
            if ($backupIsOriginal) {
                Remove-Item -LiteralPath $backupDest -Force
                Write-BridgeInstallLog "Removed unused backup $backupDest"
            }
        }
        if (Test-Path -LiteralPath $submitDest -PathType Leaf) {
            Remove-Item -LiteralPath $submitDest -Force
            Write-BridgeInstallLog "Removed $submitDest"
        }
    }

    if (Test-Path -LiteralPath $script:GoldenInstallRoot) {
        Remove-Item -LiteralPath $script:GoldenInstallRoot -Recurse -Force
        Write-BridgeInstallLog "Removed $script:GoldenInstallRoot"
    }
    if (Test-Path -LiteralPath $script:WorkInstallRoot) {
        Remove-Item -LiteralPath $script:WorkInstallRoot -Recurse -Force
        Write-BridgeInstallLog "Removed $script:WorkInstallRoot"
    }
    if (Test-Path -LiteralPath $script:CatalogInstallPath -PathType Leaf) {
        Remove-Item -LiteralPath $script:CatalogInstallPath -Force
        Write-BridgeInstallLog "Removed $script:CatalogInstallPath"
    }
    if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
        Remove-Item -LiteralPath $script:StatePath -Force
        Write-BridgeInstallLog "Removed $script:StatePath"
    }
    if (Test-Path -LiteralPath $script:CatalogInstallDir) {
        $remaining = @(Get-ChildItem -LiteralPath $script:CatalogInstallDir -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $script:CatalogInstallDir -Force
            Write-BridgeInstallLog "Removed empty $($script:CatalogInstallDir)"
        }
        else {
            Write-BridgeInstallLog "Left $($script:CatalogInstallDir) in place because it is not empty (campaign Stage folders are kept)." 'Yellow'
        }
    }

    Write-BridgeInstallLog 'WAU scheduled tasks were not changed.' 'Green'
    Write-BridgeInstallLog 'Existing campaign folders under WauPsadtBridge\Stage\<Id>\<Version> were left in place.' 'Yellow'
}

if ($Uninstall) {
    Uninstall-WauPsadtBridgePayload
}
else {
    Install-WauPsadtBridgePayload
}
