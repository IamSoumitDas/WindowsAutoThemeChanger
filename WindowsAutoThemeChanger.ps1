param (
    [ValidateSet("", "light", "dark")]
    [string]$Override = ""
)

# ============================================================
# 1. CONFIGURATION (EDIT THESE BEFORE RUNNING)
# ============================================================

# The name of the background task created in Windows Task Scheduler.
# You can usually leave this as the default.
$TaskName = "WindowsAutoThemeChanger"

# Enter your exact geographic location so the script can calculate the sun's position.
# How to find this: Go to Google Maps, right-click your city or house, and click the numbers to copy them.
# Example for New York: Latitude = 40.7128, Longitude = -74.0060
$Latitude  = 
$Longitude = 

# Adjusts exactly WHEN the theme switches based on how dark it is outside:
#   90.833 = Official Sunset   (The moment the sun touches the horizon. It is usually still bright out).
#   96.0   = Civil Twilight    (About 20-30 mins after sunset. Streetlights turn on. Recommended for Dark Mode).
#   102.0  = Nautical Twilight (About an hour after sunset. The sky is mostly dark).
$SolarZenith = 90.833

# ============================================================
# 2. CHECK FOR ADMINISTRATOR PRIVILEGES
# ============================================================
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Warning "This script requires Administrator privileges to create the Scheduled Task."
    Write-Warning "Please right-click PowerShell, select 'Run as Administrator', and try again."
    Start-Sleep -Seconds 5
    exit 1
}

$ScriptPath =$PSCommandPath
if (-not $ScriptPath) {
    Write-Warning "Save this script to a .ps1 file before running it."
    exit 1
}

# ============================================================
# 3. HELPER FUNCTIONS
# ============================================================
function Convert-DegreesToRadians { param ([double]$Degrees) return $Degrees * [Math]::PI / 180.0 }
function Convert-RadiansToDegrees { param ([double]$Radians) return $Radians * 180.0 / [Math]::PI }
function Normalize-Degrees {
    param ([double]$Degrees)
    $result =$Degrees % 360.0
    if ($result -lt 0) {$result += 360.0 }
    return $result
}

