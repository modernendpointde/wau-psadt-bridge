# Task Scheduler contracts: retry task, cleanup task, ownership, and completion.

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
