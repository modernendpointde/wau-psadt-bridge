# Staging, scheduled tasks, registry campaign state, shortcuts, and cleanup.
function Write-WauBridgeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet(1,2,3)]
        [int]$Severity = 1
    )

    if (Get-Command -Name Write-ADTLogEntry -ErrorAction SilentlyContinue) {
        Write-ADTLogEntry -Message $Message -Severity $Severity
    }
    else {
        Write-Host $Message
    }
}

function Get-WauBridgeSafeName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    return (($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
}

function Get-WauBridgeCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'An empty path cannot be canonicalized.'
    }

    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim()))
}

function Test-WauBridgePathContained {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$ParentPath,
        [switch]$AllowEqual
    )

    $candidate = (Get-WauBridgeCanonicalPath -Path $CandidatePath).TrimEnd('\','/')
    $parent = (Get-WauBridgeCanonicalPath -Path $ParentPath).TrimEnd('\','/')
    if ($AllowEqual -and $candidate.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-WauBridgeAtomicTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $directory = Split-Path -Path $LiteralPath -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Atomic write is missing a destination directory: [$LiteralPath]."
    }

    New-Item -Path $directory -ItemType Directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ('.{0}.tmp' -f [System.IO.Path]::GetRandomFileName())
    $backupPath = Join-Path $directory ('.{0}.bak' -f [System.IO.Path]::GetRandomFileName())
    try {
        Set-Content -LiteralPath $temporaryPath -Value $Content -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $LiteralPath, $backupPath)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $LiteralPath -ErrorAction Stop
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-WauBridgeCompatibilityConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration)

    $validationErrors = New-Object System.Collections.Generic.List[string]
    foreach ($requiredName in @('PackageId','DisplayName','TargetVersion','Retry','UserExperience','ProcessDefinitions')) {
        if (-not $Configuration.Contains($requiredName) -or $null -eq $Configuration[$requiredName]) {
            $validationErrors.Add("Required value [$requiredName] is missing.")
        }
    }

    if ($validationErrors.Count -eq 0) {
        $packageId = [string]$Configuration.PackageId
        if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -match '[\\/:*?"<>|]' -or $packageId -in @('.','..')) {
            $validationErrors.Add('PackageId is empty or contains illegal resource-identifier characters.')
        }
        if ([string]::IsNullOrWhiteSpace([string]$Configuration.DisplayName)) {
            $validationErrors.Add('DisplayName is empty.')
        }
        if (@($Configuration.ProcessDefinitions).Count -lt 1) {
            $validationErrors.Add('ProcessDefinitions must contain at least one process name.')
        }

        if ([int]$Configuration.Retry.Days -lt 1 -or [int]$Configuration.Retry.Days -gt 5) {
            $validationErrors.Add('Retry.Days must be between 1 and 5.')
        }
        if ([int]$Configuration.Retry.TimesPerDay -notin @(1, 2)) {
            $validationErrors.Add('Retry.TimesPerDay must be 1 or 2.')
        }
    }

    if ($validationErrors.Count -gt 0) {
        throw ("WauBridge.Config.ps1 is invalid:`n - {0}" -f ($validationErrors -join "`n - "))
    }
}

function Get-WauBridgeNormalizedTaskPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskPath)

    $normalized = $TaskPath.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return '\' }
    if (-not $normalized.StartsWith('\')) { $normalized = '\' + $normalized }
    if (-not $normalized.EndsWith('\')) { $normalized += '\' }
    return $normalized
}

function Convert-WauBridgeTaskPathToComFolderPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskPath)

    $normalized = Get-WauBridgeNormalizedTaskPath -TaskPath $TaskPath
    if ($normalized -eq '\') { return '\' }
    return $normalized.TrimEnd('\')
}

function Get-WauBridgeBaseAppName {
    [CmdletBinding()]
    param()

    return [string]$WauBridgeConfig.DisplayName
}

function Get-WauBridgeNativeProgramFiles {
    [CmdletBinding()]
    param()

    if ([Environment]::Is64BitOperatingSystem -and -not [string]::IsNullOrWhiteSpace([string]$env:ProgramW6432)) {
        return [string]$env:ProgramW6432
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:ProgramFiles)) {
        return [string]$env:ProgramFiles
    }
    return 'C:\Program Files'
}

function Get-WauBridgeInstallRoot {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-WauBridgeNativeProgramFiles) 'WauPsadtBridge')
}

function Get-WauBridgeRegistryBasePath {
    [CmdletBinding()]
    param()

    return 'HKLM:\SOFTWARE\WauPsadtBridge\Campaigns'
}

