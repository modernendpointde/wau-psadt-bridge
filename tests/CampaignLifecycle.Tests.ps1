$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$templateRoot = Join-Path $repoRoot 'template'

. (Join-Path $templateRoot 'App/WauBridge.Detect.ps1')
. (Join-Path $templateRoot 'App/WauBridge.Config.ps1')
. (Join-Path $templateRoot 'Framework/WauBridge.ps1')

$invokeText = Get-Content -LiteralPath (Join-Path $templateRoot 'Invoke-AppDeployToolkit.ps1') -Raw
Assert-True ($invokeText -match "(?s)'InstalledSameVersion'.*?Complete-WauBridgeSchedule") 'same-version completes owned schedule'
Assert-True ($invokeText -match "(?s)'InstalledNewerVersion'.*?Complete-WauBridgeSchedule") 'newer-version completes owned schedule'
Assert-True ($invokeText -match "(?s)'InstalledSameVersion'.*?Test-WauBridgeSchedulePresent") 'same-version requires owned schedule'
Assert-True ($invokeText -notmatch 'Show-ADTInstallationWelcome[\s\S]{0,200}InstalledSameVersion') 'no welcome before same-version return'

$compatText = Get-Content -LiteralPath (Join-Path $templateRoot 'Framework/WauBridge.Compatibility.ps1') -Raw
Assert-True ($compatText -match 'New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew') 'retry task IgnoreNew'
Assert-True ($compatText -match 'An existing task collides with the retry task name and is not owned by this campaign') 'foreign retry task is not overwritten'
Assert-True ($compatText -match 'An existing task collides with the cleanup task name and is not owned by this campaign') 'foreign cleanup task is not overwritten'
Assert-True ($compatText -match 'function Get-WauBridgeTaskPath') 'task path is a fixed product folder'
Assert-True ($compatText -match 'function Get-WauBridgeNativeProgramFiles') 'stage root uses native Program Files'
Assert-True ($compatText -match 'ProgramW6432') 'stage root prefers ProgramW6432 on 64-bit Windows'
Assert-True ($compatText -match 'Update_\{0\}_\{1\}') 'retry task name is Update_id_version'
Assert-True ($compatText -match 'Cleanup_\{0\}_\{1\}') 'cleanup task name is Cleanup_id_version'
Assert-True ($compatText -match 'function Grant-WauBridgeUpdateTaskRunAccess') 'retry task grants Authenticated Users run access'
Assert-True ($compatText -notmatch 'FreshInstall') 'no FreshInstall mapping'
Assert-True ($compatText -match 'function Get-WauBridgeManualTaskStartArguments') 'shortcut starts the owned retry task'
Assert-True ($compatText -notmatch 'Get-WauBridgeEffectiveTaskPath') 'no config TaskPath override'

Assert-True ($compatText -notmatch 'function Get-WauBridgeActiveCampaignsForPackageId') 'unused active-campaign reader removed'
Assert-True ($compatText -notmatch 'function Test-WauBridgeActiveCampaignForPackageId') 'no unused active-campaign wrapper'
Assert-True ($compatText -match "(?s)function Add-WauBridgePromptShown[\s\S]*?-State 'Deferred'") 'prompt shown sets Deferred'

$stageTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-stage-cleanup-' + [guid]::NewGuid().ToString('N'))
$stageBase = Join-Path $stageTestRoot 'Stage'
$ownedStage = Join-Path $stageBase 'Google.Chrome/140.0'
New-Item -ItemType Directory -Path $ownedStage -Force | Out-Null
Remove-Item -LiteralPath $ownedStage -Force
Remove-WauBridgeEmptyStageParents -Context ([pscustomobject]@{ Runtime = [pscustomobject]@{ StageRoot = $ownedStage } }) -StageBasePath $stageBase
Assert-True (-not (Test-Path -LiteralPath (Split-Path -Path $ownedStage -Parent))) 'empty package Stage parent removed'
Assert-True (-not (Test-Path -LiteralPath $stageBase)) 'empty Stage root removed'

$nonEmptyStage = Join-Path $stageBase 'Google.Chrome/141.0'
New-Item -ItemType Directory -Path $nonEmptyStage -Force | Out-Null
Remove-Item -LiteralPath $nonEmptyStage -Force
Set-Content -LiteralPath (Join-Path (Split-Path -Path $nonEmptyStage -Parent) 'keep.txt') -Value 'keep' -Encoding UTF8
Remove-WauBridgeEmptyStageParents -Context ([pscustomobject]@{ Runtime = [pscustomobject]@{ StageRoot = $nonEmptyStage } }) -StageBasePath $stageBase
Assert-True (Test-Path -LiteralPath (Join-Path (Split-Path -Path $nonEmptyStage -Parent) 'keep.txt') -PathType Leaf) 'non-empty package Stage parent preserved'

$outsideStage = Join-Path $stageTestRoot 'Outside/Google.Chrome/142.0'
New-Item -ItemType Directory -Path (Split-Path -Path $outsideStage -Parent) -Force | Out-Null
Remove-WauBridgeEmptyStageParents -Context ([pscustomobject]@{ Runtime = [pscustomobject]@{ StageRoot = $outsideStage } }) -StageBasePath $stageBase
Assert-True (Test-Path -LiteralPath (Split-Path -Path $outsideStage -Parent) -PathType Container) 'path outside Stage root is preserved'
Remove-Item -LiteralPath $stageTestRoot -Recurse -Force

$detectionText = Get-Content -LiteralPath (Join-Path $templateRoot 'Framework/WauBridge.Detection.ps1') -Raw
Assert-True ($detectionText -match '\$espKnown -and \$oobeKnown') 'provisioning uses PSADT result when both adapters succeed'

Write-Output 'CampaignLifecycle.Tests: OK'
