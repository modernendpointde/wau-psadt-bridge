# Read-only campaign status.
#
# The record builder is pure so stored and observed values can be tested without Windows.
# The collector reads the machine and hands the raw values to the builder. Every value that
# cannot be read or observed stays null, which the report renders as unknown.

function Get-WauPsadtMemberValue {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-WauPsadtOptionalText {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [string]$Value
}

function Get-WauPsadtOptionalDate {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [datetime]$Value } catch { return $null }
}

function Get-WauPsadtObservedRunTime {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    try { $observed = [datetime]$Value } catch { return $null }
    # Task Scheduler reports 1899-12-30 for a task that has never run.
    if ($observed.Year -lt 1900) { return $null }
    return $observed
}

function Get-WauPsadtOptionalBoolean {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    # A missing observation must stay unknown instead of turning into a definite false.
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [bool]$Value }
    return $null
}

function Get-WauPsadtOptionalCount {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    if ($Value -is [ValueType]) {
        try { return [int]$Value } catch { return $null }
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

function Format-WauPsadtStatusValue {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return 'unknown' }
    if ($Value -is [datetime]) { return ($Value.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + 'Z') }
    if ($Value -is [bool]) {
        if ($Value) { return 'yes' }
        return 'no'
    }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    return [string]$Value
}

function Get-WauPsadtSupportedBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    # The supported WAU version comes from the shared bridge contract and the PSADT baseline from
    # the vendored manifest, so neither value is duplicated here.
    $wauBaseline = $script:SupportedWauVersion

    $psadtBaseline = $null
    $manifestPath = Join-Path (Join-Path (Join-Path $RepositoryRoot 'template') 'PSAppDeployToolkit') 'PSAppDeployToolkit.psd1'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
            if ($null -ne $manifest -and $null -ne $manifest.ModuleVersion) {
                $psadtBaseline = [string]$manifest.ModuleVersion
            }
        }
        catch { }
    }

    return [pscustomobject]@{
        WauBaseline   = $wauBaseline
        PsadtBaseline = $psadtBaseline
    }
}

function Get-WauPsadtTemplateVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TemplateRoot)

    $invokePath = Join-Path $TemplateRoot 'Invoke-AppDeployToolkit.ps1'
    if (-not (Test-Path -LiteralPath $invokePath -PathType Leaf)) { return $null }
    try { $text = Get-Content -LiteralPath $invokePath -Raw -ErrorAction Stop }
    catch { return $null }

    $match = [regex]::Match($text, "AppScriptVersion\s*=[ ]*\[version\]'([^']+)'")
    if (-not $match.Success) { return $null }
    try { return [version]$match.Groups[1].Value } catch { return $null }
}

function Get-WauPsadtCampaignStatusRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RegistryKeyName,
        [AllowNull()]$Registry,
        [AllowNull()]$Snapshot,
        [AllowNull()]$Health,
        [AllowNull()]$Live
    )

    $campaignId = $RegistryKeyName
    $packageId = $null
    $targetVersion = $null
    $reported = $false

    $stored = [pscustomobject]@{
        State            = $null
        Operation        = $null
        DeadlineUtc      = $null
        PromptShownCount = $null
        LastUpdatedUtc   = $null
        TaskName         = $null
    }

    if ($null -ne $Registry) {
        $reported = $true
        $stored.State = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'State')
        $stored.Operation = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'Operation')
        $stored.TaskName = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'TaskName')
        $stored.DeadlineUtc = Get-WauPsadtOptionalDate -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'FinalDeadlineUtc')
        $stored.LastUpdatedUtc = Get-WauPsadtOptionalDate -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'LastUpdatedUtc')

        $stored.PromptShownCount = Get-WauPsadtOptionalCount -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'PromptShownCount')

        $reportedCampaignId = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'CampaignId')
        if ($null -ne $reportedCampaignId) { $campaignId = $reportedCampaignId }
        $packageId = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'PackageId')
        $targetVersion = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Registry -Name 'TargetVersion')
    }

    # Not named $live: PowerShell variable names are case-insensitive, so it would overwrite the
    # $Live parameter that carries the task observations.
    $observed = [pscustomobject]@{
        StagePresent       = $null
        StageOwned         = $null
        RetryTaskPresent   = $null
        CleanupTaskPresent = $null
        ShortcutPresent    = $null
        NextAttemptUtc     = $null
        LastRunUtc         = $null
        LastTaskResult     = $null
    }

    # Filesystem presence comes from the shared ownership snapshot. Task presence is queried
    # directly so the report separates an absent task from one that could not be read.
    if ($null -ne $Snapshot) {
        $observed.StagePresent = Get-WauPsadtOptionalBoolean -Value (Get-WauPsadtMemberValue -InputObject $Snapshot -Name 'StageExists')
        $observed.StageOwned = Get-WauPsadtOptionalBoolean -Value (Get-WauPsadtMemberValue -InputObject $Snapshot -Name 'StageOwned')
        $observed.ShortcutPresent = Get-WauPsadtOptionalBoolean -Value (Get-WauPsadtMemberValue -InputObject $Snapshot -Name 'ShortcutExists')
    }

    if ($null -ne $Live) {
        $observed.RetryTaskPresent = Get-WauPsadtOptionalBoolean -Value (Get-WauPsadtMemberValue -InputObject $Live -Name 'RetryTaskPresent')
        $observed.CleanupTaskPresent = Get-WauPsadtOptionalBoolean -Value (Get-WauPsadtMemberValue -InputObject $Live -Name 'CleanupTaskPresent')
        $observed.NextAttemptUtc = Get-WauPsadtObservedRunTime -Value (Get-WauPsadtMemberValue -InputObject $Live -Name 'NextRunTime')
        $lastRun = Get-WauPsadtObservedRunTime -Value (Get-WauPsadtMemberValue -InputObject $Live -Name 'LastRunTime')
        $observed.LastRunUtc = $lastRun
        if ($null -ne $lastRun) {
            $observed.LastTaskResult = Get-WauPsadtOptionalCount -Value (Get-WauPsadtMemberValue -InputObject $Live -Name 'LastTaskResult')
        }
    }

    $healthStatus = $null
    $healthReason = $null
    if ($null -ne $Health) {
        $healthStatus = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Health -Name 'Status')
        $healthReason = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $Health -Name 'Reason')
    }

    # A classification that rests on a task which could not be read is reported as unverified
    # instead of as a definite verdict.
    $healthVerified = ($null -ne $healthStatus)
    if ($null -ne $Snapshot -and ($null -eq $observed.RetryTaskPresent -or $null -eq $observed.CleanupTaskPresent)) {
        $healthVerified = $false
    }

    return [pscustomobject]@{
        CampaignId     = $campaignId
        PackageId      = $packageId
        TargetVersion  = $targetVersion
        Reported       = [bool]$reported
        HealthStatus   = $healthStatus
        HealthReason   = $healthReason
        HealthVerified = [bool]$healthVerified
        Stored         = $stored
        Live           = $observed
    }
}

function Get-WauPsadtStatusRecordList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [AllowEmptyString()][string]$PackageId
    )

    $records = @()
    foreach ($item in $Entry) {
        $recordParams = @{
            RegistryKeyName = [string](Get-WauPsadtMemberValue -InputObject $item -Name 'RegistryKeyName')
            Registry        = (Get-WauPsadtMemberValue -InputObject $item -Name 'Registry')
            Snapshot        = (Get-WauPsadtMemberValue -InputObject $item -Name 'Snapshot')
            Health          = (Get-WauPsadtMemberValue -InputObject $item -Name 'Health')
            Live            = (Get-WauPsadtMemberValue -InputObject $item -Name 'Live')
        }
        $record = Get-WauPsadtCampaignStatusRecord @recordParams
        if (-not [string]::IsNullOrWhiteSpace($PackageId)) {
            if ($null -eq $record.PackageId -or $record.PackageId -ine $PackageId) { continue }
        }
        $records += $record
    }
    return $records
}

function Get-WauPsadtCampaignTaskObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Contract)

    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }

    $nextRunTime = $null
    $lastRunTime = $null
    $lastTaskResult = $null
    if (Get-Command -Name Get-ScheduledTaskInfo -ErrorAction SilentlyContinue) {
        try {
            $info = Get-ScheduledTaskInfo -TaskPath $Contract.TaskPath -TaskName $Contract.TaskName -ErrorAction Stop
            $nextRunTime = Get-WauPsadtMemberValue -InputObject $info -Name 'NextRunTime'
            $lastRunTime = Get-WauPsadtMemberValue -InputObject $info -Name 'LastRunTime'
            $lastTaskResult = Get-WauPsadtMemberValue -InputObject $info -Name 'LastTaskResult'
        }
        catch { }
    }

    # Absence has to stay an observation. The shared observation treats only a structured
    # object-not-found result as an absent task and leaves every other failure unknown.
    $retryObservation = Get-WauPsadtScheduledTaskObservation -TaskPath $Contract.TaskPath -TaskName $Contract.TaskName
    $cleanupObservation = Get-WauPsadtScheduledTaskObservation -TaskPath $Contract.TaskPath -TaskName $Contract.CleanupTaskName

    return [pscustomobject]@{
        RetryTaskPresent   = $retryObservation.Present
        CleanupTaskPresent = $cleanupObservation.Present
        NextRunTime        = $nextRunTime
        LastRunTime        = $lastRunTime
        LastTaskResult     = $lastTaskResult
    }
}

