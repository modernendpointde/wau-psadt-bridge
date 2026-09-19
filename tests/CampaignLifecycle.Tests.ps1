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
