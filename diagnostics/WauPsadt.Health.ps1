# Read-only health checks for an installed bridge.
#
# Every check reports Pass, Fail, or Unknown. A check fails only when it established that the
# property does not hold, including an expected file that exists but cannot be read. It reports
# Unknown when it could not obtain the evidence at all. Nothing is repaired, started, or
# registered, and the checks reuse the catalog validator, the campaign rules, the shared WAU
# contract, and the runtime Winget lookup instead of restating them.

function Get-WauPsadtInstallState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallRoot)

    $statePath = Join-Path $InstallRoot 'install-state.json'
    $result = [pscustomobject]@{
        Path     = $statePath
        Present  = $false
        Readable = $false
        Invalid  = $false
        Error    = $null
        Values   = $null
    }

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $result }

    $result.Present = $true
    $content = $null
    try {
        $content = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # The file is there but could not be read at all, which is not a verdict about its content.
        $result.Error = $_.Exception.Message
        return $result
    }

    try {
        $values = $content | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $values) { throw 'The installation state is empty.' }
        $result.Values = $values
        $result.Readable = $true
    }
    catch {
        $result.Error = $_.Exception.Message
        $result.Invalid = $true
    }

    return $result
}

function Get-WauPsadtTemplateEntryPointCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TemplateRoot)

    # Mirrors the entry points in template/TECHNICAL-REFERENCE.md section 4.
    $required = @(
        (Join-Path $TemplateRoot 'install.ps1'),
        (Join-Path $TemplateRoot 'Invoke-AppDeployToolkit.ps1'),
        (Join-Path $TemplateRoot 'Cleanup-WauBridgePackage.ps1'),
        (Join-Path (Join-Path $TemplateRoot 'Config') 'config.psd1'),
        (Join-Path (Join-Path $TemplateRoot 'Messages') 'message-contract.json'),
        (Join-Path (Join-Path $TemplateRoot 'Framework') 'WauBridge.ps1')
    )

    return [pscustomobject]@{
        Root        = $TemplateRoot
        RootPresent = (Test-Path -LiteralPath $TemplateRoot -PathType Container)
        Required    = $required
        Missing     = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    }
}

function Get-WauPsadtWauLayoutCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WauRoot)

    $functionsRoot = Join-Path $WauRoot 'functions'
    $updateAppPath = Join-Path $functionsRoot 'Update-App.ps1'
    $backupPath = Join-Path $functionsRoot $script:UpdateAppBackupName

    $layout = [pscustomobject]@{
        Root             = $WauRoot
        FunctionsPresent = (Test-Path -LiteralPath $functionsRoot -PathType Container)
        UpdateAppPresent = (Test-Path -LiteralPath $updateAppPath -PathType Leaf)
        SubmitPresent    = (Test-Path -LiteralPath (Join-Path $functionsRoot 'Submit-WauPsadtUpdate.ps1') -PathType Leaf)
        ContractPresent  = (Test-Path -LiteralPath (Join-Path $functionsRoot 'WauPsadt.CampaignContract.ps1') -PathType Leaf)
        HandoffPresent   = $false
        HandoffError     = $null
        BackupPath       = $backupPath
        BackupPresent    = (Test-Path -LiteralPath $backupPath -PathType Leaf)
        BackupIsOriginal = $null
        BackupHash       = $null
        BackupError      = $null
        InstalledVersion = Get-WauInstalledVersion -WauRoot $WauRoot
    }

    if ($layout.UpdateAppPresent) {
        try { $layout.HandoffPresent = Test-WauUpdateAppContainsHandoff -LiteralPath $updateAppPath }
        catch { $layout.HandoffError = $_.Exception.Message }
    }

    if ($layout.BackupPresent) {
        try {
            $layout.BackupHash = Get-NormalizedSha256 -LiteralPath $backupPath
            $layout.BackupIsOriginal = Test-WauOriginalUpdateAppBackup -LiteralPath $backupPath
        }
        catch { $layout.BackupError = $_.Exception.Message }
    }

    return $layout
}

function Get-WauPsadtWingetObservation {
    [CmdletBinding()]
    param()

    # The runtime lookup reports an absent Winget and an unreadable one the same way, so the
    # observation exposes the error and the check stays unknown unless a path was resolved.
    $observation = [pscustomobject]@{ Path = $null; Error = $null }
    if (-not (Get-Command -Name Get-WauBridgeWingetExecutablePath -ErrorAction SilentlyContinue)) {
        $observation.Error = 'the runtime Winget lookup is not available'
        return $observation
    }

    try { $observation.Path = Get-WauBridgeWingetExecutablePath }
    catch { $observation.Error = $_.Exception.Message }
    return $observation
}

