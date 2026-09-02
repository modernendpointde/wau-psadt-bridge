# Ordered loader for WauBridge framework parts.
$wauBridgeFrameworkRoot = $PSScriptRoot

foreach ($wauBridgeFrameworkPart in @(
    'WauBridge.Compatibility.ps1',
    'WauBridge.Core.ps1',
    'WauBridge.Validation.ps1',
    'WauBridge.Localization.ps1',
    'WauBridge.Deferral.ps1',
    'WauBridge.Detection.ps1',
    'WauBridge.Actions.ps1',
    'WauBridge.CampaignJson.ps1'
)) {
    $wauBridgeFrameworkPartPath = Join-Path $wauBridgeFrameworkRoot $wauBridgeFrameworkPart
    if (-not (Test-Path -LiteralPath $wauBridgeFrameworkPartPath -PathType Leaf)) {
        throw "WauBridge framework component is missing: [$wauBridgeFrameworkPartPath]."
    }
    . $wauBridgeFrameworkPartPath
}

Remove-Variable -Name wauBridgeFrameworkPart,wauBridgeFrameworkPartPath,wauBridgeFrameworkRoot -ErrorAction SilentlyContinue
