$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1

. (Join-Path $PSScriptRoot 'Helpers.ps1')
$repoRoot = Get-BridgeRepoRoot
$templateRoot = Join-Path $repoRoot 'template'

. (Join-Path $templateRoot 'App/WauBridge.Config.ps1')
. (Join-Path $templateRoot 'Framework/WauBridge.Core.ps1')
. (Join-Path $templateRoot 'Framework/WauBridge.Deferral.ps1')
$deferralText = Get-Content -LiteralPath (Join-Path $templateRoot 'Framework/WauBridge.Deferral.ps1') -Raw
Assert-True ($deferralText -notmatch 'function Resolve-WauBridgeDeferralDeadline') 'no unused deadline resolver'

Assert-True ($WauBridgeConfig.Retry.Days -eq 3) 'Days from template config'
Assert-True ($WauBridgeConfig.Retry.TimesPerDay -eq 1) 'TimesPerDay from template config'
Assert-True (-not $WauBridgeConfig.Retry.Contains('BlockMinutes')) 'no BlockMinutes in config'
Assert-True (-not $WauBridgeConfig.Retry.Contains('DeadlineHours')) 'no DeadlineHours in config'
Assert-True (-not $WauBridgeConfig.Retry.Contains('DeferTimes')) 'no DeferTimes in config'

$tz = [TimeZoneInfo]::Utc
$policy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
Assert-True ($policy.HoursStart -eq '08:00') 'policy start from config'
Assert-True ($policy.HoursEnd -eq '17:00') 'policy end from config'
Assert-True ([bool]$policy.SkipWeekends) 'policy skip weekends from config'
Assert-True ([int]$policy.Days -eq 3) 'policy days from config'
Assert-True ([int]$policy.TimesPerDay -eq 1) 'policy times per day from config'

function Get-ReminderLocals($Schedule, $TimeZone) {
    return @($Schedule | Where-Object Kind -eq 'Reminder' | ForEach-Object {
        Get-WauBridgeLocalDateTime -Utc $_.DueAtUtc -TimeZone $TimeZone
    })
}

# Wednesday 15:00, first dialog consumes today: Thursday reminder, Friday deadline (random, not 17:00)
$wednesdayAfternoon = [datetimeoffset]::Parse('2026-09-02T15:00:00Z')
$wedSchedule = @(Get-WauBridgeReminderSchedule -Policy $policy -StartUtc $wednesdayAfternoon -TimeZone $tz -Seed 42 -ConsumedNow 1)
Assert-True ($wedSchedule.Count -eq 2) 'one future reminder plus last-day deadline'
Assert-True ($wedSchedule[-1].Kind -eq 'Deadline') 'last item is deadline'
$wedDeadlineLocal = Get-WauBridgeLocalDateTime -Utc $wedSchedule[-1].DueAtUtc -TimeZone $tz
Assert-True ($wedDeadlineLocal.Date -eq [datetime]'2026-09-04') 'deadline is Friday'
Assert-True ($wedDeadlineLocal.TimeOfDay -lt [timespan]'17:00') 'deadline is random, not HoursEnd'
$wedReminders = @(Get-ReminderLocals $wedSchedule $tz)
Assert-True ($wedReminders.Count -eq 1) 'only Thursday is a non-deadline reminder'
Assert-True (@($wedReminders | Where-Object { $_.Date -eq [datetime]'2026-09-02' }).Count -eq 0) 'no same-day reminder after the first dialog'
Assert-True ($wedReminders[0].Date -eq [datetime]'2026-09-03') 'second dialog Thursday'
Assert-True (@($wedSchedule | Where-Object { (Get-WauBridgeLocalDateTime -Utc $_.DueAtUtc -TimeZone $tz).Date -eq [datetime]'2026-09-04' }).Count -eq 1) 'Friday has a single trigger'

