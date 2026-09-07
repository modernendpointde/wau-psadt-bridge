$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$templateRoot = Join-Path $repoRoot 'template'
$examplePath = Join-Path $repoRoot 'catalog/campaign.example.json'

. (Join-Path $templateRoot 'App/WauBridge.Detect.ps1')
. (Join-Path $templateRoot 'Framework/WauBridge.ps1')
. (Join-Path $templateRoot 'Framework/WauBridge.Winget.ps1')

$example = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([int]$example.schemaVersion -eq 1) 'example schemaVersion'
Assert-True ($example.wingetId -eq 'Google.Chrome') 'example wingetId'
Assert-True (@($example.processes) -contains 'chrome') 'example processes'

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-psadt-campaignjson-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $work 'App') | Out-Null
Copy-Item -LiteralPath (Join-Path $templateRoot 'App/WauBridge.Config.ps1') -Destination (Join-Path $work 'App/WauBridge.Config.ps1')
Copy-Item -LiteralPath $examplePath -Destination (Join-Path $work 'WauBridge.Campaign.json')

. (Join-Path $work 'App/WauBridge.Config.ps1')
Assert-True (-not $WauBridgeConfig.Contains('PackageId')) 'identity not in config'
Assert-True (-not $WauBridgeConfig.Contains('DisplayName')) 'display name not in config'
Assert-True (-not $WauBridgeConfig.Contains('Detection')) 'no Detection block'
Assert-True (-not $WauBridgeConfig.Contains('Name')) 'no Name field'
Assert-True (-not $WauBridgeConfig.Contains('Uninstall')) 'no uninstall block'
Assert-True (-not $WauBridgeConfig.Retry.Contains('DeferralScope')) 'no DeferralScope'
Assert-True (-not $WauBridgeConfig.Retry.Contains('RegistryBasePath')) 'no RegistryBasePath in config'
Assert-True (-not $WauBridgeConfig.Retry.Contains('TaskPath')) 'no TaskPath in config'
Assert-True (-not $WauBridgeConfig.Contains('PackageFamilyId')) 'no PackageFamilyId'
$null = Import-WauBridgeCampaignJson -ScriptRoot $work
Assert-True (Test-WauBridgeCampaignJsonLoaded) 'campaign loaded'
Assert-True ($WauBridgeConfig.PackageId -eq 'Google.Chrome') 'PackageId from campaign'
Assert-True ($WauBridgeConfig.DisplayName -eq 'Google Chrome') 'DisplayName from campaign'
Assert-True ((Get-WauBridgeWingetDetectAppId) -eq 'Google.Chrome') 'winget id is PackageId'
Assert-True (-not $WauBridgeConfig.Contains('Name')) 'overlay does not add Name'
Assert-True (-not $WauBridgeConfig.Contains('Detection')) 'overlay does not add Detection'
Assert-True (-not $WauBridgeConfig.Contains('Install')) 'no Install block'
Assert-True (-not $WauBridgeConfig.Contains('Winget')) 'no Winget block'
Assert-True (-not $WauBridgeConfig.Contains('Publisher')) 'no Publisher'
Assert-True ([int]$WauBridgeConfig.Retry.Days -eq 3) 'Days from config'
Assert-True ([int]$WauBridgeConfig.Retry.TimesPerDay -eq 1) 'TimesPerDay from config'
Assert-True (-not $WauBridgeConfig.Retry.Contains('DeferTimes')) 'no DeferTimes in config'
Assert-True (-not $WauBridgeConfig.Retry.Contains('DeadlineHours')) 'no DeadlineHours in config'
Assert-True (-not $WauBridgeConfig.Retry.Contains('BlockMinutes')) 'no BlockMinutes in config'
Assert-True ([bool]$WauBridgeConfig.Retry.SkipWeekends) 'SkipWeekends from config'
Assert-True ($WauBridgeConfig.Retry.HoursStart -eq '08:00') 'HoursStart from config'
Assert-True ($WauBridgeConfig.Retry.HoursEnd -eq '17:00') 'HoursEnd from config'
Assert-True ([string]$WauBridgeConfig.ProcessDefinitions[0] -eq 'chrome') 'process name'
Assert-True ($WauBridgeConfig.Localization.Culture -eq 'Auto') 'culture Auto'
Assert-True ($WauBridgeConfig.Localization.DefaultCulture -eq 'en-US') 'default culture en-US'
Assert-True ([bool]$WauBridgeConfig.UserExperience.ShowProgressSilent) 'progress when silent'
Assert-True ([bool]$WauBridgeConfig.UserExperience.ShowProgressInteractive) 'progress when interactive'
Assert-True ([bool]$WauBridgeConfig.UserExperience.ShowSuccess) 'success prompt on upgrade'
Assert-True ([int]$WauBridgeConfig.UserExperience.CloseCountdownSeconds -eq 300) 'close countdown from config'
Assert-True ($null -ne (ConvertTo-Version '140.0.7339.127')) 'ConvertTo-Version'
Assert-True ($WauBridgeConfig.TargetVersion -eq (ConvertTo-Version '140.0.7339.127')) 'TargetVersion parsed'

