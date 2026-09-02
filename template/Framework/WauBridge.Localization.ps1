# Culture packs are imported as data, never dot-sourced. Every discovered pack
# must satisfy the same contract so a missing translation fails before mutation.
$script:WauBridgeLocalizationResource = $null

function Import-WauBridgePowerShellDataFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    # Windows PowerShell 5.1 treats .psd1 as the ANSI code page unless a UTF-8 BOM
    # is present. Read as UTF-8, then import from a BOM temp file so umlauts survive.
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = [System.IO.File]::ReadAllText($LiteralPath, $utf8)
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ('wau-bridge-psd1-' + [guid]::NewGuid().ToString('N') + '.psd1')
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($tempPath, $text, $utf8Bom)
        return Import-PowerShellDataFile -LiteralPath $tempPath
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Import-WauBridgeMessageContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Message contract not found: [$Path]." }
    try { $contract = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Message contract is invalid JSON: $($_.Exception.Message)" }
    if ([int]$contract.schemaVersion -ne 1 -or $null -eq $contract.messages) { throw 'Message contract schemaVersion/messages are invalid.' }
    return $contract
}

function Get-WauBridgeMessagePlaceholders {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Template)
    return @([regex]::Matches($Template, '\{([A-Za-z][A-Za-z0-9]*)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Get-WauBridgeCulturePackErrors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Pack,
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)][string]$ExpectedCulture
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($rootKey in $Pack.Keys) {
        if ([string]$rootKey -notin @('Metadata','Messages')) { $errors.Add("Unknown culture-pack root key [$rootKey].") }
    }
    $metadata = $Pack['Metadata']
    $messages = $Pack['Messages']
    if ($metadata -isnot [System.Collections.IDictionary]) { $errors.Add('Metadata must be a hashtable.') }
    else {
        foreach ($metadataKey in $metadata.Keys) {
            if ([string]$metadataKey -notin @('SchemaVersion','Culture','DisplayName','TextDirection')) { $errors.Add("Unknown metadata key [$metadataKey].") }
        }
        foreach ($required in @('SchemaVersion','Culture','DisplayName','TextDirection')) {
            if (-not $metadata.Contains($required)) { $errors.Add("Missing metadata key [$required].") }
        }
        if ([int]$metadata['SchemaVersion'] -ne 1) { $errors.Add('Metadata.SchemaVersion must be 1.') }
        if ([string]$metadata['Culture'] -ine $ExpectedCulture) { $errors.Add("Metadata.Culture must match filename [$ExpectedCulture].") }
        if ([string]$metadata['TextDirection'] -notin @('ltr','rtl')) { $errors.Add('Metadata.TextDirection must be ltr or rtl.') }
    }
    if ($messages -isnot [System.Collections.IDictionary]) {
        $errors.Add('Messages must be a hashtable.')
        return $errors.ToArray()
    }

    foreach ($definition in @($Contract.messages.PSObject.Properties)) {
        $key = [string]$definition.Name
        if (-not $messages.Contains($key)) { $errors.Add("Missing message key [$key]."); continue }
        $template = [string]$messages[$key]
        if ([string]::IsNullOrWhiteSpace($template)) { $errors.Add("Message [$key] must not be empty."); continue }
        $actual = @(Get-WauBridgeMessagePlaceholders -Template $template)
        $expected = @($definition.Value | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        $unknown = @($actual | Where-Object { $_ -notin $expected })
        $missing = @($expected | Where-Object { $_ -notin $actual })
        if ($unknown.Count) { $errors.Add("Message [$key] has unknown placeholders: $($unknown -join ', ').") }
        if ($missing.Count) { $errors.Add("Message [$key] is missing placeholders: $($missing -join ', ').") }
    }
    foreach ($key in $messages.Keys) {
        $known = @($Contract.messages.PSObject.Properties.Name) -contains [string]$key
        if (-not $known -and [string]$key -notmatch '^Package\.[A-Za-z0-9_.-]+$') {
            $errors.Add("Unknown message key [$key]; package keys must start with Package.")
        }
    }
    return $errors.ToArray()
}

