#Requires -Version 7
<#
.SYNOPSIS
    Makes an onboard machine able to correct its own clock from the factory
    server, and corrects it now. Runs ON the onboard machine.

.DESCRIPTION
    Found on agv01 2026-09-03: the clock read 2027-02-08, 158 days fast. The
    machine had no reachable time source -- its configured NTP server
    (172.19.206.222) runs RIoT and answers nothing on 123, the gateway resets
    the connection, and there is no DNS for a public pool -- so w32time reported
    "Free-running System Clock" and the drift was unbounded.

    THIS IS A PROPERTY OF THE IMAGE, NOT A ONE-OFF. agv02, first reached the
    same day, read 2027-02-08 as well -- the same 158 days, the same wrong
    172.19.206.222 (one digit off the real server's 172.19.205.222), the same
    "Local CMOS Clock" source. Expect it on every car and run this as part of
    bringing one up, before anything reads a timestamp off it. The .222 pair
    differing only in the third octet is what makes the misconfiguration survive
    review.

    IT ALSO COMES BACK ON EVERY POWER LOSS, and until 2026-09-21 this script did
    not fix that. Read this part before assuming a car that was fixed once is
    fixed for good:

      * agv01 lost power twice on 2026-09-21 and came back reading 2027-02-05,
        137 days fast, source "Local CMOS Clock" -- with the NTP config from
        2026-09-03 still in place and the factory server still answering.
        w32tm /stripchart measured the offset perfectly well (-11873082s): the
        machine KNEW it was 137 days fast and refused to move.
      * The refusal is w32time policy, not a network fault.
        MaxPosPhaseCorrection / MaxNegPhaseCorrection shipped at 54000 seconds
        (15 hours). An offset past that limit is treated as "the peer or this
        machine cannot be trusted", so w32time declines the correction and falls
        back to Local CMOS Clock. 137 days is not close to 15 hours.
      * So the 2026-09-03 fix worked for exactly one boot. Set-Date is a manual
        step that bypasses the limit; NTP was then expected to hold the clock
        there, and NTP cannot hold what it is forbidden to correct.
      * The clock lands on roughly the same date every time (2027-02-08 on
        09-03, 2027-02-05 eighteen days later) instead of advancing with real
        time. The RTC is not running while the machine is off; firmware restores
        a stale saved value at power-on. The usual cause is a dead CMOS battery,
        which is a trip to the vehicle and is NOT what this script fixes.

    So this script now raises the correction limits to 0xFFFFFFFF and installs a
    startup task, which together let the machine dig itself out of an arbitrary
    offset with nobody present. Accepting an arbitrary time step is a real cost
    on a normal machine; on one that is known to jump and has no other time
    source, it beats the current behaviour of sitting on a wrong clock forever.

    This is a safety-relevant fault, not a cosmetic one. The onboard
    vehicle-safety gate compares the server's observedAt against this machine's
    own clock inside a 5-second window:

        return now - ObservedAt <= maxAge;      // VehicleSafetySignal.IsFresh

    A clock that far off makes every projection look stale, so a clean session
    can never leave RecoveryRequired / DEPARTURE_SAFETY_NOT_READY. The gate
    fails closed on a fact that has nothing to do with the vehicle -- which is
    the correct behaviour for the gate and a useless outcome for the operator.
    Until the onboard client checks its own clock at startup and says so
    (workspace#5, suggestion 2), the correction has to be finished before the
    onboard stack is started -- hence the startup task rather than a resync the
    operator is expected to remember.

    Four steps:

      1. Point w32time at the factory server (the image points it at RIoT).
      2. Lift MaxPos/MaxNegPhaseCorrection to 0xFFFFFFFF and shorten
         SpecialPollInterval, then restart the service so it reloads them.
      3. Resync. With the limits lifted this is what actually moves the clock,
         however far off it is. Set-Date is only a fallback now, used when a
         reference time was passed and the resync still left the clock wrong.
      4. Register a startup task that resyncs before anyone starts the onboard
         stack, so the next power loss costs nobody a trip.

    Re-running this on a machine whose clock is already correct is the point,
    not a waste: steps 2 and 4 are what survive the next power loss.

.PARAMETER ReferenceTime
    The correct current time, passed in by the control host. Optional since
    2026-09-21: with the correction limits lifted the machine can fix itself
    from the factory server. Pass it to keep the old belt-and-braces behaviour
    -- it is used only if the resync fails to bring the clock in.

.PARAMETER TimeServer
    Host to sync from. The factory server, which the vehicles already reach for
    ControlServer.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [datetime] $ReferenceTime,

    [string] $TimeServer = '172.19.205.222'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$configKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
$ntpClientKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'
$startupTaskName = 'W2G-ClockResyncAtStartup'

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message)
}

