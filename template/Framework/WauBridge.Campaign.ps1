# Campaign contract: staging, registry state, schedule state, cleanup, and campaign messages.

function Stage-WauBridgePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)]$Context
    )

    $canonicalSource = Get-WauBridgeCanonicalPath -Path $SourceRoot
    $canonicalDestination = Get-WauBridgeCanonicalPath -Path $DestinationRoot
    if ($canonicalSource.TrimEnd('\','/') -ieq $canonicalDestination.TrimEnd('\','/')) { return }
    if (-not [System.IO.Path]::IsPathRooted($DestinationRoot)) {
        throw "StageRoot must be an absolute path: [$DestinationRoot]."
    }
    $destinationRoot = [System.IO.Path]::GetPathRoot($canonicalDestination)
    if ($canonicalDestination.TrimEnd('\','/') -eq $destinationRoot.TrimEnd('\','/')) {
        throw "A drive root must not be used as StageRoot: [$canonicalDestination]."
    }
    if ((Test-WauBridgePathContained -CandidatePath $canonicalDestination -ParentPath $canonicalSource) -or (Test-WauBridgePathContained -CandidatePath $canonicalSource -ParentPath $canonicalDestination)) {
        throw 'SourceRoot and StageRoot must not nest inside each other.'
    }
    if ((Get-WauBridgeCanonicalPath -Path $Context.Runtime.StageRoot).TrimEnd('\','/') -ine $canonicalDestination.TrimEnd('\','/')) {
        throw 'DestinationRoot does not match the deployment context StageRoot.'
    }
    if (-not (Test-WauBridgePathContained -CandidatePath $Context.Runtime.OwnerMarkerPath -ParentPath $canonicalDestination)) {
        throw 'The ownership marker is not inside StageRoot.'
    }

    New-Item -Path $canonicalDestination -ItemType Directory -Force | Out-Null
    # /E updates staged content and leaves unknown files; /MIR is unused.
    # Robocopy 0..7 are success or informational results.
    $robocopyOutput = & robocopy $canonicalSource $canonicalDestination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XD Logs
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -ge 8) {
        $diagnostic = (@($robocopyOutput) | Select-Object -Last 12) -join [Environment]::NewLine
        throw "Package staging with robocopy failed (ExitCode $robocopyExitCode).`n$diagnostic"
    }

    $marker = [ordered]@{
        SchemaVersion = 1
        ResourceType  = 'WauBridgeStageRoot'
        CampaignId    = $Context.Schedule.CampaignId
        PackageId     = [string]$WauBridgeConfig.PackageId
        TargetVersion = [string]$WauBridgeConfig.TargetVersion
        StageRoot     = $canonicalDestination
        UpdatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-WauBridgeAtomicTextFile -LiteralPath $Context.Runtime.OwnerMarkerPath -Content ($marker | ConvertTo-Json -Depth 4)
    Write-WauBridgeLog -Message ("Package staging completed with robocopy ExitCode [{0}]." -f $robocopyExitCode)
}

function Get-WauBridgeStageOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if (-not (Test-Path -LiteralPath $Context.Runtime.OwnerMarkerPath -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $Context.Runtime.OwnerMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-WauBridgeLog -Message ("Stage ownership marker is unreadable: {0}" -f $_.Exception.Message) -Severity 2
        return $null
    }
}

function Test-WauBridgeStageOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    try {
        $stageRoot = Get-WauBridgeCanonicalPath -Path $Context.Runtime.StageRoot
        $rootPath = [System.IO.Path]::GetPathRoot($stageRoot)
        if (-not [System.IO.Path]::IsPathRooted($stageRoot) -or $stageRoot.TrimEnd('\','/') -eq $rootPath.TrimEnd('\','/')) { return $false }
        if (-not (Test-WauBridgePathContained -CandidatePath $Context.Runtime.OwnerMarkerPath -ParentPath $stageRoot)) { return $false }
        $ownership = Get-WauBridgeStageOwnership -Context $Context
        if (-not $ownership) { return $false }
        if ([int]$ownership.SchemaVersion -ne 1 -or [string]$ownership.ResourceType -ne 'WauBridgeStageRoot') { return $false }
        if ([string]$ownership.CampaignId -ne [string]$Context.Schedule.CampaignId) { return $false }
        if ([string]$ownership.PackageId -ne [string]$WauBridgeConfig.PackageId) { return $false }
        if ([string]$ownership.TargetVersion -ne [string]$WauBridgeConfig.TargetVersion) { return $false }
        return ((Get-WauBridgeCanonicalPath -Path ([string]$ownership.StageRoot)).TrimEnd('\','/') -ieq $stageRoot.TrimEnd('\','/'))
    }
    catch {
        Write-WauBridgeLog -Message ("Stage ownership check failed: {0}" -f $_.Exception.Message) -Severity 2
        return $false
    }
}

function Set-WauBridgeCampaignState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [ValidateSet('Staged','Deferred','InProgress','Completed')][string]$State,
        [pscustomobject]$ScheduleState,
        [int]$PromptShownCount
    )

    $keyPath = $Context.Schedule.CampaignRegistryPath
    New-Item -Path $keyPath -Force | Out-Null
    # State is written last and is the commit marker for the related registry values.
    Remove-ItemProperty -Path $keyPath -Name 'State' -ErrorAction SilentlyContinue
    New-ItemProperty -Path $keyPath -Name 'SchemaVersion' -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'ResourceType' -Value 'WauBridgeCampaign' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'CampaignId' -Value $Context.Schedule.CampaignId -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'PackageId' -Value $WauBridgeConfig.PackageId -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'TargetVersion' -Value ([string]$WauBridgeConfig.TargetVersion) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'TaskPath' -Value $Context.Schedule.TaskPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'TaskName' -Value $Context.Schedule.TaskName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'Operation' -Value $Context.Schedule.Operation -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'DesktopShortcutName' -Value $Context.Schedule.DesktopShortcutName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'DesktopShortcutPath' -Value $Context.Schedule.DesktopShortcutPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'DesktopShortcutIconPath' -Value $Context.Schedule.DesktopShortcutIconPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'LastUpdatedUtc' -Value ((Get-Date).ToUniversalTime().ToString('o')) -PropertyType String -Force | Out-Null
    if ($ScheduleState -and $ScheduleState.FinalDeadline) {
        New-ItemProperty -Path $keyPath -Name 'FinalDeadlineUtc' -Value ($ScheduleState.FinalDeadline.ToUniversalTime().ToString('o')) -PropertyType String -Force | Out-Null
    }
    $promptShownCount = 0
    if ($PSBoundParameters.ContainsKey('PromptShownCount')) {
        $promptShownCount = [int]$PromptShownCount
    }
    else {
        try {
            $existingPrompt = (Get-ItemProperty -LiteralPath $keyPath -Name 'PromptShownCount' -ErrorAction SilentlyContinue).PromptShownCount
            if ($null -ne $existingPrompt) { $promptShownCount = [int]$existingPrompt }
        }
        catch { }
    }
    New-ItemProperty -Path $keyPath -Name 'PromptShownCount' -Value $promptShownCount -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name 'State' -Value $State -PropertyType String -Force | Out-Null
}

function Add-WauBridgePromptShown {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if (-not (Test-WauBridgeSchedulePresent -Context $Context)) { return }
    $current = Get-WauBridgeCampaignState -Context $Context
    $count = 1
    if ($current) { $count = [int]$current.PromptShownCount + 1 }
    Set-WauBridgeCampaignState -Context $Context -State 'Deferred' -ScheduleState $script:WauBridgeState.ScheduleState -PromptShownCount $count
}

function Get-WauBridgeCampaignState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if (-not (Test-Path -LiteralPath $Context.Schedule.CampaignRegistryPath)) { return $null }
    try {
        $raw = Get-ItemProperty -LiteralPath $Context.Schedule.CampaignRegistryPath -ErrorAction Stop
        if ([int]$raw.SchemaVersion -ne 2 -or [string]$raw.ResourceType -ne 'WauBridgeCampaign') {
            Write-WauBridgeLog -Message 'Campaign registry state has an unknown schema or resource type.' -Severity 2
            return $null
        }
        if (
            [string]$raw.Operation -ne 'Upgrade' -or
            [string]::IsNullOrWhiteSpace([string]$raw.DesktopShortcutName) -or
            [string]::IsNullOrWhiteSpace([string]$raw.DesktopShortcutPath) -or
            [string]::IsNullOrWhiteSpace([string]$raw.DesktopShortcutIconPath)
        ) {
            Write-WauBridgeLog -Message 'Campaign registry state is incomplete.' -Severity 2
            return $null
        }
        return [pscustomobject]@{
            CampaignId       = [string]$raw.CampaignId
            PackageId        = [string]$raw.PackageId
            TargetVersion    = [string]$raw.TargetVersion
            State            = [string]$raw.State
            TaskPath         = [string]$raw.TaskPath
            TaskName         = [string]$raw.TaskName
            Operation        = [string]$raw.Operation
            DesktopShortcutName = [string]$raw.DesktopShortcutName
            DesktopShortcutPath = [string]$raw.DesktopShortcutPath
            DesktopShortcutIconPath = [string]$raw.DesktopShortcutIconPath
            LastUpdatedUtc   = if ($raw.LastUpdatedUtc) { [datetime]$raw.LastUpdatedUtc } else { $null }
            FinalDeadlineUtc = if ($raw.FinalDeadlineUtc) { [datetime]$raw.FinalDeadlineUtc } else { $null }
            PromptShownCount = if ($raw.PSObject.Properties.Name -contains 'PromptShownCount') { [int]$raw.PromptShownCount } else { 0 }
        }
    }
    catch {
        Write-WauBridgeLog -Message ("Campaign registry state could not be read: {0}" -f $_.Exception.Message) -Severity 2
        return $null
    }
}

function Remove-WauBridgeCampaignState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)
    if (Test-Path -LiteralPath $Context.Schedule.CampaignRegistryPath) {
        $campaignState = Get-WauBridgeCampaignState -Context $Context
        if (-not $campaignState -or $campaignState.CampaignId -ne $Context.Schedule.CampaignId -or $campaignState.PackageId -ne $WauBridgeConfig.PackageId) {
            throw "Campaign registry key is not removed without matching ownership proof: [$($Context.Schedule.CampaignRegistryPath)]."
        }
        Remove-Item -LiteralPath $Context.Schedule.CampaignRegistryPath -Recurse -Force -ErrorAction Stop
    }
}

function Save-WauBridgeScheduleState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [datetime[]]$TriggerDates,
        [datetime]$FinalDeadline
    )

    $sorted = @($TriggerDates | Sort-Object)
    if (-not $PSBoundParameters.ContainsKey('FinalDeadline')) {
        $FinalDeadline = $sorted | Select-Object -Last 1
    }
    $finalDeadline = $FinalDeadline
    $payload = [ordered]@{
        SchemaVersion       = 3
        ResourceType        = 'WauBridgeScheduleState'
        TriggerDates        = @($TriggerDates | Sort-Object | ForEach-Object { $_.ToUniversalTime().ToString('o') })
        FinalDeadline       = if ($finalDeadline) { $finalDeadline.ToUniversalTime().ToString('o') } else { $null }
        Operation           = $Context.Schedule.Operation
        DesktopShortcutName = $Context.Schedule.DesktopShortcutName
        DesktopShortcutPath = $Context.Schedule.DesktopShortcutPath
        DesktopShortcutDescription = $Context.Schedule.DesktopShortcutDescription
        DesktopShortcutIconPath = $Context.Schedule.DesktopShortcutIconPath
        PackageId           = $WauBridgeConfig.PackageId
        CampaignId          = $Context.Schedule.CampaignId
        TargetVersion       = [string]$WauBridgeConfig.TargetVersion
        CreatedUtc          = (Get-Date).ToUniversalTime().ToString('o')
        TaskPath            = $Context.Schedule.TaskPath
        TaskName            = $Context.Schedule.TaskName
        Policy              = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
        TimeZoneId          = (Get-WauBridgeTimeZone).Id
    }
    Write-WauBridgeAtomicTextFile -LiteralPath $Context.Schedule.StateFilePath -Content ($payload | ConvertTo-Json -Depth 5)
}

