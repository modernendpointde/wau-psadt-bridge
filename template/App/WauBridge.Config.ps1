$WauBridgeConfig = [ordered]@{
    SuccessExitCodes           = @(0)
    RebootExitCodes            = @(1641, 3010)
    RequireAdmin               = $true

    Localization               = [ordered]@{
        Culture                = 'Auto'
        DefaultCulture         = 'en-US'
        MessagesPath           = 'Messages'
    }

    UserExperience             = [ordered]@{
        ShowSuccess                    = $true
        ShowRestartPrompt              = $true
        RestartPromptNoCountdown       = $false
        RestartCountdownSeconds        = 1800
        RestartCountdownNoHideSeconds  = 300
        CloseCountdownSeconds          = 300
        ShowProgressSilent             = $true
        ShowProgressInteractive        = $true
    }

    Retry                      = [ordered]@{
        Enable                     = $true
        Days                       = 3
        TimesPerDay                = 1
        SkipWeekends               = $true
        HoursStart                 = '08:00'
        HoursEnd                   = '17:00'
    }
}
