$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$diagnosticsRoot = Join-Path $repoRoot 'diagnostics'
$shippedCatalog = Join-Path (Join-Path $repoRoot 'catalog') 'apps.json'

. (Join-Path $diagnosticsRoot 'WauPsadt.Diagnostics.ps1')

Assert-True ($null -ne (Get-Command Get-WauPsadtBridgeCatalog -ErrorAction SilentlyContinue)) 'diagnostics reuses the WAU catalog rule source'
Assert-True ($null -ne (Get-Command Test-WauPsadtCatalogProcesses -ErrorAction SilentlyContinue)) 'runtime process validator is reused'
Assert-True ($null -ne (Get-Command Test-WauPsadtCatalogUi -ErrorAction SilentlyContinue)) 'runtime ui validator is reused'

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-catalog-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

function New-TestCatalog {
    param([Parameter(Mandatory)]$Content, [Parameter(Mandatory)][string]$Name)
    $catalogPath = Join-Path $work $Name
    ($Content | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $catalogPath -Encoding UTF8
    return $catalogPath
}

function New-TestAppsCatalog {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Name)
    return New-TestCatalog -Name $Name -Content ([ordered]@{ schemaVersion = 1; apps = [ordered]@{ 'Test.App' = $Entry } })
}

# Shipped catalog
$result = Get-WauPsadtCatalogValidation -Path $shippedCatalog
Assert-True ($result.StructureValid) 'shipped catalog structure is valid'
Assert-True ([int]$result.SchemaVersion -eq 1) 'shipped catalog reports schemaVersion 1'
Assert-True ($result.EntryCount -eq 4) 'shipped catalog has four entries'
Assert-True ($result.InvalidEntryCount -eq 0) 'shipped catalog entries are valid'
Assert-True ($result.ExitCode -eq 0) 'valid catalog exits 0'

$chrome = $result.Entries | Where-Object Id -eq 'Google.Chrome'
Assert-True ($chrome.UiPresent) 'explicit ui is reported as present'
Assert-True ($chrome.EffectiveProgress -and $chrome.EffectiveSuccess) 'explicit ui values are reported'

$firefox = $result.Entries | Where-Object Id -eq 'Mozilla.Firefox'
Assert-True (-not $firefox.UiPresent) 'omitted ui is reported as absent'
Assert-True ($firefox.EffectiveProgress -and $firefox.EffectiveSuccess) 'omitted ui resolves to enabled'

$before = (Get-FileHash -LiteralPath $shippedCatalog -Algorithm SHA256).Hash
$null = Get-WauPsadtCatalogValidation -Path $shippedCatalog
Assert-True ((Get-FileHash -LiteralPath $shippedCatalog -Algorithm SHA256).Hash -eq $before) 'validation does not modify the catalog file'

# A relative path belongs to the PowerShell location and must agree with the runtime loader
Copy-Item -LiteralPath $shippedCatalog -Destination (Join-Path $work 'relative-catalog.json')
$originalLocation = (Get-Location).Path
try {
    Set-Location -LiteralPath $work
    $relativePath = '.' + [System.IO.Path]::DirectorySeparatorChar + 'relative-catalog.json'
    $relativeResult = Get-WauPsadtCatalogValidation -Path $relativePath
    Assert-True ($relativeResult.StructureValid) 'relative path resolves against the PowerShell location'
    Assert-True ($relativeResult.ExitCode -eq 0) 'relative path validation exits 0'
    Assert-True ($relativeResult.EntryCount -eq 4) 'relative path validation reads every entry'
    Assert-True ([System.IO.Path]::IsPathRooted($relativeResult.Path)) 'reported path is absolute'
    Assert-True ($relativeResult.Path -eq (Join-Path $work 'relative-catalog.json')) 'reported path matches the PowerShell location'

    $script:WauPsadtBridgeCatalog = $null
    $script:WauPsadtBridgeCatalogPath = $relativePath
    $runtimeAccepted = $true
    try { $null = Get-WauPsadtBridgeCatalog }
    catch { $runtimeAccepted = $false }
    Assert-True $runtimeAccepted 'runtime loader accepts the same relative path'
}
finally {
    Set-Location -LiteralPath $originalLocation
}

# Structural failures stop the cycle
$missingCatalog = Join-Path $work 'missing.json'
$result = Get-WauPsadtCatalogValidation -Path $missingCatalog
Assert-True (-not $result.StructureValid) 'missing catalog is structurally invalid'
Assert-True ($result.ExitCode -eq 1) 'missing catalog exits 1'
Assert-True ($result.StructureError -match 'missing') 'missing catalog reports the runtime reason'
Assert-True ($result.EntryCount -eq 0) 'missing catalog reports no entries'

$brokenCatalog = Join-Path $work 'broken.json'
'{ not json' | Set-Content -LiteralPath $brokenCatalog -Encoding UTF8
$result = Get-WauPsadtCatalogValidation -Path $brokenCatalog
Assert-True (-not $result.StructureValid) 'unparseable catalog is structurally invalid'
Assert-True ($result.ExitCode -eq 1) 'unparseable catalog exits 1'
Assert-True ($result.StructureError -match 'parsed') 'unparseable catalog reports the runtime reason'

