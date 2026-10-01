$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$diagnosticsRoot = Join-Path $repoRoot 'diagnostics'

. (Join-Path $diagnosticsRoot 'WauPsadt.Diagnostics.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-health-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

function New-TestFile {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content = '')
    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

foreach ($commandName in @('Get-WauPsadtHealthReport', 'Get-WauPsadtInstallState', 'Get-WauPsadtTemplateEntryPointCheck', 'Get-WauPsadtWauLayoutCheck', 'Get-NormalizedSha256', 'Test-WauOriginalUpdateAppBackup', 'Test-WauUpdateAppContainsHandoff', 'Get-InstalledWauLocation')) {
    Assert-True ($null -ne (Get-Command $commandName -ErrorAction SilentlyContinue)) "loader exposes $commandName"
}

# The supported contract has a single source, shared with the installer
Assert-True ($script:SupportedWauVersion -eq '2.12.0') 'the shared contract states the supported WAU version'
Assert-True ([string]$script:SupportedWauUpdateAppSha256 -match '^[0-9a-f]{64}$') 'the shared contract states a normalized SHA-256'
Assert-True ($script:UpdateAppBackupName -eq 'Update-App.ps1.pre-bridge') 'the shared contract states the backup name'
Assert-True ((Get-WauPsadtSupportedBaseline -RepositoryRoot $repoRoot).WauBaseline -eq $script:SupportedWauVersion) 'the supported baseline comes from the contract'
$installerText = Get-Content -LiteralPath (Join-Path $repoRoot 'Install-WauPsadtBridge.ps1') -Raw
Assert-True ($installerText -notmatch "SupportedWauUpdateAppSha256 = '") 'the installer does not restate the supported hash'

# Installation state
$installRoot = Join-Path $work 'Bridge'
$missingState = Get-WauPsadtInstallState -InstallRoot $installRoot
Assert-True (-not $missingState.Present) 'a missing installation state is reported as absent'
Assert-True (-not $missingState.Readable) 'a missing installation state is not readable'
$statePath = Join-Path $installRoot 'install-state.json'
New-TestFile -Path $statePath -Content '{ not json'
$brokenState = Get-WauPsadtInstallState -InstallRoot $installRoot
Assert-True ($brokenState.Present -and -not $brokenState.Readable) 'a broken installation state is reported as unreadable'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$brokenState.Error)) 'a broken installation state carries a reason'
New-TestFile -Path $statePath -Content '{"schemaVersion":1,"catalogPath":"recorded.json","wauInstallLocation":"recorded-wau"}'
$goodState = Get-WauPsadtInstallState -InstallRoot $installRoot
Assert-True ($goodState.Readable) 'a valid installation state is readable'
Assert-True ($goodState.Values.catalogPath -eq 'recorded.json') 'the installation state values are exposed'
Remove-Item -LiteralPath $statePath -Force

# Template entry points
$repositoryTemplate = Get-WauPsadtTemplateEntryPointCheck -TemplateRoot (Join-Path $repoRoot 'template')
Assert-True ($repositoryTemplate.RootPresent) 'the repository template is present'
Assert-True ($repositoryTemplate.Missing.Count -eq 0) 'every required entry point exists in the repository template'
$installedTemplate = Join-Path $installRoot 'Template'
New-Item -ItemType Directory -Path $installedTemplate -Force | Out-Null
$emptyCheck = Get-WauPsadtTemplateEntryPointCheck -TemplateRoot $installedTemplate
Assert-True ($emptyCheck.Missing.Count -eq $emptyCheck.Required.Count) 'an empty template reports every entry point as missing'
foreach ($relative in @(@('install.ps1'), @('Invoke-AppDeployToolkit.ps1'), @('Cleanup-WauBridgePackage.ps1'), @('Config', 'config.psd1'), @('Messages', 'message-contract.json'), @('Framework', 'WauBridge.ps1'))) {
    $path = $installedTemplate
    foreach ($segment in $relative) { $path = Join-Path $path $segment }
    New-TestFile -Path $path -Content '# test entry point'
}
$completeCheck = Get-WauPsadtTemplateEntryPointCheck -TemplateRoot $installedTemplate
Assert-True ($completeCheck.Missing.Count -eq 0) 'a complete template reports no missing entry point'
Copy-Item -LiteralPath (Join-Path $repoRoot 'catalog/apps.json') -Destination (Join-Path $installRoot 'bridge.catalog.json')

