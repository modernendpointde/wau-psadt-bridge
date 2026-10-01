[CmdletBinding()]
param(
    [string]$Path,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

$script:DiagnosticsRoot = $PSScriptRoot
$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $script:DiagnosticsRoot 'WauPsadt.Diagnostics.ps1')

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Join-Path (Join-Path $script:RepositoryRoot 'catalog') 'apps.json'
}

$result = Get-WauPsadtCatalogValidation -Path $Path

Write-Host ''
Write-Host ('Catalog file: {0}' -f $result.Path) -ForegroundColor Cyan
if ($result.StructureValid) {
    Write-Host ('Structure:    valid (schemaVersion {0})' -f $result.SchemaVersion) -ForegroundColor Green
}
else {
    Write-Host 'Structure:    invalid' -ForegroundColor Red
    Write-Host ('Reason:       {0}' -f $result.StructureError) -ForegroundColor Red
}

if ($result.EntryCount -gt 0) {
    Write-Host ('Entries:      {0} total, {1} valid, {2} invalid' -f $result.EntryCount, $result.ValidEntryCount, $result.InvalidEntryCount)
    foreach ($entry in $result.Entries) {
        if ($entry.Valid) {
            if ($entry.UiPresent) {
                Write-Host ('  {0,-24} valid    processes: {1}; ui.progress: {2}; ui.success: {3}' -f $entry.Id, ($entry.Processes -join ', '), $entry.EffectiveProgress, $entry.EffectiveSuccess)
            }
            else {
                Write-Host ('  {0,-24} valid    processes: {1}; ui.progress: {2} (default); ui.success: {3} (default)' -f $entry.Id, ($entry.Processes -join ', '), $entry.EffectiveProgress, $entry.EffectiveSuccess)
            }
        }
        else {
            Write-Host ('  {0,-24} invalid' -f $entry.Id) -ForegroundColor Red
            foreach ($message in $entry.Errors) {
                Write-Host ('      {0}' -f $message) -ForegroundColor Red
            }
        }
    }
}

Write-Host ''
switch ($result.ExitCode) {
    0 { Write-Host 'Catalog is valid.' -ForegroundColor Green }
    1 { Write-Host 'Catalog is structurally invalid. The WAU cycle stops for this condition.' -ForegroundColor Red }
    default { Write-Host 'Catalog is structurally valid, but at least one entry is invalid. That entry is skipped and does not fall back to native WAU.' -ForegroundColor Yellow }
}
Write-Host ''

if ($PassThru) { $result }
exit $result.ExitCode