$wrongSchema = Join-Path $work 'schema.json'
'{ "schemaVersion": 2, "apps": {} }' | Set-Content -LiteralPath $wrongSchema -Encoding UTF8
$result = Get-WauPsadtCatalogValidation -Path $wrongSchema
Assert-True (-not $result.StructureValid) 'wrong schemaVersion is structurally invalid'
Assert-True ($result.ExitCode -eq 1) 'wrong schemaVersion exits 1'
Assert-True ($result.StructureError -match 'schema is invalid') 'wrong schemaVersion reports the runtime reason'

$appsString = Join-Path $work 'apps-string.json'
'{ "schemaVersion": 1, "apps": "broken" }' | Set-Content -LiteralPath $appsString -Encoding UTF8
Assert-True ((Get-WauPsadtCatalogValidation -Path $appsString).ExitCode -eq 1) 'string apps exits 1'

$appsArray = Join-Path $work 'apps-array.json'
'{ "schemaVersion": 1, "apps": [] }' | Set-Content -LiteralPath $appsArray -Encoding UTF8
Assert-True ((Get-WauPsadtCatalogValidation -Path $appsArray).ExitCode -eq 1) 'array apps exits 1'

# The structure verdict must match the runtime loader in both directions
foreach ($catalogPath in @($shippedCatalog, $missingCatalog, $brokenCatalog, $wrongSchema, $appsString, $appsArray)) {
    $validation = Get-WauPsadtCatalogValidation -Path $catalogPath
    $script:WauPsadtBridgeCatalog = $null
    $script:WauPsadtBridgeCatalogPath = $catalogPath
    $runtimeRejected = $false
    try { $null = Get-WauPsadtBridgeCatalog }
    catch { $runtimeRejected = $true }
    Assert-True ($runtimeRejected -eq (-not $validation.StructureValid)) "structure verdict matches the runtime loader for $([System.IO.Path]::GetFileName($catalogPath))"
}

# Entry failures keep the file valid and stop only that entry
$invalidProcess = New-TestAppsCatalog -Name 'process.json' -Entry ([ordered]@{ displayName = 'Test'; processes = @('chrome.exe') })
$result = Get-WauPsadtCatalogValidation -Path $invalidProcess
Assert-True ($result.StructureValid) 'entry failure keeps the structure valid'
Assert-True ($result.ExitCode -eq 2) 'invalid entry exits 2'
Assert-True ($result.EntryCount -eq 1 -and $result.InvalidEntryCount -eq 1) 'invalid entry is counted'
Assert-True ($result.ValidEntryCount -eq 0) 'invalid entry is not counted as valid'
$entry = $result.Entries[0]
Assert-True (-not $entry.Valid) 'invalid entry is marked invalid'
Assert-True (@($entry.Errors).Count -ge 1) 'invalid entry carries a reason'
Assert-True ($null -eq $entry.EffectiveProgress) 'invalid entry reports no effective progress'
Assert-True ($null -eq $entry.EffectiveSuccess) 'invalid entry reports no effective success'

foreach ($processName in @('chrome*', 'chrome?', '[c]hrome', 'chrome.exe', 'chrome/path', ' ')) {
    $path = New-TestAppsCatalog -Name 'process-case.json' -Entry ([ordered]@{ processes = @($processName) })
    Assert-True ((Get-WauPsadtCatalogValidation -Path $path).ExitCode -eq 2) "invalid process [$processName] is rejected"
}
$emptyProcesses = New-TestAppsCatalog -Name 'process-empty.json' -Entry ([ordered]@{ processes = @() })
Assert-True ((Get-WauPsadtCatalogValidation -Path $emptyProcesses).ExitCode -eq 2) 'empty process list is rejected'
$nullEntry = New-TestCatalog -Name 'null-entry.json' -Content ([ordered]@{ schemaVersion = 1; apps = [ordered]@{ 'Test.App' = $null } })
Assert-True ((Get-WauPsadtCatalogValidation -Path $nullEntry).ExitCode -eq 2) 'null entry object is rejected'

$uiCases = @(
    [pscustomobject]@{ Name = 'string ui'; Value = 'disabled' },
    [pscustomobject]@{ Name = 'string progress'; Value = [ordered]@{ progress = 'false' } },
    [pscustomobject]@{ Name = 'numeric success'; Value = [ordered]@{ success = 0 } },
    [pscustomobject]@{ Name = 'unknown key'; Value = [ordered]@{ restart = $false } }
)
foreach ($case in $uiCases) {
    $path = New-TestAppsCatalog -Name 'ui-case.json' -Entry ([ordered]@{ processes = @('chrome'); ui = $case.Value })
    $result = Get-WauPsadtCatalogValidation -Path $path
    Assert-True ($result.ExitCode -eq 2) "invalid ui [$($case.Name)] is rejected"
    Assert-True ($result.Entries[0].UiPresent) "invalid ui [$($case.Name)] is still reported as present"
    Assert-True (@($result.Entries[0].Errors).Count -ge 1) "invalid ui [$($case.Name)] carries a reason"
}

