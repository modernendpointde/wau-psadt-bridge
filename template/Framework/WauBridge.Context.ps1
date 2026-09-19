# Runtime context: identity, native paths, computed resource paths, and process helpers.

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
