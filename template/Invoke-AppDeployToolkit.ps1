[CmdletBinding()]
param(
    [ValidateSet('Install')]
    [string]$DeploymentType = 'Install',
    [ValidateSet('Interactive', 'Silent', 'NonInteractive', 'Auto')]
    [string]$DeployMode = 'Interactive',
    [switch]$AllowRebootPassThru,
    [switch]$TerminalServerMode,
    [switch]$DisableLogging,
    [ValidateSet('Bootstrap', 'RetryTask')]
    [string]$InvocationSource = 'Bootstrap'
)

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'App\WauBridge.Config.ps1')
. (Join-Path $PSScriptRoot 'App\WauBridge.Detect.ps1')
. (Join-Path $PSScriptRoot 'Framework\WauBridge.ps1')
. (Join-Path $PSScriptRoot 'Framework\WauBridge.Winget.ps1')
. (Join-Path $PSScriptRoot 'App\WauBridge.Install.ps1')

$null = Import-WauBridgeCampaignJson -ScriptRoot $PSScriptRoot
if (-not (Test-WauBridgeCampaignJsonLoaded)) {
    throw 'WauBridge.Campaign.json is required for the WAU PSADT Bridge template.'
}

Assert-WauBridgeConfiguration -Configuration $WauBridgeConfig

$script:WauBridgeState = [ordered]@{
    Operation       = $null
    Provisioning    = $false
    ScheduleState   = $null
    Context         = Get-WauBridgeContext -WauBridgeConfig $WauBridgeConfig -ScriptRoot $PSScriptRoot
    ReturnExitCode  = 0
    LastResult      = $null
}

$adtSession = @{
    AppVendor                    = ''
    AppName                      = (Get-WauBridgeBaseAppName)
    AppVersion                   = [string]$WauBridgeConfig.TargetVersion
    AppArch                      = ''
    AppLang                      = ''
    AppRevision                  = '01'
    AppSuccessExitCodes          = $WauBridgeConfig.SuccessExitCodes
    AppRebootExitCodes           = $WauBridgeConfig.RebootExitCodes
    AppProcessesToClose          = $WauBridgeConfig.ProcessDefinitions
    AppScriptVersion             = [version]'0.1.0'
    AppScriptDate                = '2026-09-02'
    AppScriptAuthor              = 'WAU PSADT Bridge'
    RequireAdmin                 = $WauBridgeConfig.RequireAdmin
    InstallName                  = $WauBridgeConfig.PackageId
    InstallTitle                 = (Get-WauBridgeTitle)
    DeployAppScriptFriendlyName  = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters    = $PSBoundParameters
    DeployAppScriptVersion       = [version]'4.1.8'
}

function Invoke-WauBridgeRetryCatchUpSafely {
    [CmdletBinding()]
    param()

    if ($InvocationSource -ne 'RetryTask') { return }
    if (-not (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context)) { return }
    $campaign = Get-WauBridgeCampaignState -Context $script:WauBridgeState.Context
    if ($campaign -and [string]$campaign.State -eq 'Completed') { return }
    try {
        Invoke-WauBridgeScheduleCatchUp -Context $script:WauBridgeState.Context
    }
    catch {
        Write-WauBridgeLog -Message ("Retry catch-up failed: {0}" -f $_.Exception.Message) -Severity 2
    }
}

