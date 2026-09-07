$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot

$installer = Join-Path $repoRoot 'Install-WauPsadtBridge.ps1'
$submit = Join-Path $repoRoot 'wau/Submit-WauPsadtUpdate.ps1'
$updateApp = Join-Path $repoRoot 'wau/Update-App.ps1'
$catalog = Join-Path $repoRoot 'catalog/apps.json'

$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$errs)
Assert-True (-not $errs -or $errs.Count -eq 0) 'installer parses'

$text = Get-Content -LiteralPath $installer -Raw
$submitText = Get-Content -LiteralPath $submit -Raw
$updateText = Get-Content -LiteralPath $updateApp -Raw
Assert-True ($text -match 'Join-Path \$script:BridgeInstallRoot ''bridge.catalog.json''') 'catalog install path'
Assert-True ($text -match 'Join-Path \$script:BridgeInstallRoot ''Template''') 'golden install path'
Assert-True ($text -match 'Join-Path \$script:BridgeInstallRoot ''Work''') 'work install path'
Assert-True ($text -match 'Install-BridgeDirectoryAcl -Path \$script:WorkInstallRoot') 'Work root gets the protected ACL'
Assert-True ($text -match 'S-1-5-32-545') 'Users SID is in the ACL policy'
Assert-True ($text -match 'ReadAndExecute') 'Users get ReadAndExecute, not Modify'
Assert-True ($submitText -match 'Join-Path \(Get-WauPsadtBridgeRoot\) ''bridge.catalog.json''') 'submit catalog path matches installer'
Assert-True ($submitText -match 'Join-Path \(Get-WauPsadtBridgeRoot\) ''Template''') 'submit golden path matches installer'
Assert-True ($submitText -match 'Join-Path \(Get-WauPsadtBridgeRoot\) ''Work''') 'submit work root is under Program Files'
Assert-True ($submitText -notmatch 'GetTempPath\(\)') 'working copy is not created under OS temp'
Assert-True ($text -match 'function Get-WauPsadtNativeProgramFiles') 'installer uses native Program Files'
Assert-True ($submitText -match 'function Get-WauPsadtNativeProgramFiles') 'submit uses native Program Files'
Assert-True ($text -match 'ProgramW6432') 'installer prefers ProgramW6432 on 64-bit Windows'
Assert-True ($submitText -match 'ProgramW6432') 'submit prefers ProgramW6432 on 64-bit Windows'
Assert-True ($text -notmatch "Register-ScheduledTask") 'wrapper does not create scheduled tasks'
Assert-True ($text -match 'Submit-WauPsadtUpdate\.ps1') 'copies submit function'
Assert-True ($text -match 'Update-App\.ps1') 'copies Update-App'
Assert-True ($text -match 'Update-App\.ps1\.pre-bridge') 'backs up stock Update-App'
Assert-True ($text -match 'Uninstall-WauPsadtBridgePayload') 'supports uninstall'
Assert-True ($text -notmatch 'Remove-Item -LiteralPath \$script:CatalogInstallDir -Recurse') 'uninstall does not delete the WauPsadtBridge root recursively'
Assert-True ($text -match 'campaign Stage folders are kept') 'uninstall keeps Stage'
Assert-True ($text -match 'function Remove-BridgeEmptyStageDirectories') 'uninstall has empty Stage cleanup'
Assert-True ($text -match 'Remove-BridgeEmptyStageDirectories -StageRoot') 'uninstall invokes empty Stage cleanup'
Assert-True ($text -notmatch 'Remove-Item -LiteralPath \$StageRoot -Recurse') 'uninstall never recursively removes Stage'
Assert-True ($text -match 'Cannot safely uninstall because the original WAU Update-App\.ps1 backup is missing') 'uninstall aborts when handoff backup is missing'
Assert-True ($text -match 'Cannot safely install because Update-App\.ps1 already contains the bridge handoff') 'reinstall aborts without an original backup'
Assert-True ($text -match '-not \$destHasHandoff -and -not \$backupIsOriginal') 'replaces a non-original backup from stock Update-App'
Assert-True ($text -match 'Get-NormalizedSha256 -LiteralPath \$LiteralPath') 'backup validation uses SHA-256'
Assert-True ($text -match '\$catalog\.apps -isnot \[pscustomobject\]') 'installer requires apps to be a JSON object'
Assert-True ($text -match '\$hasHandoff -and \$backupIsOriginal') 'uninstall restores backup only while the handoff is present'
Assert-True ($text -match "SupportedWauVersion = '2\.12\.0'") 'supports WAU 2.12.0'
Assert-True ($text -match 'Assert-WauUpdateAppCompatible') 'refuses unknown Update-App.ps1'
Assert-True ($text -match 'a7d73f2258a963d0b529a3a3bc35827313fbfa00ebce9953c95fc58a33a7b2ba') 'pins WAU 2.12.0 Update-App hash'
Assert-True ($text -match 'Install the WAU MSI first') 'requires existing WAU'
Assert-True ($text -match "'template'") 'installer copies template/'
Assert-True ($text -match "catalog\\apps\.json") 'installer copies catalog/apps.json'
Assert-True ($text -match "wau\\Submit-WauPsadtUpdate\.ps1") 'installer copies wau/Submit'
Assert-True ($updateText -match 'Submit-WauPsadtUpdate') 'Update-App calls the handoff'
Assert-True ($updateText -match 'Test-WauPsadtRunningAsSystem') 'native WAU path takes the mutex only as SYSTEM'
Assert-True ($submitText -match 'function Test-WauPsadtRunningAsSystem') 'handoff exposes SYSTEM guard'
Assert-True (Test-Path -LiteralPath $catalog -PathType Leaf) 'catalog/apps.json exists'

Write-Output 'BridgeInstaller.Tests: OK'