function Get-WauBridgeTaskPath {
    [CmdletBinding()]
    param()

    return '\WauPsadtBridge\'
}

function Get-WauBridgeTargetVersionString {
    [CmdletBinding()]
    param()

    return (Get-WauBridgeSafeName -Value ([string]$WauBridgeConfig.TargetVersion))
}

function Get-WauBridgeTaskName {
    [CmdletBinding()]
    param()

    return ('Update_{0}_{1}' -f (Get-WauBridgeSafeName -Value $WauBridgeConfig.PackageId), (Get-WauBridgeTargetVersionString))
}

function Get-WauBridgeCleanupTaskName {
    [CmdletBinding()]
    param()

    return ('Cleanup_{0}_{1}' -f (Get-WauBridgeSafeName -Value $WauBridgeConfig.PackageId), (Get-WauBridgeTargetVersionString))
}

function Get-WauBridgeStageRoot {
    [CmdletBinding()]
    param()

    return (Join-Path (Get-WauBridgeInstallRoot) (Join-Path 'Stage' (Join-Path (Get-WauBridgeSafeName -Value $WauBridgeConfig.PackageId) (Get-WauBridgeTargetVersionString))))
}

function Get-WauBridgeWindowsPowerShellPath {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($env:WINDIR)) {
        return 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function ConvertTo-WauBridgePowerShellSingleQuotedLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -match '[\x00-\x1F\x7F]') {
        throw 'PowerShell literal values must not contain control characters.'
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-WauBridgeManualTaskStartArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    $taskPathLiteral = ConvertTo-WauBridgePowerShellSingleQuotedLiteral -Value $TaskPath
    $taskNameLiteral = ConvertTo-WauBridgePowerShellSingleQuotedLiteral -Value $TaskName
    return '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "& {{ Start-ScheduledTask -TaskPath {0} -TaskName {1} -ErrorAction Stop }}"' -f $taskPathLiteral, $taskNameLiteral
}

function Get-WauBridgeContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $WauBridgeConfig,
        [Parameter(Mandatory)] [string]$ScriptRoot,
        [ValidateSet('Upgrade')][string]$Operation = 'Upgrade'
    )

    $stageRoot = Get-WauBridgeStageRoot
    $retryTaskPath = Get-WauBridgeNormalizedTaskPath -TaskPath (Get-WauBridgeTaskPath)
    $publicDesktopPath = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $desktopShortcutText = Get-WauBridgeDesktopShortcutName -Operation $Operation
    $desktopShortcutName = '{0}.lnk' -f $desktopShortcutText
    $desktopShortcutPath = Join-Path $publicDesktopPath $desktopShortcutName
    $campaignId = '{0}_{1}' -f (Get-WauBridgeSafeName -Value $WauBridgeConfig.PackageId), (Get-WauBridgeTargetVersionString)
    $campaignRegistryPath = Join-Path (Get-WauBridgeRegistryBasePath) $campaignId
    $powerShellPath = Get-WauBridgeWindowsPowerShellPath

    return [pscustomobject]@{
        ScriptRoot = $ScriptRoot
        Schedule = [pscustomobject]@{
            CampaignId             = $campaignId
            CampaignRegistryPath   = $campaignRegistryPath
            TaskPath               = $retryTaskPath
            TaskPathForCom         = (Convert-WauBridgeTaskPathToComFolderPath -TaskPath $retryTaskPath)
            TaskName               = Get-WauBridgeTaskName
            CleanupTaskName        = Get-WauBridgeCleanupTaskName
            DesktopShortcutPath    = $desktopShortcutPath
            DesktopShortcutName    = $desktopShortcutName
            DesktopShortcutText    = $desktopShortcutText
            DesktopShortcutDescription = Get-WauBridgeDesktopShortcutDescription -Operation $Operation
            DesktopShortcutIconPath = Join-Path $stageRoot 'Assets\AppIcon.ico'
            DesktopShortcutTargetPath = $powerShellPath
            DesktopShortcutWorkingDirectory = Split-Path -Path $powerShellPath -Parent
            DesktopShortcutWindowStyle = 7
            Operation              = $Operation
            CleanupScriptPath      = Join-Path $stageRoot 'Cleanup-WauBridgePackage.ps1'
            StateFilePath          = Join-Path $stageRoot 'ScheduleState.json'
        }
        Runtime = [pscustomobject]@{
            StageRoot       = $stageRoot
            OwnerMarkerPath = Join-Path $stageRoot '.waubridge-owner.json'
        }
    }
}

