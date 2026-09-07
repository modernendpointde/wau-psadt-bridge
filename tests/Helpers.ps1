$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

function Get-BridgeRepoRoot {
    $dir = $PSScriptRoot
    while ($dir) {
        $installer = Join-Path $dir 'Install-WauPsadtBridge.ps1'
        $template = Join-Path $dir 'template/install.ps1'
        if ((Test-Path -LiteralPath $installer -PathType Leaf) -and (Test-Path -LiteralPath $template -PathType Leaf)) {
            return $dir
        }
        $parent = Split-Path -Path $dir -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }
    throw 'Repository root was not found (Install-WauPsadtBridge.ps1 and template/install.ps1).'
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-ToLog {
    param([String]$LogMsg, [String]$LogColor = 'White', [Switch]$IsHeader)
    $script:WauPsadtTestLog += @($LogMsg)
}
