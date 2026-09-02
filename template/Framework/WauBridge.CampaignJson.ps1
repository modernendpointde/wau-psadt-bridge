$script:WauBridgeCampaignJsonLoaded = $false
$script:WauBridgeMutexName = 'Global\WauPsadtBridge.Update'

function Test-WauBridgeCampaignJsonLoaded {
    [CmdletBinding()]
    param()
    return [bool]$script:WauBridgeCampaignJsonLoaded
}

function Get-WauBridgeCampaignJsonPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptRoot)
    return (Join-Path $ScriptRoot 'WauBridge.Campaign.json')
}

function Import-WauBridgeCampaignJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $script:WauBridgeCampaignJsonLoaded = $false
    $campaignPath = Get-WauBridgeCampaignJsonPath -ScriptRoot $ScriptRoot
    if (-not (Test-Path -LiteralPath $campaignPath -PathType Leaf)) {
        return $false
    }

    $raw = Get-Content -LiteralPath $campaignPath -Raw -Encoding UTF8 -ErrorAction Stop
    $campaign = $raw | ConvertFrom-Json -ErrorAction Stop
    if ([int]$campaign.schemaVersion -ne 1) {
        throw "WauBridge.Campaign.json schemaVersion must be 1: [$campaignPath]."
    }

    $wingetId = [string]$campaign.wingetId
    $displayName = [string]$campaign.displayName
    $targetVersionRaw = [string]$campaign.targetVersion
    if ([string]::IsNullOrWhiteSpace($targetVersionRaw) -and $campaign.PSObject.Properties.Name -contains 'targetVersionRaw') {
        $targetVersionRaw = [string]$campaign.targetVersionRaw
    }
    $processes = @($campaign.processes)

    if ([string]::IsNullOrWhiteSpace($wingetId) -or $wingetId -match '[\\/:*?"<>|]') {
        throw "WauBridge.Campaign.json wingetId is missing or contains illegal characters: [$campaignPath]."
    }
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        throw "WauBridge.Campaign.json displayName is missing: [$campaignPath]."
    }
    $targetVersion = ConvertTo-Version $targetVersionRaw
    if (-not $targetVersion) {
        throw "WauBridge.Campaign.json targetVersion is not parseable: [$targetVersionRaw]."
    }
    if ($processes.Count -lt 1) {
        throw "WauBridge.Campaign.json processes must contain at least one process name: [$campaignPath]."
    }

    $processDefinitions = foreach ($processName in $processes) {
        $name = [string]$processName
        if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\\/:]' -or $name -match '\.exe$') {
            throw "WauBridge.Campaign.json processes contains an invalid Get-Process name: [$name]."
        }
        $name
    }

    $WauBridgeConfig.PackageId = $wingetId
    $WauBridgeConfig.DisplayName = $displayName
    $WauBridgeConfig.TargetVersion = $targetVersion
    $WauBridgeConfig.ProcessDefinitions = @($processDefinitions)

    $script:WauBridgeCampaignJsonLoaded = $true
    return $true
}

function Enter-WauBridgeMutex {
    [CmdletBinding()]
    param()

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, $script:WauBridgeMutexName, [ref]$createdNew)
    try {
        if (-not $mutex.WaitOne(0)) {
            $mutex.Dispose()
            return $null
        }
    }
    catch [System.Threading.AbandonedMutexException] {
    }
    return $mutex
}

function Exit-WauBridgeMutex {
    [CmdletBinding()]
    param($Mutex)

    if ($null -eq $Mutex) { return }
    try { $null = $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}

function Test-WauBridgeHasInteractiveUser {
    [CmdletBinding()]
    param()

    try {
        $active = @(Get-ADTLoggedOnUser | Where-Object { $_.IsActiveUserSession })
        return ($active.Count -eq 1)
    }
    catch {
        Write-WauBridgeLog -Message ("Get-ADTLoggedOnUser failed: {0}" -f $_.Exception.Message) -Severity 2
        return $false
    }
}

function Test-WauBridgeSessionGuard {
    [CmdletBinding()]
    param([bool]$ProcessesRunning)

    if (-not $ProcessesRunning) { return $true }

    $loggedOn = @()
    try {
        $loggedOn = @(Get-ADTLoggedOnUser)
    }
    catch {
        Write-WauBridgeLog -Message ("Get-ADTLoggedOnUser failed: {0}" -f $_.Exception.Message) -Severity 2
        return $false
    }

    $active = @($loggedOn | Where-Object { $_.IsActiveUserSession })
    if ($active.Count -ne 1) {
        Write-WauBridgeLog -Message ("Bridge session guard: active sessions=[{0}]." -f $active.Count)
        return $false
    }

    $sessionId = [int]$active[0].SessionId
    foreach ($processDefinition in @($WauBridgeConfig.ProcessDefinitions)) {
        $processName = [string]$processDefinition
        if ([string]::IsNullOrWhiteSpace($processName)) { continue }
        $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        foreach ($process in $running) {
            if ([int]$process.SessionId -ne $sessionId) {
                Write-WauBridgeLog -Message ("Bridge session guard: process [{0}] session [{1}] != user session [{2}]." -f $processName, $process.SessionId, $sessionId)
                return $false
            }
        }
    }

    return $true
}
