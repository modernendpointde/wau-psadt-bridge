$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

$failed = @()
$scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name)
if ($scripts.Count -lt 1) {
    throw "No test scripts found under [$PSScriptRoot]."
}

foreach ($script in $scripts) {
    Write-Host "=== $($script.Name) ===" -ForegroundColor Cyan
    & $PSHOME/pwsh -NoProfile -File $script.FullName
    if ($LASTEXITCODE -ne 0) {
        $failed += $script.Name
    }
}

if ($failed.Count -gt 0) {
    throw ("Tests failed: {0}" -f ($failed -join ', '))
}

Write-Host "All tests passed ($($scripts.Count))." -ForegroundColor Green
