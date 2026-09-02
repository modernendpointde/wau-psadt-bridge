# Lifecycle orchestration helpers. Package adapters still live under App/ so a
# package never edits framework files for application-specific behavior.

function Set-WauBridgeExitCodeFromResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)

    if (-not $Result.Succeeded) { return [int]$Result.ExitCode }
    if ($Result.RebootRequired) { return 3010 }
    return 0
}

function Close-WauBridgeProgressSafely {
    [CmdletBinding()]
    param()
    try { Close-ADTInstallationProgress }
    catch { Write-WauBridgeLog -Message ("Progress UI could not be closed: {0}" -f $_.Exception.Message) -Severity 2 }
}
