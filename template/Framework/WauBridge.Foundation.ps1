# Foundation helpers: logging, identity, safe names, canonical paths, containment, atomic writes, and escaping.

function Get-WauBridgeBaseAppName {
    [CmdletBinding()]
    param()

    return [string]$WauBridgeConfig.DisplayName
}

function Write-WauBridgeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet(1,2,3)]
        [int]$Severity = 1
    )

    if (Get-Command -Name Write-ADTLogEntry -ErrorAction SilentlyContinue) {
        Write-ADTLogEntry -Message $Message -Severity $Severity
    }
    else {
        Write-Host $Message
    }
}

function Get-WauBridgeSafeName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    return (($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
}

function Get-WauBridgeCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'An empty path cannot be canonicalized.'
    }

    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim()))
}

function Test-WauBridgePathContained {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$ParentPath,
        [switch]$AllowEqual
    )

    $candidate = (Get-WauBridgeCanonicalPath -Path $CandidatePath).TrimEnd('\','/')
    $parent = (Get-WauBridgeCanonicalPath -Path $ParentPath).TrimEnd('\','/')
    if ($AllowEqual -and $candidate.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-WauBridgeAtomicTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $directory = Split-Path -Path $LiteralPath -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Atomic write is missing a destination directory: [$LiteralPath]."
    }

    New-Item -Path $directory -ItemType Directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ('.{0}.tmp' -f [System.IO.Path]::GetRandomFileName())
    $backupPath = Join-Path $directory ('.{0}.bak' -f [System.IO.Path]::GetRandomFileName())
    try {
        Set-Content -LiteralPath $temporaryPath -Value $Content -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $LiteralPath, $backupPath)
        }
        else {
            Move-Item -LiteralPath $temporaryPath -Destination $LiteralPath -ErrorAction Stop
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-WauBridgeCompatibilityConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration)

    $validationErrors = New-Object System.Collections.Generic.List[string]
    foreach ($requiredName in @('PackageId','DisplayName','TargetVersion','Retry','UserExperience','ProcessDefinitions')) {
        if (-not $Configuration.Contains($requiredName) -or $null -eq $Configuration[$requiredName]) {
            $validationErrors.Add("Required value [$requiredName] is missing.")
        }
    }

    if ($validationErrors.Count -eq 0) {
        $packageId = [string]$Configuration.PackageId
        if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -match '[\\/:*?"<>|]' -or $packageId -in @('.','..')) {
            $validationErrors.Add('PackageId is empty or contains illegal resource-identifier characters.')
        }
        if ([string]::IsNullOrWhiteSpace([string]$Configuration.DisplayName)) {
            $validationErrors.Add('DisplayName is empty.')
        }
        if (@($Configuration.ProcessDefinitions).Count -lt 1) {
            $validationErrors.Add('ProcessDefinitions must contain at least one process name.')
        }

        if ([int]$Configuration.Retry.Days -lt 1 -or [int]$Configuration.Retry.Days -gt 5) {
            $validationErrors.Add('Retry.Days must be between 1 and 5.')
        }
        if ([int]$Configuration.Retry.TimesPerDay -notin @(1, 2)) {
            $validationErrors.Add('Retry.TimesPerDay must be 1 or 2.')
        }
    }

    if ($validationErrors.Count -gt 0) {
        throw ("WauBridge.Config.ps1 is invalid:`n - {0}" -f ($validationErrors -join "`n - "))
    }
}

function Get-WauBridgeNormalizedTaskPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskPath)

    $normalized = $TaskPath.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return '\' }
    if (-not $normalized.StartsWith('\')) { $normalized = '\' + $normalized }
    if (-not $normalized.EndsWith('\')) { $normalized += '\' }
    return $normalized
}

function Convert-WauBridgeTaskPathToComFolderPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskPath)

    $normalized = Get-WauBridgeNormalizedTaskPath -TaskPath $TaskPath
    if ($normalized -eq '\') { return '\' }
    return $normalized.TrimEnd('\')
}

function ConvertTo-WauBridgePowerShellSingleQuotedLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -match '[\x00-\x1F\x7F]') {
        throw 'PowerShell literal values must not contain control characters.'
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-WauBridgeManualTaskStartArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    $taskPathLiteral = ConvertTo-WauBridgePowerShellSingleQuotedLiteral -Value $TaskPath
    $taskNameLiteral = ConvertTo-WauBridgePowerShellSingleQuotedLiteral -Value $TaskName
    return '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "& {{ Start-ScheduledTask -TaskPath {0} -TaskName {1} -ErrorAction Stop }}"' -f $taskPathLiteral, $taskNameLiteral
}
