function Get-WauPsadtNativeProgramFiles {
    if ([Environment]::Is64BitOperatingSystem -and -not [string]::IsNullOrWhiteSpace([string]$env:ProgramW6432)) {
        return [string]$env:ProgramW6432
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:ProgramFiles)) {
        return [string]$env:ProgramFiles
    }
    return 'C:\Program Files'
}

function Get-WauPsadtBridgeRoot {
    return (Join-Path (Get-WauPsadtNativeProgramFiles) 'WauPsadtBridge')
}

function Get-WauPsadtBridgeCatalogPath {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:WauPsadtBridgeCatalogPath)) {
        return [string]$script:WauPsadtBridgeCatalogPath
    }
    return (Join-Path (Get-WauPsadtBridgeRoot) 'bridge.catalog.json')
}

function Get-WauPsadtBridgeGoldenRoot {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:WauPsadtBridgeGoldenRoot)) {
        return [string]$script:WauPsadtBridgeGoldenRoot
    }
    return (Join-Path (Get-WauPsadtBridgeRoot) 'Template')
}

function Get-WauPsadtBridgeWorkRoot {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:WauPsadtBridgeWorkRoot)) {
        return [string]$script:WauPsadtBridgeWorkRoot
    }
    return (Join-Path (Get-WauPsadtBridgeRoot) 'Work')
}

function Test-WauPsadtOwnedWorkingCopyPath {
    param([string]$LiteralPath)

    $root = Get-WauPsadtBridgeWorkRoot
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or [string]::IsNullOrWhiteSpace($root)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($LiteralPath)
        $rootFull = [System.IO.Path]::GetFullPath($root)
    }
    catch { return $false }
    $prefix = $rootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ($full.TrimEnd('\', '/') -ine $rootFull.TrimEnd('\', '/'))
}

function Remove-WauPsadtWorkingCopy {
    param([string]$LiteralPath)

    if (-not (Test-WauPsadtOwnedWorkingCopyPath -LiteralPath $LiteralPath)) { return }
    if (Test-Path -LiteralPath $LiteralPath) {
        Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-WauPsadtBridgeCatalog {
    if ($null -ne $script:WauPsadtBridgeCatalog) {
        return $script:WauPsadtBridgeCatalog
    }

    $path = Get-WauPsadtBridgeCatalogPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "WAU-PSADT Bridge catalog is missing: [$path]. Update cycle aborted."
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        $catalog = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "WAU-PSADT Bridge catalog could not be parsed: [$path]. Update cycle aborted."
    }

    if (
        [int]$catalog.schemaVersion -ne 1 -or
        $null -eq $catalog.apps -or
        $catalog.apps -isnot [pscustomobject]
    ) {
        throw "WAU-PSADT Bridge catalog schema is invalid: [$path]. Update cycle aborted."
    }

    $script:WauPsadtBridgeCatalog = $catalog
    return $catalog
}

function Resolve-WauPsadtCatalogApp {
    param($Catalog, [string]$Id)

    if ($null -eq $Catalog -or $null -eq $Catalog.apps -or [string]::IsNullOrWhiteSpace($Id)) {
        return $null
    }

    foreach ($property in $Catalog.apps.PSObject.Properties) {
        if ([string]$property.Name -ieq $Id) {
            return $property.Value
        }
    }
    return $null
}

function Test-WauPsadtCatalogProcesses {
    param($Entry)

    $names = @($Entry.processes)
    if ($names.Count -lt 1) { return $false }
    foreach ($name in $names) {
        $processName = [string]$name
        if ([string]::IsNullOrWhiteSpace($processName) -or $processName -match '[\\/:]' -or $processName -match '\.exe$') {
            return $false
        }
    }
    return $true
}

function Test-WauPsadtAppSpecificMods {
    param([string]$Id)

    $workingDirVariable = Get-Variable -Name WorkingDir -Scope Script -ErrorAction SilentlyContinue
    $workingDir = if ($workingDirVariable) { [string]$workingDirVariable.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($workingDir)) { return $false }
    $modsRoot = Join-Path $workingDir 'mods'
    foreach ($suffix in @(
            '-preinstall.ps1',
            '-override.txt',
            '-custom.txt',
            '-arguments.txt',
            '-install.ps1',
            '-upgrade.ps1',
            '-installed.ps1',
            '-notinstalled.ps1'
        )) {
        if (Test-Path -LiteralPath (Join-Path $modsRoot ($Id + $suffix)) -PathType Leaf) {
            return $true
        }
    }
    return $false
}

function Test-WauPsadtActiveCampaign {
    param([Parameter(Mandatory)][string]$PackageId)

    $basePath = 'HKLM:\SOFTWARE\WauPsadtBridge\Campaigns'
    if (-not (Test-Path -LiteralPath $basePath)) { return $false }

    $activeStates = @('Staged', 'Deferred', 'InProgress')
    foreach ($key in @(Get-ChildItem -LiteralPath $basePath -ErrorAction SilentlyContinue)) {
        try {
            $raw = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if ([int]$raw.SchemaVersion -ne 2 -or [string]$raw.ResourceType -ne 'WauBridgeCampaign') { continue }
            if ([string]$raw.PackageId -ine $PackageId) { continue }
            if ([string]$raw.State -in $activeStates) { return $true }
        }
        catch { }
    }
    return $false
}

function Test-WauPsadtRunningAsSystem {
    if ($null -ne $script:WauPsadtForceSystemContext) {
        return [bool]$script:WauPsadtForceSystemContext
    }
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    }
    catch {
        return $false
    }
}

function Enter-WauPsadtBridgeMutex {
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, 'Global\WauPsadtBridge.Update', [ref]$createdNew)
    try {
        if (-not $mutex.WaitOne(0)) {
            $mutex.Dispose()
            return $null
        }
    }
    catch [System.Threading.AbandonedMutexException] {
    }
    return $mutex
}