# WAU layout, handoff and backup
$wauRoot = Join-Path $work 'Wau'
$functionsRoot = Join-Path $wauRoot 'functions'
New-Item -ItemType Directory -Path $functionsRoot -Force | Out-Null
New-TestFile -Path (Join-Path $functionsRoot 'Update-App.ps1') -Content 'function Update-App { }'
$stockLayout = Get-WauPsadtWauLayoutCheck -WauRoot $wauRoot
Assert-True ($stockLayout.FunctionsPresent) 'the functions folder is observed'
Assert-True ($stockLayout.UpdateAppPresent) 'Update-App.ps1 is observed'
Assert-True (-not $stockLayout.HandoffPresent) 'a stock Update-App.ps1 has no handoff'
Assert-True (-not $stockLayout.BackupPresent) 'a missing backup is observed'

New-TestFile -Path (Join-Path $functionsRoot 'Update-App.ps1') -Content 'Submit-WauPsadtUpdate'
New-TestFile -Path (Join-Path $functionsRoot 'Submit-WauPsadtUpdate.ps1') -Content 'function Submit-WauPsadtUpdate { }'
New-TestFile -Path (Join-Path $functionsRoot 'WauPsadt.CampaignContract.ps1') -Content '# contract'
New-TestFile -Path (Join-Path $functionsRoot $script:UpdateAppBackupName) -Content 'function Update-App { }'
$handoffLayout = Get-WauPsadtWauLayoutCheck -WauRoot $wauRoot
Assert-True ($handoffLayout.HandoffPresent) 'the handoff marker is detected'
Assert-True ($handoffLayout.SubmitPresent -and $handoffLayout.ContractPresent) 'both bridge function files are observed'
Assert-True ($handoffLayout.BackupPresent) 'the backup is observed'
Assert-True ($handoffLayout.BackupIsOriginal -eq $false) 'a backup that is not the supported file is rejected'
Assert-True ([string]$handoffLayout.BackupHash -match '^[0-9a-f]{64}$') 'the observed backup hash is reported'

# Campaign classification: a definite problem fails, an unverified verdict stays unknown
function New-TestStatusReport {
    param([AllowEmptyCollection()][object[]]$Campaigns, [bool]$Available = $true)
    return [pscustomobject]@{ RegistryAvailable = $Available; CampaignCount = @($Campaigns).Count; Campaigns = @($Campaigns) }
}
$healthyCampaign = [pscustomobject]@{ HealthStatus = 'Healthy'; HealthVerified = $true }
$blockedCampaign = [pscustomobject]@{ HealthStatus = 'BlockedForeign'; HealthVerified = $true }
$orphanCampaign = [pscustomobject]@{ HealthStatus = 'RecoverableOrphan'; HealthVerified = $true }
$unverifiedCampaign = [pscustomobject]@{ HealthStatus = 'Healthy'; HealthVerified = $false }
$unclassifiedCampaign = [pscustomobject]@{ HealthStatus = $null; HealthVerified = $false }
$blockedUnverifiedCampaign = [pscustomobject]@{ HealthStatus = 'BlockedUnverified'; HealthVerified = $false }
$unverifiedOrphan = [pscustomobject]@{ HealthStatus = 'RecoverableOrphan'; HealthVerified = $false }
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($healthyCampaign))).Status -eq 'Pass') 'healthy campaigns pass'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($healthyCampaign, $blockedCampaign))).Status -eq 'Fail') 'a blocked campaign fails the check'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($orphanCampaign))).Status -eq 'Fail') 'a recoverable orphan fails the check'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($unverifiedCampaign))).Status -eq 'Unknown') 'an unverified campaign stays unknown'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($unclassifiedCampaign))).Status -eq 'Unknown') 'an unclassified campaign stays unknown'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($blockedUnverifiedCampaign))).Status -eq 'Unknown') 'an unreadable campaign task stays unknown'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($unverifiedOrphan))).Status -eq 'Unknown') 'an unverified orphan verdict stays unknown'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport (New-TestStatusReport -Campaigns @($healthyCampaign) -Available $false)).Status -eq 'Unknown') 'an unavailable registry stays unknown'
Assert-True ((Get-WauPsadtCampaignCheck -StatusReport $null).Status -eq 'Unknown') 'a missing report stays unknown'

# A known Winget-AutoUpdate location without the functions folder is a definite failure
$emptyWau = Join-Path $work 'EmptyWau'
New-Item -ItemType Directory -Path $emptyWau | Out-Null
$noFunctionsReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $installRoot -WauRoot $emptyWau
Assert-True ((@($noFunctionsReport.Checks | Where-Object { $_.Name -eq 'wau-handoff' })[0]).Status -eq 'Fail') 'a missing functions folder fails the handoff check'
Assert-True ((@($noFunctionsReport.Checks | Where-Object { $_.Name -eq 'wau-backup' })[0]).Status -eq 'Unknown') 'there is nothing to restore without a handoff'

