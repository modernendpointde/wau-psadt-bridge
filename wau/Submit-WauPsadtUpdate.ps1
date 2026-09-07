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
        if ([string]::IsNullOrWhiteSpace($processName) -or $processName -match '[\\/:*?\[\]]' -or $processName -match '\.exe$') {
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

function Get-WauPsadtSafeName {
    param([Parameter(Mandatory)][string]$Value)
    return (($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
}

function Get-WauPsadtCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path cannot be canonicalized.' }
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim()))
}

function Test-WauPsadtSamePath {
    param([string]$Left,[string]$Right)
    try {
        return ((Get-WauPsadtCanonicalPath -Path $Left).TrimEnd('\','/') -ieq (Get-WauPsadtCanonicalPath -Path $Right).TrimEnd('\','/'))
    }
    catch { return $false }
}

function ConvertTo-WauPsadtPowerShellSingleQuotedLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '[\x00-\x1F\x7F]') { throw 'PowerShell literal values must not contain control characters.' }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-WauPsadtCampaignContract {
    param(
        [Parameter(Mandatory)]$Registry,
        [string]$InstallRoot = (Get-WauPsadtBridgeRoot),
        [string]$PublicDesktopRoot
    )

    $packageId = [string]$Registry.PackageId
    $targetVersion = [string]$Registry.TargetVersion
    $safePackageId = Get-WauPsadtSafeName -Value $packageId
    $safeTargetVersion = Get-WauPsadtSafeName -Value $targetVersion
    if ([string]::IsNullOrWhiteSpace($safePackageId) -or [string]::IsNullOrWhiteSpace($safeTargetVersion)) {
        throw 'Campaign package or target version cannot produce a safe resource name.'
    }

    $campaignId = '{0}_{1}' -f $safePackageId, $safeTargetVersion
    $stageBase = Join-Path $InstallRoot 'Stage'
    $stageRoot = Join-Path $stageBase (Join-Path $safePackageId $safeTargetVersion)
    $taskPath = '\WauPsadtBridge\'
    $taskName = 'Update_{0}_{1}' -f $safePackageId, $safeTargetVersion
    $cleanupTaskName = 'Cleanup_{0}_{1}' -f $safePackageId, $safeTargetVersion
    $powerShellPath = if ([string]::IsNullOrWhiteSpace([string]$env:WINDIR)) {
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    else {
        Join-Path ([string]$env:WINDIR) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $invokePath = Join-Path $stageRoot 'Invoke-AppDeployToolkit.ps1'
    $cleanupPath = Join-Path $stageRoot 'Cleanup-WauBridgePackage.ps1'
    if ([string]::IsNullOrWhiteSpace($PublicDesktopRoot)) {
        $PublicDesktopRoot = [Environment]::GetFolderPath('CommonDesktopDirectory')
        if ([string]::IsNullOrWhiteSpace($PublicDesktopRoot)) { $PublicDesktopRoot = 'C:\Users\Public\Desktop' }
    }
    $shortcutName = [string]$Registry.DesktopShortcutName
    $expectedShortcutPath = if ($PublicDesktopRoot -eq 'C:\Users\Public\Desktop') {
        'C:\Users\Public\Desktop\{0}' -f $shortcutName
    }
    else {
        Join-Path $PublicDesktopRoot $shortcutName
    }

    return [pscustomobject]@{
        PackageId             = $packageId
        TargetVersion         = $targetVersion
        CampaignId            = $campaignId
        RegistryPath          = 'HKLM:\SOFTWARE\WauPsadtBridge\Campaigns\{0}' -f $campaignId
        StageBase             = $stageBase
        StageRoot             = $stageRoot
        OwnerMarkerPath       = Join-Path $stageRoot '.waubridge-owner.json'
        StateFilePath         = Join-Path $stageRoot 'ScheduleState.json'
        TaskPath              = $taskPath
        TaskName              = $taskName
        CleanupTaskName       = $cleanupTaskName
        PowerShellPath        = $powerShellPath
        TaskDescription       = 'WauBridgeCampaign:{0}:Update' -f $campaignId
        TaskArguments         = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DeploymentType Install -DeployMode Interactive -InvocationSource RetryTask' -f $invokePath
        CleanupDescription    = 'WauBridgeCampaign:{0}:Cleanup' -f $campaignId
        CleanupArguments      = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $cleanupPath
        ShortcutPath          = [string]$Registry.DesktopShortcutPath
        ShortcutName          = $shortcutName
        ExpectedShortcutPath  = $expectedShortcutPath
        ShortcutIconPath      = [string]$Registry.DesktopShortcutIconPath
    }
}

function Test-WauPsadtRegistryCampaignContract {
    param([Parameter(Mandatory)]$Registry,[Parameter(Mandatory)]$Contract)
    try {
        if ([int]$Registry.SchemaVersion -ne 2 -or [string]$Registry.ResourceType -cne 'WauBridgeCampaign') { return $false }
        if ([string]$Registry.State -notin @('Staged', 'Deferred', 'InProgress')) { return $false }
        if ([string]$Registry.PackageId -ine [string]$Contract.PackageId) { return $false }
        if ([string]$Registry.TargetVersion -cne [string]$Contract.TargetVersion) { return $false }
        if ([string]$Registry.CampaignId -cne [string]$Contract.CampaignId) { return $false }
        if ([string]$Registry.TaskPath -ine [string]$Contract.TaskPath -or [string]$Registry.TaskName -cne [string]$Contract.TaskName) { return $false }
        if ([string]$Registry.Operation -cne 'Upgrade') { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$Registry.DesktopShortcutName) -or [string]::IsNullOrWhiteSpace([string]$Registry.DesktopShortcutPath)) { return $false }
        if ([string]$Registry.DesktopShortcutName -notmatch '\.lnk$') { return $false }
        if ([System.IO.Path]::GetFileName([string]$Registry.DesktopShortcutPath) -ine [string]$Registry.DesktopShortcutName) { return $false }
        if (-not (Test-WauPsadtSamePath -Left ([string]$Registry.DesktopShortcutPath) -Right ([string]$Contract.ExpectedShortcutPath))) { return $false }
        return (Test-WauPsadtSamePath -Left ([string]$Registry.DesktopShortcutIconPath) -Right (Join-Path $Contract.StageRoot 'Assets\AppIcon.ico'))
    }
    catch { return $false }
}

function Test-WauPsadtStageMarkerContract {
    param([Parameter(Mandatory)]$Marker,[Parameter(Mandatory)]$Contract)
    try {
        return (
            [int]$Marker.SchemaVersion -eq 1 -and
            [string]$Marker.ResourceType -ceq 'WauBridgeStageRoot' -and
            [string]$Marker.CampaignId -ceq [string]$Contract.CampaignId -and
            [string]$Marker.PackageId -ieq [string]$Contract.PackageId -and
            [string]$Marker.TargetVersion -ceq [string]$Contract.TargetVersion -and
            (Test-WauPsadtSamePath -Left ([string]$Marker.StageRoot) -Right ([string]$Contract.StageRoot))
        )
    }
    catch { return $false }
}

function Test-WauPsadtScheduleStateContract {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)]$Registry,[Parameter(Mandatory)]$Contract)
    try {
        if ([int]$State.SchemaVersion -ne 3 -or [string]$State.ResourceType -cne 'WauBridgeScheduleState') { return $false }
        if ([string]$State.PackageId -ine [string]$Contract.PackageId -or [string]$State.CampaignId -cne [string]$Contract.CampaignId) { return $false }
        if ([string]$State.TargetVersion -cne [string]$Contract.TargetVersion -or [string]$State.Operation -cne 'Upgrade') { return $false }
        if ([string]$State.TaskPath -ine [string]$Contract.TaskPath -or [string]$State.TaskName -cne [string]$Contract.TaskName) { return $false }
        if ([string]$State.DesktopShortcutName -ine [string]$Registry.DesktopShortcutName) { return $false }
        if (-not (Test-WauPsadtSamePath -Left ([string]$State.DesktopShortcutPath) -Right ([string]$Registry.DesktopShortcutPath))) { return $false }
        if (-not (Test-WauPsadtSamePath -Left ([string]$State.DesktopShortcutIconPath) -Right ([string]$Contract.ShortcutIconPath))) { return $false }
        if ([string]::IsNullOrWhiteSpace([string]$State.DesktopShortcutDescription)) { return $false }
        $triggerDates = @($State.TriggerDates)
        if ($triggerDates.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$State.FinalDeadline)) { return $false }
        foreach ($date in @($triggerDates + @($State.FinalDeadline))) { $null = [datetime]$date }
        return $true
    }
    catch { return $false }
}