function Format-Dword {
    param([int] $Value)
    return '0x{0:X8}' -f $Value
}

# PowerShell parses 0xFFFFFFFF as the Int32 -1, and that is the only way to get
# those 32 bits into a DWORD from here: passing 4294967295 fails binding with
# "greater than the maximum allowed range of 2147483647". The registry holds the
# same bits either way, but a later read comes back as -1 -- do not "fix" a
# comparison against -1 by widening it to 4294967295.
function Set-W32TimeDword {
    param(
        [string] $Path,
        [string] $Name,
        [int] $Value
    )

    if (-not (Test-Path -Path $Path)) { throw "Missing registry key: $Path" }

    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    $current = if ($item -and ($item.PSObject.Properties.Name -contains $Name)) { [int] $item.$Name } else { $null }

    Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value
    Write-Step ("{0} = {1} (was {2})" -f $Name, (Format-Dword $Value), ($null -eq $current ? '<unset>' : (Format-Dword $current)))
}

# Offset against the server as w32time itself sees it, in seconds, positive when
# this machine is ahead. Independent of any reference time the caller passed --
# which is the point, because after this change the caller need not pass one.
# Best effort: returns $null when the output cannot be parsed, and the caller
# reports "unknown" rather than pretending the machine is fine.
function Get-ServerOffsetSeconds {
    param([string] $Server)

    $output = w32tm /stripchart /computer:$Server /samples:2 /dataonly 2>&1
    $hits = [regex]::Matches(($output -join "`n"), '(?m),\s*([-+]?\d+(?:[.,]\d+)?)s\s*$')
    if ($hits.Count -eq 0) {
        Write-Step ("stripchart gave nothing parseable: {0}" -f (($output -join ' ').Trim()))
        return $null
    }

    # stripchart reports the offset of the PEER relative to us, so a machine
    # running fast shows a large negative number. Flip it so "how far ahead is
    # this machine" reads the way it is named.
    $value = $hits[$hits.Count - 1].Groups[1].Value -replace ',', '.'
    return -1 * [double]::Parse($value, [cultureinfo]::InvariantCulture)
}

# Resync retries because the first attempt right after a service restart or a
# coarse jump can come back "no time data available" while w32time is still
# settling -- measured on agv03 2026-09-03, attempt 1 failed and attempt 2 a few
# seconds later succeeded. Judge it by the exit code, never by the message,
# which is localized.
#
# This used to judge the outcome by /query /source alone -- but the /config call
# has ALREADY set that string, so a failed resync produced no warning and looked
# exactly like success.
function Invoke-Resync {
    param([int] $Attempts = 5)

    foreach ($attempt in 1..$Attempts) {
        $resync = w32tm /resync /force 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Step ("resync succeeded on attempt {0}" -f $attempt)
            return $true
        }
        Write-Step ("resync attempt {0} failed: {1}" -f $attempt, ($resync -join ' '))
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 3 }
    }
    return $false
}

# The task exists so the correction happens before the onboard stack is started,
# not after an operator remembers. SYSTEM because w32time needs it; the retry
# loop because at startup the CPE link is often not up yet for the first try.
function Register-StartupResyncTask {
    param([string] $TaskName)

    $pwsh = (Get-Command -Name pwsh -CommandType Application -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) { throw 'pwsh was not found on this machine; the startup task would never run.' }

    $loop = 'foreach ($i in 1..10) { & w32tm.exe /resync /force *>$null; if ($LASTEXITCODE -eq 0) { exit 0 }; Start-Sleep -Seconds 30 }; exit 1'
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "{0}"' -f $loop)

    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    # -AllowStartIfOnBatteries is load-bearing here and not boilerplate: these
    # machines ride on the vehicle and Windows sees a battery, so without it the
    # task would skip exactly the boots this is for.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Resync the clock from the factory server at startup (workspace#5).' -Force | Out-Null
    Write-Step ("Startup task '{0}' registered, running {1}" -f $TaskName, $pwsh)
}