function Get-SolarEvent {
    param (
        [datetime]$Date,
        [double]$Latitude,
        [double]$Longitude,
        [double]$TimeZoneOffsetHours,
        [double]$Zenith,
        [ValidateSet("Sunrise", "Sunset")]
        [string]$Event
    )

    $utcDate = $Date.Date.AddHours(-$TimeZoneOffsetHours)
    $year =$utcDate.Year
    $month =$utcDate.Month
    $day =$utcDate.Day

    if ($month -le 2) {$year -= 1; $month += 12 }
    $A = [Math]::Floor($year / 100.0)
    $B = 2 - $A + [Math]::Floor($A / 4.0)

    $JD = [Math]::Floor(365.25 * ($year + 4716)) + [Math]::Floor(30.6001 * ($month + 1)) + $day +$B - 1524.5
    $T = ($JD - 2451545.0) / 36525.0

    $L0 = Normalize-Degrees (280.46646 +$T * (36000.76983 + 0.0003032 * $T))$M = Normalize-Degrees (357.52911 + $T * (35999.05029 - 0.0001537 * $T))
    $Mr = Convert-DegreesToRadians $M

    $C = ([Math]::Sin($Mr) * (1.914602 -$T * (0.004817 + 0.000014 * $T))) + ([Math]::Sin(2 * $Mr) * (0.019993 - 0.000101 * $T)) + ([Math]::Sin(3 * $Mr) * 0.000289)
    $SunTrueLongitude =$L0 + $C
    $Omega = 125.04 - 1934.136 * $T
    $SunApparentLongitude = $SunTrueLongitude - 0.00569 - 0.00478 * [Math]::Sin((Convert-DegreesToRadians $Omega))

    $ObliquityMean = 23.0 + (26.0 + ((21.448 -$T * (46.815 + $T * (0.00059 - 0.001813 * $T))) / 60.0)) / 60.0
    $ObliquityCorrection =$ObliquityMean + 0.00256 * [Math]::Cos((Convert-DegreesToRadians $Omega))
    $ObliquityRad = Convert-DegreesToRadians $ObliquityCorrection $ApparentLongitudeRad = Convert-DegreesToRadians $SunApparentLongitude $SinDeclination = [Math]::Sin($ObliquityRad) * [Math]::Sin($ApparentLongitudeRad)
    $SolarDeclination = Convert-RadiansToDegrees ([Math]::Asin($SinDeclination))

    $y = [Math]::Pow([Math]::Tan($ObliquityRad / 2.0), 2)
    $L0Rad = Convert-DegreesToRadians $L0

    $EqTimeRadians = $y * [Math]::Sin(2.0 * $L0Rad) - 2.0 * 0.016708634 * [Math]::Sin($Mr) + 4.0 * 0.016708634 * $y * [Math]::Sin($Mr) * [Math]::Cos(2.0 * $L0Rad) - 0.5 * $y * $y * [Math]::Sin(4.0 * $L0Rad) - 1.25 * 0.016708634 * 0.016708634 * [Math]::Sin(2.0 * $Mr)
    $EqTime = 4.0 * (Convert-RadiansToDegrees $EqTimeRadians)

    $LatitudeRad = Convert-DegreesToRadians $Latitude
    $ZenithRad = Convert-DegreesToRadians $Zenith
    $DeclinationRad = Convert-DegreesToRadians $SolarDeclination

    $CosHourAngle = ([Math]::Cos($ZenithRad) / ([Math]::Cos($LatitudeRad) * [Math]::Cos($DeclinationRad))) - ([Math]::Tan($LatitudeRad) * [Math]::Tan($DeclinationRad))

    if ($CosHourAngle -gt 1.0) { throw "Sun does not rise on $($Date.ToString('yyyy-MM-dd')) at this location." }
    if ($CosHourAngle -lt -1.0) { throw "Sun does not set on $($Date.ToString('yyyy-MM-dd')) at this location." }

    $HourAngle = Convert-RadiansToDegrees ([Math]::Acos($CosHourAngle))
    if ($Event -eq "Sunset") { $HourAngle = -$HourAngle }

    $UTCMinutes = 720.0 - (4.0 * ($Longitude +$HourAngle)) - $EqTime
    $localMinutes = $UTCMinutes + ($TimeZoneOffsetHours * 60.0)

    while ($localMinutes -lt 0) {$localMinutes += 1440 }
    while ($localMinutes -ge 1440) {$localMinutes -= 1440 }

    $hours = [Math]::Floor($localMinutes / 60.0)
    $minutes = [Math]::Floor($localMinutes - ($hours * 60.0))
    $seconds = [Math]::Round(($localMinutes - ($hours * 60.0) -$minutes) * 60.0)

    if ($seconds -ge 60) { $seconds = 0; $minutes++ }
    if ($minutes -ge 60) { $minutes = 0; $hours++ }
    if ($hours -ge 24) {$hours = 0 }

    return $Date.Date.AddHours($hours).AddMinutes($minutes).AddSeconds($seconds)
}

# ============================================================
# 4. CALCULATE TODAY'S SUNRISE AND SUNSET
# ============================================================
$Now = Get-Date
$TzOffsetNow = [TimeZoneInfo]::Local.GetUtcOffset($Now).TotalHours

try {
    $SunriseToday = Get-SolarEvent -Date $Now -Latitude $Latitude -Longitude $Longitude -TimeZoneOffsetHours $TzOffsetNow -Zenith $SolarZenith -Event "Sunrise"
    $SunsetToday = Get-SolarEvent -Date $Now -Latitude $Latitude -Longitude $Longitude -TimeZoneOffsetHours $TzOffsetNow -Zenith $SolarZenith -Event "Sunset"
} catch {
    Write-Host "ERROR calculating today's sunrise/sunset:"
    Write-Host $_
    exit 1
}

Write-Host "`n==============================================="
Write-Host " Windows Automatic Theme Changer"
Write-Host "===============================================`n"
Write-Host "Location:"
Write-Host "  Latitude : $Latitude"
Write-Host "  Longitude: $Longitude"
Write-Host "  Timezone : $([TimeZoneInfo]::Local.DisplayName)`n"
Write-Host "Current time : $($Now.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Sunrise      : $($SunriseToday.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Sunset       : $($SunsetToday.ToString('yyyy-MM-dd HH:mm:ss'))`n"

