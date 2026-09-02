# Usage-day reminders from template Retry policy. Trigger instants are local;
# UTC is used only for arithmetic and persistence.

function Get-WauBridgeDeferralPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration)

    $retry = $Configuration.Retry
    $start = ConvertTo-WauBridgeDayTime -Value ([string]$retry.HoursStart)
    $end = ConvertTo-WauBridgeDayTime -Value ([string]$retry.HoursEnd)
    return [ordered]@{
        Enabled      = [bool]$retry.Enable
        Days         = [int]$retry.Days
        TimesPerDay  = [int]$retry.TimesPerDay
        SkipWeekends = [bool]$retry.SkipWeekends
        HoursStart   = $start.ToString('hh\:mm')
        HoursEnd     = $end.ToString('hh\:mm')
    }
}

function Get-WauBridgePolicyDayTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][ValidateSet('HoursStart','HoursEnd')][string]$Name
    )
    return (ConvertTo-WauBridgeDayTime -Value ([string]$Policy[$Name]))
}

function ConvertTo-WauBridgeDayTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'Usage hours value is empty.'
    }
    try {
        return [timespan]::ParseExact($Value.Trim(), 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "Usage hours value [$Value] is not HH:mm."
    }
}

function ConvertTo-WauBridgeUtc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Local,
        [Parameter(Mandatory)][System.TimeZoneInfo]$TimeZone
    )

    $unspec = [datetime]::SpecifyKind($Local, [DateTimeKind]::Unspecified)
    while ($TimeZone.IsInvalidTime($unspec)) { $unspec = $unspec.AddMinutes(1) }
    return [datetimeoffset]([TimeZoneInfo]::ConvertTimeToUtc($unspec, $TimeZone))
}

function Get-WauBridgeLocalDateTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetimeoffset]$Utc,
        [Parameter(Mandatory)][System.TimeZoneInfo]$TimeZone
    )

    return [TimeZoneInfo]::ConvertTime($Utc.ToUniversalTime(), $TimeZone).DateTime
}

function Test-WauBridgeUsageDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Date,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy
    )

    if ([bool]$Policy.SkipWeekends -and $Date.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) {
        return $false
    }
    return $true
}

function Test-WauBridgeLocalTimeEligible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Local,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [switch]$AllowWindowEnd
    )

    if (-not (Test-WauBridgeUsageDate -Date $Local.Date -Policy $Policy)) {
        return $false
    }
    $tod = $Local.TimeOfDay
    $start = Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursStart'
    $end = Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursEnd'
    if ($AllowWindowEnd) {
        return ($tod -ge $start -and $tod -le $end)
    }
    return ($tod -ge $start -and $tod -lt $end)
}

function Get-WauBridgeNextEligibleUtc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetimeoffset]$Utc,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][System.TimeZoneInfo]$TimeZone
    )

    $cursor = Get-WauBridgeLocalDateTime -Utc $Utc -TimeZone $TimeZone
    $maxDays = [Math]::Max(14, ([int]$Policy.Days * 2) + 7)
    for ($day = 0; $day -le $maxDays; $day++) {
        $date = $cursor.Date.AddDays($day)
        if (-not (Test-WauBridgeUsageDate -Date $date -Policy $Policy)) {
            continue
        }
        $from = $date.Add((Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursStart'))
        $to = $date.Add((Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursEnd'))
        if ($day -eq 0) {
            if ($cursor -lt $from) { return (ConvertTo-WauBridgeUtc -Local $from -TimeZone $TimeZone) }
            if ($cursor -lt $to) { return (ConvertTo-WauBridgeUtc -Local $cursor -TimeZone $TimeZone) }
            continue
        }
        return (ConvertTo-WauBridgeUtc -Local $from -TimeZone $TimeZone)
    }
    throw "No eligible usage-hour slot was found within $maxDays days."
}

function Test-WauBridgeUsageHoursActive {
    [CmdletBinding()]
    param(
        [datetimeoffset]$Utc = [datetimeoffset]::UtcNow,
        [System.TimeZoneInfo]$TimeZone = (Get-WauBridgeTimeZone)
    )

    $policy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
    $local = Get-WauBridgeLocalDateTime -Utc $Utc -TimeZone $TimeZone
    return (Test-WauBridgeLocalTimeEligible -Local $local -Policy $policy)
}

function Get-WauBridgeUsageDayDates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$FromLocal,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy
    )

    $dates = New-Object System.Collections.Generic.List[datetime]
    $date = $FromLocal.Date
    $guard = 0
    while ($dates.Count -lt $Count -and $guard -lt 32) {
        $guard++
        if (Test-WauBridgeUsageDate -Date $date -Policy $Policy) {
            $dates.Add($date)
        }
        $date = $date.AddDays(1)
    }
    if ($dates.Count -lt $Count) {
        throw "Could not collect $Count usage days from [$($FromLocal.ToString('yyyy-MM-dd'))]."
    }

    $hoursEnd = Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursEnd'
    while ($dates[-1].Add($hoursEnd) -le $FromLocal -and $guard -lt 48) {
        $guard++
        if (Test-WauBridgeUsageDate -Date $date -Policy $Policy) {
            $dates.Add($date)
        }
        $date = $date.AddDays(1)
    }
    return @($dates)
}

function Get-WauBridgeReminderMinGapMinutes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Policy)

    $window = (Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursEnd') - (Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursStart')
    $timesPerDay = [Math]::Max(1, [int]$Policy.TimesPerDay)
    return [int][Math]::Floor($window.TotalMinutes / ($timesPerDay + 1))
}

function Get-WauBridgeRandomTimesInWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][int]$MinGapMinutes,
        [Parameter(Mandatory)][Random]$Random
    )

    if ($Count -lt 1) { return @() }
    $spanMinutes = ($To - $From).TotalMinutes
    if ($spanMinutes -lt 15) { return @() }

    $times = New-Object System.Collections.Generic.List[datetime]
    if ($Count -eq 1 -or $spanMinutes -lt ($MinGapMinutes + 15)) {
        $due = $From.AddMinutes($Random.NextDouble() * $spanMinutes)
        if ($due -ge $To) { $due = $To.AddMinutes(-1) }
        if ($due -gt $From -and $due -lt $To) { $times.Add($due) }
        elseif ($spanMinutes -ge 15) { $times.Add($From.AddMinutes([Math]::Min(14, $spanMinutes / 2))) }
        return @($times)
    }

    $firstMax = $To.AddMinutes(-$MinGapMinutes)
    if ($firstMax -le $From) { return (Get-WauBridgeRandomTimesInWindow -From $From -To $To -Count 1 -MinGapMinutes $MinGapMinutes -Random $Random) }
    $firstSpan = ($firstMax - $From).TotalMinutes
    $first = $From.AddMinutes($Random.NextDouble() * $firstSpan)
    $secondFrom = $first.AddMinutes($MinGapMinutes)
    if ($secondFrom -ge $To) { return @($first) }
    $secondSpan = ($To - $secondFrom).TotalMinutes
    $second = $secondFrom.AddMinutes($Random.NextDouble() * $secondSpan)
    if ($second -ge $To) { $second = $To.AddMinutes(-1) }
    $times.Add($first)
    if ($second -gt $first -and $second -lt $To) { $times.Add($second) }
    return @($times)
}

function Test-WauBridgeDeferralPolicyMatches {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$PersistedPolicy,[Parameter(Mandatory)][System.Collections.IDictionary]$CurrentPolicy)

    if ($null -eq $PersistedPolicy) { return $false }
    foreach ($name in @('Enabled','Days','TimesPerDay','SkipWeekends','HoursStart','HoursEnd')) {
        if ($PersistedPolicy.PSObject.Properties.Name -notcontains $name) { return $false }
        if ([string]$PersistedPolicy.$name -cne [string]$CurrentPolicy[$name]) { return $false }
    }
    return $true
}

function Get-WauBridgeReminderSchedule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][datetimeoffset]$StartUtc,
        [System.TimeZoneInfo]$TimeZone = [System.TimeZoneInfo]::Utc,
        [int]$Seed = 0,
        [int]$ConsumedNow = 0
    )

    if (-not [bool]$Policy.Enabled) { return @() }

    $start = $StartUtc.ToUniversalTime()
    $startLocal = Get-WauBridgeLocalDateTime -Utc $start -TimeZone $TimeZone
    $hoursStart = Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursStart'
    $hoursEnd = Get-WauBridgePolicyDayTime -Policy $Policy -Name 'HoursEnd'
    $timesPerDay = [int]$Policy.TimesPerDay
    $minGap = Get-WauBridgeReminderMinGapMinutes -Policy $Policy
    $usageDays = @(Get-WauBridgeUsageDayDates -FromLocal $startLocal -Count ([int]$Policy.Days) -Policy $Policy)
    $deadlineLocal = $usageDays[-1].Add($hoursEnd)
    $deadlineUtc = ConvertTo-WauBridgeUtc -Local $deadlineLocal -TimeZone $TimeZone
    $rng = [Random]::new($Seed)
    $schedule = New-Object System.Collections.Generic.List[object]
    $consumed = [Math]::Max(0, $ConsumedNow)

    for ($i = 0; $i -lt $usageDays.Count; $i++) {
        $day = $usageDays[$i]
        $from = $day.Add($hoursStart)
        $to = $day.Add($hoursEnd)
        $slots = $timesPerDay

        if ($consumed -gt 0) {
            if ($day.Date -eq $startLocal.Date) {
                $slots -= $consumed
                $gapStart = $startLocal.AddMinutes($minGap)
                if ($gapStart -gt $from) { $from = $gapStart }
                $consumed = 0
            }
            elseif ($i -eq 0) {
                $slots -= $consumed
                $consumed = 0
            }
        }

        if ($from -ge $to -or $slots -lt 1) { continue }
        foreach ($local in @(Get-WauBridgeRandomTimesInWindow -From $from -To $to -Count $slots -MinGapMinutes $minGap -Random $rng)) {
            $due = ConvertTo-WauBridgeUtc -Local $local -TimeZone $TimeZone
            if ($due -gt $start -and $due -lt $deadlineUtc) {
                $schedule.Add([pscustomobject]@{ Kind = 'Reminder'; DueAtUtc = $due })
            }
        }
    }

    if ($schedule.Count -eq 0) {
        $day = $usageDays[-1]
        $from = $day.Add($hoursStart)
        $to = $day.Add($hoursEnd)
        if ($startLocal -gt $from) { $from = $startLocal.AddMinutes([Math]::Max(1, $minGap)) }
        foreach ($local in @(Get-WauBridgeRandomTimesInWindow -From $from -To $to -Count 1 -MinGapMinutes $minGap -Random $rng)) {
            $due = ConvertTo-WauBridgeUtc -Local $local -TimeZone $TimeZone
            if ($due -gt $start) {
                $schedule.Add([pscustomobject]@{ Kind = 'Deadline'; DueAtUtc = $due })
            }
        }
    }
    else {
        $ordered = @($schedule | Sort-Object DueAtUtc)
        $ordered[-1].Kind = 'Deadline'
        return $ordered
    }

    if ($schedule.Count -eq 0) {
        throw 'Deferral deadline must be later than campaign start.'
    }
    return @($schedule | Sort-Object DueAtUtc)
}