function Test-WauPsadtScheduledTaskContract {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$Contract,
        [switch]$Cleanup,
        [switch]$RequireTriggers
    )
    try {
        $actions = @($Task.Actions)
        if ($actions.Count -ne 1) { return $false }
        $description = if ($Cleanup) { $Contract.CleanupDescription } else { $Contract.TaskDescription }
        $arguments = if ($Cleanup) { $Contract.CleanupArguments } else { $Contract.TaskArguments }
        if ([string]$Task.Description -cne [string]$description) { return $false }
        if ([string]$actions[0].Execute -ine [string]$Contract.PowerShellPath -or [string]$actions[0].Arguments -cne [string]$arguments) { return $false }
        if ([string]$Task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) { return $false }
        if ([string]$Task.Principal.RunLevel -notmatch 'Highest' -or [string]$Task.Principal.LogonType -notmatch 'ServiceAccount') { return $false }
        if (-not $Cleanup -and [bool]$Task.Settings.StartWhenAvailable -ne $true) { return $false }
        if ($RequireTriggers -and @($Task.Triggers).Count -lt 1) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-WauPsadtShortcutProperties {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LiteralPath)
    return [pscustomobject]@{
        ShortcutPath     = $LiteralPath
        ShortcutName     = [System.IO.Path]::GetFileName($LiteralPath)
        TargetPath       = [string]$shortcut.TargetPath
        Arguments        = [string]$shortcut.Arguments
        WorkingDirectory = [string]$shortcut.WorkingDirectory
        Description      = [string]$shortcut.Description
        IconLocation     = [string]$shortcut.IconLocation
        WindowStyle      = [int]$shortcut.WindowStyle
    }
}