function Get-WauPsadtStatusReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$PackageId,
        [string]$RegistryBasePath = 'HKLM:\SOFTWARE\WauPsadtBridge\Campaigns',
        [string]$InstallRoot,
        [string]$PublicDesktopRoot
    )

    # The native Program Files path only resolves on Windows. Off Windows the collector reports
    # the install root as unknown and still answers for the registry when it is reachable.
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        try { $InstallRoot = Get-WauPsadtBridgeRoot }
        catch { $InstallRoot = $null }
    }

    $templateVersion = $null
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $templateVersion = Get-WauPsadtTemplateVersion -TemplateRoot (Join-Path $InstallRoot 'Template')
    }

    $entries = @()
    $registryAvailable = Test-Path -LiteralPath $RegistryBasePath
    $registryError = $null
    $observationError = $null

    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $observationError = 'Task Scheduler queries are unavailable, so campaign resources and health are reported as unknown.'
    }

    if (-not $registryAvailable) {
        $registryError = "The campaign registry is not available: [$RegistryBasePath]."
    }
    else {
        $keys = $null
        try {
            $keys = @(Get-ChildItem -LiteralPath $RegistryBasePath -ErrorAction Stop)
        }
        catch {
            # An enumeration failure must not look like an empty machine.
            $registryAvailable = $false
            $registryError = "The campaign registry could not be enumerated: $($_.Exception.Message)"
        }

        foreach ($key in @($keys)) {
            if (-not $registryAvailable) { break }
            $raw = $null
            try { $raw = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { }

            $snapshot = $null
            $health = $null
            $live = $null
            if ($null -ne $raw -and $null -eq $observationError) {
                try {
                    $contractParams = @{ Registry = $raw; InstallRoot = $InstallRoot }
                    if (-not [string]::IsNullOrWhiteSpace($PublicDesktopRoot)) { $contractParams.PublicDesktopRoot = $PublicDesktopRoot }
                    $contract = Get-WauPsadtCampaignContract @contractParams
                    $snapshot = Get-WauPsadtCampaignSnapshot -Registry $raw -Contract $contract -RegistryKeyName ([string]$key.PSChildName)
                    $health = Get-WauPsadtCampaignHealth -Snapshot $snapshot
                    $live = Get-WauPsadtCampaignTaskObservation -Contract $contract
                }
                catch {
                    $snapshot = $null
                    $health = $null
                    $live = $null
                }
            }

            $entries += [pscustomobject]@{
                RegistryKeyName = [string]$key.PSChildName
                Registry        = $raw
                Snapshot        = $snapshot
                Health          = $health
                Live            = $live
            }
        }
    }

    $baseline = Get-WauPsadtSupportedBaseline -RepositoryRoot $RepositoryRoot
    $records = @(Get-WauPsadtStatusRecordList -Entry $entries -PackageId $PackageId)

    return [pscustomobject]@{
        RepositoryRoot         = $RepositoryRoot
        InstallRoot            = $InstallRoot
        RegistryBasePath       = $RegistryBasePath
        RegistryAvailable      = [bool]$registryAvailable
        RegistryError          = $registryError
        ObservationError       = $observationError
        UnreadableCampaignCount = @($entries | Where-Object { $null -eq $_.Registry }).Count
        TemplateVersion        = $templateVersion
        SupportedWauBaseline   = $baseline.WauBaseline
        SupportedPsadtBaseline = $baseline.PsadtBaseline
        PackageIdFilter        = Get-WauPsadtOptionalText -Value $PackageId
        CampaignCount          = $records.Count
        Campaigns              = $records
        ExitCode               = if ($registryAvailable) { 0 } else { 1 }
    }
}