function Exit-WauPsadtBridgeMutex {
    param($Mutex)
    if ($null -eq $Mutex) { return }
    try { $null = $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

function New-WauPsadtWorkingCopy {
    $golden = Get-WauPsadtBridgeGoldenRoot
    $installScript = Join-Path $golden 'install.ps1'
    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
        throw "WAU-PSADT Bridge golden copy is missing install.ps1: [$golden]."
    }

    $workRoot = Get-WauPsadtBridgeWorkRoot
    if ([string]::IsNullOrWhiteSpace($workRoot) -or -not (Test-Path -LiteralPath $workRoot -PathType Container)) {
        throw "WAU-PSADT Bridge work root is missing: [$workRoot]."
    }
    $destination = Join-Path $workRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    try {
        $winDir = [string]$env:WINDIR
        $robocopy = if (-not [string]::IsNullOrWhiteSpace($winDir)) {
            Join-Path $winDir 'System32\Robocopy.exe'
        } else { '' }
        if ($robocopy -and (Test-Path -LiteralPath $robocopy -PathType Leaf)) {
            $null = & $robocopy $golden $destination /E /NFL /NDL /NJH /NJS /NC /NS /NP
            if ($LASTEXITCODE -ge 8) {
                throw "Robocopy failed with ExitCode [$LASTEXITCODE] from [$golden] to [$destination]."
            }
        }
        else {
            Copy-Item -Path (Join-Path $golden '*') -Destination $destination -Recurse -Force -ErrorAction Stop
        }
        return $destination
    }
    catch {
        Remove-WauPsadtWorkingCopy -LiteralPath $destination
        throw
    }
}

function Save-WauPsadtCampaignJson {
    param(
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)]$CatalogEntry
    )

    $displayName = [string]$CatalogEntry.displayName
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [string]$App.Name }
    $targetVersion = [string]$App.AvailableVersion
    $campaign = [ordered]@{
        schemaVersion    = 1
        wingetId         = [string]$App.Id
        displayName      = $displayName
        targetVersionRaw = $targetVersion
        targetVersion    = $targetVersion
        processes        = @($CatalogEntry.processes | ForEach-Object { [string]$_ })
    }
    $jsonPath = Join-Path $DestinationRoot 'WauBridge.Campaign.json'
    ($campaign | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $jsonPath -Encoding UTF8 -ErrorAction Stop
    return $jsonPath
}

