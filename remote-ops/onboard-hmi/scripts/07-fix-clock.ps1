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

    A SUB-SECOND OFFSET STRANDS THE CAR TOO, and a resync does not fix it
    (workspace#55). agv02 lost power on 2026-10-18 and came back 0.77 s slow.
    The onboard tolerance is vehicleSafety.clockSkewToleranceMs = 500, so every
    projection looked stale and the car sat in DEPARTURE_SAFETY_NOT_READY for 83
    minutes with RIoT healthy and nothing on the screen. w32tm /resync did not
    help: MaxAllowedPhaseOffset is 1 second on these machines (read on agv02 and
    agv03 2026-10-19), so anything under a second is slewed, not stepped, and
    the slew had not closed the gap 83 minutes later. Set-Date -Adjust 0.7655 s
    did, and the car went Ready within seconds -- while the onboard client was
    already running, which is what makes a correction shortly after boot enough.

    Five steps:

      1. Point w32time at the factory server (the image points it at RIoT).
      2. Lift MaxPos/MaxNegPhaseCorrection to 0xFFFFFFFF and shorten
         SpecialPollInterval, then restart the service so it reloads them.
      3. Resync. With the limits lifted this is what actually moves the clock,
         however far off it is. Set-Date is only a fallback now, used when a
         reference time was passed and the resync still left the clock wrong.
      4. Measure the offset against the server and step a sub-second one out
         with Set-Date -Adjust (Invoke-SubSecondCorrection).
      5. Install a copy of this script under Program Files and register a
         startup task that runs steps 3 and 4 (-AtStartup) before anyone
         starts the onboard stack, so the next power loss costs nobody a trip.
         It runs right after step 2, so a failure in steps 3 and 4 does not
         cost the car its startup task.

    Exit 2 when the offset could not be confirmed within the threshold.

    Re-running this on a machine whose clock is already correct is the point,
    not a waste: steps 2 and 5 are what survive the next power loss.

.PARAMETER ReferenceTime
    The correct current time, passed in by the control host. Optional since
    2026-09-21: with the correction limits lifted the machine can fix itself
    from the factory server. Pass it to keep the old belt-and-braces behaviour
    -- it is used only if the resync fails to bring the clock in.

.PARAMETER TimeServer
    Host to sync from. The factory server, which the vehicles already reach for
    ControlServer.

.PARAMETER AtStartup
    What the startup task runs: resync, then measure and step out a sub-second
    offset (steps 3 and 4), logging to the installed copy's directory. Exit 0
    only when the offset was measured and is within the threshold.

.PARAMETER SelfTest
    Offline self-test (07-fix-clock.selftest.ps1): the offset decision, the
    startup loop and the registry writes, with stand-ins for w32tm, Set-Date
    and the clock, against a temporary HKCU key. Needs no elevation and
    touches neither the clock nor w32time.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Fix')]
param(
    [Parameter(ParameterSetName = 'Fix')]
    [datetime] $ReferenceTime,

    [Parameter(ParameterSetName = 'Fix')]
    [Parameter(ParameterSetName = 'AtStartup')]
    [string] $TimeServer = '172.19.205.222',

    [Parameter(Mandatory, ParameterSetName = 'AtStartup')]
    [switch] $AtStartup,

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$configKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
$ntpClientKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'
$startupTaskName = 'W2G-ClockResyncAtStartup'

# Program Files, not ProgramData: a SYSTEM task must not run a file from a
# directory a standard user can write to.
$installDirectory = Join-Path $env:ProgramFiles 'W2G-Clock'

# Above this the startup task steps the clock. The onboard tolerance is 500 ms
# (vehicleSafety.clockSkewToleranceMs); 200 ms leaves room for the measurement
# error of one NTP exchange over the CPE link. Exactly 0.2 s is left alone.
$subSecondThresholdSeconds = 0.2

# At or above this the offset is not a sub-second one: it belongs to the resync
# (which steps it, with the limits lifted) and to the -ReferenceTime fallback,
# as before. The same 5 seconds the fallback has always used.
$coarseOffsetSeconds = 5

$script:StepLog = $null
$script:ClockTouched = $false

function Write-Step {
    param([string] $Message)
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
    Write-Host $line
    if ($script:StepLog) { Add-Content -LiteralPath $script:StepLog -Value ("{0:yyyy-MM-dd} {1}" -f (Get-Date), $line) -Encoding utf8NoBOM }
}

# Takes any integer and prints its low 32 bits, so -1 (Int32), 4294967295
# (UInt32 or Int64) and 0xFFFFFFFF all print 0xFFFFFFFF.
function Format-Dword {
    param([long] $Value)
    return '0x{0:X8}' -f ($Value -band 0xFFFFFFFFL)
}

# What a registry value is, read without any conversion: its kind and its raw
# value as RegistryKey hands it back, or $null when it is not there.
function Get-RegistryValueRaw {
    param([string] $Path, [string] $Name)

    $key = Get-Item -LiteralPath $Path
    if ($key.GetValueNames() -notcontains $Name) { return $null }
    return [pscustomobject]@{
        Kind  = $key.GetValueKind($Name)
        Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
}

function Format-RegistryValue {
    param($Raw)
    if ($null -eq $Raw) { return '<unset>' }
    if ($Raw.Kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { return Format-Dword $Raw.Value }
    return 'REG_{0} {1}' -f $Raw.Kind.ToString().ToUpperInvariant(), $Raw.Value
}

# PowerShell parses 0xFFFFFFFF as the Int32 -1, and that is the only way to get
# those 32 bits into a DWORD from here: passing 4294967295 fails binding with
# "greater than the maximum allowed range of 2147483647". Do not "fix" a
# comparison against -1 by widening it to 4294967295.
#
# Reading the old value back is where workspace#54 came from. Get-ItemProperty
# under pwsh 7.6 returns a DWORD with the top bit set as UInt32 4294967295 (not
# the Int32 -1 that RegistryKey.GetValue gives), so the [int] cast that stood
# here threw "Cannot convert value "4294967295" to type "System.Int32"" on every
# car where a previous run had already lifted the limit -- before anything was
# written and before the resync, so the clock was left as it was. Read it raw
# and compare bits, never through [int].
function Set-W32TimeDword {
    param(
        [string] $Path,
        [string] $Name,
        [int] $Value
    )

    if (-not (Test-Path -Path $Path)) { throw "Missing registry key: $Path" }

    $current = Get-RegistryValueRaw -Path $Path -Name $Name

    Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value

    $after = Get-RegistryValueRaw -Path $Path -Name $Name
    if ($null -eq $after -or $after.Kind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or (Format-Dword $after.Value) -ne (Format-Dword $Value)) {
        throw ("{0} reads back as {1} after writing {2}" -f $Name, (Format-RegistryValue $after), (Format-Dword $Value))
    }
    Write-Step ("{0} = {1} (was {2})" -f $Name, (Format-Dword $Value), (Format-RegistryValue $current))
}

# The offset in w32tm /stripchart /dataonly output, in seconds, positive when
# this machine is ahead; $null when no sample parses (the server did not
# answer). The median of the samples, so one slow round trip does not decide.
function ConvertFrom-StripchartOutput {
    param([string[]] $Lines)

    $hits = [regex]::Matches(($Lines -join "`n"), '(?m),\s*([-+]?\d+(?:[.,]\d+)?)s\s*$')
    if ($hits.Count -eq 0) { return $null }

    # stripchart reports the offset of the PEER relative to us, so a machine
    # running fast shows a large negative number. Flip it so "how far ahead is
    # this machine" reads the way it is named.
    $samples = @($hits | ForEach-Object { -1 * [double]::Parse(($_.Groups[1].Value -replace ',', '.'), [cultureinfo]::InvariantCulture) } | Sort-Object)
    return $samples[[int][Math]::Floor(($samples.Count - 1) / 2)]
}

# Offset against the server as w32time itself sees it. Independent of any
# reference time the caller passed -- which is the point, because the caller
# need not pass one. Best effort: returns $null when the output cannot be
# parsed, and the caller reports "unknown" rather than pretending the machine
# is fine.
function Get-ServerOffsetSeconds {
    param([string] $Server)

    $output = @(w32tm /stripchart /computer:$Server /samples:3 /dataonly 2>&1 | ForEach-Object { "$_" })
    $offset = ConvertFrom-StripchartOutput -Lines $output
    if ($null -eq $offset) {
        Write-Step ("stripchart gave nothing parseable: {0}" -f (($output -join ' ').Trim()))
    }
    return $offset
}

# What to do about one measured offset (seconds, positive = this machine ahead).
# Pure, so the self-test covers every branch:
#   Unknown  nothing measured: do nothing, and do not call it success;
#   None     within the threshold (exactly 0.2 s included);
#   Adjust   over the threshold and under the coarse limit: step by -offset;
#   Coarse   5 s or more: not this function's business (resync / fallback).
function Get-ClockCorrection {
    param(
        [Nullable[double]] $OffsetSeconds,
        [double] $ThresholdSeconds = $subSecondThresholdSeconds,
        [double] $CoarseSeconds = $coarseOffsetSeconds
    )

    if ($null -eq $OffsetSeconds) { return [pscustomobject]@{ Action = 'Unknown'; AdjustSeconds = 0.0 } }
    $size = [Math]::Abs($OffsetSeconds)
    if ($size -le $ThresholdSeconds) { return [pscustomobject]@{ Action = 'None'; AdjustSeconds = 0.0 } }
    if ($size -ge $CoarseSeconds) { return [pscustomobject]@{ Action = 'Coarse'; AdjustSeconds = 0.0 } }
    return [pscustomobject]@{ Action = 'Adjust'; AdjustSeconds = -1 * $OffsetSeconds }
}

# Step 4. MaxAllowedPhaseOffset (1 s here) makes w32time slew anything smaller,
# and a slew left agv02 0.77 s slow for 83 minutes (workspace#55), so measure
# and step it ourselves. -Measure returns the offset or $null; -Adjust takes a
# TimeSpan to add to the clock. Outcomes:
#   IN_RANGE   measured, within the threshold, nothing done        (success)
#   ADJUSTED   stepped, and a fresh measurement is within it        (success)
#   UNMEASURED no measurement                                       (failure)
#   COARSE     5 s or more, left to the resync and the fallback      (failure)
#   NOT_CONFIRMED stepped, but the re-measurement failed or is still over it
function Invoke-SubSecondCorrection {
    param(
        [Parameter(Mandatory)][scriptblock] $Measure,
        [Parameter(Mandatory)][scriptblock] $Adjust
    )

    $before = & $Measure
    $decision = Get-ClockCorrection -OffsetSeconds $before
    $result = [pscustomobject]@{ Outcome = $null; Before = $before; After = $before; AdjustSeconds = 0.0 }

    switch ($decision.Action) {
        'Unknown' {
            Write-Step 'Offset could not be measured; the clock was not stepped.'
            $result.Outcome = 'UNMEASURED'
        }
        'None' {
            Write-Step ("Offset {0:+0.000;-0.000} s is within {1} s; nothing to step." -f $before, $subSecondThresholdSeconds)
            $result.Outcome = 'IN_RANGE'
        }
        'Coarse' {
            Write-Step ("Offset {0:+0.000;-0.000} s is {1} s or more; not stepping it here (resync / -ReferenceTime fallback)." -f $before, $coarseOffsetSeconds)
            $result.Outcome = 'COARSE'
        }
        'Adjust' {
            $script:ClockTouched = $true
            $result.AdjustSeconds = $decision.AdjustSeconds
            & $Adjust ([TimeSpan]::FromSeconds($decision.AdjustSeconds))
            $after = & $Measure
            $result.After = $after
            $confirmed = $null -ne $after -and [Math]::Abs($after) -le $subSecondThresholdSeconds
            $result.Outcome = $confirmed ? 'ADJUSTED' : 'NOT_CONFIRMED'
            Write-Step ("Offset {0:+0.000;-0.000} s stepped by {1:+0.000;-0.000} s; now {2}." -f $before, $decision.AdjustSeconds, ($null -eq $after ? 'unmeasured' : ('{0:+0.000;-0.000} s' -f $after)))
        }
    }
    return $result
}

function Test-ClockCorrectionSucceeded {
    param($Result)
    return $Result.Outcome -in 'IN_RANGE', 'ADJUSTED'
}

# What the startup task does: resync (for the big offsets, which w32time steps
# with the limits lifted), then step out a sub-second one, round after round
# until a round measures the clock within the threshold WITHOUT having to step
# it. Returns the last correction result; the caller exits 0 only on IN_RANGE.
#
# It keeps trying for hours, not minutes (review S1 of workspace#55). It used
# to give up after 10 rounds, about 5 minutes. After a plant-wide power cut the
# factory server reboots as well and its NTP answers late, and a task that has
# already given up leaves the car stranded exactly as on 10-18. 480 rounds at
# 30 s is about 4 hours; one NTP packet per round costs nothing. It stays a
# startup task rather than also running every hour: a sub-second step is a
# discontinuity, and after the first good round w32time's own slew is what
# should hold the clock.
#
# After a step it waits $Settle and measures again in the next round, because
# a measurement right after Set-Date cannot show whether w32time's pending
# slew then pulls the clock off again (review S2). Stepping again in that
# round is allowed; the log shows it.
function Invoke-StartupClockCheck {
    param(
        [Parameter(Mandatory)][scriptblock] $Resync,
        [Parameter(Mandatory)][scriptblock] $Measure,
        [Parameter(Mandatory)][scriptblock] $Adjust,
        [scriptblock] $Sleep = { Start-Sleep -Seconds 30 },
        [scriptblock] $Settle = { Start-Sleep -Seconds 90 },
        [int] $Rounds = 480
    )

    $result = $null
    foreach ($round in 1..$Rounds) {
        $synced = & $Resync
        Write-Step ("Startup round {0}: resync {1}" -f $round, ($synced ? 'succeeded' : 'failed'))
        $result = Invoke-SubSecondCorrection -Measure $Measure -Adjust $Adjust
        if ($result.Outcome -eq 'IN_RANGE') { return $result }
        if ($round -lt $Rounds) { & ($result.Outcome -eq 'ADJUSTED' ? $Settle : $Sleep) }
    }
    return $result
}

# The operator-facing line when the script stops on an error: whether the clock
# was moved before it did. Nothing before the resync moves the clock.
function Get-FailureNotice {
    param([bool] $ClockTouched)
    if ($ClockTouched) {
        return 'FAILED after the clock may have been moved. Read the offset (w32tm /stripchart) before starting the onboard stack.'
    }
    return 'FAILED before anything moved the clock: THE CLOCK WAS NOT CHANGED (时钟未改). Fix the error and run this again.'
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

    # A successful resync can step the clock, so from here on a failure can no
    # longer promise the operator that the clock is untouched.
    $script:ClockTouched = $true
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

# The startup task runs an installed copy of this script with -AtStartup, so
# what runs at boot is the code the self-test covers, not a one-line loop kept
# in step by hand. It used to be exactly that loop -- resync only -- which is
# why a sub-second offset survived every boot (workspace#55).
function New-StartupTaskArguments {
    param([string] $ScriptPath, [string] $Server)
    return '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -AtStartup -TimeServer {1}' -f $ScriptPath, $Server
}

# -AllowStartIfOnBatteries is load-bearing here and not boilerplate: these
# machines ride on the vehicle and Windows sees a battery, so without it the
# task would skip exactly the boots this is for.
function New-StartupTaskSettings {
    return New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 5)
}

function Install-StartupCopy {
    param([string] $Source, [string] $Directory)

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $target = Join-Path $Directory (Split-Path -Leaf $Source)
    # Re-running the installed copy itself is legitimate, and Copy-Item onto
    # the same path throws "Cannot overwrite the item ... with itself".
    if ([System.IO.Path]::GetFullPath($Source) -ieq [System.IO.Path]::GetFullPath($target)) {
        Write-Step ("Running from the installed copy {0}; nothing to copy" -f $target)
        return $target
    }
    Copy-Item -LiteralPath $Source -Destination $target -Force
    Write-Step ("Installed {0}" -f $target)
    return $target
}

# The task exists so the correction happens before the onboard stack is started,
# not after an operator remembers. SYSTEM because w32time and Set-Date need it.
function Register-StartupResyncTask {
    param([string] $TaskName, [string] $ScriptPath, [string] $Server)

    $pwsh = (Get-Command -Name pwsh -CommandType Application -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) { throw 'pwsh was not found on this machine; the startup task would never run.' }

    $action = New-ScheduledTaskAction -Execute $pwsh -Argument (New-StartupTaskArguments -ScriptPath $ScriptPath -Server $Server)

    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT30S'

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings (New-StartupTaskSettings) -Description 'Resync the clock from the factory server at startup and step out a sub-second offset (workspace#5, workspace#55).' -Force | Out-Null
    Write-Step ("Startup task '{0}' registered, running {1} -File {2} -AtStartup" -f $TaskName, $pwsh, $ScriptPath)
}

function Invoke-SelfTest {
    $failures = [System.Collections.Generic.List[string]]::new()
    function Check([string] $Name, [scriptblock] $Body) {
        try { & $Body; "PASS $Name" } catch { $failures.Add($Name); "FAIL $Name -- $($_.Exception.Message)" }
    }
    $work = "HKCU:\Software\8005-clock-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -Path $work -Force | Out-Null
    try {
        . (Join-Path $PSScriptRoot '07-fix-clock.selftest.ps1')
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    "SELFTEST $(if ($failures.Count -eq 0) { 'PASS' } else { "FAIL ($($failures -join '; '))" }) ($($failures.Count) failed)"
    if ($failures.Count -ne 0) { exit 1 }
}

if ($PSCmdlet.ParameterSetName -eq 'SelfTest') { Invoke-SelfTest; return }

# The elevation check is skipped under -WhatIf so a dry run can be read from any
# shell. Every call that actually changes something sits behind the
# ShouldProcess gate below, so nothing can slip past this.
if (-not $WhatIfPreference) {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated.'
    }
}

if ($PSCmdlet.ParameterSetName -eq 'AtStartup') {
    $script:StepLog = Join-Path $PSScriptRoot 'startup.log'
    if ((Test-Path -LiteralPath $script:StepLog) -and (Get-Item -LiteralPath $script:StepLog).Length -gt 1MB) {
        Move-Item -LiteralPath $script:StepLog -Destination "$($script:StepLog).1" -Force
    }
    Write-Step ("Startup clock check against {0}" -f $TimeServer)
    $result = Invoke-StartupClockCheck `
        -Resync { Invoke-Resync -Attempts 1 } `
        -Measure { Get-ServerOffsetSeconds -Server $TimeServer } `
        -Adjust { param($by) Set-Date -Adjust $by | Out-Null }
    Write-Step ("Startup clock check: {0}" -f $result.Outcome)
    # Only a round that measured the clock in range without stepping it counts.
    exit (($result.Outcome -eq 'IN_RANGE') ? 0 : 1)
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

# DO NOT re-add the "clock is already within 5 seconds, nothing to do" early
# return that stood here until 2026-09-21. It reads like an obvious saving and
# it is the bug: what this script installs -- the lifted correction limits and
# the startup task -- is for the NEXT power loss, not for the reading on the
# screen right now. A car whose clock currently looks fine is precisely the one
# that has not been inoculated yet. Running this again on a healthy machine
# costs one NTP packet (workspace#5).
if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Lift the w32time correction limits, sync from $TimeServer, step out a sub-second offset, and register '$startupTaskName'")) {
    Write-Step 'WhatIf: nothing above was changed.'
    return
}

try {
    # Step 1: a reachable source. 0x9 is "client mode, use as fallback" -- the flag
    # the previous (unreachable) entry also used, and its 0x1 half is what makes
    # SpecialPollInterval below the interval that applies.
    $null = w32tm /config /manualpeerlist:"${TimeServer},0x9" /syncfromflags:manual /update 2>&1

    # Step 2: the limits. Without these the machine measures a 137-day offset,
    # decides the measurement cannot be trusted, and stays wrong -- which is the
    # whole of workspace#5.
    #
    # MaxAllowedPhaseOffset is deliberately left alone, and since workspace#55
    # that is a choice with a cost, not a free one. It decides step vs. slew for
    # EVERY sync, the hourly poll included: its default (1 s on these machines)
    # steps an offset as big as workspace#5's, and slews anything under a second.
    # Lowering it would also step sub-second offsets, but it would do so at any
    # poll, mid-drive, with the onboard client stamping and comparing times --
    # a backward step there is what a slew exists to avoid. What it fails to do
    # is close a sub-second gap promptly (0.77 s stayed for 83 minutes on agv02
    # 2026-10-18). That one case is handled by step 4 instead, once, shortly
    # after boot, bounded to under 5 seconds and measured against the server.
    Set-W32TimeDword -Path $configKey -Name 'MaxPosPhaseCorrection' -Value 0xFFFFFFFF
    Set-W32TimeDword -Path $configKey -Name 'MaxNegPhaseCorrection' -Value 0xFFFFFFFF

    # 32768 seconds (9 hours) shipped with the image. An hour bounds how long a
    # machine that drifts between polls stays wrong, and one NTP packet an hour
    # costs the factory server nothing.
    Set-W32TimeDword -Path $ntpClientKey -Name 'SpecialPollInterval' -Value 3600

    $null = w32tm /config /update 2>&1

    # Step 5: make the next power loss a non-event. It runs here, before steps 3
    # and 4, on purpose (review S5 of workspace#55): those talk to the server and
    # can fail, and a failure there must not also cost the car its startup task,
    # which is what fixes the clock at the next boot without anyone present.
    $installed = Install-StartupCopy -Source $PSCommandPath -Directory $installDirectory
    Register-StartupResyncTask -TaskName $startupTaskName -ScriptPath $installed -Server $TimeServer

    Set-Service w32time -StartupType Automatic
    # w32time may sync as it comes back up, so a failure past here may follow a
    # moved clock.
    $script:ClockTouched = $true
    Restart-Service w32time
    Start-Sleep -Seconds 3

    # Step 3: this is now the step that moves the clock, however far off it is.
    $synced = Invoke-Resync
    Write-Step ("Now: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

    # Step 4: what the resync leaves under a second, it slews; step it out.
    $correction = Invoke-SubSecondCorrection `
        -Measure { Get-ServerOffsetSeconds -Server $TimeServer } `
        -Adjust { param($by) Set-Date -Adjust $by | Out-Null }
    $offset = $correction.After
    if ($null -ne $offset) {
        Write-Step ("Offset vs {0}: {1:N3} seconds" -f $TimeServer, $offset)
    }

    # The fallback. It is the old step 1, demoted: it only runs when the resync left
    # the clock wrong AND the caller supplied a time to jump to.
    $stillWrong = ($null -ne $offset -and [Math]::Abs($offset) -ge $coarseOffsetSeconds) -or (-not $synced -and $null -eq $offset)
    if ($stillWrong -and $hasReference) {
        Write-Step 'Resync did not bring the clock in; falling back to the manual coarse jump.'
        Set-Date -Date $ReferenceTime | Out-Null
        Write-Step ("Clock set by hand. Now: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $synced = Invoke-Resync
        $correction = Invoke-SubSecondCorrection `
            -Measure { Get-ServerOffsetSeconds -Server $TimeServer } `
            -Adjust { param($by) Set-Date -Adjust $by | Out-Null }
    }
    elseif ($stillWrong) {
        Write-Warning "The clock is still wrong and no -ReferenceTime was passed. Re-run with one, and check that 16-enable-ntp-server.ps1 has been run on the factory server."
    }

    if (-not (Test-ClockCorrectionSucceeded $correction)) {
        Write-Warning ("The offset against {0} is not confirmed within {1} s ({2}). The onboard tolerance is 0.5 s -- do not start the onboard stack until it is." -f $TimeServer, $subSecondThresholdSeconds, $correction.Outcome)
    }

    if (-not $synced) {
        Write-Warning 'w32tm /resync never succeeded. Nothing is holding this clock -- do not start the onboard stack until it is.'
    }
}
catch {
    Write-Host (Get-FailureNotice -ClockTouched $script:ClockTouched)
    throw
}

$source = w32tm /query /source 2>&1
Write-Step ("Source now: {0}" -f ($source -join ' '))
Write-Step ("After: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

if ($source -match 'Free-running|本地 CMOS|Local CMOS') {
    Write-Warning "Still free-running: $TimeServer did not answer. The clock may be correct now but nothing is holding it there."
    Write-Warning "Check that 16-enable-ntp-server.ps1 has been run on the factory server."
}

# Exit 2 when the offset was not confirmed within the threshold, so a caller
# driving this over SSH does not read a clock it was warned about as fixed.
if (-not (Test-ClockCorrectionSucceeded $correction)) { exit 2 }