function Install-ADTDeployment {
    [CmdletBinding()]
    param()

    $bridgeMutex = $null
    try {
        $bridgeMutex = Enter-WauBridgeMutex
        if ($null -eq $bridgeMutex) {
            Write-WauBridgeLog -Message 'Bridge mutex is held by another deployment. Skipping this run.' -Severity 2
            Invoke-WauBridgeRetryCatchUpSafely
            $script:WauBridgeState.ReturnExitCode = 1618
            return
        }

        $script:WauBridgeState.Operation = Get-WauBridgeInstallOperation
        if ($script:WauBridgeState.Operation -eq 'Upgrade') {
            $script:WauBridgeState.Context = Get-WauBridgeContext -WauBridgeConfig $WauBridgeConfig -ScriptRoot $PSScriptRoot -Operation $script:WauBridgeState.Operation
        }
        $script:WauBridgeState.Provisioning = Test-WauBridgeProvisioningActive
        $script:WauBridgeState.ScheduleState = Get-WauBridgeScheduleState -Context $script:WauBridgeState.Context

        $uiTitle = Get-WauBridgeTitle -Operation $script:WauBridgeState.Operation
        $subtitle = Get-WauBridgeUserExperienceValue -Name 'Subtitle'
        Write-WauBridgeLog -Message ("Detected operation: [{0}], provisioning active: [{1}]" -f $script:WauBridgeState.Operation, $script:WauBridgeState.Provisioning)

        switch ($script:WauBridgeState.Operation) {
            'InstalledSameVersion' {
                Write-WauBridgeLog -Message 'Target version already installed. Nothing to do.'
                if (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context) {
                    Set-WauBridgeCampaignState -Context $script:WauBridgeState.Context -State 'Completed' -ScheduleState $script:WauBridgeState.ScheduleState
                    Complete-WauBridgeSchedule -Context $script:WauBridgeState.Context
                }
                return
            }
            'InstalledNewerVersion' {
                Write-WauBridgeLog -Message 'A newer version than the target version is already installed. Nothing will be changed.' -Severity 2
                if (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context) {
                    Set-WauBridgeCampaignState -Context $script:WauBridgeState.Context -State 'Completed' -ScheduleState $script:WauBridgeState.ScheduleState
                    Complete-WauBridgeSchedule -Context $script:WauBridgeState.Context
                }
                return
            }
        }

        $processesRunning = $false
        $processDisplayNames = ''
        if ($WauBridgeConfig.ProcessDefinitions.Count -gt 0) {
            $processesRunning = Test-WauBridgeProcessesRunning
            $processDisplayNames = Get-WauBridgeProcessDisplayNames
        }

        $finalDeadline = if ($script:WauBridgeState.ScheduleState) { $script:WauBridgeState.ScheduleState.FinalDeadline } else { $null }
        $deadlinePassed = $false
        if ($finalDeadline) { $deadlinePassed = ((Get-Date) -ge $finalDeadline) }

        $promptShownCount = 0
        if (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context) {
            $campaignState = Get-WauBridgeCampaignState -Context $script:WauBridgeState.Context
            if ($campaignState -and $null -ne $campaignState.PromptShownCount) {
                $promptShownCount = [int]$campaignState.PromptShownCount
            }
        }

        if ($InvocationSource -eq 'RetryTask' -and -not (Test-WauBridgeUsageHoursActive) -and -not (Test-WauBridgeHasInteractiveUser)) {
            Write-WauBridgeLog -Message 'Retry task skipped UI outside usage hours; ensuring a future trigger exists.'
            Invoke-WauBridgeScheduleCatchUp -Context $script:WauBridgeState.Context
            return
        }

        $processInteractionRequired = ($script:WauBridgeState.Operation -eq 'Upgrade' -and $processesRunning)
        $deferralScenario = ($processInteractionRequired -and $WauBridgeConfig.Retry.Enable)
        $allowDeferAfterDeadline = ($deadlinePassed -and $promptShownCount -lt 1)
        $deferralEligible = (
            $deferralScenario -and
            -not $script:WauBridgeState.Provisioning -and
            (-not $deadlinePassed -or $allowDeferAfterDeadline) -and
            [int]$WauBridgeConfig.Retry.Days -ge 1
        )
        $forceCloseAfterDeadline = ($deadlinePassed -and $promptShownCount -ge 1)

        $sessionGuardOk = Test-WauBridgeSessionGuard -ProcessesRunning $processesRunning
        Write-WauBridgeLog -Message ("Bridge session guard ok: [{0}]" -f $sessionGuardOk)

        Write-WauBridgeLog -Message ("Operation=[{0}] Provisioning=[{1}] ProcessesRunning=[{2}] ProcessInteractionRequired=[{3}] DeadlinePassed=[{4}] RetryEnable=[{5}] Days=[{6}] TimesPerDay=[{7}] DeferralEligible=[{8}] InvocationSource=[{9}]" -f `
            $script:WauBridgeState.Operation,
            $script:WauBridgeState.Provisioning,
            $processesRunning,
            $processInteractionRequired,
            $deadlinePassed,
            $WauBridgeConfig.Retry.Enable,
            $WauBridgeConfig.Retry.Days,
            $WauBridgeConfig.Retry.TimesPerDay,
            $deferralEligible,
            $InvocationSource
        )

        if ($InvocationSource -eq 'Bootstrap' -and $deferralEligible) {
            $consumedNow = 0
            if ($sessionGuardOk) { $consumedNow = 1 }
            $schedule = Register-WauBridgeSchedule -SourceRoot $PSScriptRoot -Operation $script:WauBridgeState.Operation -ConsumedNow $consumedNow
            $script:WauBridgeState.Context = $schedule.Context
            $script:WauBridgeState.ScheduleState = Get-WauBridgeScheduleState -Context $script:WauBridgeState.Context
            if ($script:WauBridgeState.ScheduleState -and $null -ne $script:WauBridgeState.ScheduleState.FinalDeadline) {
                $finalDeadline = $script:WauBridgeState.ScheduleState.FinalDeadline
            }
            Write-WauBridgeLog -Message 'Bridge bootstrap registered retry infrastructure.'
            if ($sessionGuardOk -and (Test-WauBridgeUsageHoursActive)) {
                Exit-WauBridgeMutex -Mutex $bridgeMutex
                $bridgeMutex = $null
                Start-ScheduledTask -TaskPath $schedule.Context.Schedule.TaskPath -TaskName $schedule.Context.Schedule.TaskName
                Write-WauBridgeLog -Message ("Bridge bootstrap started owned retry task [{0}{1}]." -f $schedule.Context.Schedule.TaskPath, $schedule.Context.Schedule.TaskName)
                return
            }
            if (-not $sessionGuardOk) {
                Exit-WauBridgeMutex -Mutex $bridgeMutex
                $bridgeMutex = $null
                Invoke-WauBridgeScheduleCatchUp -Context $schedule.Context
                Write-WauBridgeLog -Message 'Bridge bootstrap skipped Start-ScheduledTask; existing reminder triggers will retry.'
                return
            }
            Write-WauBridgeLog -Message 'Bridge bootstrap showing UI in this process because the current time is outside usage hours.'
        }

        if ($InvocationSource -eq 'Bootstrap' -and $deferralScenario -and -not $script:WauBridgeState.Provisioning -and -not $deferralEligible) {
            Write-WauBridgeLog -Message 'A deferral-capable scenario was detected, but deferral is no longer allowed. Continuing without retry infrastructure.'
        }

        $showProgress = $false

        if ($script:WauBridgeState.Provisioning -and $processesRunning) {
            Write-WauBridgeLog -Message 'Provisioning is active and a catalog process is running; skip UI, close-apps and winget.'
            if (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context) {
                Invoke-WauBridgeScheduleCatchUp -Context $script:WauBridgeState.Context
            }
            $script:WauBridgeState.ReturnExitCode = 1618
            return
        }

        if ($processesRunning -and -not $sessionGuardOk) {
            Write-WauBridgeLog -Message 'Bridge session guard blocked UI, force-close and winget. Retry later.'
            if (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context) {
                Invoke-WauBridgeScheduleCatchUp -Context $script:WauBridgeState.Context
            }
            $script:WauBridgeState.ReturnExitCode = 1618
            return
        }

        if (-not $script:WauBridgeState.Provisioning -and $processInteractionRequired) {
            $messageParams = @{ DeadlinePassed = $deadlinePassed; ProcessDisplayNames = $processDisplayNames }
            if ($null -ne $finalDeadline) { $messageParams.FinalDeadline = $finalDeadline }
            $customMessage = Get-WauBridgeUpdateCustomMessage @messageParams
            Set-WauBridgeCloseAppsCustomMessage -Message $customMessage
            $welcomeParams = @{
                CloseProcesses = $WauBridgeConfig.ProcessDefinitions
                PromptToSave   = $true
                PersistPrompt  = $true
                BlockExecution = $true
                Title          = $uiTitle
                Subtitle       = $subtitle
                CustomText     = $true
            }
            if ($deferralEligible) {
                $welcomeParams.AllowDeferCloseProcesses = $true
                if ($finalDeadline) { $welcomeParams.DeferDeadline = $finalDeadline }
            }
            if ($forceCloseAfterDeadline) {
                $welcomeParams.CloseProcessesCountdown = [int]$WauBridgeConfig.UserExperience.CloseCountdownSeconds
            }
            Add-WauBridgePromptShown -Context $script:WauBridgeState.Context
            Show-ADTInstallationWelcome @welcomeParams
            $showProgress = [bool]$WauBridgeConfig.UserExperience.ShowProgressInteractive
        }
        elseif (-not $script:WauBridgeState.Provisioning -and $script:WauBridgeState.Operation -eq 'Upgrade') {
            $showProgress = [bool]$WauBridgeConfig.UserExperience.ShowProgressSilent
        }

        if ($showProgress -and -not (Test-WauBridgeHasInteractiveUser)) {
            Write-WauBridgeLog -Message 'Bridge progress UI skipped because no single interactive user is present.'
            $showProgress = $false
        }

        Write-WauBridgeLog -Message ("Progress UI enabled: [{0}]" -f $showProgress)

        if ($showProgress) {
            $statusMessage = Get-WauBridgeUserExperienceValue -Name 'UpgradeStatusMessage'
            Show-ADTInstallationProgress -Title $uiTitle -Subtitle $subtitle -StatusMessage $statusMessage
        }

        $installResult = $null
        try {
            if (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context) {
                Set-WauBridgeCampaignState -Context $script:WauBridgeState.Context -State 'InProgress' -ScheduleState $script:WauBridgeState.ScheduleState
            }

            $installResult = Invoke-WauBridgeInstall -Operation $script:WauBridgeState.Operation
        }
        finally {
            if ($showProgress) { Close-WauBridgeProgressSafely }
        }
        $script:WauBridgeState.LastResult = $installResult
        $script:WauBridgeState.ReturnExitCode = Set-WauBridgeExitCodeFromResult -Result $installResult

        if (Test-WauBridgeSchedulePresent -Context $script:WauBridgeState.Context) {
            Set-WauBridgeCampaignState -Context $script:WauBridgeState.Context -State 'Completed' -ScheduleState $script:WauBridgeState.ScheduleState
            Complete-WauBridgeSchedule -Context $script:WauBridgeState.Context
        }

        if (-not $script:WauBridgeState.Provisioning) {
            if ($installResult.RebootRequired -and $WauBridgeConfig.UserExperience.ShowRestartPrompt) {
                $restartParams = @{ Title = $uiTitle; Subtitle = $subtitle }
                if ($WauBridgeConfig.UserExperience.RestartPromptNoCountdown) {
                    $restartParams.NoCountdown = $true
                }
                else {
                    if ($WauBridgeConfig.UserExperience.RestartCountdownSeconds) {
                        $restartParams.CountdownSeconds = [int]$WauBridgeConfig.UserExperience.RestartCountdownSeconds
                    }
                    if ($WauBridgeConfig.UserExperience.RestartCountdownNoHideSeconds) {
                        $restartParams.CountdownNoHideSeconds = [int]$WauBridgeConfig.UserExperience.RestartCountdownNoHideSeconds
                    }
                }
                Show-ADTInstallationRestartPrompt @restartParams
            }
            elseif ($script:WauBridgeState.Operation -eq 'Upgrade' -and $WauBridgeConfig.UserExperience.ShowSuccess) {
                if (-not (Test-WauBridgeHasInteractiveUser)) {
                    Write-WauBridgeLog -Message 'Bridge success prompt skipped because no single interactive user is present.'
                }
                else {
                    Show-ADTInstallationPrompt -Title $uiTitle -Subtitle (Get-WauBridgeUserExperienceValue -Name 'UpgradeSuccessSubtitle') -Message (Get-WauBridgeUserExperienceValue -Name 'UpgradeSuccess') -ButtonRightText (Get-WauBridgeUserExperienceValue -Name 'SuccessButtonText')
                }
            }
        }
    }
    catch {
        Invoke-WauBridgeRetryCatchUpSafely
        throw
    }
    finally {
        Exit-WauBridgeMutex -Mutex $bridgeMutex
    }
}

try {
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf) {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -Name "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -Force
    }
    else {
        Import-Module -Name 'PSAppDeployToolkit' -Force
    }
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
    $null = Get-WauBridgeLocalizationResource -Configuration $WauBridgeConfig -ScriptRoot $PSScriptRoot -Refresh
}
catch {
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}

try {
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | ForEach-Object {
        if ($_.Name -match 'PSAppDeployToolkit\..+$') {
            Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
            Import-Module -Name $_.FullName -Force
        }
    }
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession -ExitCode ([int]$script:WauBridgeState.ReturnExitCode)
}
catch {
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