function Test-WauBridgeProcessesRunning {
    [CmdletBinding()]
    param()

    foreach ($processName in @($WauBridgeConfig.ProcessDefinitions)) {
        if ($processName -and (Get-Process -Name $processName -ErrorAction SilentlyContinue)) { return $true }
    }
    return $false
}

function Get-WauBridgeProcessDisplayNames {
    [CmdletBinding()]
    param()

    $names = foreach ($processName in @($WauBridgeConfig.ProcessDefinitions)) {
        [string]$processName
    }
    return ($names | Where-Object { $_ } | Sort-Object -Unique) -join ', '
}

function Ensure-WauBridgeTaskFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$TaskPath)

    $normalized = (Convert-WauBridgeTaskPathToComFolderPath -TaskPath $TaskPath).Trim('\')
    if (-not $normalized) { return }
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $currentFolder = $service.GetFolder('\')
    foreach ($segment in $normalized.Split('\')) {
        try { $currentFolder = $currentFolder.GetFolder($segment) }
        catch { $currentFolder = $currentFolder.CreateFolder($segment) }
    }
}

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

function Get-WauBridgeDesktopShortcutContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    return [pscustomobject]@{
        ShortcutPath     = $Context.Schedule.DesktopShortcutPath
        ShortcutName     = $Context.Schedule.DesktopShortcutName
        TargetPath       = $Context.Schedule.DesktopShortcutTargetPath
        Arguments        = Get-WauBridgeManualTaskStartArguments -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.TaskName
        WorkingDirectory = $Context.Schedule.DesktopShortcutWorkingDirectory
        Description      = $Context.Schedule.DesktopShortcutDescription
        IconLocation     = '{0},0' -f $Context.Schedule.DesktopShortcutIconPath
        WindowStyle      = [int]$Context.Schedule.DesktopShortcutWindowStyle
    }
}

function Test-WauBridgeDesktopShortcutContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    return (
        [string]$Actual.ShortcutPath -ieq [string]$Expected.ShortcutPath -and
        [string]$Actual.ShortcutName -ieq [string]$Expected.ShortcutName -and
        [string]$Actual.TargetPath -ieq [string]$Expected.TargetPath -and
        [string]$Actual.Arguments -ceq [string]$Expected.Arguments -and
        [string]$Actual.WorkingDirectory -ieq [string]$Expected.WorkingDirectory -and
        [string]$Actual.Description -ceq [string]$Expected.Description -and
        [string]$Actual.IconLocation -ieq [string]$Expected.IconLocation -and
        [int]$Actual.WindowStyle -eq [int]$Expected.WindowStyle
    )
}

function Grant-WauBridgeUpdateTaskRunAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$TaskPath,[Parameter(Mandatory)] [string]$TaskName)

    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder((Convert-WauBridgeTaskPathToComFolderPath -TaskPath $TaskPath))
        $task = $folder.GetTask($TaskName)
        $securityDescriptor = [string]$task.GetSecurityDescriptor(0x7)
        if ([string]::IsNullOrWhiteSpace($securityDescriptor) -or $securityDescriptor.IndexOf('D:') -lt 0) {
            throw 'Existing task security descriptor has no DACL.'
        }
        if ($securityDescriptor -match ';;;(AU|S-1-5-11)\)') { return }

        $authenticatedUsersAce = '(A;;GRGX;;;AU)'
        $saclIndex = $securityDescriptor.IndexOf('S:', $securityDescriptor.IndexOf('D:') + 2)
        $updatedDescriptor = if ($saclIndex -ge 0) {
            $securityDescriptor.Insert($saclIndex, $authenticatedUsersAce)
        }
        else {
            $securityDescriptor + $authenticatedUsersAce
        }
        $task.SetSecurityDescriptor($updatedDescriptor, 0)
    }
    catch {
        Write-WauBridgeLog -Message 'Retry task ACL could not be adjusted. Desktop shortcut start may fail for standard users.' -Severity 2
    }
}

function Get-WauBridgeUpdateTaskDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    return ('WauBridgeCampaign:{0}:Update' -f $Context.Schedule.CampaignId)
}

function Get-WauBridgeCleanupTaskDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    return ('WauBridgeCampaign:{0}:Cleanup' -f $Context.Schedule.CampaignId)
}

function Get-WauBridgeUpdateTaskContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    return [pscustomobject]@{
        Execute     = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DeploymentType Install -DeployMode Interactive -InvocationSource RetryTask' -f (Join-Path $Context.Runtime.StageRoot 'Invoke-AppDeployToolkit.ps1')
        Principal   = 'SYSTEM'
        Description = Get-WauBridgeUpdateTaskDescription -Context $Context
        StartWhenAvailable = $true
    }
}

function Get-WauBridgeCleanupTaskContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    return [pscustomobject]@{
        Execute     = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Context.Schedule.CleanupScriptPath
        Principal   = 'SYSTEM'
        Description = Get-WauBridgeCleanupTaskDescription -Context $Context
    }
}

function Test-WauBridgeScheduledTaskContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)]$Contract,
        [switch]$RequireTriggers
    )

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) { return $false }
    if ([string]$Task.Description -cne [string]$Contract.Description) { return $false }
    if ([string]$actions[0].Execute -ine [string]$Contract.Execute) { return $false }
    if ([string]$actions[0].Arguments -cne [string]$Contract.Arguments) { return $false }
    if ([string]$Task.Principal.UserId -notin @([string]$Contract.Principal, 'S-1-5-18')) { return $false }
    if ([string]$Task.Principal.RunLevel -notmatch 'Highest') { return $false }
    if ([string]$Task.Principal.LogonType -notmatch 'ServiceAccount') { return $false }
    if ($Contract.PSObject.Properties.Name -contains 'StartWhenAvailable' -and [bool]$Task.Settings.StartWhenAvailable -ne [bool]$Contract.StartWhenAvailable) { return $false }
    if ($RequireTriggers -and @($Task.Triggers).Count -lt 1) { return $false }
    return $true
}

function Test-WauBridgeUpdateTaskOwned {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Task,[switch]$RequireTriggers)
    return (Test-WauBridgeScheduledTaskContract -Task $Task -Contract (Get-WauBridgeUpdateTaskContract -Context $Context) -RequireTriggers:$RequireTriggers)
}

function Test-WauBridgeUpdateTaskSchedule {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Task,[Parameter(Mandatory)]$ScheduleState)

    $taskDates = @($Task.Triggers | Where-Object StartBoundary | ForEach-Object { ([datetime]$_.StartBoundary).ToUniversalTime() } | Sort-Object)
    $stateDates = @($ScheduleState.TriggerDates | ForEach-Object { ([datetime]$_).ToUniversalTime() } | Sort-Object)
    if ($taskDates.Count -eq 0 -or $taskDates.Count -ne $stateDates.Count) { return $false }
    for ($index = 0; $index -lt $taskDates.Count; $index++) {
        if ([math]::Abs(($taskDates[$index] - $stateDates[$index]).TotalSeconds) -gt 1) { return $false }
    }
    return $true
}

function Test-WauBridgeCleanupTaskOwned {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Task)
    return (Test-WauBridgeScheduledTaskContract -Task $Task -Contract (Get-WauBridgeCleanupTaskContract -Context $Context))
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

function Get-WauBridgeActiveCampaignsForPackageId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageId)

    $basePath = Get-WauBridgeRegistryBasePath
    if (-not (Test-Path -LiteralPath $basePath)) { return @() }

    $activeStates = @('Staged', 'Deferred', 'InProgress')
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($key in @(Get-ChildItem -LiteralPath $basePath -ErrorAction SilentlyContinue)) {
        try {
            $raw = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if ([int]$raw.SchemaVersion -ne 2 -or [string]$raw.ResourceType -ne 'WauBridgeCampaign') { continue }
            if ([string]$raw.PackageId -ine $PackageId) { continue }
            if ([string]$raw.State -notin $activeStates) { continue }
            $result.Add([pscustomobject]@{
                CampaignId    = [string]$raw.CampaignId
                PackageId     = [string]$raw.PackageId
                TargetVersion = [string]$raw.TargetVersion
                State         = [string]$raw.State
                TaskPath      = [string]$raw.TaskPath
                TaskName      = [string]$raw.TaskName
                Operation     = [string]$raw.Operation
            }) | Out-Null
        }
        catch { }
    }
    return @($result)
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

