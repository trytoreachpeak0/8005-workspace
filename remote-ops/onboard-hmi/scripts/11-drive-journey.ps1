#Requires -Version 7
<#
.SYNOPSIS
    Drives one WIRE_TO_GATE station operation on a real vehicle with nobody at
    the HMI. Runs ON the control host.

.DESCRIPTION
    The L2 rig already automates the operator, but only on one machine: both
    halves are local to it, so it drives the WPF client through UI Automation
    directly. In the production topology the client is on the vehicle and this
    script is somewhere else, and UI Automation cannot see a window in another
    machine's session. So the work is split three ways, and the middle part is
    the reason it is three and not two:

        1. vehicle   type the sublot, click submit          (UI Automation)
        2. HERE      wait for the client to report WAITING_OPERATOR, and read
                     which slot it opened
        3. vehicle   put the cargo in that slot, close the door

    STEP 2 IS NOT BOOKKEEPING. The first version did 1 and 3 in one pass on the
    vehicle and triggered 3 on the simulator reporting `doorState = OPEN`. That
    is true the instant the unlock pulse lands, before the client has watched the
    lock feedback settle. On 2026-09-07 the entire IO trace landed inside 0.4 s
    and the server judged the load LOAD_RESULT_REQUIRES_RECOVERY. The run before
    it, driven by hand, had 23 s between unlock and cargo. WAITING_OPERATOR is
    the client saying it actually observed the door open; nothing else means
    that.

    It is read from the server's ProtocolInbox because that is where the client's
    OperationProgress lands, and because the onboard's own automation plane --
    which would expose the phase locally -- hangs the client at startup when
    enabled (8005-agv-onboard-hmi#14).

    The vehicle half runs in the interactive session, started by the same
    scheduled-task mechanism 10-start-onboard-stack.ps1 uses, because that is the
    only session where the client's window exists.

.PARAMETER Sublot
    Submit this instead of what the server asked for. Only useful for negative
    tests.

.PARAMETER CargoState
    OCCUPIED (default) completes a load. EMPTY reproduces a failed one, and is
    also what an unload wants.

.EXAMPLE
    ./11-drive-journey.ps1

.EXAMPLE
    ./11-drive-journey.ps1 -CargoState EMPTY
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SshAlias = 'agv01',
    [string] $ServerAlias = 'factory01',
    [string] $Sublot,
    [ValidateSet('OCCUPIED', 'EMPTY')]
    [string] $CargoState = 'OCCUPIED',
    [string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer\data\controlserver.db',
    [string] $ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer',
    [string] $VehicleWorkRoot = 'C:\8005\automation',
    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Remote {
    param([string] $Alias, [string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $Alias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $Alias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

# ssh writes its own banner to stderr and Invoke-Remote folds stderr in, so a
# JSON payload arrives with whatever the server had to say in front of it.
function ConvertFrom-RemoteJson {
    param([string] $Raw)
    $start = $Raw.IndexOf('{')
    if ($start -lt 0) { throw "No JSON in the remote output: $Raw" }
    return $Raw.Substring($start) | ConvertFrom-Json
}

function Invoke-VehiclePhase {
    param([string] $PhaseName, [string] $Arguments, [string] $ResultPath)

    # sshd hands us session 0, and UI Automation there cannot see the client's
    # window. Same mechanism as 10-start-onboard-stack.ps1: a scheduled task with
    # an Interactive principal runs in the logged-on user's session, and the task
    # is unregistered immediately so nothing outlives this run.
    $taskName = "W2G-Drive-$PhaseName-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $null = Invoke-Remote $SshAlias @"
`$ErrorActionPreference = 'Stop'
`$console = (query session 2>&1 | Select-String -Pattern '^\s*>?console\s+(\S+)\s+(\d+)\s+Active').Matches
if (-not `$console) { throw 'No active console session on this vehicle.' }
`$user = `$console[0].Groups[1].Value
Remove-Item -LiteralPath '$ResultPath' -Force -ErrorAction SilentlyContinue
`$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '$Arguments' -WorkingDirectory '$VehicleWorkRoot'
`$principal = New-ScheduledTaskPrincipal -UserId `$user -LogonType Interactive -RunLevel Limited
`$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
try {
    Register-ScheduledTask -TaskName '$taskName' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
    Start-ScheduledTask -TaskName '$taskName'
} finally {
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
}
"@

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $raw = Invoke-Remote $SshAlias "if (Test-Path -LiteralPath '$ResultPath') { Get-Content -Raw -LiteralPath '$ResultPath' } else { '' }"
        if ($raw -and $raw.Contains('{')) { break }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw "Timed out after ${TimeoutSeconds}s; the $PhaseName phase wrote no result to $ResultPath."
        }
        Start-Sleep -Seconds 3
    }
    $result = ConvertFrom-RemoteJson $raw
    foreach ($s in $result.steps) { Write-Step "$($s.step): $($s.detail)" }
    if ($result.status -ne 'OK') { throw "$PhaseName phase failed: $($result.message)" }
    return $result
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Driving one operation on $SshAlias" -ForegroundColor Green

# --- what does the server want scanned? -----------------------------------

if (-not $Sublot) {
    $expected = Invoke-Remote $ServerAlias @"
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly')
`$c.Open()
`$m = `$c.CreateCommand()
`$m.CommandText = "SELECT PayloadJson FROM ProtocolOutbox WHERE MessageType = 'SublotEntryRequested' AND AcknowledgedAt IS NULL ORDER BY CreatedAt DESC LIMIT 1"
`$p = [string]`$m.ExecuteScalar()
`$c.Close()
if (`$p -match '"expectedSublot"\s*:\s*"([^"]+)"') { `$matches[1] } else { '' }
"@
    if (-not $expected) { throw 'The server has no unanswered SublotEntryRequested; there is nothing to drive.' }
    $Sublot = $expected.Trim()
}
Write-Step "Sublot to submit: $Sublot"

if (-not $PSCmdlet.ShouldProcess($SshAlias, "Submit sublot $Sublot and play the operator's part (cargo=$CargoState)")) { return }

# --- deploy ---------------------------------------------------------------

$runId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$driverLocal = Join-Path $PSScriptRoot 'agv-drive-journey.ps1'
if (-not (Test-Path -LiteralPath $driverLocal)) { throw "Driver not found: $driverLocal" }
$null = Invoke-Remote $SshAlias "New-Item -ItemType Directory -Path '$VehicleWorkRoot' -Force | Out-Null"
& scp -o BatchMode=yes $driverLocal "${SshAlias}:$VehicleWorkRoot/agv-drive-journey.ps1" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not copy the driver to $SshAlias" }
Write-Step "Driver deployed to $VehicleWorkRoot"

# --- 1. the scan ----------------------------------------------------------

$scanResult = "$VehicleWorkRoot\scan-$runId.json"
$null = Invoke-VehiclePhase 'Scan' `
    ("-NoProfile -ExecutionPolicy Bypass -File `"$VehicleWorkRoot\agv-drive-journey.ps1`" " +
     "-Phase Scan -Sublot `"$Sublot`" -ResultPath `"$scanResult`"") `
    $scanResult

# --- 2. wait for the client to say it is waiting --------------------------

# activeUnlockSlots names the slot, and the phase is the client's own statement
# that it observed the door open and settle. Acting before this is what turned a
# good load into LOAD_RESULT_REQUIRES_RECOVERY on 2026-09-07.
# One operation can span several slots -- the client opens them one at a time,
# reporting WAITING_OPERATOR for each. The first version drove the first slot and
# returned, so on 2026-09-07 a two-basket demand had slot 1 filled, slot 2 opened
# with nobody there, and the operation timed out into
# LOAD_RESULT_REQUIRES_RECOVERY. The runs that passed before it happened to be
# single-slot demands.
$handled = [System.Collections.Generic.HashSet[int]]::new()
while ($true) {
Write-Step 'Waiting for the client to report WAITING_OPERATOR'
# No time filter. The obvious one -- ReceivedAt > (now - 2 min) -- silently
# matched nothing: SQLite compares those as strings, the column holds
# "2026-09-07 10:21:50.123+00:00" with a space, and DateTimeOffset.ToString('o')
# produces a "T". Space sorts below "T", so every row failed the test and the
# wait ran its full 300 s. The newest WAITING_OPERATOR is the right row anyway --
# each run starts from a reset database, and within a journey the newest is the
# operation currently open.
# Waiting for the FIRST slot can take as long as the caller allows; waiting for a
# further one should not, because "no more slots" is the normal ending and the
# client only holds a slot open for its own operator timeout anyway.
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($handled.Count -eq 0 ? $TimeoutSeconds : 20)
$slotNo = 0
while ($true) {
    $raw = Invoke-Remote $ServerAlias @"
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly')
`$c.Open()
`$m = `$c.CreateCommand()
`$m.CommandText = "SELECT RequestJson FROM ProtocolInbox WHERE MessageType = 'OperationProgress' ORDER BY ReceivedAt DESC"
`$slots = ''
`$r = `$m.ExecuteReader()
while (`$r.Read()) {
    `$p = ([string]`$r.GetValue(0) | ConvertFrom-Json).payload
    if (`$p.phase -eq 'WAITING_OPERATOR' -and `$p.activeUnlockSlots.Count -eq 1) {
        `$slots = [string]`$p.activeUnlockSlots[0]
        break
    }
}
`$r.Close(); `$c.Close()
"{""slot"":""`$slots""}"
"@
    $candidate = [int]((ConvertFrom-RemoteJson $raw).slot ?? 0)
    if ($candidate -gt 0 -and -not $handled.Contains($candidate)) { $slotNo = $candidate; break }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        if ($handled.Count -gt 0) {
            # No new slot appeared before the deadline and we have already served
            # at least one. That is the ordinary end of a multi-slot operation,
            # not a failure.
            $slotNo = 0
            break
        }
        throw "Timed out after ${TimeoutSeconds}s waiting for WAITING_OPERATOR on a single slot."
    }
    Start-Sleep -Seconds 2
}

if ($slotNo -eq 0) { break }
Write-Step "Client is waiting on slot $slotNo"

# --- 3. the operator's hands ----------------------------------------------

$operatorResult = "$VehicleWorkRoot\operator-$runId-$slotNo.json"
$final = Invoke-VehiclePhase "Operator-$slotNo" `
    ("-NoProfile -ExecutionPolicy Bypass -File `"$VehicleWorkRoot\agv-drive-journey.ps1`" " +
     "-Phase Operator -SlotNo $slotNo -CargoState $CargoState -ResultPath `"$operatorResult`"") `
    $operatorResult
$null = $handled.Add($slotNo)
Write-Host "  slot ${slotNo}: $($final.message)" -ForegroundColor Green

}  # next slot, if the client opens one

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Served $($handled.Count) slot(s): $(($handled | Sort-Object) -join ', ')" -ForegroundColor Green
Write-Host '  The journey continues on the server; this script only played the operator.' -ForegroundColor Yellow
