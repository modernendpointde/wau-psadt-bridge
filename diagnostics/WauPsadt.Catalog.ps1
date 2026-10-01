# Read-only catalog validation.
#
# The verdicts come from the WAU-side rule source that this component loads through
# WauPsadt.Diagnostics.ps1, so the runtime and the diagnostics cannot drift apart.

function Get-WauPsadtCatalogEntryValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowNull()]$Entry
    )

    $errors = New-Object System.Collections.Generic.List[string]

    $processesValid = Test-WauPsadtCatalogProcesses -Entry $Entry
    if (-not $processesValid) {
        $errors.Add('processes must list at least one exact Get-Process name without path, .exe suffix, or wildcard characters')
    }

    $uiValid = Test-WauPsadtCatalogUi -Entry $Entry
    if (-not $uiValid) {
        $errors.Add('ui must be an object containing only the Boolean progress and success values')
    }

    $uiPresent = $false
    $uiProperty = $null
    if ($null -ne $Entry) {
        $uiProperty = $Entry.PSObject.Properties['ui']
        $uiPresent = $null -ne $uiProperty
    }

    # Mirrors the campaign payload: both values default to enabled and the entry overrides them.
    # An invalid entry is skipped at runtime, so it has no effective values to report.
    $effectiveProgress = $null
    $effectiveSuccess = $null
    if ($errors.Count -eq 0) {
        $effectiveProgress = $true
        $effectiveSuccess = $true
        if ($uiPresent) {
            foreach ($property in $uiProperty.Value.PSObject.Properties) {
                if ([string]$property.Name -ieq 'progress') { $effectiveProgress = [bool]$property.Value }
                if ([string]$property.Name -ieq 'success') { $effectiveSuccess = [bool]$property.Value }
            }
        }
    }

    $processNames = @()
    if ($null -ne $Entry -and $null -ne $Entry.PSObject.Properties['processes']) {
        $processNames = @($Entry.processes | ForEach-Object { [string]$_ })
    }

    return [pscustomobject]@{
        Id                = $Id
        DisplayName       = if ($null -ne $Entry) { [string]$Entry.displayName } else { '' }
        Processes         = $processNames
        ProcessesValid    = [bool]$processesValid
        UiPresent         = [bool]$uiPresent
        UiValid           = [bool]$uiValid
        EffectiveProgress = $effectiveProgress
        EffectiveSuccess  = $effectiveSuccess
        Errors            = @($errors)
        Valid             = ($errors.Count -eq 0)
    }
}

function Get-WauPsadtCatalogValidation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    # Resolve against the PowerShell location. The .NET working directory is a different
    # value, so GetFullPath would resolve a relative path against the wrong directory.
    $fullPath = $Path
    try { $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } catch { }

    # The runtime loader reads the catalog through these script-scoped values.
    $script:WauPsadtBridgeCatalog = $null
    $script:WauPsadtBridgeCatalogPath = $fullPath

    $structureError = $null
    $catalog = $null
    try { $catalog = Get-WauPsadtBridgeCatalog }
    catch { $structureError = $_.Exception.Message }

    if ($null -ne $structureError) {
        return [pscustomobject]@{
            Path              = $fullPath
            StructureValid    = $false
            StructureError    = $structureError
            SchemaVersion     = $null
            EntryCount        = 0
            ValidEntryCount   = 0
            InvalidEntryCount = 0
            Entries           = @()
            ExitCode          = 1
        }
    }

    $entries = @()
    foreach ($property in $catalog.apps.PSObject.Properties) {
        $entries += Get-WauPsadtCatalogEntryValidation -Id ([string]$property.Name) -Entry $property.Value
    }
    $invalidEntries = @($entries | Where-Object { -not $_.Valid })

    return [pscustomobject]@{
        Path              = $fullPath
        StructureValid    = $true
        StructureError    = $null
        SchemaVersion     = [int]$catalog.schemaVersion
        EntryCount        = $entries.Count
        ValidEntryCount   = $entries.Count - $invalidEntries.Count
        InvalidEntryCount = $invalidEntries.Count
        Entries           = $entries
        ExitCode          = if ($invalidEntries.Count -gt 0) { 2 } else { 0 }
    }
}
