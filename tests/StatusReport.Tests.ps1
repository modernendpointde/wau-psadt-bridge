$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$diagnosticsRoot = Join-Path $repoRoot 'diagnostics'

. (Join-Path $diagnosticsRoot 'WauPsadt.Diagnostics.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-status-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$missingRegistry = Join-Path $work 'missing-registry'

# The loader exposes every component and the canonical rule sources
foreach ($commandName in @('Get-WauPsadtCatalogValidation', 'Get-WauPsadtCampaignStatusRecord', 'Get-WauPsadtStatusReport', 'Get-WauPsadtCampaignContract', 'Get-WauPsadtCampaignSnapshot', 'Get-WauPsadtCampaignHealth')) {
    Assert-True ($null -ne (Get-Command $commandName -ErrorAction SilentlyContinue)) "loader exposes $commandName"
}

# Supported baselines cannot drift from the sources they describe
$baseline = Get-WauPsadtSupportedBaseline -RepositoryRoot $repoRoot
$contractText = Get-Content -LiteralPath (Join-Path $repoRoot 'wau/WauPsadt.BridgeContract.ps1') -Raw
$contractSupported = [regex]::Match($contractText, "SupportedWauVersion = '([^']+)'").Groups[1].Value
Assert-True (-not [string]::IsNullOrWhiteSpace($contractSupported)) 'the shared bridge contract states a supported WAU version'
Assert-True ($baseline.WauBaseline -eq $contractSupported) 'WAU baseline matches the shared bridge contract'
$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path (Join-Path (Join-Path $repoRoot 'template') 'PSAppDeployToolkit') 'PSAppDeployToolkit.psd1')
Assert-True (-not [string]::IsNullOrWhiteSpace($baseline.PsadtBaseline)) 'PSADT baseline is reported'
Assert-True ($baseline.PsadtBaseline -eq [string]$manifest.ModuleVersion) 'PSADT baseline matches the vendored manifest'

$repoTemplateVersion = Get-WauPsadtTemplateVersion -TemplateRoot (Join-Path $repoRoot 'template')
Assert-True ($null -ne $repoTemplateVersion) 'the repository template version is read'
Assert-True ($repoTemplateVersion -is [version]) 'the template version is a version value'
Assert-True ($null -eq (Get-WauPsadtTemplateVersion -TemplateRoot $missingRegistry)) 'a missing template reports an unknown version'