# An expected file that exists but cannot be read is a failure, an absent component is unknown
$brokenStateRoot = Join-Path $work 'BrokenState'
New-TestFile -Path (Join-Path $brokenStateRoot 'install-state.json') -Content '{ not json'
$brokenStateReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $brokenStateRoot
Assert-True ((@($brokenStateReport.Checks | Where-Object { $_.Name -eq 'bridge-installation' })[0]).Status -eq 'Fail') 'an unreadable installation state fails the installation check'
Assert-True ((@($brokenStateReport.Checks | Where-Object { $_.Name -eq 'template-entry-points' })[0]).Status -eq 'Unknown') 'an absent template stays unknown'
Assert-True ($brokenStateReport.ExitCode -eq 1) 'an unreadable installation state exits 1'

# An expected file that is absent fails, an unreadable one stays unknown
$noCatalogRoot = Join-Path $work 'NoCatalog'
Copy-Item -LiteralPath $installRoot -Destination $noCatalogRoot -Recurse
Remove-Item -LiteralPath (Join-Path $noCatalogRoot 'bridge.catalog.json') -Force
$noCatalogReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $noCatalogRoot -WauRoot $wauRoot
Assert-True ((@($noCatalogReport.Checks | Where-Object { $_.Name -eq 'catalog' })[0]).Status -eq 'Fail') 'a missing installed catalog fails the catalog check'
Assert-True ($null -eq $noCatalogReport.Catalog) 'a missing catalog reports no validation result'

if (Get-Command -Name chmod -ErrorAction SilentlyContinue) {
    $lockedCatalogRoot = Join-Path $work 'LockedCatalog'
    Copy-Item -LiteralPath $installRoot -Destination $lockedCatalogRoot -Recurse
    & chmod 000 (Join-Path $lockedCatalogRoot 'bridge.catalog.json')
    $catalogReadBlocked = $false
    try { $null = Get-Content -LiteralPath (Join-Path $lockedCatalogRoot 'bridge.catalog.json') -Raw -ErrorAction Stop }
    catch { $catalogReadBlocked = $true }
    if ($catalogReadBlocked) {
        $lockedCatalogReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $lockedCatalogRoot
        Assert-True ((@($lockedCatalogReport.Checks | Where-Object { $_.Name -eq 'catalog' })[0]).Status -eq 'Unknown') 'an unreadable catalog stays unknown'
    }
    & chmod 644 (Join-Path $lockedCatalogRoot 'bridge.catalog.json')

    $lockedStateRoot = Join-Path $work 'LockedState'
    New-Item -ItemType Directory -Path $lockedStateRoot -Force | Out-Null
    New-TestFile -Path (Join-Path $lockedStateRoot 'install-state.json') -Content '{"schemaVersion":1}'
    & chmod 000 (Join-Path $lockedStateRoot 'install-state.json')
    $stateReadBlocked = $false
    try { $null = Get-Content -LiteralPath (Join-Path $lockedStateRoot 'install-state.json') -Raw -ErrorAction Stop }
    catch { $stateReadBlocked = $true }
    if ($stateReadBlocked) {
        $lockedStateReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $lockedStateRoot
        Assert-True ((@($lockedStateReport.Checks | Where-Object { $_.Name -eq 'bridge-installation' })[0]).Status -eq 'Unknown') 'an unreadable installation state stays unknown'
    }
    & chmod 644 (Join-Path $lockedStateRoot 'install-state.json')
}

