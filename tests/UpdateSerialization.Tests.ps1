$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot

$script:WauPsadtTestLog = @()
. (Join-Path $repoRoot 'wau/Submit-WauPsadtUpdate.ps1')

$held = Enter-WauPsadtBridgeMutex
Assert-True ($null -ne $held) 'mutex acquire succeeds'
Exit-WauPsadtBridgeMutex -Mutex $held
$again = Enter-WauPsadtBridgeMutex
Assert-True ($null -ne $again) 'mutex can be acquired after release'
Exit-WauPsadtBridgeMutex -Mutex $again

$updateApp = Get-Content -LiteralPath (Join-Path $repoRoot 'wau/Update-App.ps1') -Raw
$submitAt = $updateApp.IndexOf('Submit-WauPsadtUpdate')
$enterAt = $updateApp.IndexOf('Enter-WauPsadtBridgeMutex')
$toastAt = $updateApp.IndexOf('Start-NotifTask')
$wingetAt = $updateApp.IndexOf('WINGET UPGRADE')
Assert-True ($submitAt -ge 0 -and $enterAt -gt $submitAt) 'direct path mutex is after handoff'
Assert-True ($enterAt -lt $toastAt -and $enterAt -lt $wingetAt) 'direct path mutex is before toast and winget'
Assert-True ($updateApp -match 'finally\s*\{\s*Exit-WauPsadtBridgeMutex -Mutex \$wauMutex') 'direct path releases mutex in finally'

$submit = Get-Content -LiteralPath (Join-Path $repoRoot 'wau/Submit-WauPsadtUpdate.ps1') -Raw
Assert-True ($submit -match "Global\\WauPsadtBridge\.Update") 'WAU submit uses the shared mutex name'
$campaign = Get-Content -LiteralPath (Join-Path $repoRoot 'template/Framework/WauBridge.CampaignJson.ps1') -Raw
Assert-True ($campaign -match "Global\\WauPsadtBridge\.Update") 'template uses the shared mutex name'

Write-Output 'UpdateSerialization.Tests: OK'