# Unavailable values become unknown, never an invented value
Assert-True ($null -eq (Get-WauPsadtOptionalText -Value '')) 'empty text is unknown'
Assert-True ($null -eq (Get-WauPsadtOptionalText -Value $null)) 'missing text is unknown'
Assert-True ((Get-WauPsadtOptionalText -Value 'Deferred') -eq 'Deferred') 'a real text value is kept'
Assert-True ($null -eq (Get-WauPsadtOptionalDate -Value 'not a date')) 'an unparseable date is unknown'
Assert-True ((Get-WauPsadtOptionalDate -Value '2026-09-19T19:00:00Z').Year -eq 2026) 'a parseable date is kept'
Assert-True ($null -eq (Get-WauPsadtObservedRunTime -Value ([datetime]'1899-12-30'))) 'the never-run sentinel is unknown'
Assert-True ((Get-WauPsadtObservedRunTime -Value ([datetime]'2026-09-19T19:00:00Z')).Year -eq 2026) 'a real run time is kept'
Assert-True ((Format-WauPsadtStatusValue -Value $null) -eq 'unknown') 'unknown renders as unknown'
Assert-True ((Format-WauPsadtStatusValue -Value $false) -eq 'no') 'false renders as no'
Assert-True ((Format-WauPsadtStatusValue -Value 0) -eq '0') 'zero is a value and not unknown'
Assert-True ((Format-WauPsadtStatusValue -Value ([datetime]'2026-09-19T19:00:00Z')) -eq '2026-09-19 19:00Z') 'a date renders in UTC'
Assert-True ($null -eq (Get-WauPsadtOptionalBoolean -Value $null)) 'a missing boolean is unknown'
Assert-True ($null -eq (Get-WauPsadtOptionalBoolean -Value 'yes')) 'a non-boolean observation is unknown'
Assert-True ((Get-WauPsadtOptionalBoolean -Value $false) -eq $false) 'a false observation is kept'
Assert-True ($null -eq (Get-WauPsadtOptionalCount -Value '')) 'an empty count is unknown'
Assert-True ($null -eq (Get-WauPsadtOptionalCount -Value 'abc')) 'an unparseable count is unknown'
Assert-True ((Get-WauPsadtOptionalCount -Value 0) -eq 0) 'a zero count is kept'
if ($null -eq (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    $unavailableObservation = Get-WauPsadtScheduledTaskObservation -TaskPath 'x' -TaskName 'y'
    Assert-True ($null -eq $unavailableObservation.Present) 'task presence is unknown without Task Scheduler'
}

# Stored values and live observations are separated
$registry = [pscustomobject]@{
    CampaignId       = 'Google.Chrome_140.0.7339.127'
    PackageId        = 'Google.Chrome'
    TargetVersion    = '140.0.7339.127'
    State            = 'Deferred'
    Operation        = 'Upgrade'
    TaskName         = 'Update_Google.Chrome_140.0.7339.127'
    FinalDeadlineUtc = '2026-09-22T14:13:00Z'
    LastUpdatedUtc   = '2026-09-19T19:02:00Z'
    PromptShownCount = 1
}
$snapshot = [pscustomobject]@{ StageExists = $true; StageOwned = $true; TaskExists = $true; CleanupTaskExists = $false; ShortcutExists = $true }
$health = [pscustomobject]@{ Status = 'Healthy'; Reason = 'registry, StageRoot, schedule state, and retry task match' }
$live = [pscustomobject]@{ RetryTaskPresent = $true; CleanupTaskPresent = $false; NextRunTime = [datetime]'2026-09-20T09:41:00Z'; LastRunTime = [datetime]'2026-09-19T19:02:00Z'; LastTaskResult = 0 }

$record = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'Google.Chrome_140.0.7339.127' -Registry $registry -Snapshot $snapshot -Health $health -Live $live
Assert-True ($record.Reported) 'a readable registry entry is reported'
Assert-True ($record.CampaignId -eq 'Google.Chrome_140.0.7339.127') 'campaign identity comes from the registry'
Assert-True ($record.PackageId -eq 'Google.Chrome') 'the package identity is reported'
Assert-True ($record.TargetVersion -eq '140.0.7339.127') 'the target version is reported'
Assert-True ($record.Stored.State -eq 'Deferred') 'the stored state is reported'
Assert-True ($record.Stored.PromptShownCount -eq 1) 'the stored prompt count is reported'
Assert-True ($record.Stored.DeadlineUtc -is [datetime]) 'the stored deadline is a date'
Assert-True ($record.HealthStatus -eq 'Healthy') 'the health status is reported'
Assert-True ($record.HealthReason -match 'retry task match') 'the health reason is reported'
Assert-True ($record.Live.NextAttemptUtc -is [datetime]) 'the live next attempt is reported'
Assert-True ($record.Live.LastRunUtc -is [datetime]) 'the live last run is reported'
Assert-True ($record.Live.LastTaskResult -eq 0) 'the live last result is reported'
Assert-True ($record.Live.StagePresent -and $record.Live.StageOwned) 'observed resources are reported'
Assert-True ($record.Live.CleanupTaskPresent -eq $false) 'an absent resource is reported as no'
Assert-True ($record.HealthVerified) 'health is verified when the retry task was observed'
$unverifiedRecord = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'a' -Registry $registry -Snapshot $snapshot -Health $health -Live ([pscustomobject]@{ RetryTaskPresent = $null; CleanupTaskPresent = $null })
Assert-True (-not $unverifiedRecord.HealthVerified) 'health is unverified when the retry task could not be observed'
Assert-True ($null -ne $unverifiedRecord.HealthStatus) 'an unverified campaign still reports the classification it could compute'
$verifiedAbsentRecord = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'a' -Registry $registry -Snapshot $snapshot -Health $health -Live ([pscustomobject]@{ RetryTaskPresent = $false; CleanupTaskPresent = $false })
Assert-True ($verifiedAbsentRecord.HealthVerified) 'an observed absent retry task keeps the classification verified'
$unverifiedCleanupRecord = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'a' -Registry $registry -Snapshot $snapshot -Health $health -Live ([pscustomobject]@{ RetryTaskPresent = $true; CleanupTaskPresent = $null })
Assert-True (-not $unverifiedCleanupRecord.HealthVerified) 'health is unverified when the cleanup task could not be observed'
Assert-True ($null -eq $record.Live.StageObservedOnly) 'no invented fields are added'

# Unknown stays unknown instead of being invented
$bare = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'Orphan_1' -Registry $null -Snapshot $null -Health $null -Live $null
Assert-True (-not $bare.Reported) 'an unreadable registry entry is not reported'
Assert-True ($bare.CampaignId -eq 'Orphan_1') 'the registry key name is the fallback identity'
Assert-True ($null -eq $bare.PackageId) 'an unknown package stays unknown'
Assert-True ($null -eq $bare.Stored.State) 'an unknown stored state stays unknown'
Assert-True ($null -eq $bare.Stored.PromptShownCount) 'an unknown prompt count stays unknown'
Assert-True ($null -eq $bare.Live.StagePresent) 'unobserved resources stay unknown'
Assert-True ($null -eq $bare.Live.NextAttemptUtc) 'an unobserved next attempt stays unknown'
Assert-True ($null -eq $bare.HealthStatus) 'absent health stays unknown'

# A missing observation must not become a definite false
$partialSnapshot = [pscustomobject]@{ StageExists = $true }
$partialRecord = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'a' -Registry $registry -Snapshot $partialSnapshot -Health $health -Live $null
Assert-True ($partialRecord.Live.StagePresent -eq $true) 'an observed resource is reported'
Assert-True ($null -eq $partialRecord.Live.StageOwned) 'a missing ownership observation stays unknown'
Assert-True ($null -eq $partialRecord.Live.RetryTaskPresent) 'an unobserved task stays unknown'
Assert-True ($null -eq $partialRecord.Live.ShortcutPresent) 'an unobserved shortcut stays unknown'

# A malformed stored count becomes unknown instead of zero or an exception
foreach ($badCount in @('', 'not a number', $true)) {
    $badRegistry = [pscustomobject]@{ CampaignId = 'a'; PackageId = 'p'; PromptShownCount = $badCount }
    $badRecord = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'a' -Registry $badRegistry
    Assert-True ($null -eq $badRecord.Stored.PromptShownCount) "a malformed prompt count [$badCount] stays unknown"
}
$zeroRegistry = [pscustomobject]@{ CampaignId = 'a'; PackageId = 'p'; PromptShownCount = 0 }
Assert-True ((Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'a' -Registry $zeroRegistry).Stored.PromptShownCount -eq 0) 'a zero prompt count is a value'
$textRegistry = [pscustomobject]@{ CampaignId = 'a'; PackageId = 'p'; PromptShownCount = '2' }
Assert-True ((Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'a' -Registry $textRegistry).Stored.PromptShownCount -eq 2) 'a numeric string prompt count is parsed'

# A task that never ran must not look like a successful run
$neverRan = [pscustomobject]@{ RetryTaskPresent = $true; CleanupTaskPresent = $false; NextRunTime = [datetime]'1899-12-30'; LastRunTime = [datetime]'1899-12-30'; LastTaskResult = 267009 }
$record = Get-WauPsadtCampaignStatusRecord -RegistryKeyName 'Google.Chrome_140.0.7339.127' -Registry $registry -Snapshot $snapshot -Health $health -Live $neverRan
Assert-True ($null -eq $record.Live.LastRunUtc) 'a never-run task reports no last run'
Assert-True ($null -eq $record.Live.LastTaskResult) 'a never-run task reports no last result'
Assert-True ($null -eq $record.Live.NextAttemptUtc) 'a stale next run time stays unknown'

# The status filter matches an exact package ID, as the runtime does
$entries = @(
    [pscustomobject]@{ RegistryKeyName = 'a'; Registry = [pscustomobject]@{ CampaignId = 'a'; PackageId = 'Google.Chrome' }; Snapshot = $null; Health = $null; Live = $null },
    [pscustomobject]@{ RegistryKeyName = 'b'; Registry = [pscustomobject]@{ CampaignId = 'b'; PackageId = 'Mozilla.Firefox' }; Snapshot = $null; Health = $null; Live = $null },
    [pscustomobject]@{ RegistryKeyName = 'c'; Registry = $null; Snapshot = $null; Health = $null; Live = $null }
)
Assert-True (@(Get-WauPsadtStatusRecordList -Entry $entries).Count -eq 3) 'every entry is reported without a filter'
$filtered = @(Get-WauPsadtStatusRecordList -Entry $entries -PackageId 'Google.Chrome')
Assert-True ($filtered.Count -eq 1) 'the filter selects one entry'
Assert-True ($filtered[0].CampaignId -eq 'a') 'the filter matches the exact package ID'
Assert-True (@(Get-WauPsadtStatusRecordList -Entry $entries -PackageId 'google.chrome').Count -eq 1) 'the filter is case-insensitive like the runtime'
Assert-True (@(Get-WauPsadtStatusRecordList -Entry $entries -PackageId 'Chrome').Count -eq 0) 'a partial package ID does not match'
Assert-True (@(Get-WauPsadtStatusRecordList -Entry @()).Count -eq 0) 'an empty entry list is handled'

# An unavailable registry is stated instead of guessed
$report = Get-WauPsadtStatusReport -RepositoryRoot $repoRoot -RegistryBasePath $missingRegistry
Assert-True (-not $report.RegistryAvailable) 'an unavailable registry is reported as unavailable'
Assert-True ($report.ExitCode -eq 1) 'an unavailable registry produces exit code 1'
Assert-True ($report.CampaignCount -eq 0) 'an unavailable registry reports no campaigns'
Assert-True ($report.SupportedWauBaseline -eq $baseline.WauBaseline) 'the report carries the WAU baseline'
Assert-True ($null -ne $report.PSObject.Properties['TemplateVersion']) 'the report carries a template version field'
Assert-True ($null -ne $report.PSObject.Properties['Campaigns']) 'the report carries a campaign collection'
Assert-True ($null -ne $report.PSObject.Properties['RegistryError']) 'the report carries a registry error field'
Assert-True ($null -ne $report.PSObject.Properties['ObservationError']) 'the report carries an observation error field'
Assert-True ($report.UnreadableCampaignCount -eq 0) 'an unavailable registry reports no unreadable campaigns'
Assert-True ([string]$report.RegistryError -match 'not available') 'an unavailable registry explains why'
if ($null -eq (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    Assert-True ([string]$report.ObservationError -match 'Task Scheduler') 'a missing Task Scheduler is stated'
}

# An unreadable registry must not look like an empty machine
$lockedRoot = Join-Path $work 'locked-registry'
New-Item -ItemType Directory -Path $lockedRoot | Out-Null
if (Get-Command -Name chmod -ErrorAction SilentlyContinue) {
    & chmod 000 $lockedRoot
    $enumerationBlocked = $false
    try { $null = Get-ChildItem -LiteralPath $lockedRoot -ErrorAction Stop }
    catch { $enumerationBlocked = $true }
    if ($enumerationBlocked) {
        $lockedReport = Get-WauPsadtStatusReport -RepositoryRoot $repoRoot -RegistryBasePath $lockedRoot
        Assert-True (-not $lockedReport.RegistryAvailable) 'an unreadable registry is not reported as available'
        Assert-True ([string]$lockedReport.RegistryError -match 'enumerat') 'an unreadable registry explains the failure'
        Assert-True ($lockedReport.ExitCode -eq 1) 'an unreadable registry produces exit code 1'
    }
    & chmod 755 $lockedRoot
}

# Command-line contract
$cli = Join-Path $diagnosticsRoot 'Get-WauPsadtBridgeStatus.ps1'
& $PSHOME/pwsh -NoProfile -File $cli -RegistryBasePath $missingRegistry *> $null
Assert-True ($LASTEXITCODE -eq 1) 'CLI exits 1 when the campaign registry is unavailable'

$wrapperPath = Join-Path $work 'status-json.ps1'
$dollar = [char]36
$wrapperText = "& '" + $cli + "' -RegistryBasePath '" + $missingRegistry + "' -PassThru 6>" + $dollar + "null | ConvertTo-Json -Depth 6"
Set-Content -LiteralPath $wrapperPath -Value $wrapperText -Encoding UTF8
$jsonText = & $PSHOME/pwsh -NoProfile -File $wrapperPath
$parsed = ($jsonText -join [Environment]::NewLine) | ConvertFrom-Json
Assert-True (-not [bool]$parsed.RegistryAvailable) 'CLI PassThru carries registry availability'
Assert-True ([int]$parsed.ExitCode -eq 1) 'CLI PassThru carries the exit code'
Assert-True ([int]$parsed.CampaignCount -eq 0) 'CLI PassThru carries the campaign count'

Remove-Item -LiteralPath $work -Recurse -Force
Write-Output 'StatusReport.Tests: OK'