function Move-WauBridgeCorruptScheduleState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if (-not (Test-Path -LiteralPath $Context.Schedule.StateFilePath -PathType Leaf)) { return }
    $quarantinePath = '{0}.corrupt.{1}' -f $Context.Schedule.StateFilePath, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff')
    try {
        Move-Item -LiteralPath $Context.Schedule.StateFilePath -Destination $quarantinePath -ErrorAction Stop
        Write-WauBridgeLog -Message ("Invalid retry state was quarantined: [{0}]." -f $quarantinePath) -Severity 2
    }
    catch {
        Write-WauBridgeLog -Message ("Invalid retry state could not be quarantined: {0}" -f $_.Exception.Message) -Severity 2
    }
}

function Get-WauBridgeScheduleState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if (Test-Path -LiteralPath $Context.Schedule.StateFilePath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $Context.Schedule.StateFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $schemaVersion = if ($raw.PSObject.Properties.Name -contains 'SchemaVersion') { [int]$raw.SchemaVersion } else { 0 }
            if ($schemaVersion -ne 3) { throw "Unsupported retry-state schema version [$schemaVersion]." }
            if ([string]$raw.ResourceType -ne 'WauBridgeScheduleState') { throw 'Retry state has an invalid ResourceType.' }
            if ([string]$raw.PackageId -ne [string]$WauBridgeConfig.PackageId -or [string]$raw.CampaignId -ne [string]$Context.Schedule.CampaignId -or [string]$raw.TargetVersion -ne [string]$WauBridgeConfig.TargetVersion) {
                throw 'Retry state does not belong to the current deployment campaign.'
            }
            if (
                [string]$raw.Operation -ne [string]$Context.Schedule.Operation -or
                [string]$raw.TaskPath -ne [string]$Context.Schedule.TaskPath -or
                [string]$raw.TaskName -ne [string]$Context.Schedule.TaskName -or
                [string]$raw.DesktopShortcutName -ne [string]$Context.Schedule.DesktopShortcutName -or
                [string]$raw.DesktopShortcutPath -ne [string]$Context.Schedule.DesktopShortcutPath -or
                [string]$raw.DesktopShortcutDescription -ne [string]$Context.Schedule.DesktopShortcutDescription -or
                [string]$raw.DesktopShortcutIconPath -ne [string]$Context.Schedule.DesktopShortcutIconPath
            ) {
                throw 'Retry state does not match the expected campaign and shortcut contract.'
            }
            $triggerDates = @()
            if ($raw.TriggerDates) { $triggerDates = @($raw.TriggerDates | ForEach-Object { [datetime]$_ }) }
            $policyMatches = Test-WauBridgeDeferralPolicyMatches -PersistedPolicy $raw.Policy -CurrentPolicy (Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig)
            return [pscustomobject]@{
                SchemaVersion = $schemaVersion
                PolicyMatches = $policyMatches
                TriggerDates = $triggerDates
                FinalDeadline = if ($raw.FinalDeadline) { [datetime]$raw.FinalDeadline } else { $null }
                Operation = [string]$raw.Operation
                DesktopShortcutName = [string]$raw.DesktopShortcutName
                DesktopShortcutPath = [string]$raw.DesktopShortcutPath
                DesktopShortcutDescription = [string]$raw.DesktopShortcutDescription
                DesktopShortcutIconPath = [string]$raw.DesktopShortcutIconPath
                TaskPath = [string]$raw.TaskPath
                TaskName = [string]$raw.TaskName
            }
        }
        catch {
            Write-WauBridgeLog -Message ("Retry state could not be loaded: {0}. Falling back to validated task inspection." -f $_.Exception.Message) -Severity 2
            Move-WauBridgeCorruptScheduleState -Context $Context
        }
    }

    try {
        $scheduledTask = Get-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.TaskName -ErrorAction Stop
        if (-not (Test-WauBridgeUpdateTaskOwned -Context $Context -Task $scheduledTask -RequireTriggers)) {
            Write-WauBridgeLog -Message 'Existing retry task does not match the expected ownership contract and is not used as a state source.' -Severity 2
            return [pscustomobject]@{ SchemaVersion = 0; PolicyMatches = $false; TriggerDates = @(); FinalDeadline = $null }
        }
        $dates = @($scheduledTask.Triggers | Where-Object StartBoundary | ForEach-Object { [datetime]$_.StartBoundary } | Sort-Object)
        return [pscustomobject]@{ SchemaVersion = 0; PolicyMatches = $false; TriggerDates = $dates; FinalDeadline = $dates | Select-Object -Last 1 }
    }
    catch {
        return [pscustomobject]@{ SchemaVersion = 0; PolicyMatches = $false; TriggerDates = @(); FinalDeadline = $null }
    }
}