# The elevation check is skipped under -WhatIf so a dry run can be read from any
# shell. Every call that actually changes something sits behind the
# ShouldProcess gate below, so nothing can slip past this.
if (-not $WhatIfPreference) {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated.'
    }
}

$hasReference = $PSBoundParameters.ContainsKey('ReferenceTime')
$before = Get-Date
Write-Step ("Before: {0}" -f $before.ToString('yyyy-MM-dd HH:mm:ss'))
if ($hasReference) {
    $drift = $before - $ReferenceTime
    Write-Step ("Reference: {0}" -f $ReferenceTime.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Step ("Drift vs reference: {0:N1} days ({1:N0} seconds)" -f $drift.TotalDays, $drift.TotalSeconds)
}
else {
    Write-Step 'No reference time passed; the correction comes from the time server.'
}

# No early return when the clock already looks right. Installing the limits and
# the startup task is what makes the NEXT power loss a non-event, and a machine
# whose clock is currently fine is exactly where that has to be installed.
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Lift the w32time correction limits, sync from $TimeServer, and register '$startupTaskName'")) {
    Write-Step 'WhatIf: nothing above was changed.'
    return
}

# Step 1: a reachable source. 0x9 is "client mode, use as fallback" -- the flag
# the previous (unreachable) entry also used, and its 0x1 half is what makes
# SpecialPollInterval below the interval that applies.
$null = w32tm /config /manualpeerlist:"${TimeServer},0x9" /syncfromflags:manual /update 2>&1

# Step 2: the limits. Without these the machine measures a 137-day offset,
# decides the measurement cannot be trusted, and stays wrong -- which is the
# whole of workspace#5. MaxAllowedPhaseOffset is deliberately left alone: it
# only decides step vs. slew, and its default already steps an offset this big.
Set-W32TimeDword -Path $configKey -Name 'MaxPosPhaseCorrection' -Value 0xFFFFFFFF
Set-W32TimeDword -Path $configKey -Name 'MaxNegPhaseCorrection' -Value 0xFFFFFFFF

# 32768 seconds (9 hours) shipped with the image. An hour bounds how long a
# machine that drifts between polls stays wrong, and one NTP packet an hour
# costs the factory server nothing.
Set-W32TimeDword -Path $ntpClientKey -Name 'SpecialPollInterval' -Value 3600

$null = w32tm /config /update 2>&1
Set-Service w32time -StartupType Automatic
Restart-Service w32time
Start-Sleep -Seconds 3

# Step 3: this is now the step that moves the clock, however far off it is.
$synced = Invoke-Resync
Write-Step ("Now: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

$offset = Get-ServerOffsetSeconds -Server $TimeServer
if ($null -ne $offset) {
    Write-Step ("Offset vs {0}: {1:N3} seconds" -f $TimeServer, $offset)
}

# The fallback. It is the old step 1, demoted: it only runs when the resync left
# the clock wrong AND the caller supplied a time to jump to.
$stillWrong = ($null -ne $offset -and [Math]::Abs($offset) -ge 5) -or (-not $synced -and $null -eq $offset)
if ($stillWrong -and $hasReference) {
    Write-Step 'Resync did not bring the clock in; falling back to the manual coarse jump.'
    Set-Date -Date $ReferenceTime | Out-Null
    Write-Step ("Clock set by hand. Now: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $synced = Invoke-Resync
    $offset = Get-ServerOffsetSeconds -Server $TimeServer
}
elseif ($stillWrong) {
    Write-Warning "The clock is still wrong and no -ReferenceTime was passed. Re-run with one, and check that 16-enable-ntp-server.ps1 has been run on the factory server."
}

if (-not $synced) {
    Write-Warning 'w32tm /resync never succeeded. Nothing is holding this clock -- do not start the onboard stack until it is.'
}

# Step 4: make the next power loss a non-event.
Register-StartupResyncTask -TaskName $startupTaskName

$source = w32tm /query /source 2>&1
Write-Step ("Source now: {0}" -f ($source -join ' '))
Write-Step ("After: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

if ($source -match 'Free-running|本地 CMOS|Local CMOS') {
    Write-Warning "Still free-running: $TimeServer did not answer. The clock may be correct now but nothing is holding it there."
    Write-Warning "Check that 16-enable-ntp-server.ps1 has been run on the factory server."
}
