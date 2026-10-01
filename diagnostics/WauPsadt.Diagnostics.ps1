# Read-only diagnostics: loads the canonical rule sources and the diagnostic components.
#
# The WAU-side and template files stay the single source of the catalog rules, the campaign
# ownership rules, and the Winget lookup, so the diagnostics load them instead of restating them.
# Inspection never repairs a resource, starts an update, or registers a task.

$wauPsadtDiagnosticsRoot = $PSScriptRoot
$wauPsadtRepositoryRoot = Split-Path -Parent $wauPsadtDiagnosticsRoot

    foreach ($wauPsadtRuleSource in @(
        (Join-Path (Join-Path $wauPsadtRepositoryRoot 'wau') 'WauPsadt.BridgeContract.ps1'),
        (Join-Path (Join-Path $wauPsadtRepositoryRoot 'wau') 'Submit-WauPsadtUpdate.ps1'),
        (Join-Path (Join-Path $wauPsadtRepositoryRoot 'wau') 'WauPsadt.CampaignContract.ps1'),
        (Join-Path (Join-Path (Join-Path $wauPsadtRepositoryRoot 'template') 'Framework') 'WauBridge.Foundation.ps1'),
        (Join-Path (Join-Path (Join-Path $wauPsadtRepositoryRoot 'template') 'Framework') 'WauBridge.Winget.ps1')
    )) {
    if (-not (Test-Path -LiteralPath $wauPsadtRuleSource -PathType Leaf)) {
        throw "Diagnostics rule source was not found: [$wauPsadtRuleSource]."
    }
    . $wauPsadtRuleSource
}

foreach ($wauPsadtComponentFile in @('WauPsadt.Catalog.ps1', 'WauPsadt.Status.ps1', 'WauPsadt.Health.ps1')) {
    $wauPsadtComponentPath = Join-Path $wauPsadtDiagnosticsRoot $wauPsadtComponentFile
    if (-not (Test-Path -LiteralPath $wauPsadtComponentPath -PathType Leaf)) {
        throw "Diagnostics component was not found: [$wauPsadtComponentPath]."
    }
    . $wauPsadtComponentPath
}

Remove-Variable -Name wauPsadtRuleSource, wauPsadtComponentFile, wauPsadtComponentPath, wauPsadtRepositoryRoot -ErrorAction SilentlyContinue
