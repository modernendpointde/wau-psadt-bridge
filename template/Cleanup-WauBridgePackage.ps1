$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'App\WauBridge.Config.ps1')
. (Join-Path $PSScriptRoot 'App\WauBridge.Detect.ps1')
. (Join-Path $PSScriptRoot 'Framework\WauBridge.ps1')
$null = Import-WauBridgeCampaignJson -ScriptRoot $PSScriptRoot
$context = Get-WauBridgeContext -WauBridgeConfig $WauBridgeConfig -ScriptRoot $PSScriptRoot
Start-Sleep -Seconds 5
Remove-WauBridgeSchedule -Context $context -RemoveStageRoot