function Get-WauBridgeCulturePackCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MessagesPath,[Parameter(Mandatory)]$Contract)

    if (-not (Test-Path -LiteralPath $MessagesPath -PathType Container)) { throw "Messages directory not found: [$MessagesPath]." }
    $catalog = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $MessagesPath -Filter '*.psd1' -File | Sort-Object Name)) {
        $cultureName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        try {
            $cultureInfo = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
            if ([string]::IsNullOrWhiteSpace($cultureInfo.Name)) { throw 'Invariant culture is not supported.' }
        }
        catch { throw "Culture-pack filename is not a valid BCP-47 culture: [$($file.Name)]." }
        try { $pack = Import-WauBridgePowerShellDataFile -LiteralPath $file.FullName }
        catch { throw "Culture pack [$($file.Name)] is not safe PowerShell data: $($_.Exception.Message)" }
        $packErrors = @(Get-WauBridgeCulturePackErrors -Pack $pack -Contract $Contract -ExpectedCulture $cultureName)
        if ($packErrors.Count) { throw "Culture pack [$($file.Name)] is invalid:`n - $($packErrors -join "`n - ")" }
        $catalog.Add([pscustomobject]@{
            Culture = $cultureName
            CultureInfo = $cultureInfo
            TextDirection = [string]$pack.Metadata.TextDirection
            Messages = $pack.Messages
            Path = $file.FullName
        })
    }
    if ($catalog.Count -eq 0) { throw 'No culture packs were found.' }
    if (@($catalog | Where-Object Culture -ieq 'en-US').Count -ne 1) { throw 'The required en-US fallback pack is missing.' }
    return $catalog.ToArray()
}

function Resolve-WauBridgeCulturePack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestedCulture,
        [string]$InteractiveCulture = '',
        [Parameter(Mandatory)][string]$DefaultCulture,
        [Parameter(Mandatory)][string]$MessagesPath,
        [Parameter(Mandatory)][string]$ContractPath
    )

    $contract = Import-WauBridgeMessageContract -Path $ContractPath
    $catalog = @(Get-WauBridgeCulturePackCatalog -MessagesPath $MessagesPath -Contract $contract)
    $selectedCulture = if ($RequestedCulture -eq 'Auto') { $InteractiveCulture } else { $RequestedCulture }
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($selectedCulture)) {
        try { $culture = [Globalization.CultureInfo]::GetCultureInfo($selectedCulture) }
        catch { throw "Requested UI culture is invalid: [$selectedCulture]." }
        while ($culture -and -not [string]::IsNullOrWhiteSpace($culture.Name)) {
            if (-not $candidates.Contains($culture.Name)) { $candidates.Add($culture.Name) }
            $culture = $culture.Parent
        }
    }
    $defaultInfo = [Globalization.CultureInfo]::GetCultureInfo($DefaultCulture)
    if (-not $candidates.Contains($defaultInfo.Name)) { $candidates.Add($defaultInfo.Name) }
    if (-not $candidates.Contains('en-US')) { $candidates.Add('en-US') }

    $attempted = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        $attempted.Add($candidate)
        $match = @($catalog | Where-Object Culture -ieq $candidate)
        if ($match.Count -eq 1) {
            return [pscustomobject]@{
                RequestedCulture = $RequestedCulture
                InteractiveCulture = $InteractiveCulture
                ResolvedCulture = $match[0].Culture
                CultureInfo = $match[0].CultureInfo
                TextDirection = $match[0].TextDirection
                Messages = $match[0].Messages
                FallbackChain = @($attempted)
                SourcePath = $match[0].Path
            }
        }
    }
    throw 'No usable culture pack could be resolved.'
}

function Get-WauBridgeLocalizationResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration,[Parameter(Mandatory)][string]$ScriptRoot,[switch]$Refresh)

    if ($script:WauBridgeLocalizationResource -and -not $Refresh) { return $script:WauBridgeLocalizationResource }
    $messagesPath = Resolve-WauBridgeContainedPath -PackageRoot $ScriptRoot -RelativePath ([string]$Configuration.Localization.MessagesPath)
    $contractPath = Join-Path $messagesPath 'message-contract.json'
    $script:WauBridgeLocalizationResource = Resolve-WauBridgeCulturePack `
        -RequestedCulture ([string]$Configuration.Localization.Culture) `
        -InteractiveCulture (Get-WauBridgeInteractiveCultureName) `
        -DefaultCulture ([string]$Configuration.Localization.DefaultCulture) `
        -MessagesPath $messagesPath `
        -ContractPath $contractPath
    Write-WauBridgeLog -Message ("Localization culture resolved to [{0}] via [{1}]." -f $script:WauBridgeLocalizationResource.ResolvedCulture, ($script:WauBridgeLocalizationResource.FallbackChain -join ' -> '))
    return $script:WauBridgeLocalizationResource
}

function Get-WauBridgeMessageTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TemplateName)
    $resource = Get-WauBridgeLocalizationResource -Configuration $WauBridgeConfig -ScriptRoot (Split-Path -Path $PSScriptRoot -Parent)
    if (-not $resource.Messages.Contains($TemplateName)) { throw "Localized message [$TemplateName] was not found." }
    return [string]$resource.Messages[$TemplateName]
}