function Test-WauBridgeSchedulePresent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if (Test-Path -LiteralPath $Context.Schedule.StateFilePath -PathType Leaf) { return $true }
    if (Test-Path -LiteralPath $Context.Schedule.CampaignRegistryPath) { return $true }
    try {
        $task = Get-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.TaskName -ErrorAction Stop
        return (Test-WauBridgeUpdateTaskOwned -Context $Context -Task $task)
    }
    catch { return $false }
}

function Register-WauBridgeSchedule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][ValidateSet('Upgrade')][string]$Operation,
        [int]$ConsumedNow = 0
    )

    $context = Get-WauBridgeContext -WauBridgeConfig $WauBridgeConfig -ScriptRoot $SourceRoot -Operation $Operation

    Ensure-WauBridgeTaskFolder -TaskPath $context.Schedule.TaskPath
    Stage-WauBridgePackage -SourceRoot $SourceRoot -DestinationRoot $context.Runtime.StageRoot -Context $context
    if (-not (Test-Path -LiteralPath $context.Schedule.DesktopShortcutIconPath -PathType Leaf)) {
        throw "Shortcut icon is missing from the staged package: [$($context.Schedule.DesktopShortcutIconPath)]."
    }

    $existingState = Get-WauBridgeScheduleState -Context $context
    $existingTask = Get-ScheduledTask -TaskPath $context.Schedule.TaskPath -TaskName $context.Schedule.TaskName -ErrorAction SilentlyContinue

    $existingTaskOwned = ($existingTask -and (Test-WauBridgeUpdateTaskOwned -Context $context -Task $existingTask -RequireTriggers))
    $existingTaskValid = (
        $existingTask -and
        $existingState.FinalDeadline -and
        $existingState.PolicyMatches -and
        @($existingState.TriggerDates).Count -gt 0 -and
        $existingTaskOwned -and
        (Test-WauBridgeUpdateTaskSchedule -Task $existingTask -ScheduleState $existingState)
    )
    if ($existingTask -and -not $existingTaskOwned) {
        throw "An existing task collides with the retry task name and is not owned by this campaign: [$($context.Schedule.TaskPath)$($context.Schedule.TaskName)]."
    }

    if ($existingState.FinalDeadline -and $existingTaskValid) {
        Save-WauBridgeScheduleState -Context $context -TriggerDates $existingState.TriggerDates
        Set-WauBridgeCampaignState -Context $context -State 'Staged' -ScheduleState $existingState
        Grant-WauBridgeUpdateTaskRunAccess -TaskPath $context.Schedule.TaskPath -TaskName $context.Schedule.TaskName
        New-WauBridgeDesktopShortcut -Context $context
        return [pscustomobject]@{ Context = $context; TriggerDates = $existingState.TriggerDates; FinalDeadline = $existingState.FinalDeadline; FirstBootstrap = $false; ReusedExisting = $true }
    }

    if ($existingTaskOwned -and -not $existingTaskValid) {
        Write-WauBridgeLog -Message 'Owned retry task is stale and will be reconciled to the current deferral policy.' -Severity 2
        Unregister-ScheduledTask -TaskPath $context.Schedule.TaskPath -TaskName $context.Schedule.TaskName -Confirm:$false -ErrorAction Stop
    }

    $reminderDates = @(Get-WauBridgeScheduleTriggerDates -ConsumedNow $ConsumedNow)
    if ($reminderDates.Count -lt 1) {
        throw 'Retry schedule produced no trigger dates.'
    }
    $triggerObjects = foreach ($date in $reminderDates) { New-ScheduledTaskTrigger -Once -At $date }
    $taskContract = Get-WauBridgeUpdateTaskContract -Context $context
    $action = New-ScheduledTaskAction -Execute $taskContract.Execute -Argument $taskContract.Arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $triggerObjects -Principal $principal -Settings $settings -Description $taskContract.Description
    Register-ScheduledTask -TaskPath $context.Schedule.TaskPath -TaskName $context.Schedule.TaskName -InputObject $task | Out-Null
    Grant-WauBridgeUpdateTaskRunAccess -TaskPath $context.Schedule.TaskPath -TaskName $context.Schedule.TaskName
    Save-WauBridgeScheduleState -Context $context -TriggerDates $reminderDates
    $retryState = Get-WauBridgeScheduleState -Context $context
    Set-WauBridgeCampaignState -Context $context -State 'Staged' -ScheduleState $retryState
    New-WauBridgeDesktopShortcut -Context $context
    return [pscustomobject]@{ Context = $context; TriggerDates = $reminderDates; FinalDeadline = ($reminderDates | Sort-Object | Select-Object -Last 1); FirstBootstrap = $true; ReusedExisting = $false }
}