# Friday evening: Monday reminder, Tuesday deadline (random)
$fridayEvening = [datetimeoffset]::Parse('2026-09-04T21:38:00Z')
$fridaySchedule = @(Get-WauBridgeReminderSchedule -Policy $policy -StartUtc $fridayEvening -TimeZone $tz -Seed 42 -ConsumedNow 1)
$fridayReminders = @(Get-ReminderLocals $fridaySchedule $tz)
$fridayDeadlineLocal = Get-WauBridgeLocalDateTime -Utc $fridaySchedule[-1].DueAtUtc -TimeZone $tz
Assert-True ($fridaySchedule[-1].Kind -eq 'Deadline') 'Friday-evening last item is deadline'
Assert-True ($fridayDeadlineLocal.Date -eq [datetime]'2026-09-08') 'deadline is Tuesday'
Assert-True ($fridayDeadlineLocal.TimeOfDay -lt [timespan]'17:00') 'Tuesday deadline is random, not 17:00'
Assert-True ($fridayReminders.Count -eq 1) 'one reminder before the last day'
Assert-True ($fridayReminders[0].Date -eq [datetime]'2026-09-07') 'Monday reminder'
Assert-True (@($fridaySchedule | Where-Object { (Get-WauBridgeLocalDateTime -Utc $_.DueAtUtc -TimeZone $tz).Date -eq [datetime]'2026-09-08' }).Count -eq 1) 'Tuesday has a single trigger'

# Tuesday 10:00 in window, consumed today: not a 24h deadline at Wednesday 10:00
$tuesdayMorning = [datetimeoffset]::Parse('2026-09-08T10:00:00Z')
$tueSchedule = @(Get-WauBridgeReminderSchedule -Policy $policy -StartUtc $tuesdayMorning -TimeZone $tz -Seed 7 -ConsumedNow 1)
$tueReminders = @(Get-ReminderLocals $tueSchedule $tz)
$tueDeadlineLocal = Get-WauBridgeLocalDateTime -Utc $tueSchedule[-1].DueAtUtc -TimeZone $tz
Assert-True (@($tueReminders | Where-Object { $_.Date -eq [datetime]'2026-09-08' }).Count -eq 0) 'no extra Tuesday trigger'
Assert-True ($tueDeadlineLocal.Date -eq [datetime]'2026-09-10') 'last usage day is Thursday'
Assert-True ($tueDeadlineLocal.TimeOfDay -ne [timespan]'10:00') 'deadline is not start-plus-24h'

$afterClose = Get-WauBridgeNextEligibleUtc -Utc ([datetimeoffset]::Parse('2026-09-07T17:01:00Z')) -Policy $policy -TimeZone $tz
Assert-True ($afterClose.UtcDateTime -eq [datetime]'2026-09-08 08:00:00') '17:01 -> next weekday 08:00'

$saturday = Get-WauBridgeNextEligibleUtc -Utc ([datetimeoffset]::Parse('2026-09-05T10:00:00Z')) -Policy $policy -TimeZone $tz
Assert-True ($saturday.UtcDateTime -eq [datetime]'2026-09-07 08:00:00') 'saturday -> Monday 08:00'

$WauBridgeConfig.Retry.SkipWeekends = $false
$weekendPolicy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
$saturdayOpen = Get-WauBridgeNextEligibleUtc -Utc ([datetimeoffset]::Parse('2026-09-05T10:00:00Z')) -Policy $weekendPolicy -TimeZone $tz
Assert-True ($saturdayOpen.UtcDateTime -eq [datetime]'2026-09-05 10:00:00') 'skip weekends off keeps Saturday 10:00'
$WauBridgeConfig.Retry.SkipWeekends = $true
$policy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig

foreach ($item in $wedSchedule) {
    $local = Get-WauBridgeLocalDateTime -Utc $item.DueAtUtc -TimeZone $tz
    if ($item.Kind -eq 'Deadline') {
        Assert-True (Test-WauBridgeLocalTimeEligible -Local $local -Policy $policy -AllowWindowEnd) 'deadline in usage hours'
    }
    else {
        Assert-True (Test-WauBridgeLocalTimeEligible -Local $local -Policy $policy) 'reminder in usage hours'
        Assert-True ($local.DayOfWeek -notin @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) 'reminder not on weekend'
    }
}

