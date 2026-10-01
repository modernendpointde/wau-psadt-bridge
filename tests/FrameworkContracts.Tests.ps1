$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$templateRoot = Join-Path $repoRoot 'template'

. (Join-Path $templateRoot 'App/WauBridge.Config.ps1')
. (Join-Path $templateRoot 'Framework/WauBridge.ps1')

$frameworkText = (Get-ChildItem -LiteralPath (Join-Path $templateRoot 'Framework') -Filter '*.ps1' -File |
    Sort-Object Name |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join [Environment]::NewLine

foreach ($component in @('Foundation', 'Context', 'Campaign', 'Scheduling', 'Shortcuts')) {
    $componentPath = Join-Path $templateRoot ('Framework/WauBridge.{0}.ps1' -f $component)
    Assert-True (Test-Path -LiteralPath $componentPath -PathType Leaf) "framework component $component exists"
}

# Identity normally arrives with the campaign JSON overlay. Supplying it directly keeps
# these component contracts testable without a Windows deployment.
$WauBridgeConfig.PackageId = 'Google.Chrome'
$WauBridgeConfig.DisplayName = 'Google Chrome'
$WauBridgeConfig.TargetVersion = '140.0.7339.127'

$previousProgramFiles = $env:ProgramFiles
$previousProgramW6432 = $env:ProgramW6432
$previousWinDir = $env:WINDIR

try {
    # Join-Path rejects drive-qualified Windows paths outside Windows, so the environment
    # uses platform-native directories. The preference order under test is unchanged.
    $nativeProgramFiles = Join-Path ([System.IO.Path]::GetTempPath()) 'waubridge-native'
    $wow64ProgramFiles = Join-Path ([System.IO.Path]::GetTempPath()) 'waubridge-wow64'
    $env:ProgramFiles = $wow64ProgramFiles
    $env:ProgramW6432 = $nativeProgramFiles
    $env:WINDIR = Join-Path ([System.IO.Path]::GetTempPath()) 'waubridge-windows'

    # Native Program Files must win over the WOW64 view, otherwise a 32-bit process would
    # install or look under Program Files (x86).
    Assert-True ((Get-WauBridgeNativeProgramFiles) -eq $nativeProgramFiles) 'native Program Files is preferred'
    Assert-True ((Get-WauBridgeInstallRoot) -eq (Join-Path $nativeProgramFiles 'WauPsadtBridge')) 'bridge root is the native product folder'
    Assert-True ((Get-WauBridgeRegistryBasePath) -eq 'HKLM:\SOFTWARE\WauPsadtBridge\Campaigns') 'campaign registry base is fixed'
    Assert-True ((Get-WauBridgeTaskPath) -eq '\WauPsadtBridge\') 'task path is a fixed product folder'
    Assert-True ((Get-WauBridgeStageRoot) -match 'Stage') 'deferred campaigns stage under Stage'
    Assert-True ((Get-WauBridgeStageRoot).StartsWith((Get-WauBridgeInstallRoot), [System.StringComparison]::OrdinalIgnoreCase)) 'stage root is below the bridge root'
    Assert-True ((Get-WauBridgeWindowsPowerShellPath) -match 'powershell\.exe$') 'Windows PowerShell resolves below WINDIR'

    $env:ProgramW6432 = ''
    Assert-True ((Get-WauBridgeNativeProgramFiles) -eq $wow64ProgramFiles) 'Program Files is used when no native view exists'
    $env:ProgramW6432 = $nativeProgramFiles

    Assert-True ((Get-WauBridgeSafeName -Value 'Google.Chrome 140.0') -eq 'Google.Chrome_140.0') 'safe name replaces illegal characters'
    Assert-True ((Get-WauBridgeNormalizedTaskPath -TaskPath 'WauPsadtBridge') -eq '\WauPsadtBridge\') 'task path is normalized'
    Assert-True ((Convert-WauBridgeTaskPathToComFolderPath -TaskPath '\WauPsadtBridge\') -eq '\WauPsadtBridge') 'task path drops the trailing separator for COM'

    Assert-True ((Get-WauBridgeTaskName) -eq 'Update_Google.Chrome_140.0.7339.127') 'retry task name is Update_id_version'
    Assert-True ((Get-WauBridgeCleanupTaskName) -eq 'Cleanup_Google.Chrome_140.0.7339.127') 'cleanup task name is Cleanup_id_version'

    Assert-True ((ConvertTo-WauBridgePowerShellSingleQuotedLiteral -Value "O'Brien") -eq "'O''Brien'") 'single quotes are escaped for a PowerShell literal'
    $controlRejected = $false
    try { $null = ConvertTo-WauBridgePowerShellSingleQuotedLiteral -Value "bad`nvalue" }
    catch { $controlRejected = $true }
    Assert-True $controlRejected 'control characters are rejected in a PowerShell literal'

    $containRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('waubridge-contain-' + [guid]::NewGuid().ToString('N'))
    Assert-True (Test-WauBridgePathContained -CandidatePath (Join-Path $containRoot 'child') -ParentPath $containRoot) 'child path is contained'
    Assert-True (-not (Test-WauBridgePathContained -CandidatePath $containRoot -ParentPath $containRoot)) 'equal path is not contained by default'
    Assert-True (Test-WauBridgePathContained -CandidatePath $containRoot -ParentPath $containRoot -AllowEqual) 'AllowEqual admits the parent itself'
    Assert-True (-not (Test-WauBridgePathContained -CandidatePath (Join-Path $containRoot 'sibling') -ParentPath (Join-Path $containRoot 'child'))) 'sibling path is not contained'

    $atomicRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('waubridge-atomic-' + [guid]::NewGuid().ToString('N'))
    $atomicPath = Join-Path $atomicRoot 'state.json'
    Write-WauBridgeAtomicTextFile -LiteralPath $atomicPath -Content 'first'
    Assert-True ((Get-Content -LiteralPath $atomicPath -Raw).Trim() -eq 'first') 'atomic write creates the file'
    Write-WauBridgeAtomicTextFile -LiteralPath $atomicPath -Content 'second'
    Assert-True ((Get-Content -LiteralPath $atomicPath -Raw).Trim() -eq 'second') 'atomic write replaces an existing file'
    Assert-True (@(Get-ChildItem -LiteralPath $atomicRoot -Force).Count -eq 1) 'atomic write leaves no temporary file behind'
    Remove-Item -LiteralPath $atomicRoot -Recurse -Force

    $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'waubridge-contract/Stage/Google.Chrome/140.0.7339.127'
    $context = [pscustomobject]@{
        Runtime  = [pscustomobject]@{
            StageRoot       = $stageRoot
            OwnerMarkerPath = Join-Path $stageRoot '.waubridge-owner.json'
        }
        Schedule = [pscustomobject]@{
            CampaignId                 = 'Google.Chrome_140.0.7339.127'
            Operation                  = 'Upgrade'
            TaskPath                   = '\WauPsadtBridge\'
            TaskName                   = 'Update_Google.Chrome_140.0.7339.127'
            CleanupTaskName            = 'Cleanup_Google.Chrome_140.0.7339.127'
            DesktopShortcutPath        = Join-Path $stageRoot 'Update Google Chrome.lnk'
            DesktopShortcutName        = 'Update Google Chrome.lnk'
            DesktopShortcutDescription = 'Update Google Chrome now'
            DesktopShortcutIconPath    = Join-Path $stageRoot 'Assets/AppIcon.ico'
            DesktopShortcutTargetPath  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
            DesktopShortcutWorkingDirectory = 'C:\Windows\System32\WindowsPowerShell\v1.0'
            DesktopShortcutWindowStyle = 7
            CleanupScriptPath          = Join-Path $stageRoot 'Cleanup-WauBridgePackage.ps1'
            StateFilePath              = Join-Path $stageRoot 'ScheduleState.json'
        }
    }

    $startArguments = Get-WauBridgeManualTaskStartArguments -TaskPath '\WauPsadtBridge\' -TaskName 'Update_X_1.0'
    Assert-True ($startArguments -match 'Start-ScheduledTask -TaskPath') 'shortcut arguments start the owned retry task'
    Assert-True ($startArguments -match "'\\WauPsadtBridge\\'") 'shortcut arguments quote the task path'

    $expectedShortcut = Get-WauBridgeDesktopShortcutContract -Context $context
    $matchingShortcut = [pscustomobject]@{
        ShortcutPath     = $expectedShortcut.ShortcutPath
        ShortcutName     = $expectedShortcut.ShortcutName
        TargetPath       = $expectedShortcut.TargetPath
        Arguments        = $expectedShortcut.Arguments
        WorkingDirectory = $expectedShortcut.WorkingDirectory
        Description      = $expectedShortcut.Description
        IconLocation     = $expectedShortcut.IconLocation
        WindowStyle      = $expectedShortcut.WindowStyle
    }
    Assert-True (Test-WauBridgeDesktopShortcutContract -Expected $expectedShortcut -Actual $matchingShortcut) 'an owned shortcut matches the contract'
    $foreignShortcut = $matchingShortcut.PSObject.Copy()
    $foreignShortcut.Description = 'Something else'
    Assert-True (-not (Test-WauBridgeDesktopShortcutContract -Expected $expectedShortcut -Actual $foreignShortcut)) 'a shortcut with a foreign description is rejected'

    $updateContract = Get-WauBridgeUpdateTaskContract -Context $context
    Assert-True ((Get-WauBridgeUpdateTaskDescription -Context $context) -eq 'WauBridgeCampaign:Google.Chrome_140.0.7339.127:Update') 'retry task description carries the campaign identity'
    $ownedTask = [pscustomobject]@{
        Description = $updateContract.Description
        Actions     = @([pscustomobject]@{ Execute = $updateContract.Execute; Arguments = $updateContract.Arguments })
        Principal   = [pscustomobject]@{ UserId = 'SYSTEM'; RunLevel = 'Highest'; LogonType = 'ServiceAccount' }
        Settings    = [pscustomobject]@{ StartWhenAvailable = $true }
        Triggers    = @([pscustomobject]@{ StartBoundary = (Get-Date) })
    }
    Assert-True (Test-WauBridgeUpdateTaskOwned -Context $context -Task $ownedTask -RequireTriggers) 'an owned retry task matches the contract'
    $foreignTask = $ownedTask.PSObject.Copy()
    $foreignTask.Description = 'Foreign task'
    Assert-True (-not (Test-WauBridgeUpdateTaskOwned -Context $context -Task $foreignTask)) 'a retry task with a foreign description is rejected'
    $wrongPrincipal = $ownedTask.PSObject.Copy()
    $wrongPrincipal.Principal = [pscustomobject]@{ UserId = 'SYSTEM'; RunLevel = 'Limited'; LogonType = 'ServiceAccount' }
    Assert-True (-not (Test-WauBridgeUpdateTaskOwned -Context $context -Task $wrongPrincipal)) 'a retry task without the highest run level is rejected'

    $cleanupContract = Get-WauBridgeCleanupTaskContract -Context $context
    Assert-True ((Get-WauBridgeCleanupTaskDescription -Context $context) -eq 'WauBridgeCampaign:Google.Chrome_140.0.7339.127:Cleanup') 'cleanup task description carries the campaign identity'
    $ownedCleanupTask = [pscustomobject]@{
        Description = $cleanupContract.Description
        Actions     = @([pscustomobject]@{ Execute = $cleanupContract.Execute; Arguments = $cleanupContract.Arguments })
        Principal   = [pscustomobject]@{ UserId = 'SYSTEM'; RunLevel = 'Highest'; LogonType = 'ServiceAccount' }
        Settings    = [pscustomobject]@{ StartWhenAvailable = $false }
        Triggers    = @([pscustomobject]@{ StartBoundary = (Get-Date) })
    }
    Assert-True (Test-WauBridgeCleanupTaskOwned -Context $context -Task $ownedCleanupTask) 'an owned cleanup task matches the contract'
    $foreignCleanupTask = $ownedCleanupTask.PSObject.Copy()
    $foreignCleanupTask.Actions = @([pscustomobject]@{ Execute = $cleanupContract.Execute; Arguments = '-NoProfile' })
    Assert-True (-not (Test-WauBridgeCleanupTaskOwned -Context $context -Task $foreignCleanupTask)) 'a cleanup task with foreign arguments is rejected'

    $triggerDate = (Get-Date).AddHours(1)
    $scheduleState = [pscustomobject]@{ TriggerDates = @($triggerDate) }
    $matchingTriggerTask = [pscustomobject]@{ Triggers = @([pscustomobject]@{ StartBoundary = $triggerDate }) }
    Assert-True (Test-WauBridgeUpdateTaskSchedule -Task $matchingTriggerTask -ScheduleState $scheduleState) 'a retry task with matching triggers is accepted'
    $divergentTriggerTask = [pscustomobject]@{ Triggers = @([pscustomobject]@{ StartBoundary = $triggerDate.AddMinutes(10) }) }
    Assert-True (-not (Test-WauBridgeUpdateTaskSchedule -Task $divergentTriggerTask -ScheduleState $scheduleState)) 'a retry task with divergent triggers is rejected'

    # Recording the prompt requires registry and Task Scheduler access on Windows, so the
    # persistence contract is exercised with recording stand-ins.
    $script:WauBridgeState = @{ ScheduleState = $null }
    $script:recordedPromptState = $null
    $script:recordedPromptCount = $null
    function Test-WauBridgeSchedulePresent { param($Context) return $true }
    function Get-WauBridgeCampaignState { param($Context) return [pscustomobject]@{ PromptShownCount = 4 } }
    function Set-WauBridgeCampaignState {
        param($Context, $State, $ScheduleState, $PromptShownCount)
        $script:recordedPromptState = $State
        $script:recordedPromptCount = $PromptShownCount
    }
    Add-WauBridgePromptShown -Context $context
    Assert-True ($script:recordedPromptState -eq 'Deferred') 'showing the prompt records the campaign as Deferred'
    Assert-True ($script:recordedPromptCount -eq 5) 'showing the prompt increments the prompt count'

    # Task Scheduler wiring cannot execute off Windows. These guards keep the fail-closed
    # settings and collision messages visible across the framework set; the live behavior
    # is validated on a Windows target.
    Assert-True ($frameworkText -match 'New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew') 'retry task runs once and starts when available'
    Assert-True ($frameworkText -match 'An existing task collides with the retry task name and is not owned by this campaign') 'a foreign retry task is not overwritten'
    Assert-True ($frameworkText -match 'An existing task collides with the cleanup task name and is not owned by this campaign') 'a foreign cleanup task is not overwritten'
    Assert-True ($frameworkText -match 'function Grant-WauBridgeUpdateTaskRunAccess') 'the retry task grants Authenticated Users run access'

    # A task that is already gone is a normal cleanup outcome. It has to be recognised from the
    # error identity, because the ScheduledTasks cmdlets localize their message text.
    function New-TestTaskErrorRecord {
        param([Parameter(Mandatory)][System.Management.Automation.ErrorCategory]$Category)
        $exception = [System.Exception]::new('classification test')
        return [System.Management.Automation.ErrorRecord]::new($exception, 'TestError', $Category, $null)
    }
    Assert-True (Test-WauBridgeTaskMissingError -ErrorRecord (New-TestTaskErrorRecord -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound))) 'an object-not-found error means the task is gone'
    Assert-True (-not (Test-WauBridgeTaskMissingError -ErrorRecord (New-TestTaskErrorRecord -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied)))) 'a permission failure is not a missing task'
    Assert-True (-not (Test-WauBridgeTaskMissingError -ErrorRecord (New-TestTaskErrorRecord -Category ([System.Management.Automation.ErrorCategory]::NotSpecified)))) 'an unspecified failure is not a missing task'
    $missingCommand = [System.Management.Automation.CommandNotFoundException]::new('Get-ScheduledTask')
    $missingCommandRecord = [System.Management.Automation.ErrorRecord]::new($missingCommand, 'CommandNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
    Assert-True (-not (Test-WauBridgeTaskMissingError -ErrorRecord $missingCommandRecord)) 'a missing command is not a missing task'

    # The cleanup path must stay quiet for a task that is already gone and stay visible for a real
    # failure. The logger is replaced so the decision itself is observed.
    $script:recordedCleanupLog = @()
    function Write-WauBridgeLog {
        param([Parameter(Mandatory)][string]$Message, [ValidateSet(1, 2, 3)][int]$Severity = 1)
        $script:recordedCleanupLog += $Message
    }
    Write-WauBridgeTaskCleanupFailure -TaskName 'Update_Probe_1.0' -ErrorRecord (New-TestTaskErrorRecord -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound))
    Assert-True ($script:recordedCleanupLog.Count -eq 0) 'a task that is already gone produces no cleanup warning'
    Write-WauBridgeTaskCleanupFailure -TaskName 'Update_Probe_1.0' -ErrorRecord (New-TestTaskErrorRecord -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied))
    Assert-True ($script:recordedCleanupLog.Count -eq 1) 'a real cleanup failure is reported once'
    Assert-True ($script:recordedCleanupLog[0] -match 'Update_Probe_1\.0') 'the cleanup warning names the task'

    Assert-True ($frameworkText -notmatch 'FreshInstall') 'no FreshInstall mapping'
    Assert-True ($frameworkText -notmatch 'Get-WauBridgeEffectiveTaskPath') 'no config TaskPath override'
    Assert-True ($frameworkText -notmatch 'function Get-WauBridgeActiveCampaignsForPackageId') 'unused active-campaign reader removed'
    Assert-True ($frameworkText -notmatch 'function Test-WauBridgeActiveCampaignForPackageId') 'no unused active-campaign wrapper'
}
finally {
    $env:ProgramFiles = $previousProgramFiles
    $env:ProgramW6432 = $previousProgramW6432
    $env:WINDIR = $previousWinDir
}

Write-Output 'FrameworkContracts.Tests: OK'
