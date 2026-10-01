[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$WauRoot,
    [string]$PackageId,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

$script:DiagnosticsRoot = $PSScriptRoot
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $script:DiagnosticsRoot 'WauPsadt.Diagnostics.ps1')

$reportParams = @{ RepositoryRoot = $script:RepositoryRoot }
if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $reportParams.InstallRoot = $InstallRoot }
if (-not [string]::IsNullOrWhiteSpace($WauRoot)) { $reportParams.WauRoot = $WauRoot }
if (-not [string]::IsNullOrWhiteSpace($PackageId)) { $reportParams.PackageId = $PackageId }

$report = Get-WauPsadtHealthReport @reportParams

Write-Host ''
Write-Host ('Bridge install: {0}' -f (Format-WauPsadtStatusValue -Value $report.InstallRoot)) -ForegroundColor Cyan
Write-Host ('Supported:      WAU {0}, backup {1}' -f (Format-WauPsadtStatusValue -Value $report.SupportedWauVersion), (Format-WauPsadtStatusValue -Value $report.BackupName))
Write-Host ''

foreach ($check in $report.Checks) {
    $color = 'Gray'
    if ($check.Status -eq 'Pass') { $color = 'Green' }
    elseif ($check.Status -eq 'Fail') { $color = 'Red' }
    elseif ($check.Status -eq 'Unknown') { $color = 'Yellow' }
    Write-Host ('  {0,-8} {1,-22} {2}' -f $check.Status.ToUpperInvariant(), $check.Name, $check.Detail) -ForegroundColor $color
}

Write-Host ''
if ($report.ExitCode -eq 0) {
    Write-Host 'No check failed. An unknown check needs the matching platform or an installed component.' -ForegroundColor Green
}
else {
    Write-Host ('{0} of {1} checks failed.' -f $report.FailedCheckCount, $report.Checks.Count) -ForegroundColor Red
}
Write-Host ''

if ($PassThru) { $report }
exit $report.ExitCode

