# Preflight validates the config hashtable before a PSADT session opens.

function Assert-WauBridgeConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration)

    Assert-WauBridgeCompatibilityConfiguration -Configuration $Configuration
    $errors = New-Object System.Collections.Generic.List[string]

    if (-not $Configuration.Contains('Localization') -or $Configuration.Localization -isnot [System.Collections.IDictionary]) {
        $errors.Add('Localization must be configured as a hashtable.')
    }
    else {
        $requestedCulture = [string]$Configuration.Localization.Culture
        $defaultCulture = [string]$Configuration.Localization.DefaultCulture
        if ($requestedCulture -ne 'Auto') {
            try { $null = [Globalization.CultureInfo]::GetCultureInfo($requestedCulture) }
            catch { $errors.Add("Localization.Culture is not a valid BCP-47 tag: [$requestedCulture].") }
        }
        try {
            $defaultInfo = [Globalization.CultureInfo]::GetCultureInfo($defaultCulture)
            if ([string]::IsNullOrWhiteSpace($defaultInfo.Name)) { throw 'Invariant culture is not allowed.' }
        }
        catch { $errors.Add("Localization.DefaultCulture is not a valid specific BCP-47 tag: [$defaultCulture].") }

        $messagesPath = [string]$Configuration.Localization.MessagesPath
        if ([string]::IsNullOrWhiteSpace($messagesPath) -or [IO.Path]::IsPathRooted($messagesPath) -or $messagesPath -match '(^|[\\/])[.][.]([\\/]|$)') {
            $errors.Add('Localization.MessagesPath must be a safe package-relative path.')
        }
    }

    if ([int]$Configuration.Retry.Days -lt 1 -or [int]$Configuration.Retry.Days -gt 5) {
        $errors.Add('Retry.Days must be between 1 and 5.')
    }
    if ([int]$Configuration.Retry.TimesPerDay -notin @(1, 2)) {
        $errors.Add('Retry.TimesPerDay must be 1 or 2.')
    }
    try {
        $windowStart = [timespan]::ParseExact([string]$Configuration.Retry.HoursStart, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
        $windowEnd = [timespan]::ParseExact([string]$Configuration.Retry.HoursEnd, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
        if ($windowEnd -le $windowStart) { $errors.Add('Retry.HoursEnd must be after HoursStart.') }
    }
    catch {
        $errors.Add('Retry.HoursStart and HoursEnd must be in HH:mm format.')
    }

    if ([int]$Configuration.UserExperience.CloseCountdownSeconds -lt 1 -or [int]$Configuration.UserExperience.CloseCountdownSeconds -gt 3600) {
        $errors.Add('UserExperience.CloseCountdownSeconds must be between 1 and 3600.')
    }

    $overlap = @($Configuration.SuccessExitCodes | Where-Object { $_ -in $Configuration.RebootExitCodes })
    if ($overlap.Count -gt 0) {
        $errors.Add("SuccessExitCodes and RebootExitCodes must be disjoint: [$($overlap -join ', ')].")
    }
    if ($errors.Count -gt 0) {
        throw ("WauBridge.Config.ps1 is invalid:`n - {0}" -f ($errors -join "`n - "))
    }

    $null = Get-WauBridgeLocalizationResource -Configuration $Configuration -ScriptRoot (Split-Path -Path $PSScriptRoot -Parent) -Refresh
}