function Invoke-WauBridgeScheduleCatchUp {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) { return }
    $state = Get-WauBridgeScheduleState -Context $Context
    if (-not $state -or -not $state.FinalDeadline) { return }

    $now = Get-Date
    $future = @($state.TriggerDates | Where-Object { $_ -gt $now.AddMinutes(2) })
    if ($future.Count -gt 0) { return }

    $dates = @(Get-WauBridgeCatchUpTriggerDates -FinalDeadline $state.FinalDeadline)
    if ($dates.Count -lt 1) { return }

    $existingTask = Get-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.TaskName -ErrorAction SilentlyContinue
    if (-not $existingTask -or -not (Test-WauBridgeUpdateTaskOwned -Context $Context -Task $existingTask)) {
        Write-WauBridgeLog -Message 'Catch-up skipped because the retry task is missing or not owned.' -Severity 2
        return
    }

    $triggerObjects = foreach ($date in $dates) { New-ScheduledTaskTrigger -Once -At $date }
    Set-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.TaskName -Trigger $triggerObjects | Out-Null
    Save-WauBridgeScheduleState -Context $Context -TriggerDates $dates -FinalDeadline $state.FinalDeadline
    Write-WauBridgeLog -Message ("Catch-up scheduled next retry at [{0}]." -f $dates[0])
}