function Test-WauPsadtShortcutContract {
    param([Parameter(Mandatory)]$Shortcut,[Parameter(Mandatory)]$State,[Parameter(Mandatory)]$Contract)
    try {
        $taskPathLiteral = ConvertTo-WauPsadtPowerShellSingleQuotedLiteral -Value $Contract.TaskPath
        $taskNameLiteral = ConvertTo-WauPsadtPowerShellSingleQuotedLiteral -Value $Contract.TaskName
        $arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "& {{ Start-ScheduledTask -TaskPath {0} -TaskName {1} -ErrorAction Stop }}"' -f $taskPathLiteral, $taskNameLiteral
        return (
            (Test-WauPsadtSamePath -Left ([string]$Shortcut.ShortcutPath) -Right ([string]$Contract.ShortcutPath)) -and
            [string]$Shortcut.ShortcutName -ieq [string]$Contract.ShortcutName -and
            (Test-WauPsadtSamePath -Left ([string]$Shortcut.TargetPath) -Right ([string]$Contract.PowerShellPath)) -and
            [string]$Shortcut.Arguments -ceq $arguments -and
            (Test-WauPsadtSamePath -Left ([string]$Shortcut.WorkingDirectory) -Right (Split-Path -Path $Contract.PowerShellPath -Parent)) -and
            [string]$Shortcut.Description -ceq [string]$State.DesktopShortcutDescription -and
            [string]$Shortcut.IconLocation -ieq ('{0},0' -f $Contract.ShortcutIconPath) -and
            [int]$Shortcut.WindowStyle -eq 7
        )
    }
    catch { return $false }
}