foreach ($invalidProcessName in @('chrome*', 'chrome?', '[c]hrome', 'chrome.exe', 'chrome/path')) {
    $invalidCampaign = [ordered]@{
        schemaVersion = 1
        wingetId = 'Google.Chrome'
        displayName = 'Google Chrome'
        targetVersion = '140.0.7339.127'
        processes = @($invalidProcessName)
    }
    ($invalidCampaign | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $work 'WauBridge.Campaign.json') -Encoding UTF8
    $rejected = $false
    try { $null = Import-WauBridgeCampaignJson -ScriptRoot $work }
    catch { $rejected = $_.Exception.Message -match 'invalid Get-Process name' }
    Assert-True $rejected "invalid campaign process [$invalidProcessName] is rejected"
}
Copy-Item -LiteralPath $examplePath -Destination (Join-Path $work 'WauBridge.Campaign.json') -Force
$null = Import-WauBridgeCampaignJson -ScriptRoot $work

$upgradeArgs = Get-WauBridgeWingetUpgradeArgumentList -AppId 'Google.Chrome'
$expected = @(
    'upgrade','--id','Google.Chrome','--exact','--source','winget','--scope','machine',
    '--silent','--disable-interactivity','--accept-package-agreements','--accept-source-agreements'
)
Assert-True ($upgradeArgs.Count -eq $expected.Count) 'upgrade arg count'
for ($i = 0; $i -lt $expected.Count; $i++) {
    Assert-True ($upgradeArgs[$i] -ceq $expected[$i]) ("upgrade arg {0}: {1}" -f $i, $upgradeArgs[$i])
}
Assert-True ($upgradeArgs -notcontains '--version') 'no --version'
Assert-True ($upgradeArgs -notcontains '--force') 'no --force'

Assert-True (Test-WauBridgeSessionGuard -ProcessesRunning $false) 'session guard without processes'
Assert-True ($script:WauBridgeMutexName -eq 'Global\WauPsadtBridge.Update') 'mutex name'

