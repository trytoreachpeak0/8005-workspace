#Requires -Version 7
<#
.SYNOPSIS
    Corrects an onboard machine's clock and points it at the factory server for
    ongoing sync. Runs ON the onboard machine.

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

    This is a safety-relevant fault, not a cosmetic one. The onboard
    vehicle-safety gate compares the server's observedAt against this machine's
    own clock inside a 5-second window:

        return now - ObservedAt <= maxAge;      // VehicleSafetySignal.IsFresh

    A clock that far off makes every projection look stale, so a clean session
    can never leave RecoveryRequired / DEPARTURE_SAFETY_NOT_READY. The gate
    fails closed on a fact that has nothing to do with the vehicle -- which is
    the correct behaviour for the gate and a useless outcome for the operator.

    Two steps, in this order. w32time refuses a correction this large on its own
    (MaxPosPhaseCorrection), so the coarse jump is made with Set-Date first and
    NTP only takes over for the fine correction and for keeping it there.

.PARAMETER ReferenceTime
    The correct current time, passed in by the control host. Required: this
    machine has no trustworthy source of it, which is the whole problem.

.PARAMETER TimeServer
    Host to sync from afterwards. The factory server, which the vehicles already
    reach for ControlServer.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [datetime] $ReferenceTime,

    [string] $TimeServer = '172.19.205.222'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message)
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run elevated.'
}

$before = Get-Date
$drift = $before - $ReferenceTime
Write-Step ("Before: {0}" -f $before.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Step ("Reference: {0}" -f $ReferenceTime.ToString('yyyy-MM-dd HH:mm:ss'))
Write-Step ("Drift: {0:N1} days ({1:N0} seconds)" -f $drift.TotalDays, $drift.TotalSeconds)

if ([Math]::Abs($drift.TotalSeconds) -lt 5) {
    Write-Step 'Clock is already within 5 seconds of the reference; nothing to do.'
    return
}

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Set the clock and sync from $TimeServer")) { return }

# Step 1: the coarse jump.
Set-Date -Date $ReferenceTime | Out-Null
Write-Step ("Clock set. Now: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

# Step 2: a source, so this does not have to be done again by hand. 0x9 is
# "client mode, use as fallback" -- the flag the previous (unreachable) entry
# also used.
$null = w32tm /config /manualpeerlist:"${TimeServer},0x9" /syncfromflags:manual /update 2>&1
Set-Service w32time -StartupType Automatic
Restart-Service w32time
Start-Sleep -Seconds 3

# The first resync right after a coarse jump can fail while w32time is still
# settling. Measured on agv03 2026-09-03: attempt 1 came back "no time data
# available", attempt 2 a few seconds later succeeded. Retry on the exit code
# rather than on the message, which is localized.
#
# This used to run once and then judge the outcome by /query /source alone --
# but the /config call above has ALREADY set that string, so a failed resync
# produced no warning and looked exactly like success.
$synced = $false
foreach ($attempt in 1..5) {
    $resync = w32tm /resync /force 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Step ("resync succeeded on attempt {0}" -f $attempt)
        $synced = $true
        break
    }
    Write-Step ("resync attempt {0} failed: {1}" -f $attempt, ($resync -join ' '))
    if ($attempt -lt 5) { Start-Sleep -Seconds 3 }
}
if (-not $synced) {
    Write-Warning 'w32tm /resync never succeeded in 5 attempts. The coarse jump above is in place, but nothing is holding the clock there -- it will drift again.'
}

$source = w32tm /query /source 2>&1
Write-Step ("Source now: {0}" -f ($source -join ' '))

$after = Get-Date
Write-Step ("After: {0}" -f $after.ToString('yyyy-MM-dd HH:mm:ss'))

if ($source -match 'Free-running|本地 CMOS|Local CMOS') {
    Write-Warning "Still free-running: $TimeServer did not answer. The clock is correct now but will drift again."
    Write-Warning "Check that 16-enable-ntp-server.ps1 has been run on the factory server."
}
