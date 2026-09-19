# Desktop shortcut contract and lifecycle for a deferred campaign.

function Get-WauBridgeDesktopShortcutContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    return [pscustomobject]@{
        ShortcutPath     = $Context.Schedule.DesktopShortcutPath
        ShortcutName     = $Context.Schedule.DesktopShortcutName
        TargetPath       = $Context.Schedule.DesktopShortcutTargetPath
        Arguments        = Get-WauBridgeManualTaskStartArguments -TaskPath $Context.Schedule.TaskPath -TaskName $Context.Schedule.TaskName
        WorkingDirectory = $Context.Schedule.DesktopShortcutWorkingDirectory
        Description      = $Context.Schedule.DesktopShortcutDescription
        IconLocation     = '{0},0' -f $Context.Schedule.DesktopShortcutIconPath
        WindowStyle      = [int]$Context.Schedule.DesktopShortcutWindowStyle
    }
}

function Test-WauBridgeDesktopShortcutContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    return (
        [string]$Actual.ShortcutPath -ieq [string]$Expected.ShortcutPath -and
        [string]$Actual.ShortcutName -ieq [string]$Expected.ShortcutName -and
        [string]$Actual.TargetPath -ieq [string]$Expected.TargetPath -and
        [string]$Actual.Arguments -ceq [string]$Expected.Arguments -and
        [string]$Actual.WorkingDirectory -ieq [string]$Expected.WorkingDirectory -and
        [string]$Actual.Description -ceq [string]$Expected.Description -and
        [string]$Actual.IconLocation -ieq [string]$Expected.IconLocation -and
        [int]$Actual.WindowStyle -eq [int]$Expected.WindowStyle
    )
}

function New-WauBridgeDesktopShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)

    $expected = Get-WauBridgeDesktopShortcutContract -Context $Context
    if (-not (Test-Path -LiteralPath $Context.Schedule.DesktopShortcutIconPath -PathType Leaf)) {
        throw "Desktop shortcut icon was not found: [$($Context.Schedule.DesktopShortcutIconPath)]."
    }
    if (-not (Test-Path -LiteralPath $expected.TargetPath -PathType Leaf)) {
        throw "Windows PowerShell was not found at the expected system path: [$($expected.TargetPath)]."
    }
    if (-not (Test-Path -LiteralPath $expected.WorkingDirectory -PathType Container)) {
        throw "Desktop shortcut working directory was not found: [$($expected.WorkingDirectory)]."
    }

    if ((Test-Path -LiteralPath $expected.ShortcutPath -PathType Leaf) -and -not (Test-WauBridgeDesktopShortcutOwned -Context $Context)) {
        throw "An existing desktop shortcut collides with the configured name and is left in place: [$($expected.ShortcutPath)]."
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($expected.ShortcutPath)
    $shortcut.TargetPath = $expected.TargetPath
    $shortcut.Arguments = $expected.Arguments
    $shortcut.WorkingDirectory = $expected.WorkingDirectory
    $shortcut.Description = $expected.Description
    $shortcut.IconLocation = $expected.IconLocation
    $shortcut.WindowStyle = $expected.WindowStyle
    $shortcut.Save()
}

function Get-WauBridgeDesktopShortcutProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Context.Schedule.DesktopShortcutPath)
    return [pscustomobject]@{
        ShortcutPath     = $Context.Schedule.DesktopShortcutPath
        ShortcutName     = [System.IO.Path]::GetFileName($Context.Schedule.DesktopShortcutPath)
        TargetPath       = [string]$shortcut.TargetPath
        Arguments        = [string]$shortcut.Arguments
        WorkingDirectory = [string]$shortcut.WorkingDirectory
        Description      = [string]$shortcut.Description
        IconLocation     = [string]$shortcut.IconLocation
        WindowStyle      = [int]$shortcut.WindowStyle
    }
}

function Test-WauBridgeDesktopShortcutOwned {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if (-not (Test-Path -LiteralPath $Context.Schedule.DesktopShortcutPath -PathType Leaf)) { return $false }
    try {
        $expected = Get-WauBridgeDesktopShortcutContract -Context $Context
        $actual = Get-WauBridgeDesktopShortcutProperties -Context $Context
        return (Test-WauBridgeDesktopShortcutContract -Expected $expected -Actual $actual)
    }
    catch {
        Write-WauBridgeLog -Message ("Desktop shortcut ownership could not be verified: {0}" -f $_.Exception.Message) -Severity 2
        return $false
    }
}

function Remove-WauBridgeDesktopShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Context)
    if (Test-Path -LiteralPath $Context.Schedule.DesktopShortcutPath) {
        if (Test-WauBridgeDesktopShortcutOwned -Context $Context) {
            Remove-Item -LiteralPath $Context.Schedule.DesktopShortcutPath -Force -ErrorAction Stop
        }
        else {
            Write-WauBridgeLog -Message ("Desktop shortcut was left in place because ownership was not proven: [$($Context.Schedule.DesktopShortcutPath)].") -Severity 2
        }
    }
}
