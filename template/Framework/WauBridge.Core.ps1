# Core contracts shared by lifecycle adapters. These functions avoid PSADT
# types so package hooks and policy tests can use them independently.

function New-WauBridgeResult {
    <#
    .SYNOPSIS
        Creates the normalized result returned by every package action.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Upgrade')][string]$Operation,
        [Parameter(Mandatory)][int]$ExitCode,
        [int[]]$SuccessExitCodes = @(0),
        [int[]]$RebootExitCodes = @(1641,3010),
        [string]$Adapter = 'Unknown',
        [string]$Diagnostic = ''
    )

    $successful = $ExitCode -in @($SuccessExitCodes + $RebootExitCodes)
    return [pscustomobject]@{
        PSTypeName     = 'WauBridge.ActionResult'
        Operation      = $Operation
        Adapter        = $Adapter
        ExitCode       = $ExitCode
        Succeeded      = $successful
        RebootRequired = $ExitCode -in $RebootExitCodes
        Diagnostic     = $Diagnostic
    }
}

function ConvertTo-WauBridgeResult {
    <#
    .SYNOPSIS
        Normalizes PSADT, integer and package-script action results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][ValidateSet('Upgrade')][string]$Operation,
        [int[]]$SuccessExitCodes = @(0),
        [int[]]$RebootExitCodes = @(1641,3010),
        [string]$Adapter = 'Unknown'
    )

    $exitCode = $null
    if ($InputObject -is [int]) { $exitCode = [int]$InputObject }
    elseif ($InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains 'ExitCode') { $exitCode = [int]$InputObject.ExitCode }
    if ($null -eq $exitCode) {
        throw "Action adapter [$Adapter] returned no ExitCode."
    }

    $result = New-WauBridgeResult -Operation $Operation -ExitCode $exitCode -SuccessExitCodes $SuccessExitCodes -RebootExitCodes $RebootExitCodes -Adapter $Adapter
    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Name -contains 'RebootRequired') {
        $result.RebootRequired = [bool]$InputObject.RebootRequired
    }
    if (-not $result.Succeeded) {
        throw "Action adapter [$Adapter] failed with ExitCode [$exitCode]."
    }
    return $result
}

function Get-WauBridgeCultureNameForSid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sid)

    foreach ($entry in @(
        @{ Key = "HKEY_USERS\$Sid\Control Panel\International\User Profile"; Name = 'Languages' }
        @{ Key = "HKEY_USERS\$Sid\Control Panel\Desktop"; Name = 'PreferredUILanguages' }
    )) {
        try {
            $value = [Microsoft.Win32.Registry]::GetValue($entry.Key, $entry.Name, $null)
            $first = @($value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
            if ($first) { return [string]$first }
        }
        catch { }
    }
    return ''
}

function Get-WauBridgeInteractiveUserSid {
    [CmdletBinding()]
    param()

    if (Get-Command -Name Get-ADTLoggedOnUser -ErrorAction SilentlyContinue) {
        try {
            $active = @(Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession })
            if ($active.Count -lt 1) {
                $active = @(Get-ADTLoggedOnUser | Where-Object { $_.IsConsoleSession })
            }
            if ($active.Count -ge 1 -and $active[0].SID) {
                return [string]$active[0].SID
            }
        }
        catch { }
    }

    try {
        $explorers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            Where-Object { [int]$_.SessionId -ne 0 } |
            Sort-Object SessionId)
        foreach ($proc in $explorers) {
            try {
                $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
                if ([int]$owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace([string]$owner.User)) { continue }
                $account = if (-not [string]::IsNullOrWhiteSpace([string]$owner.Domain)) {
                    '{0}\{1}' -f $owner.Domain, $owner.User
                }
                else { [string]$owner.User }
                $sid = ([System.Security.Principal.NTAccount]$account).Translate([System.Security.Principal.SecurityIdentifier]).Value
                if (-not [string]::IsNullOrWhiteSpace($sid)) { return $sid }
            }
            catch { }
        }
    }
    catch { }

    return $null
}

function Get-WauBridgeInteractiveCultureName {
    [CmdletBinding()]
    param()

    try {
        $sid = Get-WauBridgeInteractiveUserSid
        if (-not [string]::IsNullOrWhiteSpace($sid)) {
            $name = Get-WauBridgeCultureNameForSid -Sid $sid
            if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
        }
    }
    catch {
        Write-WauBridgeLog -Message ("Interactive UI culture could not be resolved; localization fallback will be used: {0}" -f $_.Exception.Message) -Severity 2
    }
    return ''
}

function Resolve-WauBridgeContainedPath {
    <#
    .SYNOPSIS
        Resolves a relative child while proving package-root containment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$RelativePath)

    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])[.][.]([\\/]|$)') {
        throw "Path must be package-relative and cannot traverse: [$RelativePath]."
    }
    $root = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\','/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path leaves package root: [$RelativePath]."
    }
    return $candidate
}

function Get-WauBridgeTimeZone {
    [CmdletBinding()]
    param()

    try { return [System.TimeZoneInfo]::Local }
    catch {
        Write-WauBridgeLog -Message ("Local timezone could not be resolved; UTC will be used: {0}" -f $_.Exception.Message) -Severity 2
        return [System.TimeZoneInfo]::Utc
    }
}
