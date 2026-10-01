# Campaign contract and health evaluation for the WAU-side handoff.

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
    # An unreadable task is not proof that it is missing. Preserve the campaign instead of
    # treating it as an orphan, which would remove its resources.
    if ($Snapshot.TaskObserved -ne $true -or $Snapshot.CleanupTaskObserved -ne $true) {
        return [pscustomobject]@{ Status = 'BlockedUnverified'; Reason = 'the retry or cleanup task could not be read' }
    }
    if ($Snapshot.StageOwned -and $Snapshot.StateOwned -and $Snapshot.TaskHealthy -and -not $Snapshot.CleanupTaskExists) {
        return [pscustomobject]@{ Status = 'Healthy'; Reason = 'registry, StageRoot, schedule state, and retry task match' }
    }
    return [pscustomobject]@{ Status = 'RecoverableOrphan'; Reason = 'one or more owned campaign resources are missing or incomplete' }
}

function Test-WauPsadtTaskNotFoundError {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    # Structured evidence only. Matching the message text would be locale-dependent and could turn
    # an unrelated query failure into an observed absence, which is what this guard exists to stop.
    # A missing command also reports ObjectNotFound, and that is not an absent task.
    if ($ErrorRecord.Exception -is [System.Management.Automation.CommandNotFoundException]) { return $false }
    return ($ErrorRecord.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound)
}

function Get-WauPsadtScheduledTaskObservation {
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)

    # A failed query must not look like an absent task. The runtime removes the resources of a
    # recoverable orphan, so absence has to be an observation rather than a fallback.
    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Present = $null; Task = $null }
    }

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        return [pscustomobject]@{ Present = ($null -ne $task); Task = $task }
    }
    catch {
        if (Test-WauPsadtTaskNotFoundError -ErrorRecord $_) {
            return [pscustomobject]@{ Present = $false; Task = $null }
        }
        return [pscustomobject]@{ Present = $null; Task = $null }
    }
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

    $retryObservation = Get-WauPsadtScheduledTaskObservation -TaskPath $Contract.TaskPath -TaskName $Contract.TaskName
    $task = $retryObservation.Task
    $taskObserved = $null -ne $retryObservation.Present
    $taskExists = $retryObservation.Present -eq $true
    $taskOwned = $taskExists -and (Test-WauPsadtScheduledTaskContract -Task $task -Contract $Contract)
    $taskHealthy = $taskExists -and (Test-WauPsadtScheduledTaskContract -Task $task -Contract $Contract -RequireTriggers)

    $cleanupObservation = Get-WauPsadtScheduledTaskObservation -TaskPath $Contract.TaskPath -TaskName $Contract.CleanupTaskName
    $cleanupTask = $cleanupObservation.Task
    $cleanupTaskObserved = $null -ne $cleanupObservation.Present
    $cleanupTaskExists = $cleanupObservation.Present -eq $true
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
        TaskObserved        = [bool]$taskObserved
        TaskOwned           = [bool]$taskOwned
        TaskHealthy         = [bool]$taskHealthy
        CleanupTaskExists   = $cleanupTaskExists
        CleanupTaskObserved = [bool]$cleanupTaskObserved
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
            if ($health.Status -ne 'RecoverableOrphan') {
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