# A read that fails leaves the verdict unknown instead of failing it
if (Get-Command -Name chmod -ErrorAction SilentlyContinue) {
    $lockedWau = Join-Path $work 'LockedWau'
    $lockedFunctions = Join-Path $lockedWau 'functions'
    New-Item -ItemType Directory -Path $lockedFunctions -Force | Out-Null
    New-TestFile -Path (Join-Path $lockedFunctions 'Submit-WauPsadtUpdate.ps1') -Content '# test'
    New-TestFile -Path (Join-Path $lockedFunctions 'WauPsadt.CampaignContract.ps1') -Content '# test'
    New-TestFile -Path (Join-Path $lockedFunctions 'Update-App.ps1') -Content 'Submit-WauPsadtUpdate'
    New-TestFile -Path (Join-Path $lockedFunctions $script:UpdateAppBackupName) -Content 'function Update-App { }'
    & chmod 000 (Join-Path $lockedFunctions 'Update-App.ps1')
    & chmod 000 (Join-Path $lockedFunctions $script:UpdateAppBackupName)
    $readBlocked = $false
    try { $null = Get-Content -LiteralPath (Join-Path $lockedFunctions 'Update-App.ps1') -Raw -ErrorAction Stop }
    catch { $readBlocked = $true }
    if ($readBlocked) {
        $lockedReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $installRoot -WauRoot $lockedWau
        Assert-True ((@($lockedReport.Checks | Where-Object { $_.Name -eq 'wau-handoff' })[0]).Status -eq 'Unknown') 'an unreadable handoff stays unknown'
        Assert-True ((@($lockedReport.Checks | Where-Object { $_.Name -eq 'wau-backup' })[0]).Status -eq 'Unknown') 'an unreadable backup stays unknown'
    }
    & chmod 644 (Join-Path $lockedFunctions 'Update-App.ps1')
    & chmod 644 (Join-Path $lockedFunctions $script:UpdateAppBackupName)
}

# The report separates what it verified from what it could not read
$cleanReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $installRoot
Assert-True ((@($cleanReport.Checks | Where-Object { $_.Name -eq 'bridge-installation' })[0]).Status -eq 'Pass') 'the installation check passes for an installed template'
Assert-True ((@($cleanReport.Checks | Where-Object { $_.Name -eq 'template-entry-points' })[0]).Status -eq 'Pass') 'the template check passes for a complete template'
Assert-True ((@($cleanReport.Checks | Where-Object { $_.Name -eq 'catalog' })[0]).Status -eq 'Pass') 'the catalog check reuses the standalone validator'
Assert-True ((@($cleanReport.Checks | Where-Object { $_.Name -eq 'wau-handoff' })[0]).Status -eq 'Unknown') 'an unknown Winget-AutoUpdate location is stated as unknown'
Assert-True ((@($cleanReport.Checks | Where-Object { $_.Name -eq 'wau-backup' })[0]).Status -eq 'Unknown') 'there is nothing to restore without a handoff'
Assert-True (@($cleanReport.Checks | Where-Object { $_.Status -notin @('Pass', 'Fail', 'Unknown') }).Count -eq 0) 'every check uses a known status'
Assert-True ($cleanReport.FailedCheckCount -eq 0) 'unknown checks do not count as failures'
Assert-True ($cleanReport.ExitCode -eq 0) 'a report without a failed check exits 0'
if ($env:OS -ne 'Windows_NT') {
    Assert-True ((@($cleanReport.Checks | Where-Object { $_.Name -eq 'winget' })[0]).Status -eq 'Unknown') 'a Winget lookup failure stays unknown off Windows'
}

$failedReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot $installRoot -WauRoot $wauRoot
Assert-True ((@($failedReport.Checks | Where-Object { $_.Name -eq 'wau-handoff' })[0]).Status -eq 'Pass') 'the handoff check passes for an installed handoff'
Assert-True ((@($failedReport.Checks | Where-Object { $_.Name -eq 'wau-backup' })[0]).Status -eq 'Fail') 'a mismatched backup fails the backup check'
Assert-True (@($failedReport.Checks | Where-Object { $_.Status -eq 'Fail' }).Count -eq $failedReport.FailedCheckCount) 'the failure count matches the checks'
Assert-True ($failedReport.ExitCode -eq 1) 'a failed check produces exit code 1'

$uninstalledReport = Get-WauPsadtHealthReport -RepositoryRoot $repoRoot -InstallRoot (Join-Path $work 'Absent')
Assert-True ((@($uninstalledReport.Checks | Where-Object { $_.Name -eq 'bridge-installation' })[0]).Status -eq 'Fail') 'a missing installation fails the installation check'
Assert-True ($uninstalledReport.ExitCode -eq 1) 'a missing installation exits 1'

# Command-line contract
$cli = Join-Path $diagnosticsRoot 'Test-WauPsadtBridgeHealth.ps1'
& $PSHOME/pwsh -NoProfile -File $cli -InstallRoot $installRoot *> $null
Assert-True ($LASTEXITCODE -eq 0) 'CLI exits 0 when no check fails'
& $PSHOME/pwsh -NoProfile -File $cli -InstallRoot $installRoot -WauRoot $wauRoot *> $null
Assert-True ($LASTEXITCODE -eq 1) 'CLI exits 1 when a check fails'

Remove-Item -LiteralPath $work -Recurse -Force
Write-Output 'HealthReport.Tests: OK'
