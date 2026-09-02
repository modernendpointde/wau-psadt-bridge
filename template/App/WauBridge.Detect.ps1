function ConvertTo-Version {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $m = [regex]::Match($Value, '\d+(?:\s*[\.,]\s*\d+){0,3}')
    if (-not $m.Success) { return $null }

    $parts = [regex]::Split($m.Value, '\s*[\.,]\s*') | Where-Object { $_ -match '^\d+$' }
    while ($parts.Count -lt 4) { $parts += '0' }

    try { return [version]($parts[0..3] -join '.') } catch { return $null }
}

function Get-WauBridgeInstalledVersion {
    [CmdletBinding()]
    param()

    $wingetAppId = Get-WauBridgeWingetDetectAppId
    if ([string]::IsNullOrWhiteSpace($wingetAppId)) { return $null }
    try { return Get-WauBridgeWingetInstalledVersion -AppId $wingetAppId }
    catch {
        Write-WauBridgeLog -Message ("Winget version detection failed: {0}" -f $_.Exception.Message) -Severity 2
        return $null
    }
}

function Test-WauBridgeAppInstalled {
    [CmdletBinding()]
    param()

    $wingetAppId = Get-WauBridgeWingetDetectAppId
    if ([string]::IsNullOrWhiteSpace($wingetAppId)) { return $false }
    return [bool](Test-WauBridgeWingetPackagePresent -AppId $wingetAppId)
}