# TimesPerDay and Days come from config, not hardcoded 3/1 in the scheduler
$WauBridgeConfig.Retry.TimesPerDay = 2
$twoPolicy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
Assert-True ([int]$twoPolicy.TimesPerDay -eq 2) 'TimesPerDay 2 is read from config'
$twoLate = @(Get-WauBridgeReminderSchedule -Policy $twoPolicy -StartUtc $wednesdayAfternoon -TimeZone $tz -Seed 42 -ConsumedNow 1)
$twoLateReminders = @(Get-ReminderLocals $twoLate $tz)
Assert-True (@($twoLateReminders | Where-Object { $_.Date -eq [datetime]'2026-09-02' }).Count -eq 0) '15:00 start does not add a second slot the same day'
Assert-True (($twoLate.Count -eq 4) -and ($twoLateReminders.Count -eq 3)) 'remaining days get two slots; last slot is the deadline'

$wednesdayMorning = [datetimeoffset]::Parse('2026-09-02T09:00:00Z')
$twoEarly = @(Get-WauBridgeReminderSchedule -Policy $twoPolicy -StartUtc $wednesdayMorning -TimeZone $tz -Seed 42 -ConsumedNow 1)
$twoEarlyReminders = @(Get-ReminderLocals $twoEarly $tz)
$twoEarlyToday = @($twoEarlyReminders | Where-Object { $_.Date -eq [datetime]'2026-09-02' })
Assert-True ($twoEarlyToday.Count -eq 1) 'morning start keeps one later slot today when TimesPerDay is 2'
Assert-True ($twoEarlyToday[0].Hour -ge 12) 'second today stays after the config-derived gap'

$WauBridgeConfig.Retry.TimesPerDay = 1

$pastDeadline = Get-Date '2026-09-01 10:00:00'
$catchUpAfterDeadline = @(Get-WauBridgeCatchUpTriggerDates -FinalDeadline $pastDeadline -Utc ([datetimeoffset]::Parse('2026-09-02T15:00:00Z')) -TimeZone $tz)
Assert-True ($catchUpAfterDeadline.Count -eq 1) 'catch-up after deadline still has one future trigger'
Assert-True ($catchUpAfterDeadline[0] -gt [datetime]'2026-09-02 15:00:00') 'catch-up after deadline is in the future'
Assert-True ($catchUpAfterDeadline[0] -ne $pastDeadline) 'catch-up after deadline does not move FinalDeadline'
$WauBridgeConfig.Retry.HoursStart = '09:30'
$WauBridgeConfig.Retry.HoursEnd = '16:00'
$customPolicy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
Assert-True ($customPolicy.HoursStart -eq '09:30') 'custom start is not hardcoded'
Assert-True ($customPolicy.HoursEnd -eq '16:00') 'custom end is not hardcoded'
$customSchedule = @(Get-WauBridgeReminderSchedule -Policy $customPolicy -StartUtc $wednesdayAfternoon -TimeZone $tz -Seed 42 -ConsumedNow 1)
$customDeadlineLocal = Get-WauBridgeLocalDateTime -Utc $customSchedule[-1].DueAtUtc -TimeZone $tz
Assert-True ($customDeadlineLocal.Date -eq [datetime]'2026-09-04') 'custom window last day is Friday'
Assert-True ($customDeadlineLocal.TimeOfDay -ge [timespan]'09:30') 'custom deadline is inside HoursStart'
Assert-True ($customDeadlineLocal.TimeOfDay -lt [timespan]'16:00') 'custom deadline is random, not HoursEnd'
$customNext = Get-WauBridgeNextEligibleUtc -Utc ([datetimeoffset]::Parse('2026-09-07T16:01:00Z')) -Policy $customPolicy -TimeZone $tz
Assert-True ($customNext.UtcDateTime -eq [datetime]'2026-09-08 09:30:00') 'custom window 16:01 -> next day 09:30'

Write-Output 'Deferral.Tests: OK'