function New-WauPsadtHealthCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)][AllowEmptyString()][string]$Detail)
    return [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

function Get-WauPsadtCampaignCheck {
    [CmdletBinding()]
    param([AllowNull()]$StatusReport)

    if ($null -eq $StatusReport -or -not $StatusReport.RegistryAvailable) {
        return New-WauPsadtHealthCheck -Name 'campaigns' -Status 'Unknown' -Detail 'the campaign registry is not available'
    }

    $definite = 0
    $unclassified = 0
    foreach ($campaign in $StatusReport.Campaigns) {
        $health = [string]$campaign.HealthStatus
        # Only a verified verdict counts. BlockedUnverified means the task evidence could not be
        # read, which is an unknown outcome rather than a definite problem.
        if ($campaign.HealthVerified -eq $true -and $health -in @('BlockedForeign', 'RecoverableOrphan')) { $definite++ }
        elseif ($campaign.HealthVerified -eq $true -and $health -eq 'Healthy') { }
        else { $unclassified++ }
    }

    if ($definite -gt 0) {
        return New-WauPsadtHealthCheck -Name 'campaigns' -Status 'Fail' -Detail ("{0} of {1} campaigns need attention" -f $definite, $StatusReport.CampaignCount)
    }
    if ($unclassified -gt 0) {
        return New-WauPsadtHealthCheck -Name 'campaigns' -Status 'Unknown' -Detail ("{0} of {1} campaigns could not be classified" -f $unclassified, $StatusReport.CampaignCount)
    }
    return New-WauPsadtHealthCheck -Name 'campaigns' -Status 'Pass' -Detail ("{0} campaigns are healthy" -f $StatusReport.CampaignCount)
}

function Get-WauPsadtHealthReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$InstallRoot,
        [string]$WauRoot,
        [string]$PackageId
    )

    $checks = @()

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        try { $InstallRoot = Get-WauPsadtBridgeRoot }
        catch { $InstallRoot = $null }
    }

    $installState = $null
    $templateCheck = $null
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $installState = Get-WauPsadtInstallState -InstallRoot $InstallRoot
        $templateCheck = Get-WauPsadtTemplateEntryPointCheck -TemplateRoot (Join-Path $InstallRoot 'Template')
    }

    $bridgeFound = $false
    if ($null -ne $installState -and $installState.Present) { $bridgeFound = $true }
    if ($null -ne $templateCheck -and $templateCheck.RootPresent) { $bridgeFound = $true }

    if (-not $bridgeFound) {
        $checks += (New-WauPsadtHealthCheck -Name 'bridge-installation' -Status 'Fail' -Detail 'no bridge installation was found')
    }
    elseif ($null -ne $installState -and $installState.Present -and -not $installState.Readable) {
        if ($installState.Invalid) {
            $checks += (New-WauPsadtHealthCheck -Name 'bridge-installation' -Status 'Fail' -Detail ("the installation state is invalid: {0}" -f $installState.Error))
        }
        else {
            $checks += (New-WauPsadtHealthCheck -Name 'bridge-installation' -Status 'Unknown' -Detail ("the installation state could not be read: {0}" -f $installState.Error))
        }
    }
    else {
        $checks += (New-WauPsadtHealthCheck -Name 'bridge-installation' -Status 'Pass' -Detail 'the bridge installation is present')
    }

    if ($null -eq $templateCheck -or -not $templateCheck.RootPresent) {
        $checks += (New-WauPsadtHealthCheck -Name 'template-entry-points' -Status 'Unknown' -Detail 'no installed template was found')
    }
    elseif ($templateCheck.Missing.Count -gt 0) {
        $checks += (New-WauPsadtHealthCheck -Name 'template-entry-points' -Status 'Fail' -Detail ("missing: {0}" -f (($templateCheck.Missing | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')))
    }
    else {
        $checks += (New-WauPsadtHealthCheck -Name 'template-entry-points' -Status 'Pass' -Detail 'every required entry point is present')
    }

    # Catalog validity reuses the standalone validator.
    $catalogPath = $null
    if ($null -ne $installState -and $installState.Readable) {
        $catalogPath = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $installState.Values -Name 'catalogPath')
    }
    if ([string]::IsNullOrWhiteSpace($catalogPath) -and -not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        $catalogPath = Join-Path $InstallRoot 'bridge.catalog.json'
    }

    $catalogResult = $null
    if ([string]::IsNullOrWhiteSpace($catalogPath)) {
        $checks += (New-WauPsadtHealthCheck -Name 'catalog' -Status 'Unknown' -Detail 'no installed catalog was found')
    }
    elseif (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        $checks += (New-WauPsadtHealthCheck -Name 'catalog' -Status 'Fail' -Detail ("the installed catalog was not found: {0}" -f $catalogPath))
    }
    else {
        $catalogReadable = $true
        try { $null = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 -ErrorAction Stop }
        catch { $catalogReadable = $false }

        if (-not $catalogReadable) {
            $checks += (New-WauPsadtHealthCheck -Name 'catalog' -Status 'Unknown' -Detail 'the installed catalog could not be read')
        }
        else {
            $catalogResult = Get-WauPsadtCatalogValidation -Path $catalogPath
            switch ($catalogResult.ExitCode) {
                0 { $checks += (New-WauPsadtHealthCheck -Name 'catalog' -Status 'Pass' -Detail ("{0} entries are valid" -f $catalogResult.EntryCount)) }
                2 { $checks += (New-WauPsadtHealthCheck -Name 'catalog' -Status 'Fail' -Detail ("{0} of {1} entries are invalid" -f $catalogResult.InvalidEntryCount, $catalogResult.EntryCount)) }
                default { $checks += (New-WauPsadtHealthCheck -Name 'catalog' -Status 'Fail' -Detail 'the installed catalog is structurally invalid') }
            }
        }
    }

    # The WAU handoff and its backup reuse the shared read-only contract.
    $layout = $null
    if ([string]::IsNullOrWhiteSpace($WauRoot) -and $null -ne $installState -and $installState.Readable) {
        $WauRoot = Get-WauPsadtOptionalText -Value (Get-WauPsadtMemberValue -InputObject $installState.Values -Name 'wauInstallLocation')
    }
    if (-not [string]::IsNullOrWhiteSpace($WauRoot)) {
        $layout = Get-WauPsadtWauLayoutCheck -WauRoot $WauRoot
    }

    if ($null -eq $layout) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-handoff' -Status 'Unknown' -Detail 'no Winget-AutoUpdate location was found')
    }
    elseif (-not $layout.FunctionsPresent) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-handoff' -Status 'Fail' -Detail 'the Winget-AutoUpdate functions folder is missing')
    }
    elseif ($null -ne $layout.HandoffError) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-handoff' -Status 'Unknown' -Detail ("the handoff could not be read: {0}" -f $layout.HandoffError))
    }
    elseif (-not $layout.UpdateAppPresent -or -not $layout.SubmitPresent -or -not $layout.ContractPresent) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-handoff' -Status 'Fail' -Detail 'the installed Winget-AutoUpdate functions are incomplete')
    }
    elseif (-not $layout.HandoffPresent) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-handoff' -Status 'Fail' -Detail 'Update-App.ps1 does not contain the bridge handoff')
    }
    else {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-handoff' -Status 'Pass' -Detail 'the bridge handoff is installed')
    }

    if ($null -eq $layout -or -not $layout.UpdateAppPresent -or -not $layout.HandoffPresent) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-backup' -Status 'Unknown' -Detail 'there is no installed handoff that needs a restorable backup')
    }
    elseif (-not $layout.BackupPresent) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-backup' -Status 'Fail' -Detail ("the original Winget-AutoUpdate backup is missing: {0}" -f $script:UpdateAppBackupName))
    }
    elseif ($null -ne $layout.BackupError -or $null -eq $layout.BackupIsOriginal) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-backup' -Status 'Unknown' -Detail 'the backup could not be read or hashed')
    }
    elseif ($layout.BackupIsOriginal -ne $true) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-backup' -Status 'Fail' -Detail 'the backup is not the supported Winget-AutoUpdate file')
    }
    else {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-backup' -Status 'Pass' -Detail 'the backup matches the supported Winget-AutoUpdate file')
    }

    $supportedVersion = $script:SupportedWauVersion
    if ($null -eq $layout -or $null -eq $layout.InstalledVersion) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-version' -Status 'Unknown' -Detail 'the installed Winget-AutoUpdate version could not be read')
    }
    elseif ($layout.InstalledVersion -ne $supportedVersion) {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-version' -Status 'Fail' -Detail ("installed {0}, supported {1}" -f $layout.InstalledVersion, $supportedVersion))
    }
    else {
        $checks += (New-WauPsadtHealthCheck -Name 'wau-version' -Status 'Pass' -Detail ("{0} is the supported version" -f $supportedVersion))
    }

    $winget = Get-WauPsadtWingetObservation
    if ($null -ne $winget.Path) {
        $checks += (New-WauPsadtHealthCheck -Name 'winget' -Status 'Pass' -Detail $winget.Path)
    }
    else {
        $detail = 'the runtime Winget lookup did not resolve a path'
        if ($null -ne $winget.Error) { $detail = $detail + (": {0}" -f $winget.Error) }
        $checks += (New-WauPsadtHealthCheck -Name 'winget' -Status 'Unknown' -Detail $detail)
    }

    $statusReport = Get-WauPsadtStatusReport -RepositoryRoot $RepositoryRoot -PackageId $PackageId
    $checks += (Get-WauPsadtCampaignCheck -StatusReport $statusReport)

    $failed = @($checks | Where-Object { $_.Status -eq 'Fail' })

    return [pscustomobject]@{
        RepositoryRoot      = $RepositoryRoot
        InstallRoot         = $InstallRoot
        WauRoot             = $WauRoot
        SupportedWauVersion = $supportedVersion
        SupportedAppHash    = $script:SupportedWauUpdateAppSha256
        BackupName          = $script:UpdateAppBackupName
        InstallState        = $installState
        Template            = $templateCheck
        Catalog             = $catalogResult
        WauLayout           = $layout
        Campaigns           = $statusReport
        Checks              = $checks
        FailedCheckCount    = $failed.Count
        ExitCode            = if ($failed.Count -gt 0) { 1 } else { 0 }
    }
}
