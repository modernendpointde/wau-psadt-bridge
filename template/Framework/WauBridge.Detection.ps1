# Detection policy separates evidence from operation classification. Presence
# without a parseable version is explicit and defaults to Upgrade, never a
# silent same-version no-op.

function Get-WauBridgeDetectionEvidence {
    [CmdletBinding()]
    param()

    $installedVersion = Get-WauBridgeInstalledVersion
    if ($installedVersion) {
        return [pscustomobject]@{ State = 'Versioned'; Present = $true; Version = [version]$installedVersion; Method = 'WingetScript' }
    }
    $present = [bool](Test-WauBridgeAppInstalled)
    if ($present) {
        return [pscustomobject]@{ State = 'PresentUnknownVersion'; Present = $true; Version = $null; Method = 'WingetScript' }
    }
    return [pscustomobject]@{ State = 'Missing'; Present = $false; Version = $null; Method = 'WingetScript' }
}

function Get-WauBridgeInstallOperation {
    [CmdletBinding()]
    param()

    $evidence = Get-WauBridgeDetectionEvidence
    if ($evidence.State -eq 'Versioned') {
        if ($evidence.Version -lt $WauBridgeConfig.TargetVersion) { return 'Upgrade' }
        if ($evidence.Version -eq $WauBridgeConfig.TargetVersion) { return 'InstalledSameVersion' }
        return 'InstalledNewerVersion'
    }
    if ($evidence.State -eq 'PresentUnknownVersion') {
        Write-WauBridgeLog -Message 'Application presence was detected without a version; treating as Upgrade.' -Severity 2
        return 'Upgrade'
    }
    return 'Upgrade'
}

function Test-WauBridgeProvisioningActive {
    [CmdletBinding()]
    param()

    $espKnown = $false
    $oobeKnown = $false
    $espActive = $false
    $oobeCompleted = $true

    $espCommand = Get-Command -Name Test-ADTEspActive -ErrorAction SilentlyContinue
    if ($espCommand) {
        try {
            $espActive = [bool](Test-ADTEspActive)
            $espKnown = $true
        }
        catch { Write-WauBridgeLog -Message ("ESP detection failed: {0}" -f $_.Exception.Message) -Severity 2 }
    }
    else { Write-WauBridgeLog -Message 'PSADT ESP detection adapter is unavailable.' -Severity 2 }

    $oobeCommand = Get-Command -Name Test-ADTOobeCompleted -ErrorAction SilentlyContinue
    if ($oobeCommand) {
        try {
            $oobeCompleted = [bool](Test-ADTOobeCompleted)
            $oobeKnown = $true
        }
        catch { Write-WauBridgeLog -Message ("OOBE detection failed: {0}" -f $_.Exception.Message) -Severity 2 }
    }
    else { Write-WauBridgeLog -Message 'PSADT OOBE detection adapter is unavailable.' -Severity 2 }

    if ($espKnown -and $oobeKnown) {
        return ($espActive -or -not $oobeCompleted)
    }

    $enrollmentRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (-not (Test-Path -LiteralPath $enrollmentRoot)) { return ($espActive -or -not $oobeCompleted) }
    try {
        foreach ($enrollmentKey in Get-ChildItem -LiteralPath $enrollmentRoot -ErrorAction Stop) {
            if (Test-Path -LiteralPath (Join-Path $enrollmentKey.PSPath 'EnrollmentStatusTracking')) { return $true }
        }
    }
    catch { Write-WauBridgeLog -Message ("Enrollment provisioning fallback failed: {0}" -f $_.Exception.Message) -Severity 2 }
    return ($espActive -or -not $oobeCompleted)
}