function Get-WauPsadtCampaignHealth {
    param([Parameter(Mandatory)]$Snapshot)

    if (-not $Snapshot.RegistryOwned) { return [pscustomobject]@{ Status = 'BlockedForeign'; Reason = 'registry contract is incomplete or mismatched' } }
    if ($Snapshot.StageExists -and -not $Snapshot.StageOwned) { return [pscustomobject]@{ Status = 'BlockedForeign'; Reason = 'StageRoot exists without a matching ownership marker' } }
    if ($Snapshot.TaskExists -and -not $Snapshot.TaskOwned) { return [pscustomobject]@{ Status = 'BlockedForeign'; Reason = 'retry task does not match the campaign contract' } }
    if ($Snapshot.CleanupTaskExists -and -not $Snapshot.CleanupTaskOwned) { return [pscustomobject]@{ Status = 'BlockedForeign'; Reason = 'cleanup task does not match the campaign contract' } }
    if ($Snapshot.ShortcutExists -and -not $Snapshot.ShortcutOwned) { return [pscustomobject]@{ Status = 'BlockedForeign'; Reason = 'desktop shortcut ownership cannot be proven' } }
    if ($Snapshot.StageOwned -and $Snapshot.StateOwned -and $Snapshot.TaskHealthy -and -not $Snapshot.CleanupTaskExists) {
        return [pscustomobject]@{ Status = 'Healthy'; Reason = 'registry, StageRoot, schedule state, and retry task match' }
    }
    return [pscustomobject]@{ Status = 'RecoverableOrphan'; Reason = 'one or more owned campaign resources are missing or incomplete' }
}