$invokeText = Get-Content -LiteralPath (Join-Path $templateRoot 'Invoke-AppDeployToolkit.ps1') -Raw
Assert-True ($invokeText -match '\$schedule = Register-WauBridgeSchedule -SourceRoot \$PSScriptRoot -Operation \$script:WauBridgeState\.Operation') 'bridge register without StartTaskNow'
Assert-True ($invokeText -notmatch '-StartTaskNow') 'no StartTaskNow in bridge bootstrap'
Assert-True ($invokeText -match 'WauBridge\.Campaign\.json is required') 'campaign json required'
Assert-True ($invokeText -match 'CloseProcessesCountdown = \[int\]\$WauBridgeConfig\.UserExperience\.CloseCountdownSeconds') 'deadline countdown from config'
Assert-True ($invokeText -match '(?s)Add-WauBridgePromptShown -Context \$script:WauBridgeState\.Context\s+Show-ADTInstallationWelcome') 'prompt count is recorded before Welcome'
Assert-True ($invokeText -notmatch '(?s)Show-ADTInstallationWelcome @welcomeParams\s+Add-WauBridgePromptShown') 'Welcome does not run before prompt count'
$psadtConfig = Get-Content -LiteralPath (Join-Path $templateRoot 'Config/config.psd1') -Raw
Assert-True ($psadtConfig -match "CompanyName = 'WAU PSADT Bridge'") 'PSADT company name'
Assert-True ($psadtConfig -match 'DefaultTimeout = 3300') 'PSADT dialog timeout'
Assert-True ($invokeText -match 'Import-WauBridgeCampaignJson') 'invoke imports campaign json'
Assert-True ($invokeText -notmatch 'function Uninstall-ADTDeployment') 'no uninstall lifecycle'
Assert-True ($invokeText -notmatch 'function Repair-ADTDeployment') 'no repair lifecycle'
Assert-True ($invokeText -match "ValidateSet\('Bootstrap', 'RetryTask'\)") 'invocation sources are Bootstrap and RetryTask'
Assert-True ($invokeText -match "AppScriptVersion\s+=\s+\[version\]'0\.1\.1'") 'AppScriptVersion is 0.1.1'
Assert-True ($invokeText -match "AppScriptDate\s+=\s+'2026-09-05'") 'AppScriptDate is 2026-09-05'
Assert-True ($invokeText -notmatch "'Shortcut'") 'no Shortcut invocation source'
$compatShortcutText = Get-Content -LiteralPath (Join-Path $templateRoot 'Framework/WauBridge.Compatibility.ps1') -Raw
Assert-True ($compatShortcutText -match 'Start-ScheduledTask -TaskPath') 'shortcut arguments start the scheduled task'
Assert-True ($compatShortcutText -match 'function Grant-WauBridgeUpdateTaskRunAccess') 'users may run the retry task'
Assert-True ($compatShortcutText -notmatch 'StartTaskNow') 'Register-WauBridgeSchedule has no StartTaskNow'
Assert-True ($compatShortcutText -notmatch 'function Test-WauBridgeActiveCampaignForPackageId') 'no unused active-campaign wrapper'
Assert-True ($compatShortcutText -match "Join-Path 'Stage'") 'deferred campaigns still stage under Stage'
Assert-True ($compatShortcutText -notmatch "Join-Path 'Work'") 'Stage path is not the Work root'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $templateRoot 'Invoke-AppDeployToolkit.exe') -PathType Leaf)) 'no unused outer PSADT launcher'
Assert-True ($invokeText -notmatch "'Direct'") 'no Direct invocation source'
Assert-True ($invokeText -notmatch '\$bridgeMode') 'no bridgeMode switch'
Assert-True ($invokeText -notmatch 'Test-WauBridgeGeneralDeferralScope') 'no general deferral scope'
Assert-True ($invokeText -notmatch 'FreshInstallSuccess') 'no FreshInstall success UX'
Assert-True ($invokeText -notmatch 'ShowProgressOnFreshInstall') 'no FreshInstall progress UX'
Assert-True ($invokeText -match 'Retry\.Days') 'invoke uses Days from config'
Assert-True ($invokeText -match 'ConsumedNow') 'first dialog consumes today'
Assert-True ($invokeText -notmatch 'Retry\.DeferTimes') 'invoke does not use DeferTimes'
Assert-True ($invokeText -notmatch 'Retry\.DeferralCount') 'invoke does not use DeferralCount'
Assert-True ($invokeText -match 'ShowProgressInteractive') 'invoke uses ShowProgressInteractive'
Assert-True ($invokeText -match 'ShowProgressSilent') 'invoke uses ShowProgressSilent'
Assert-True ($invokeText -match 'Provisioning is active and a catalog process is running') 'provisioning skips winget while a catalog process is running'
Assert-True ($invokeText -match '(?s)session guard blocked[\s\S]{0,400}Invoke-WauBridgeScheduleCatchUp') 'session guard catch-up keeps a future retry'
Assert-True ($invokeText -match 'function Invoke-WauBridgeRetryCatchUpSafely') 'retry catch-up helper exists'
Assert-True ($invokeText -match '(?s)mutex is held by another deployment[\s\S]{0,250}Invoke-WauBridgeRetryCatchUpSafely') 'mutex 1618 still catch-up'
Assert-True ($invokeText -match '(?s)catch \{\s+Invoke-WauBridgeRetryCatchUpSafely\s+throw') 'failed upgrade still catch-up'
Assert-True ($invokeText -notmatch 'ShowProgressOnUpgradeWhen') 'invoke does not use old progress names'
Assert-True ($invokeText -notmatch 'ShowSuccessOnUpgrade') 'invoke does not use ShowSuccessOnUpgrade'
Assert-True ($invokeText -match 'Get-WauBridgeLocalizationResource -Configuration \$WauBridgeConfig -ScriptRoot \$PSScriptRoot -Refresh') 'localization refresh after Open-ADTSession'