function Start-WauPsadtBootstrap {
    param([Parameter(Mandatory)][string]$WorkingCopy)

    $installScript = Join-Path $WorkingCopy 'install.ps1'
    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
        throw "Working copy is missing install.ps1: [$installScript]."
    }

    $winDir = [string]$env:WINDIR
    $sysnative = if (-not [string]::IsNullOrWhiteSpace($winDir)) { Join-Path $winDir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
    $system32 = if (-not [string]::IsNullOrWhiteSpace($winDir)) { Join-Path $winDir 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
    if ($sysnative -and (Test-Path -LiteralPath $sysnative -PathType Leaf)) {
        $hostExe = $sysnative
    }
    elseif ($system32 -and (Test-Path -LiteralPath $system32 -PathType Leaf)) {
        $hostExe = $system32
    }
    else {
        $pwsh = Get-Command -Name pwsh -ErrorAction SilentlyContinue
        if (-not $pwsh) { throw 'No PowerShell host is available to start install.ps1.' }
        $hostExe = $pwsh.Source
    }

    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-WindowStyle', 'Hidden'
        '-File', ('"{0}"' -f $installScript)
    )
    $process = Start-Process -FilePath $hostExe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    return [int]$process.ExitCode
}

function Submit-WauPsadtUpdate {
    param(
        $App,
        [Alias('src')]
        $Source = 'winget'
    )

    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = 'winget' }
    else { $Source = $Source.Trim() }
    if ($Source -ine 'winget') { return $false }

    if (-not (Test-WauPsadtRunningAsSystem)) {
        Write-ToLog "WAU-PSADT Bridge ignored [$($App.Id)] because this is not a SYSTEM WAU cycle." "Yellow"
        return $false
    }

    $catalog = Get-WauPsadtBridgeCatalog

    $entry = Resolve-WauPsadtCatalogApp -Catalog $catalog -Id ([string]$App.Id)
    if ($null -eq $entry) { return $false }

    if (-not (Test-WauPsadtCatalogProcesses -Entry $entry)) {
        Write-ToLog "WAU-PSADT Bridge skipped [$($App.Id)] because catalog processes are invalid. This catalog ID will not be updated." "Yellow"
        return $true
    }

    if (Test-WauPsadtAppSpecificMods -Id ([string]$App.Id)) {
        Write-ToLog "WAU-PSADT Bridge configuration conflict: app-specific WAU mods exist for [$($App.Id)]. Neither bridge nor WAU will update this app." "Red"
        return $true
    }

    $mutex = $null
    $work = $null
    try {
        $mutex = Enter-WauPsadtBridgeMutex
        if ($null -eq $mutex) {
            Write-ToLog "WAU-PSADT Bridge mutex is held; skipping [$($App.Id)] this cycle." "Yellow"
            return $true
        }

        if (Test-WauPsadtActiveCampaign -PackageId ([string]$App.Id)) {
            Write-ToLog "WAU-PSADT Bridge found an active campaign for [$($App.Id)]; not creating a second campaign." "Yellow"
            return $true
        }

        $work = New-WauPsadtWorkingCopy
        $null = Save-WauPsadtCampaignJson -DestinationRoot $work -App $App -CatalogEntry $entry
    }
    catch {
        Write-ToLog "WAU-PSADT Bridge failed to prepare [$($App.Id)]: $($_.Exception.Message)" "Red"
        Remove-WauPsadtWorkingCopy -LiteralPath $work
        return $true
    }
    finally {
        Exit-WauPsadtBridgeMutex -Mutex $mutex
    }

    try {
        $exitCode = Start-WauPsadtBootstrap -WorkingCopy $work
        if ($exitCode -ne 0) {
            Write-ToLog "WAU-PSADT Bridge bootstrap for [$($App.Id)] ended with ExitCode [$exitCode]." "Red"
        }
        else {
            Write-ToLog "WAU-PSADT Bridge handed off [$($App.Id)] $($App.Version) -> $($App.AvailableVersion)." "Cyan"
        }
    }
    catch {
        Write-ToLog "WAU-PSADT Bridge bootstrap failed for [$($App.Id)]: $($_.Exception.Message)" "Red"
    }
    finally {
        Remove-WauPsadtWorkingCopy -LiteralPath $work
    }

    return $true
}