function Get-WauPsadtCampaignSnapshot {
    param([Parameter(Mandatory)]$Registry,[Parameter(Mandatory)]$Contract,[string]$RegistryKeyName)

    $stageExists = Test-Path -LiteralPath $Contract.StageRoot -PathType Container
    $marker = $null
    if (Test-Path -LiteralPath $Contract.OwnerMarkerPath -PathType Leaf) {
        try { $marker = Get-Content -LiteralPath $Contract.OwnerMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
    $stageOwned = $stageExists -and $marker -and (Test-WauPsadtStageMarkerContract -Marker $marker -Contract $Contract)

    $stateExists = Test-Path -LiteralPath $Contract.StateFilePath -PathType Leaf
    $state = $null
    if ($stateExists) {
        try { $state = Get-Content -LiteralPath $Contract.StateFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
    $stateOwned = $state -and (Test-WauPsadtScheduleStateContract -State $state -Registry $Registry -Contract $Contract)

    $task = Get-ScheduledTask -TaskPath $Contract.TaskPath -TaskName $Contract.TaskName -ErrorAction SilentlyContinue
    $taskExists = $null -ne $task
    $taskOwned = $taskExists -and (Test-WauPsadtScheduledTaskContract -Task $task -Contract $Contract)
    $taskHealthy = $taskExists -and (Test-WauPsadtScheduledTaskContract -Task $task -Contract $Contract -RequireTriggers)
    $cleanupTask = Get-ScheduledTask -TaskPath $Contract.TaskPath -TaskName $Contract.CleanupTaskName -ErrorAction SilentlyContinue
    $cleanupTaskExists = $null -ne $cleanupTask
    $cleanupTaskOwned = $cleanupTaskExists -and (Test-WauPsadtScheduledTaskContract -Task $cleanupTask -Contract $Contract -Cleanup)

    $shortcutExists = -not [string]::IsNullOrWhiteSpace($Contract.ShortcutPath) -and (Test-Path -LiteralPath $Contract.ShortcutPath -PathType Leaf)
    $shortcutOwned = $false
    if ($shortcutExists -and $stateOwned) {
        try {
            $shortcut = Get-WauPsadtShortcutProperties -LiteralPath $Contract.ShortcutPath
            $shortcutOwned = Test-WauPsadtShortcutContract -Shortcut $shortcut -State $state -Contract $Contract
        }
        catch { }
    }

    return [pscustomobject]@{
        RegistryOwned       = (Test-WauPsadtRegistryCampaignContract -Registry $Registry -Contract $Contract) -and ([string]::IsNullOrWhiteSpace($RegistryKeyName) -or $RegistryKeyName -ceq $Contract.CampaignId)
        StageExists         = $stageExists
        StageOwned          = [bool]$stageOwned
        StateExists         = $stateExists
        StateOwned          = [bool]$stateOwned
        TaskExists          = $taskExists
        TaskOwned           = [bool]$taskOwned
        TaskHealthy         = [bool]$taskHealthy
        CleanupTaskExists   = $cleanupTaskExists
        CleanupTaskOwned    = [bool]$cleanupTaskOwned
        ShortcutExists      = $shortcutExists
        ShortcutOwned       = [bool]$shortcutOwned
    }
}

function Remove-WauPsadtEmptyStageParents {
    param([Parameter(Mandatory)][string]$StageRoot,[Parameter(Mandatory)][string]$StageBase)
    try {
        $canonicalStageRoot = Get-WauPsadtCanonicalPath -Path $StageRoot
        $canonicalStageBase = Get-WauPsadtCanonicalPath -Path $StageBase
        $packageRoot = Split-Path -Path $canonicalStageRoot -Parent
        if (-not (Test-WauPsadtSamePath -Left (Split-Path -Path $packageRoot -Parent) -Right $canonicalStageBase)) { return }
        if ((Test-Path -LiteralPath $packageRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $packageRoot -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $packageRoot -Force -ErrorAction Stop
        }
        if ((Test-Path -LiteralPath $canonicalStageBase -PathType Container) -and @(Get-ChildItem -LiteralPath $canonicalStageBase -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $canonicalStageBase -Force -ErrorAction Stop
        }
    }
    catch { }
}

function Remove-WauPsadtOwnedOrphanedCampaign {
    param([Parameter(Mandatory)]$RegistryKey,[Parameter(Mandatory)]$Contract,[Parameter(Mandatory)]$Snapshot)

    $health = Get-WauPsadtCampaignHealth -Snapshot $Snapshot
    if ($health.Status -ne 'RecoverableOrphan') {
        throw "Campaign cleanup requires a recoverable, fully owned orphan; current status is [$($health.Status)]."
    }
    if ($Snapshot.ShortcutExists) { Remove-Item -LiteralPath $Contract.ShortcutPath -Force -ErrorAction Stop }
    if ($Snapshot.TaskExists) { Unregister-ScheduledTask -TaskPath $Contract.TaskPath -TaskName $Contract.TaskName -Confirm:$false -ErrorAction Stop }
    if ($Snapshot.CleanupTaskExists) { Unregister-ScheduledTask -TaskPath $Contract.TaskPath -TaskName $Contract.CleanupTaskName -Confirm:$false -ErrorAction Stop }
    if (Test-Path -LiteralPath $RegistryKey) { Remove-Item -LiteralPath $RegistryKey -Recurse -Force -ErrorAction Stop }
    if ($Snapshot.StageExists) {
        Remove-Item -LiteralPath $Contract.StageRoot -Recurse -Force -ErrorAction Stop
        Remove-WauPsadtEmptyStageParents -StageRoot $Contract.StageRoot -StageBase $Contract.StageBase
    }
}

function Test-WauPsadtActiveCampaign {
    param([Parameter(Mandatory)][string]$PackageId)

    $basePath = 'HKLM:\SOFTWARE\WauPsadtBridge\Campaigns'
    if (-not (Test-Path -LiteralPath $basePath)) { return $false }

    foreach ($key in @(Get-ChildItem -LiteralPath $basePath -ErrorAction SilentlyContinue)) {
        try {
            $raw = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if ([string]$raw.PackageId -ine $PackageId -or [string]$raw.State -notin @('Staged', 'Deferred', 'InProgress')) { continue }
            $contract = Get-WauPsadtCampaignContract -Registry $raw
            $snapshot = Get-WauPsadtCampaignSnapshot -Registry $raw -Contract $contract -RegistryKeyName ([string]$key.PSChildName)
            $health = Get-WauPsadtCampaignHealth -Snapshot $snapshot
            if ($health.Status -eq 'Healthy') {
                Write-ToLog "WAU-PSADT Bridge found a healthy active campaign [$($contract.CampaignId)] for [$PackageId]." "Yellow"
                return $true
            }
            if ($health.Status -eq 'BlockedForeign') {
                Write-ToLog "WAU-PSADT Bridge cannot reconcile campaign [$($contract.CampaignId)] for [$PackageId]: $($health.Reason). No resource was removed." "Red"
                return $true
            }

            Remove-WauPsadtOwnedOrphanedCampaign -RegistryKey $key.PSPath -Contract $contract -Snapshot $snapshot
            Write-ToLog "WAU-PSADT Bridge removed recoverable orphan campaign [$($contract.CampaignId)] for [$PackageId]; a fresh campaign may now be created." "Yellow"
        }
        catch {
            Write-ToLog "WAU-PSADT Bridge could not inspect or reconcile an active campaign for [$PackageId]: $($_.Exception.Message). No unproven resource was removed." "Red"
            return $true
        }
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