# Effective values and the runtime campaign writer must agree
$partialUi = New-TestAppsCatalog -Name 'ui-partial.json' -Entry ([ordered]@{ processes = @('chrome'); ui = [ordered]@{ progress = $false } })
$result = Get-WauPsadtCatalogValidation -Path $partialUi
Assert-True ($result.ExitCode -eq 0) 'partial ui keeps the catalog valid'
Assert-True (-not [bool]$result.Entries[0].EffectiveProgress) 'partial ui applies progress false'
Assert-True ([bool]$result.Entries[0].EffectiveSuccess) 'partial ui defaults success to true'

$campaignRoot = Join-Path $work 'campaign'
New-Item -ItemType Directory -Path $campaignRoot | Out-Null
$script:WauPsadtBridgeCatalog = $null
$script:WauPsadtBridgeCatalogPath = $shippedCatalog
$shipped = Get-WauPsadtBridgeCatalog
$app = [pscustomobject]@{ Id = 'Google.Chrome'; Name = 'Google Chrome'; AvailableVersion = '140.0.7339.127' }
$jsonPath = Save-WauPsadtCampaignJson -DestinationRoot $campaignRoot -App $app -CatalogEntry (Resolve-WauPsadtCatalogApp -Catalog $shipped -Id 'Google.Chrome')
$written = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([bool]$written.ui.progress -eq [bool]$chrome.EffectiveProgress) 'effective progress matches the campaign writer'
Assert-True ([bool]$written.ui.success -eq [bool]$chrome.EffectiveSuccess) 'effective success matches the campaign writer'

$app.Id = 'Mozilla.Firefox'
$app.Name = 'Mozilla Firefox'
$jsonPath = Save-WauPsadtCampaignJson -DestinationRoot $campaignRoot -App $app -CatalogEntry (Resolve-WauPsadtCatalogApp -Catalog $shipped -Id 'Mozilla.Firefox')
$written = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($null -eq $written.PSObject.Properties['ui']) 'omitted ui stays omitted in the campaign payload'
Assert-True ([bool]$firefox.EffectiveProgress -and [bool]$firefox.EffectiveSuccess) 'omitted ui resolves to the runtime default'

# The diagnostics entry points are read-only
foreach ($scriptFile in @(Get-ChildItem -LiteralPath $diagnosticsRoot -Filter '*.ps1' -File | Sort-Object Name)) {
    $scriptText = Get-Content -LiteralPath $scriptFile.FullName -Raw
    foreach ($mutating in @('Register-ScheduledTask', 'Unregister-ScheduledTask', 'Set-ScheduledTask', 'Start-ScheduledTask', 'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty', 'Remove-Item', 'New-Item', 'Set-Content', 'robocopy')) {
        Assert-True ($scriptText -notmatch [regex]::Escape($mutating)) "read-only guard: $($scriptFile.Name) has no $mutating"
    }
}

# Command-line contract
$cli = Join-Path $diagnosticsRoot 'Test-WauPsadtBridgeCatalog.ps1'
& $PSHOME/pwsh -NoProfile -File $cli -Path $shippedCatalog *> $null
Assert-True ($LASTEXITCODE -eq 0) 'CLI exits 0 for a valid catalog'
& $PSHOME/pwsh -NoProfile -File $cli -Path $missingCatalog *> $null
Assert-True ($LASTEXITCODE -eq 1) 'CLI exits 1 for a structural failure'
& $PSHOME/pwsh -NoProfile -File $cli -Path $invalidProcess *> $null
Assert-True ($LASTEXITCODE -eq 2) 'CLI exits 2 for an invalid entry'
& $PSHOME/pwsh -NoProfile -File $cli *> $null
Assert-True ($LASTEXITCODE -eq 0) 'CLI validates the shipped catalog when no path is given'

$wrapperPath = Join-Path $work 'pass-thru.ps1'
$dollar = [char]36
$wrapperText = "& '" + $cli + "' -Path '" + $shippedCatalog + "' -PassThru 6>" + $dollar + "null | ConvertTo-Json -Depth 6"
Set-Content -LiteralPath $wrapperPath -Value $wrapperText -Encoding UTF8
$jsonText = & $PSHOME/pwsh -NoProfile -File $wrapperPath
$parsed = ($jsonText -join [Environment]::NewLine) | ConvertFrom-Json
Assert-True ([bool]$parsed.StructureValid) 'CLI PassThru emits a structured result'
Assert-True ([int]$parsed.ExitCode -eq 0) 'CLI structured result carries the exit code'
Assert-True (@($parsed.Entries).Count -eq 4) 'CLI structured result carries every entry'

Remove-Item -LiteralPath $work -Recurse -Force
Write-Output 'CatalogValidation.Tests: OK'
