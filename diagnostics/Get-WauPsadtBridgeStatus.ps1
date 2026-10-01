[CmdletBinding()]
param(
    [string]$PackageId,
    [string]$RegistryBasePath,
    [string]$InstallRoot,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

$script:DiagnosticsRoot = $PSScriptRoot
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $script:DiagnosticsRoot 'WauPsadt.Diagnostics.ps1')

$reportParams = @{ RepositoryRoot = $script:RepositoryRoot }
if (-not [string]::IsNullOrWhiteSpace($PackageId)) { $reportParams.PackageId = $PackageId }
if (-not [string]::IsNullOrWhiteSpace($RegistryBasePath)) { $reportParams.RegistryBasePath = $RegistryBasePath }
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $reportParams.InstallRoot = $InstallRoot }

$report = Get-WauPsadtStatusReport @reportParams

Write-Host ''
Write-Host ('Bridge install:   {0}' -f (Format-WauPsadtStatusValue -Value $report.InstallRoot)) -ForegroundColor Cyan
Write-Host ('Template version: {0}' -f (Format-WauPsadtStatusValue -Value $report.TemplateVersion))
Write-Host ('Supported:        WAU {0}, PSADT {1}' -f (Format-WauPsadtStatusValue -Value $report.SupportedWauBaseline), (Format-WauPsadtStatusValue -Value $report.SupportedPsadtBaseline))
if ($null -ne $report.PackageIdFilter) {
    Write-Host ('Filter:           {0}' -f $report.PackageIdFilter)
}

if ($null -ne $report.ObservationError) {
    Write-Host ''
    Write-Host $report.ObservationError -ForegroundColor Yellow
}

if (-not $report.RegistryAvailable) {
    Write-Host ''
    Write-Host $report.RegistryError -ForegroundColor Red
    Write-Host 'No campaign state was read.'
}
else {
    Write-Host ('Campaigns:        {0}' -f $report.CampaignCount)
    if ($report.UnreadableCampaignCount -gt 0) {
        Write-Host ('Unreadable:       {0} registry entries could not be read; they are listed without stored values.' -f $report.UnreadableCampaignCount) -ForegroundColor Yellow
    }
    foreach ($campaign in $report.Campaigns) {
        Write-Host ''
        Write-Host ('  {0}' -f $campaign.CampaignId) -ForegroundColor Cyan
        if (-not $campaign.Reported) {
            Write-Host '    Registry values could not be read for this key.' -ForegroundColor Red
        }
        Write-Host ('    Package / target: {0} / {1}' -f (Format-WauPsadtStatusValue -Value $campaign.PackageId), (Format-WauPsadtStatusValue -Value $campaign.TargetVersion))
        $healthSuffix = ''
        if (-not $campaign.HealthVerified) { $healthSuffix = ' [unverified]' }
        Write-Host ('    Health:           {0} ({1}){2}' -f (Format-WauPsadtStatusValue -Value $campaign.HealthStatus), (Format-WauPsadtStatusValue -Value $campaign.HealthReason), $healthSuffix)
        Write-Host ('    Stored:           state {0}, deadline {1}, prompts {2}, updated {3}' -f (Format-WauPsadtStatusValue -Value $campaign.Stored.State), (Format-WauPsadtStatusValue -Value $campaign.Stored.DeadlineUtc), (Format-WauPsadtStatusValue -Value $campaign.Stored.PromptShownCount), (Format-WauPsadtStatusValue -Value $campaign.Stored.LastUpdatedUtc))
        Write-Host ('    Live:             next attempt {0}, last run {1}, last result {2}' -f (Format-WauPsadtStatusValue -Value $campaign.Live.NextAttemptUtc), (Format-WauPsadtStatusValue -Value $campaign.Live.LastRunUtc), (Format-WauPsadtStatusValue -Value $campaign.Live.LastTaskResult))
        Write-Host ('    Resources:        stage {0} (owned {1}), retry task {2}, cleanup task {3}, shortcut {4}' -f (Format-WauPsadtStatusValue -Value $campaign.Live.StagePresent), (Format-WauPsadtStatusValue -Value $campaign.Live.StageOwned), (Format-WauPsadtStatusValue -Value $campaign.Live.RetryTaskPresent), (Format-WauPsadtStatusValue -Value $campaign.Live.CleanupTaskPresent), (Format-WauPsadtStatusValue -Value $campaign.Live.ShortcutPresent))
    }
}

Write-Host ''
if ($report.ExitCode -eq 0) {
    Write-Host 'Status report complete.' -ForegroundColor Green
}
else {
    Write-Host 'Status report could not read the campaign registry.' -ForegroundColor Red
}
Write-Host ''

if ($PassThru) { $report }
exit $report.ExitCode