# ============================================================
# 5. DETERMINE CURRENT MODE AND NEXT EVENT
# ============================================================
if ($Now -ge $SunriseToday -and $Now -lt $SunsetToday) {$CurrentMode = "light"
    $NextTime =$SunsetToday
} else {
    $CurrentMode = "dark"
    if ($Now -lt $SunriseToday) {
        $NextTime = $SunriseToday
    } else {
        $Tomorrow = $Now.AddDays(1)
        $TzOffsetTomorrow = [TimeZoneInfo]::Local.GetUtcOffset($Tomorrow).TotalHours
        try {
            $NextTime = Get-SolarEvent -Date $Tomorrow -Latitude $Latitude -Longitude $Longitude -TimeZoneOffsetHours $TzOffsetTomorrow -Zenith $SolarZenith -Event "Sunrise"
        } catch {
            Write-Host "ERROR calculating tomorrow's sunrise:"
            Write-Host $_
            exit 1
        }
    }
}

if ($Override -eq "light" -or $Override -eq "dark") {
    $CurrentMode =$Override
    Write-Host "Manual override applied: $CurrentMode"
}

# ============================================================
# 6. APPLY THEME
# ============================================================
$RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$TargetValue = if ($CurrentMode -eq "light") { 1 } else { 0 }

$SystemTheme = (Get-ItemProperty -Path $RegPath -Name "SystemUsesLightTheme" -ErrorAction SilentlyContinue).SystemUsesLightTheme
$AppsTheme = (Get-ItemProperty -Path $RegPath -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue).AppsUseLightTheme

if ($SystemTheme -ne $TargetValue -or$AppsTheme -ne $TargetValue -or$Override) {
    Set-ItemProperty -Path $RegPath -Name "SystemUsesLightTheme" -Type DWord -Value $TargetValue
    Set-ItemProperty -Path $RegPath -Name "AppsUseLightTheme" -Type DWord -Value $TargetValue

    $RefreshCode = @'
    using System;
    using System.Runtime.InteropServices;
    public class ThemeRefresh {
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
'@
    Add-Type -TypeDefinition $RefreshCode -ErrorAction SilentlyContinue
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x001A
    [ThemeRefresh]::SendMessageTimeout($HWND_BROADCAST,$WM_SETTINGCHANGE, [UIntPtr]::Zero, "ImmersiveColorSet", 2, 5000, [ref][UIntPtr]::Zero) | Out-Null
    Write-Host "Theme applied: $CurrentMode"
} else {
    Write-Host "Theme already correct: $CurrentMode"
}

# ============================================================
# 7. SCHEDULE TASK
# ============================================================
if ($NextTime -le$Now) { $NextTime =$Now.AddMinutes(2) }

$TimeTrigger = New-ScheduledTaskTrigger -Once -At $NextTime
$LogonTrigger = New-ScheduledTaskTrigger -AtLogOn
$Triggers = @($TimeTrigger,$LogonTrigger)

$VbsPath =$ScriptPath -replace '\.ps1$', '.vbs'
$VbsContent = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$ScriptPath""", 0, False
"@
Set-Content -Path $VbsPath -Value $VbsContent -Force

$Action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
$TaskExists = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

if ($TaskExists) {
    Set-ScheduledTask -TaskName $TaskName -Trigger $Triggers -Action $Action -Settings $Settings -Principal $Principal | Out-Null
    Write-Host "`nScheduled task updated (Highest Privileges applied)."
    Write-Host "Next run: $($NextTime.ToString('yyyy-MM-dd HH:mm:ss')) (and at Log On)"
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Triggers -Settings $Settings -Principal $Principal | Out-Null
    Write-Host "`nScheduled task created (Highest Privileges applied)."
    Write-Host "Next run: $($NextTime.ToString('yyyy-MM-dd HH:mm:ss')) (and at Log On)"
}

Write-Host "`n==============================================="
Write-Host " Status"
Write-Host "==============================================="
Write-Host "Current mode : $CurrentMode"
Write-Host "Next event   : $($NextTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Task name    : $TaskName"
Write-Host "===============================================`n"