function Remove-WauBridgeEmptyStageParents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$StageBasePath = (Join-Path (Get-WauBridgeInstallRoot) 'Stage')
    )

    try {
        $stageRoot = Get-WauBridgeCanonicalPath -Path $Context.Runtime.StageRoot
        $stageBase = Get-WauBridgeCanonicalPath -Path $StageBasePath
        $packageRoot = Split-Path -Path $stageRoot -Parent
        if (Test-Path -LiteralPath $stageRoot) { return }
        if ((Split-Path -Path $packageRoot -Parent).TrimEnd('\','/') -ine $stageBase.TrimEnd('\','/')) { return }

        if ((Test-Path -LiteralPath $packageRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $packageRoot -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $packageRoot -Force -ErrorAction Stop
        }
        if ((Test-Path -LiteralPath $stageBase -PathType Container) -and @(Get-ChildItem -LiteralPath $stageBase -Force -ErrorAction Stop).Count -eq 0) {
            Remove-Item -LiteralPath $stageBase -Force -ErrorAction Stop
        }
    }
    catch {
        Write-WauBridgeLog -Message ("Empty Stage parent cleanup was skipped: {0}" -f $_.Exception.Message) -Severity 2
    }
}

function Remove-WauBridgeSchedule {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context,[switch]$RemoveStageRoot)
    $stageOwned = Test-WauBridgeStageOwnership -Context $Context
    Remove-WauBridgeDesktopShortcut -Context $Context
    foreach ($taskDefinition in @(
        [pscustomobject]@{ Name = $Context.Schedule.TaskName; Kind = 'Retry' },
        [pscustomobject]@{ Name = $Context.Schedule.CleanupTaskName; Kind = 'Cleanup' }
    )) {
        try {
            $scheduledTask = Get-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $taskDefinition.Name -ErrorAction Stop
            $owned = if ($taskDefinition.Kind -eq 'Retry') {
                Test-WauBridgeUpdateTaskOwned -Context $Context -Task $scheduledTask
            }
            else {
                Test-WauBridgeCleanupTaskOwned -Context $Context -Task $scheduledTask
            }
            if ($owned) {
                Unregister-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $taskDefinition.Name -Confirm:$false -ErrorAction Stop
            }
            else {
                Write-WauBridgeLog -Message ("Task [{0}{1}] was left in place because ownership was not proven." -f $Context.Schedule.TaskPath, $taskDefinition.Name) -Severity 2
            }
        }
        catch [Microsoft.Management.Infrastructure.CimException] {
            if ($_.Exception.Message -notmatch 'cannot find|nicht gefunden') {
                Write-WauBridgeLog -Message ("Task [{0}] could not be inspected or removed: {1}" -f $taskDefinition.Name, $_.Exception.Message) -Severity 2
            }
        }
        catch {
            Write-WauBridgeLog -Message ("Task [{0}] could not be inspected or removed: {1}" -f $taskDefinition.Name, $_.Exception.Message) -Severity 2
        }
    }
    Remove-WauBridgeCampaignState -Context $Context
    if ($stageOwned) {
        if (Test-Path -LiteralPath $Context.Schedule.StateFilePath) { Remove-Item -LiteralPath $Context.Schedule.StateFilePath -Force -ErrorAction Stop }
    }
    elseif (Test-Path -LiteralPath $Context.Schedule.StateFilePath) {
        Write-WauBridgeLog -Message 'State file was left in place because stage ownership was not proven.' -Severity 2
    }
    if ($RemoveStageRoot -and $Context.Runtime.StageRoot -and (Test-Path -LiteralPath $Context.Runtime.StageRoot)) {
        if (-not $stageOwned) {
            throw "StageRoot is not removed recursively without a matching ownership marker: [$($Context.Runtime.StageRoot)]."
        }
        Remove-Item -LiteralPath $Context.Runtime.StageRoot -Recurse -Force -ErrorAction Stop
        Remove-WauBridgeEmptyStageParents -Context $Context
    }
}

function Set-WauBridgeCloseAppsCustomMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Message)
    $module = Get-Module -Name PSAppDeployToolkit -ErrorAction SilentlyContinue
    if (-not $module) { return }
    try {
        $adtState = $module.SessionState.PSVariable.GetValue('ADT')
        if ($adtState -and $adtState.Strings -and $adtState.Strings.CloseAppsPrompt) {
            $adtState.Strings.CloseAppsPrompt.CustomMessage = $Message
        }
    }
    catch {
        Write-WauBridgeLog -Message 'Unable to update the in-memory PSADT custom message.' -Severity 2
    }
}

function Get-WauBridgeUpdateCustomMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [bool]$DeadlinePassed,[Parameter(Mandatory)] [string]$ProcessDisplayNames,[Nullable[datetime]]$FinalDeadline)

    $context = @{
        AppName             = (Get-WauBridgeBaseAppName)
        ProcessDisplayNames = $ProcessDisplayNames
        DesktopShortcutName = (Get-WauBridgeDesktopShortcutName)
        FinalDeadlineText   = if ($FinalDeadline) { Format-WauBridgeDateTime -DateTime $FinalDeadline } else { '' }
    }

    if ($DeadlinePassed) { return Get-WauBridgeRenderedMessage -TemplateName 'UpgradeAfterDeadline' -Context $context }
    if ($FinalDeadline)  { return Get-WauBridgeRenderedMessage -TemplateName 'UpgradeBeforeDeadline' -Context $context }
    return Get-WauBridgeRenderedMessage -TemplateName 'UpgradeNoDeadline' -Context $context
}