$messagesPath = Join-Path $templateRoot 'Messages'
$contractPath = Join-Path $messagesPath 'message-contract.json'
$autoEnGb = Resolve-WauBridgeCulturePack -RequestedCulture 'Auto' -InteractiveCulture 'en-GB' -DefaultCulture 'en-US' -MessagesPath $messagesPath -ContractPath $contractPath
Assert-True ($autoEnGb.ResolvedCulture -eq 'en-US') 'Auto en-GB falls back to en-US pack'
$autoDe = Resolve-WauBridgeCulturePack -RequestedCulture 'Auto' -InteractiveCulture 'de-DE' -DefaultCulture 'en-US' -MessagesPath $messagesPath -ContractPath $contractPath
Assert-True ($autoDe.ResolvedCulture -eq 'de-DE') 'Auto de-DE uses de-DE pack'
$autoEmpty = Resolve-WauBridgeCulturePack -RequestedCulture 'Auto' -InteractiveCulture '' -DefaultCulture 'en-US' -MessagesPath $messagesPath -ContractPath $contractPath
Assert-True ($autoEmpty.ResolvedCulture -eq 'en-US') 'Auto without interactive user uses DefaultCulture'
$coreText = Get-Content -LiteralPath (Join-Path $templateRoot 'Framework/WauBridge.Core.ps1') -Raw
Assert-True ($coreText -match 'Control Panel\\International\\User Profile') 'interactive culture reads the user profile'
Assert-True ($coreText -notmatch 'CurrentUICulture') 'interactive culture does not use the process UI culture'

foreach ($packName in @('de-DE.psd1', 'en-US.psd1')) {
    $packPath = Join-Path $templateRoot ('Messages/' + $packName)
    $bytes = [System.IO.File]::ReadAllBytes($packPath)
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) ("UTF-8 BOM on $packName")
}

$detectText = Get-Content -LiteralPath (Join-Path $templateRoot 'App/WauBridge.Detect.ps1') -Raw
Assert-True ($detectText -match 'Get-WauBridgeWingetInstalledVersion') 'versioned winget detect'

$installText = Get-Content -LiteralPath (Join-Path $templateRoot 'App/WauBridge.Install.ps1') -Raw
Assert-True ($installText -match 'Invoke-WauBridgeWingetUpgrade') 'install uses bridge upgrade'
Assert-True ($installText -notmatch 'Invoke-WauBridgeVendorWingetInstall') 'vendor winget install removed'

Remove-Item -LiteralPath $work -Recurse -Force
Write-Output 'CampaignJson.Tests: OK'
