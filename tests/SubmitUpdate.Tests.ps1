$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$wauFunctions = Join-Path $repoRoot 'wau'
$catalogSource = Join-Path $repoRoot 'catalog/apps.json'

$script:WauPsadtTestLog = @()
. (Join-Path $wauFunctions 'Submit-WauPsadtUpdate.ps1')
$script:WauPsadtForceSystemContext = $true

$updateApp = Get-Content -LiteralPath (Join-Path $wauFunctions 'Update-App.ps1') -Raw
Assert-True ($updateApp -match 'if \(Submit-WauPsadtUpdate -App \$app -Source \$src\) \{\s*return\s*\}') 'Update-App hands off before mods'
$toastIndex = $updateApp.IndexOf('Start-NotifTask')
$handoffIndex = $updateApp.IndexOf('Submit-WauPsadtUpdate')
$modsIndex = $updateApp.IndexOf('Test-Mods')
Assert-True ($handoffIndex -ge 0 -and $handoffIndex -lt $toastIndex -and $handoffIndex -lt $modsIndex) 'handoff precedes toast and mods'

$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = Join-Path ([System.IO.Path]::GetTempPath()) ('missing-catalog-' + [guid]::NewGuid().ToString('N') + '.json')
$failedClosed = $false
try { $null = Get-WauPsadtBridgeCatalog }
catch { $failedClosed = $_.Exception.Message -match 'missing' }
Assert-True $failedClosed 'missing catalog aborts the cycle'

$invalidPath = Join-Path ([System.IO.Path]::GetTempPath()) ('invalid-catalog-' + [guid]::NewGuid().ToString('N') + '.json')
'{ not json' | Set-Content -LiteralPath $invalidPath -Encoding UTF8
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $invalidPath
$failedParse = $false
try { $null = Get-WauPsadtBridgeCatalog }
catch { $failedParse = $_.Exception.Message -match 'parsed' }
Assert-True $failedParse 'unreadable catalog aborts the cycle'
Remove-Item -LiteralPath $invalidPath -Force

$badSchema = Join-Path ([System.IO.Path]::GetTempPath()) ('bad-schema-' + [guid]::NewGuid().ToString('N') + '.json')
'{ "schemaVersion": 2, "apps": {} }' | Set-Content -LiteralPath $badSchema -Encoding UTF8
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $badSchema
$failedSchema = $false
try { $null = Get-WauPsadtBridgeCatalog }
catch { $failedSchema = $_.Exception.Message -match 'schema is invalid' }
Assert-True $failedSchema 'invalid schema aborts the cycle'
Remove-Item -LiteralPath $badSchema -Force

$badAppsType = Join-Path ([System.IO.Path]::GetTempPath()) ('bad-apps-type-' + [guid]::NewGuid().ToString('N') + '.json')
'{ "schemaVersion": 1, "apps": "kaputt" }' | Set-Content -LiteralPath $badAppsType -Encoding UTF8
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $badAppsType
$failedAppsString = $false
try { $null = Get-WauPsadtBridgeCatalog }
catch { $failedAppsString = $_.Exception.Message -match 'schema is invalid' }
Assert-True $failedAppsString 'string apps aborts the cycle'
Remove-Item -LiteralPath $badAppsType -Force

$badAppsArray = Join-Path ([System.IO.Path]::GetTempPath()) ('bad-apps-array-' + [guid]::NewGuid().ToString('N') + '.json')
'{ "schemaVersion": 1, "apps": [] }' | Set-Content -LiteralPath $badAppsArray -Encoding UTF8
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $badAppsArray
$failedAppsArray = $false
try { $null = Get-WauPsadtBridgeCatalog }
catch { $failedAppsArray = $_.Exception.Message -match 'schema is invalid' }
Assert-True $failedAppsArray 'array apps aborts the cycle'
Remove-Item -LiteralPath $badAppsArray -Force

$submitTextForSchema = Get-Content -LiteralPath (Join-Path $wauFunctions 'Submit-WauPsadtUpdate.ps1') -Raw
Assert-True ($submitTextForSchema -match '\$catalog\.apps -isnot \[pscustomobject\]') 'submit requires apps to be a JSON object'