function Get-WauBridgeScheduleRandomSeed {
    [CmdletBinding()]
    param(
        [string]$CampaignId,
        [datetimeoffset]$StartUtc
    )

    $material = '{0}|{1}' -f $CampaignId, $StartUtc.ToUniversalTime().ToString('o')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToInt32($hash, 0) -band [int]::MaxValue)
    }
    finally {
        $sha.Dispose()
    }
}

function Get-WauBridgeScheduleTriggerDates {
    [CmdletBinding()]
    param(
        [datetimeoffset]$StartUtc = [datetimeoffset]::UtcNow,
        [System.TimeZoneInfo]$TimeZone = (Get-WauBridgeTimeZone),
        [int]$Seed = -1,
        [int]$ConsumedNow = 0
    )

    $policy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
    if ($Seed -lt 0) {
        $campaignId = ''
        if ($WauBridgeConfig.Contains('PackageId')) { $campaignId = [string]$WauBridgeConfig.PackageId }
        $Seed = Get-WauBridgeScheduleRandomSeed -CampaignId $campaignId -StartUtc $StartUtc
    }
    $schedule = @(Get-WauBridgeReminderSchedule -Policy $policy -StartUtc $StartUtc -TimeZone $TimeZone -Seed $Seed -ConsumedNow $ConsumedNow)
    return @($schedule | ForEach-Object {
        Get-WauBridgeLocalDateTime -Utc $_.DueAtUtc -TimeZone $TimeZone
    })
}

function Get-WauBridgeCatchUpTriggerDates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$FinalDeadline,
        [datetimeoffset]$Utc = [datetimeoffset]::UtcNow,
        [System.TimeZoneInfo]$TimeZone = (Get-WauBridgeTimeZone)
    )

    $policy = Get-WauBridgeDeferralPolicy -Configuration $WauBridgeConfig
    $nowLocal = Get-WauBridgeLocalDateTime -Utc $Utc -TimeZone $TimeZone
    if ($nowLocal -ge $FinalDeadline) {
        $nextUtc = Get-WauBridgeNextEligibleUtc -Utc $Utc.AddMinutes(2) -Policy $policy -TimeZone $TimeZone
        return @(Get-WauBridgeLocalDateTime -Utc $nextUtc -TimeZone $TimeZone)
    }

    $nextUtc = Get-WauBridgeNextEligibleUtc -Utc $Utc.AddMinutes(2) -Policy $policy -TimeZone $TimeZone
    $from = Get-WauBridgeLocalDateTime -Utc $nextUtc -TimeZone $TimeZone
    $to = $from.Date.Add((Get-WauBridgePolicyDayTime -Policy $policy -Name 'HoursEnd'))
    if ($to -gt $FinalDeadline) { $to = $FinalDeadline }
    if ($from -ge $to) { return @($FinalDeadline) }

    $seed = Get-WauBridgeScheduleRandomSeed -CampaignId ([string]$WauBridgeConfig.PackageId) -StartUtc $Utc
    $rng = [Random]::new($seed)
    $minGap = Get-WauBridgeReminderMinGapMinutes -Policy $policy
    $times = @(Get-WauBridgeRandomTimesInWindow -From $from -To $to -Count 1 -MinGapMinutes $minGap -Random $rng)
    if ($FinalDeadline -gt $nowLocal.AddMinutes(2) -and $times -notcontains $FinalDeadline) {
        $times += $FinalDeadline
    }
    return @($times | Sort-Object -Unique)
}