function Get-WauBridgeRenderedMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TemplateName,[Parameter(Mandatory)][hashtable]$Context)

    $message = Get-WauBridgeMessageTemplate -TemplateName $TemplateName
    $required = @(Get-WauBridgeMessagePlaceholders -Template $message)
    foreach ($key in $required) {
        if (-not $Context.ContainsKey($key)) { throw "Message [$TemplateName] requires placeholder [$key]." }
        $message = $message.Replace(('{' + $key + '}'), [string]$Context[$key])
    }
    if ($message -match '\{[A-Za-z][A-Za-z0-9]*\}') { throw "Message [$TemplateName] contains unresolved placeholders." }
    return $message.Trim()
}

function Format-WauBridgeDateTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$DateTime)
    $resource = Get-WauBridgeLocalizationResource -Configuration $WauBridgeConfig -ScriptRoot (Split-Path -Path $PSScriptRoot -Parent)
    $value = if ($DateTime.Kind -eq [DateTimeKind]::Utc) { [TimeZoneInfo]::ConvertTimeFromUtc($DateTime, (Get-WauBridgeTimeZone)) } else { $DateTime }
    return $value.ToString('g', $resource.CultureInfo)
}

function Get-WauBridgeUserExperienceValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $messageKey = switch ($Name) {
        'Subtitle' { 'Subtitle' }
        'UpgradeSuccess' { 'UpgradeSuccess' }
        'UpgradeSuccessSubtitle' { 'UpgradeSuccessSubtitle' }
        'SuccessButtonText' { 'SuccessButtonText' }
        'UpgradeStatusMessage' { 'UpgradeStatusMessage' }
        default { return $null }
    }
    return Get-WauBridgeRenderedMessage -TemplateName $messageKey -Context @{ AppName = (Get-WauBridgeBaseAppName) }
}

function Get-WauBridgeDesktopShortcutName {
    [CmdletBinding()]
    param([ValidateSet('Upgrade')][string]$Operation = 'Upgrade')
    return Get-WauBridgeRenderedMessage -TemplateName 'DesktopShortcutNameUpgrade' -Context @{ AppName = (Get-WauBridgeBaseAppName) }
}

function Get-WauBridgeDesktopShortcutDescription {
    [CmdletBinding()]
    param([ValidateSet('Upgrade')][string]$Operation = 'Upgrade')
    return Get-WauBridgeRenderedMessage -TemplateName 'DesktopShortcutDescriptionUpgrade' -Context @{ AppName = (Get-WauBridgeBaseAppName) }
}

function Get-WauBridgeTitle {
    [CmdletBinding()]
    param([string]$Operation)
    return Get-WauBridgeRenderedMessage -TemplateName 'UpgradeTitle' -Context @{ AppName = (Get-WauBridgeBaseAppName) }
}