$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $catalogSource
$catalog = Get-WauPsadtBridgeCatalog
Assert-True ($null -ne (Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'Google.Chrome')) 'chrome is catalogued'
Assert-True ($null -ne (Resolve-WauPsadtCatalogApp -Catalog $catalog -Id '7zip.7zip')) '7zip is catalogued'
Assert-True ($null -ne (Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'Mozilla.Firefox')) 'firefox is catalogued'
Assert-True ($null -ne (Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'Mozilla.Firefox.de')) 'firefox.de is catalogued'
Assert-True (Test-WauPsadtCatalogProcesses -Entry (Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'Mozilla.Firefox')) 'firefox processes are valid'
Assert-True ($null -eq (Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'VideoLAN.VLC')) 'unknown id is not catalogued'
Assert-True (Test-WauPsadtCatalogProcesses -Entry (Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'Google.Chrome')) 'chrome processes are valid'
foreach ($invalidProcessName in @('chrome*', 'chrome?', '[c]hrome', 'chrome.exe', 'chrome/path')) {
    Assert-True (-not (Test-WauPsadtCatalogProcesses -Entry ([pscustomobject]@{ processes = @($invalidProcessName) }))) "invalid catalog process [$invalidProcessName] is rejected"
}
Assert-True (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome') })) 'omitted catalog ui is valid'
Assert-True (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome'); ui = [pscustomobject]@{} })) 'empty catalog ui uses defaults'
Assert-True (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome'); ui = [pscustomobject]@{ progress = $false; success = $true } })) 'Boolean catalog ui is valid'
Assert-True (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome'); ui = [pscustomobject]@{ progress = $false } })) 'partial catalog ui is valid'
Assert-True (-not (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome'); ui = 'disabled' }))) 'non-object catalog ui is rejected'
Assert-True (-not (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome'); ui = [pscustomobject]@{ progress = 'false' } }))) 'string catalog progress is rejected'
Assert-True (-not (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome'); ui = [pscustomobject]@{ success = 0 } }))) 'numeric catalog success is rejected'
Assert-True (-not (Test-WauPsadtCatalogUi -Entry ([pscustomobject]@{ processes = @('chrome'); ui = [pscustomobject]@{ restart = $false } }))) 'unknown catalog ui key is rejected'

$app = [pscustomobject]@{ Name = 'VLC'; Id = 'VideoLAN.VLC'; Version = '1.0'; AvailableVersion = '1.1' }
Assert-True (-not (Submit-WauPsadtUpdate -App $app -Source 'winget')) 'unknown id uses WAU path'
$app.Id = 'Google.Chrome'
Assert-True (-not (Submit-WauPsadtUpdate -App $app -Source 'msstore')) 'non-winget source uses WAU path'

$script:WauPsadtForceSystemContext = $false
Assert-True (-not (Submit-WauPsadtUpdate -App $app -Source 'winget')) 'non-SYSTEM catalog id uses WAU path'
$script:WauPsadtForceSystemContext = $true

$missingForBypass = Join-Path ([System.IO.Path]::GetTempPath()) ('bypass-catalog-' + [guid]::NewGuid().ToString('N') + '.json')
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $missingForBypass
$script:WauPsadtForceSystemContext = $false
Assert-True (-not (Submit-WauPsadtUpdate -App $app -Source 'winget')) 'non-SYSTEM does not load the catalog'
$script:WauPsadtForceSystemContext = $true
Assert-True (-not (Submit-WauPsadtUpdate -App $app -Source 'msstore')) 'non-winget source does not load the catalog'
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $catalogSource
$catalog = Get-WauPsadtBridgeCatalog

$submitText = Get-Content -LiteralPath (Join-Path $wauFunctions 'Submit-WauPsadtUpdate.ps1') -Raw
$sourceIndex = $submitText.IndexOf("if (`$Source -ine 'winget')")
$systemIndex = $submitText.IndexOf('if (-not (Test-WauPsadtRunningAsSystem))')
$catalogIndex = $submitText.LastIndexOf('$catalog = Get-WauPsadtBridgeCatalog')
Assert-True ($sourceIndex -ge 0 -and $systemIndex -gt $sourceIndex -and $catalogIndex -gt $systemIndex) 'Submit checks source and SYSTEM before loading the catalog'

$badCatalogPath = Join-Path ([System.IO.Path]::GetTempPath()) ('bad-processes-' + [guid]::NewGuid().ToString('N') + '.json')
$badCatalog = [ordered]@{
    schemaVersion = 1
    apps = [ordered]@{
        'Google.Chrome' = [ordered]@{
            displayName = 'Google Chrome'
            processes   = @('chrome.exe')
        }
    }
}
($badCatalog | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $badCatalogPath -Encoding UTF8
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $badCatalogPath
Assert-True (Submit-WauPsadtUpdate -App $app -Source 'winget') 'invalid catalog processes fail closed'
Remove-Item -LiteralPath $badCatalogPath -Force

$badUiCatalogPath = Join-Path ([System.IO.Path]::GetTempPath()) ('bad-ui-' + [guid]::NewGuid().ToString('N') + '.json')
$badUiCatalog = [ordered]@{
    schemaVersion = 1
    apps = [ordered]@{
        'Google.Chrome' = [ordered]@{
            displayName = 'Google Chrome'
            processes   = @('chrome')
            ui          = [ordered]@{ progress = 'false' }
        }
    }
}
($badUiCatalog | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $badUiCatalogPath -Encoding UTF8
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $badUiCatalogPath
Assert-True (Submit-WauPsadtUpdate -App $app -Source 'winget') 'invalid catalog ui fails closed for the package'
Assert-True (@($script:WauPsadtTestLog | Where-Object { $_ -match 'catalog ui is invalid' }).Count -ge 1) 'invalid catalog ui is logged'
Remove-Item -LiteralPath $badUiCatalogPath -Force
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $catalogSource
$catalog = Get-WauPsadtBridgeCatalog

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-submit-' + [guid]::NewGuid().ToString('N'))
$modsRoot = Join-Path $workRoot 'mods'
New-Item -ItemType Directory -Path $modsRoot | Out-Null
Set-Content -LiteralPath (Join-Path $modsRoot 'Google.Chrome-preinstall.ps1') -Value '$true' -Encoding UTF8
$Script:WorkingDir = $workRoot
$app.Id = 'Google.Chrome'
$app.Name = 'Google Chrome'
$app.AvailableVersion = '140.0.7339.127'
Assert-True (Test-WauPsadtAppSpecificMods -Id 'Google.Chrome') 'app-specific mods detected'
Assert-True (Submit-WauPsadtUpdate -App $app -Source 'winget') 'mods conflict skips WAU and bridge'
Assert-True (-not (Test-WauPsadtAppSpecificMods -Id '7zip.7zip')) 'global-only mods are not app-specific'

$campaignDir = Join-Path $workRoot 'campaign'
New-Item -ItemType Directory -Path $campaignDir | Out-Null
$chromeEntry = Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'Google.Chrome'
$jsonPath = Save-WauPsadtCampaignJson -DestinationRoot $campaignDir -App $app -CatalogEntry $chromeEntry
$written = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($written.wingetId -eq 'Google.Chrome') 'campaign wingetId'
Assert-True ($written.targetVersion -eq '140.0.7339.127') 'campaign targetVersion'
Assert-True (@($written.processes) -contains 'chrome') 'campaign processes'
Assert-True ([bool]$written.ui.progress) 'campaign progress copied from catalog'
Assert-True ([bool]$written.ui.success) 'campaign success copied from catalog'

$firefoxEntry = Resolve-WauPsadtCatalogApp -Catalog $catalog -Id 'Mozilla.Firefox'
$app.Id = 'Mozilla.Firefox'
$app.Name = 'Mozilla Firefox'
$jsonPath = Save-WauPsadtCampaignJson -DestinationRoot $campaignDir -App $app -CatalogEntry $firefoxEntry
$writtenWithoutUi = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($null -eq $writtenWithoutUi.PSObject.Properties['ui']) 'omitted catalog ui stays omitted in campaign json'

$partialUiEntry = [pscustomobject]@{
    displayName = 'Google Chrome'
    processes = @('chrome')
    ui = [pscustomobject]@{ progress = $false }
}
$app.Id = 'Google.Chrome'
$app.Name = 'Google Chrome'
$jsonPath = Save-WauPsadtCampaignJson -DestinationRoot $campaignDir -App $app -CatalogEntry $partialUiEntry
$writtenPartialUi = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (-not [bool]$writtenPartialUi.ui.progress) 'explicit campaign progress false is serialized'
Assert-True ([bool]$writtenPartialUi.ui.success) 'omitted catalog success is serialized with true default'

$golden = Join-Path $workRoot 'golden'
New-Item -ItemType Directory -Path $golden | Out-Null
Set-Content -LiteralPath (Join-Path $golden 'install.ps1') -Value 'exit 0' -Encoding UTF8
$script:WauPsadtBridgeGoldenRoot = $golden
$bridgeWorkRoot = Join-Path $workRoot 'Work'
New-Item -ItemType Directory -Path $bridgeWorkRoot | Out-Null
$script:WauPsadtBridgeWorkRoot = $bridgeWorkRoot
$Script:WorkingDir = Join-Path $workRoot 'nomods'
New-Item -ItemType Directory -Path $Script:WorkingDir | Out-Null
$app.Id = '7zip.7zip'
$app.Name = '7-Zip'
$created = $null
$workPath = New-WauPsadtWorkingCopy
$created = $workPath
Assert-True (Test-WauPsadtOwnedWorkingCopyPath -LiteralPath $workPath) 'working copy is below the protected Work root'
$workFull = [System.IO.Path]::GetFullPath($workPath)
$bridgeWorkFull = [System.IO.Path]::GetFullPath($bridgeWorkRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
Assert-True ($workFull.StartsWith($bridgeWorkFull, [System.StringComparison]::OrdinalIgnoreCase)) 'working copy is a child of the Work root'
$newCopyText = Get-Content -LiteralPath (Join-Path $wauFunctions 'Submit-WauPsadtUpdate.ps1') -Raw
Assert-True ($newCopyText -notmatch 'GetTempPath\(\)') 'working copy is not created under OS temp'
$quotedFile = @'
'-File', ('"{0}"' -f $installScript)
'@
Assert-True ($newCopyText.Contains($quotedFile.Trim())) 'bootstrap quotes -File because Work lives under Program Files'
Remove-WauPsadtWorkingCopy -LiteralPath $workPath
Assert-True (-not (Test-Path -LiteralPath $created)) 'direct working-copy helper removes owned path'

$before = @(Get-ChildItem -LiteralPath $bridgeWorkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$result = Submit-WauPsadtUpdate -App $app -Source 'winget'
Assert-True $result 'catalogued app is handed off'
$after = @(Get-ChildItem -LiteralPath $bridgeWorkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$leaked = @($after | Where-Object { $_ -notin $before })
Assert-True ($leaked.Count -eq 0) 'working copy is removed after successful bootstrap'

Set-Content -LiteralPath (Join-Path $golden 'install.ps1') -Value 'exit 1' -Encoding UTF8
$beforeFail = @(Get-ChildItem -LiteralPath $bridgeWorkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$failResult = Submit-WauPsadtUpdate -App $app -Source 'winget'
Assert-True $failResult 'bootstrap failure still returns handled'
$afterFail = @(Get-ChildItem -LiteralPath $bridgeWorkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$leakedFail = @($afterFail | Where-Object { $_ -notin $beforeFail })
Assert-True ($leakedFail.Count -eq 0) 'working copy is removed after bootstrap failure'

Set-Content -LiteralPath (Join-Path $golden 'install.ps1') -Value 'exit 0' -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $golden 'install.ps1') -Force
$beforePrep = @(Get-ChildItem -LiteralPath $bridgeWorkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$prepResult = Submit-WauPsadtUpdate -App $app -Source 'winget'
Assert-True $prepResult 'prepare failure still returns handled'
$afterPrep = @(Get-ChildItem -LiteralPath $bridgeWorkRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$leakedPrep = @($afterPrep | Where-Object { $_ -notin $beforePrep })
Assert-True ($leakedPrep.Count -eq 0) 'working copy is removed after preparation failure'

Remove-Item -LiteralPath $workRoot -Recurse -Force
Write-Output 'SubmitUpdate.Tests: OK'
