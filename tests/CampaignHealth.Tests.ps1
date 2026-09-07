$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
. (Join-Path $repoRoot 'wau/Submit-WauPsadtUpdate.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-health-' + [guid]::NewGuid().ToString('N'))
$registry = [pscustomobject]@{
    SchemaVersion              = 2
    ResourceType               = 'WauBridgeCampaign'
    CampaignId                 = ''
    PackageId                  = 'Google.Chrome'
    TargetVersion              = '140.0.7339.127'
    State                      = 'Deferred'
    TaskPath                   = ''
    TaskName                   = ''
    Operation                  = 'Upgrade'
    DesktopShortcutName        = 'Update Google Chrome.lnk'
    DesktopShortcutPath        = Join-Path $testRoot 'Update Google Chrome.lnk'
    DesktopShortcutIconPath    = ''
}
$contract = Get-WauPsadtCampaignContract -Registry $registry -InstallRoot $testRoot -PublicDesktopRoot $testRoot
$registry.CampaignId = $contract.CampaignId
$registry.TaskPath = $contract.TaskPath
$registry.TaskName = $contract.TaskName
$registry.DesktopShortcutIconPath = Join-Path $contract.StageRoot 'Assets/AppIcon.ico'
$contract = Get-WauPsadtCampaignContract -Registry $registry -InstallRoot $testRoot -PublicDesktopRoot $testRoot

$deadline = (Get-Date).AddDays(1).ToUniversalTime().ToString('o')
$state = [pscustomobject]@{
    SchemaVersion               = 3
    ResourceType                = 'WauBridgeScheduleState'
    TriggerDates                = @($deadline)
    FinalDeadline               = $deadline
    Operation                   = 'Upgrade'
    DesktopShortcutName         = $registry.DesktopShortcutName
    DesktopShortcutPath         = $registry.DesktopShortcutPath
    DesktopShortcutDescription  = 'Update Google Chrome now'
    DesktopShortcutIconPath      = $registry.DesktopShortcutIconPath
    PackageId                   = $registry.PackageId
    CampaignId                  = $registry.CampaignId
    TargetVersion               = $registry.TargetVersion
    TaskPath                    = $registry.TaskPath
    TaskName                    = $registry.TaskName
}
$task = [pscustomobject]@{
    Description = $contract.TaskDescription
    Actions     = @([pscustomobject]@{ Execute = $contract.PowerShellPath; Arguments = $contract.TaskArguments })
    Principal   = [pscustomobject]@{ UserId = 'SYSTEM'; RunLevel = 'Highest'; LogonType = 'ServiceAccount' }
    Settings    = [pscustomobject]@{ StartWhenAvailable = $true }
    Triggers    = @([pscustomobject]@{ StartBoundary = $deadline })
}

Assert-True (Test-WauPsadtRegistryCampaignContract -Registry $registry -Contract $contract) 'owned registry contract'
Assert-True (Test-WauPsadtStageMarkerContract -Marker ([pscustomobject]@{
            SchemaVersion = 1
            ResourceType = 'WauBridgeStageRoot'
            CampaignId = $contract.CampaignId
            PackageId = $contract.PackageId
            TargetVersion = $contract.TargetVersion
            StageRoot = $contract.StageRoot
        }) -Contract $contract) 'owned StageRoot marker contract'
Assert-True (Test-WauPsadtScheduleStateContract -State $state -Registry $registry -Contract $contract) 'owned schedule state contract'
Assert-True (Test-WauPsadtScheduledTaskContract -Task $task -Contract $contract -RequireTriggers) 'owned retry task contract'

function New-TestSnapshot {
    param(
        [bool]$RegistryOwned = $true,
        [bool]$StageExists = $true,
        [bool]$StageOwned = $true,
        [bool]$StateExists = $true,
        [bool]$StateOwned = $true,
        [bool]$TaskExists = $true,
        [bool]$TaskOwned = $true,
        [bool]$TaskHealthy = $true,
        [bool]$CleanupTaskExists = $false,
        [bool]$CleanupTaskOwned = $false,
        [bool]$ShortcutExists = $false,
        [bool]$ShortcutOwned = $false
    )
    return [pscustomobject]@{
        RegistryOwned = $RegistryOwned
        StageExists = $StageExists
        StageOwned = $StageOwned
        StateExists = $StateExists
        StateOwned = $StateOwned
        TaskExists = $TaskExists
        TaskOwned = $TaskOwned
        TaskHealthy = $TaskHealthy
        CleanupTaskExists = $CleanupTaskExists
        CleanupTaskOwned = $CleanupTaskOwned
        ShortcutExists = $ShortcutExists
        ShortcutOwned = $ShortcutOwned
    }
}

Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot)).Status -eq 'Healthy') 'healthy campaign remains active'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -StageExists $false -StageOwned $false -StateExists $false -StateOwned $false -TaskExists $false -TaskOwned $false -TaskHealthy $false)).Status -eq 'RecoverableOrphan') 'registry-only orphan is recoverable'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -TaskExists $false -TaskOwned $false -TaskHealthy $false)).Status -eq 'RecoverableOrphan') 'missing retry task is recoverable'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -StageExists $false -StageOwned $false -StateExists $false -StateOwned $false)).Status -eq 'RecoverableOrphan') 'missing StageRoot is recoverable when remaining resources are owned'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -StageOwned $false)).Status -eq 'BlockedForeign') 'StageRoot without owner marker is blocked'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -StateOwned $false)).Status -eq 'RecoverableOrphan') 'corrupt schedule state is recoverable without an unproven shortcut'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -TaskOwned $false -TaskHealthy $false)).Status -eq 'BlockedForeign') 'foreign retry task collision is blocked'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -ShortcutExists $true -ShortcutOwned $false)).Status -eq 'BlockedForeign') 'foreign shortcut collision is blocked'
Assert-True ((Get-WauPsadtCampaignHealth -Snapshot (New-TestSnapshot -RegistryOwned $false)).Status -eq 'BlockedForeign') 'foreign registry contract is blocked'

Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'CampaignHealth.Tests: OK'