function New-WauBridgeDesktopShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $expected = Get-WauBridgeDesktopShortcutContract -Context $Context
    if (-not (Test-Path -LiteralPath $Context.Schedule.DesktopShortcutIconPath -PathType Leaf)) {
        throw "Desktop shortcut icon was not found: [$($Context.Schedule.DesktopShortcutIconPath)]."
    }
    if (-not (Test-Path -LiteralPath $expected.TargetPath -PathType Leaf)) {
        throw "Windows PowerShell was not found at the expected system path: [$($expected.TargetPath)]."
    }
    if (-not (Test-Path -LiteralPath $expected.WorkingDirectory -PathType Container)) {
        throw "Desktop shortcut working directory was not found: [$($expected.WorkingDirectory)]."
    }

    if ((Test-Path -LiteralPath $expected.ShortcutPath -PathType Leaf) -and -not (Test-WauBridgeDesktopShortcutOwned -Context $Context)) {
        throw "An existing desktop shortcut collides with the configured name and is left in place: [$($expected.ShortcutPath)]."
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($expected.ShortcutPath)
    $shortcut.TargetPath = $expected.TargetPath
    $shortcut.Arguments = $expected.Arguments
    $shortcut.WorkingDirectory = $expected.WorkingDirectory
    $shortcut.Description = $expected.Description
    $shortcut.IconLocation = $expected.IconLocation
    $shortcut.WindowStyle = $expected.WindowStyle
    $shortcut.Save()
}

function Get-WauBridgeDesktopShortcutProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Context.Schedule.DesktopShortcutPath)
    return [pscustomobject]@{
        ShortcutPath     = $Context.Schedule.DesktopShortcutPath
        ShortcutName     = [System.IO.Path]::GetFileName($Context.Schedule.DesktopShortcutPath)
        TargetPath       = [string]$shortcut.TargetPath
        Arguments        = [string]$shortcut.Arguments
        WorkingDirectory = [string]$shortcut.WorkingDirectory
        Description      = [string]$shortcut.Description
        IconLocation     = [string]$shortcut.IconLocation
        WindowStyle      = [int]$shortcut.WindowStyle
    }
}

function Test-WauBridgeDesktopShortcutOwned {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if (-not (Test-Path -LiteralPath $Context.Schedule.DesktopShortcutPath -PathType Leaf)) { return $false }
    try {
        $expected = Get-WauBridgeDesktopShortcutContract -Context $Context
        $actual = Get-WauBridgeDesktopShortcutProperties -Context $Context
        return (Test-WauBridgeDesktopShortcutContract -Expected $expected -Actual $actual)
    }
    catch {
        Write-WauBridgeLog -Message ("Desktop shortcut ownership could not be verified: {0}" -f $_.Exception.Message) -Severity 2
        return $false
    }
}

function Remove-WauBridgeDesktopShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)
    if (Test-Path -LiteralPath $Context.Schedule.DesktopShortcutPath) {
        if (Test-WauBridgeDesktopShortcutOwned -Context $Context) {
            Remove-Item -LiteralPath $Context.Schedule.DesktopShortcutPath -Force -ErrorAction Stop
        }
        else {
            Write-WauBridgeLog -Message ("Desktop shortcut was left in place because ownership was not proven: [$($Context.Schedule.DesktopShortcutPath)].") -Severity 2
        }
    }
}

function Clear-WauBridgeUpdateTaskTriggers {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    try {
        $scheduledTask = Get-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.TaskName -ErrorAction Stop
        if (-not (Test-WauBridgeUpdateTaskOwned -Context $Context -Task $scheduledTask)) {
            throw 'Retry task does not match the ownership contract.'
        }
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder($Context.Schedule.TaskPathForCom)
        $task = $folder.GetTask($Context.Schedule.TaskName)
        $definition = $task.Definition
        $definition.Triggers.Clear() | Out-Null
        $folder.RegisterTaskDefinition($Context.Schedule.TaskName,$definition,6,$definition.Principal.UserId,$null,$definition.Principal.LogonType,$null) | Out-Null
    }
    catch {
        Write-WauBridgeLog -Message 'Retry task triggers could not be cleared.' -Severity 2
    }
}

function Register-WauBridgeCleanupTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    Ensure-WauBridgeTaskFolder -TaskPath $Context.Schedule.TaskPath
    $existingCleanupTask = Get-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.CleanupTaskName -ErrorAction SilentlyContinue
    if ($existingCleanupTask -and -not (Test-WauBridgeCleanupTaskOwned -Context $Context -Task $existingCleanupTask)) {
        throw "An existing task collides with the cleanup task name and is not owned by this campaign: [$($Context.Schedule.TaskPath)$($Context.Schedule.CleanupTaskName)]."
    }
    $taskContract = Get-WauBridgeCleanupTaskContract -Context $Context
    $action = New-ScheduledTaskAction -Execute $taskContract.Execute -Argument $taskContract.Arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $taskContract.Description
    Register-ScheduledTask -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.CleanupTaskName -InputObject $task -Force | Out-Null
}

function Complete-WauBridgeSchedule {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)
    Remove-WauBridgeDesktopShortcut -Context $Context
    Clear-WauBridgeUpdateTaskTriggers -Context $Context
    Register-WauBridgeCleanupTask -Context $Context
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
