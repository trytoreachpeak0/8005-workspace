#Requires -Version 7
<#
.SYNOPSIS
    Watches the ControlServer journey to reach Completed and stops the service the
    instant it does. Runs ON the factory server; 13-close-gates-when-idle.ps1
    deploys and drives it.

.DESCRIPTION
    This half exists on the server for one reason: latency. The race it closes is
    two seconds wide -- JourneyRuntimeWorker polls every PollInterval (2 s), so
    the iteration that writes Completed is followed by one that discovers and
    accepts the next demand. On 2026-09-07 that gap was measured at exactly 2 s
    (Completed 13:52:14, next demand accepted 13:52:16, RIoT order created).

    A watcher on the control host cannot win that: one ssh round trip is already
    most of the budget. Here the poll is 250 ms against the same SQLite file the
    engine writes, and the reaction is a local Stop-Service.

    Stopping the service -- rather than rewriting appsettings and restarting -- is
    deliberate, and it is what makes this fast enough to matter:

      * JourneyRuntimeWorker reads IOptions<JourneyRuntimeOptions> ONCE, at
        startup (Program.cs binds IOptions, not IOptionsMonitor). Writing
        `enabled = false` into appsettings.Production.json does nothing to a
        running process. Only a restart closes the gate, and a restart begins
        with exactly this stop.
      * The stop is what beats the clock. ExecuteOnceAsync is handed the host's
        stoppingToken, so a stop that lands mid-iteration cancels the iteration
        before it can commit an acceptance.

    Writing the two booleans is left to Set-JourneyRuntime.ps1, which is the one
    place that file is edited: it backs up, verifies the change field by field,
    and brings the service back. By then nothing is racing, because the engine is
    not running.

    WHY IT WAITS FOR Completed AND NOT SOMETHING EARLIER. Closing the gate
    mid-journey does not merely fail to help, it breaks the journey. A disabled
    JourneyRuntimeWorker logs one warning and sleeps forever -- it never calls
    ExecuteOnceAsync again -- and every remaining transition of an in-flight
    journey (publishing the gate worklist, the unload command, settling the
    result) is made by that loop. A vehicle whose runtime was closed after the
    load would drive to the gate and find nothing opening. `-Off` not stopping an
    in-flight journey is true of the VEHICLE, not of the server-side journey.

    Blocked is the other terminal stage and it is NOT a reason to stop the
    service. A blocked journey still counts as unresolved, so the engine never
    reaches discovery and no new demand can be accepted -- there is no race to
    win -- while recovery needs the loop that a stop would take away. It is
    reported and the service is left alone.

.PARAMETER Database
    The ControlServer SQLite file to watch. Pointing this at a copy is how the
    completion path is exercised without a real vehicle: the stop, the config
    write and the verification are all real, only the completion signal is not.

.PARAMETER DemandId
    Watch this journey instead of latching onto whichever one is unresolved.

.OUTPUTS
    Heartbeat lines while waiting, then exactly one line of compact JSON. The
    caller reads the last line beginning with '{'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Database,
    [Parameter(Mandatory = $true)][string] $InstallRoot,
    [Parameter(Mandatory = $true)][string] $ServiceName,
    [string] $DemandId,
    [ValidateRange(50, 5000)][int] $PollMilliseconds = 250,
    [ValidateRange(1, 86400)][int] $LatchTimeoutSeconds = 600,
    [ValidateRange(1, 86400)][int] $JourneyTimeoutSeconds = 3600,
    [ValidateRange(15, 600)][int] $HeartbeatSeconds = 15
)

$ErrorActionPreference = 'Stop'

$dll = (Get-ChildItem -LiteralPath $InstallRoot -Filter 'Microsoft.Data.Sqlite.dll' -Recurse |
    Select-Object -First 1).FullName
if (-not $dll) { throw "Microsoft.Data.Sqlite.dll not found under $InstallRoot." }
Add-Type -Path $dll

$connectionString = "Data Source=$Database;Mode=ReadOnly"

function Read-Rows {
    param([string] $Sql)

    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new($connectionString)
    $connection.Open()
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        $reader = $command.ExecuteReader()
        $rows = [System.Collections.Generic.List[object]]::new()
        while ($reader.Read()) {
            $values = @(0..($reader.FieldCount - 1) | ForEach-Object {
                    $reader.IsDBNull($_) ? $null : [string]$reader.GetValue($_)
                })
            $rows.Add($values)
        }
        $reader.Close()
        return , $rows.ToArray()
    }
    finally { $connection.Close() }
}

# Sampled at latch and again after the stop. The comparison across those two
# points is the acceptance evidence: an AcceptedDemands set that grew means the
# runtime slipped a demand through the window this script exists to close.
function Read-Ledger {
    [pscustomobject]@{
        acceptedDemandIds = @(Read-Rows 'SELECT DemandId FROM AcceptedDemands ORDER BY DemandId' | ForEach-Object { $_[0] })
        orderIntentLegIds = @(Read-Rows 'SELECT MovementLegId FROM OrderIntents ORDER BY MovementLegId' | ForEach-Object { $_[0] })
    }
}

function Write-Heartbeat {
    param([string] $Message)
    Write-Output "[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message"
}

function Write-Result {
    param([hashtable] $Fields)
    Write-Output ([pscustomobject]$Fields | ConvertTo-Json -Depth 5 -Compress)
}

$nonTerminal = "Stage NOT IN ('Completed', 'Blocked')"

# ------------------------------------------------------------------- latch ---

# The interesting case is being started BEFORE the journey exists, which is the
# only way to be sure the watcher is already in place when it completes. So an
# empty JourneyRuntimes table is a wait, not an answer -- unless something has
# already finished, in which case the runtime is idle right now and the gate
# should have been shut already.
$latchDeadline = [DateTime]::UtcNow.AddSeconds($LatchTimeoutSeconds)
$latchedStage = $null
$lastHeartbeat = [DateTime]::UtcNow
Write-Heartbeat "Watching $Database for a journey to latch onto (poll ${PollMilliseconds} ms)"
while (-not $DemandId) {
    $open = Read-Rows "SELECT DemandId, Stage FROM JourneyRuntimes WHERE $nonTerminal ORDER BY CreatedAt"
    if ($open.Count -gt 1) {
        Write-Result @{
            status  = 'AMBIGUOUS'
            message = "More than one unresolved journey: $(($open | ForEach-Object { $_[0] }) -join ', '). Nothing was stopped."
        }
        return
    }
    if ($open.Count -eq 1) {
        $DemandId = $open[0][0]
        $latchedStage = $open[0][1]
        break
    }
    $finished = Read-Rows 'SELECT DemandId, Stage FROM JourneyRuntimes ORDER BY UpdatedAt DESC'
    if ($finished.Count -gt 0) {
        $DemandId = $finished[0][0]
        $latchedStage = $finished[0][1]
        Write-Heartbeat "No unresolved journey; newest is $DemandId at $latchedStage -- the runtime is idle already"
        break
    }
    if ([DateTime]::UtcNow -ge $latchDeadline) {
        Write-Result @{
            status  = 'TIMEOUT'
            message = "No journey appeared within ${LatchTimeoutSeconds}s. Nothing was stopped."
        }
        return
    }
    if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
        $lastHeartbeat = [DateTime]::UtcNow
        Write-Heartbeat 'No journey yet'
    }
    Start-Sleep -Milliseconds $PollMilliseconds
}

if (-not $latchedStage) {
    $row = Read-Rows "SELECT Stage FROM JourneyRuntimes WHERE DemandId = '$($DemandId -replace "'", "''")'"
    if ($row.Count -eq 0) {
        Write-Result @{ status = 'VANISHED'; demandId = $DemandId; message = "No journey row for $DemandId. Nothing was stopped." }
        return
    }
    $latchedStage = $row[0][0]
}

$latchedAt = [DateTimeOffset]::UtcNow
$ledgerAtLatch = Read-Ledger
Write-Heartbeat "Latched onto $DemandId at stage $latchedStage; AcceptedDemands=$($ledgerAtLatch.acceptedDemandIds.Count) OrderIntents=$($ledgerAtLatch.orderIntentLegIds.Count)"

# -------------------------------------------------------------------- wait ---

$idQuoted = $DemandId -replace "'", "''"
$journeyDeadline = [DateTime]::UtcNow.AddSeconds($JourneyTimeoutSeconds)
$lastHeartbeat = [DateTime]::UtcNow
$consecutiveFailures = 0
$stage = $latchedStage
$blockReason = $null
$updatedAt = $null

while ($true) {
    try {
        $row = Read-Rows "SELECT Stage, BlockReasonCode, UpdatedAt FROM JourneyRuntimes WHERE DemandId = '$idQuoted'"
        $consecutiveFailures = 0
    }
    catch {
        # A read-only reader can meet SQLITE_BUSY while the engine checkpoints
        # the WAL. That is noise, not an answer; only a run of them is a fault.
        $consecutiveFailures++
        if ($consecutiveFailures -ge 40) { throw }
        Start-Sleep -Milliseconds $PollMilliseconds
        continue
    }

    if ($row.Count -eq 0) {
        Write-Result @{
            status   = 'VANISHED'
            demandId = $DemandId
            message  = "Journey $DemandId disappeared while being watched (12-reset-journey-state.ps1?). Nothing was stopped."
        }
        return
    }

    $stage = $row[0][0]
    $blockReason = $row[0][1]
    $updatedAt = $row[0][2]

    if ($stage -eq 'Completed') { break }

    if ($stage -eq 'Blocked') {
        Write-Result @{
            status          = 'BLOCKED'
            demandId        = $DemandId
            stage           = $stage
            blockReasonCode = $blockReason
            updatedAt       = $updatedAt
            message         = "Journey $DemandId is Blocked ($blockReason). The service was left running: a blocked journey is still unresolved, so no new demand can be accepted, and recovery needs the runtime loop."
        }
        return
    }

    if ([DateTime]::UtcNow -ge $journeyDeadline) {
        Write-Result @{
            status   = 'TIMEOUT'
            demandId = $DemandId
            stage    = $stage
            message  = "Journey $DemandId was still at $stage after ${JourneyTimeoutSeconds}s. Nothing was stopped."
        }
        return
    }

    if (([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
        $lastHeartbeat = [DateTime]::UtcNow
        Write-Heartbeat "stage=$stage$($blockReason ? " blockReason=$blockReason" : '')"
    }
    Start-Sleep -Milliseconds $PollMilliseconds
}

# -------------------------------------------------------------------- stop ---

# Nothing between the detection and the stop. Every statement here costs part of
# the two seconds; the reporting happens afterwards.
$stopRequestedAt = [DateTimeOffset]::UtcNow
$stopError = $null
try {
    Stop-Service -Name $ServiceName -Force
}
catch {
    $stopError = $_.Exception.Message
}
$stoppedAt = [DateTimeOffset]::UtcNow

$serviceStatus = (Get-Service -Name $ServiceName).Status.ToString()
$ledgerAfterStop = Read-Ledger
$completedAt = $null
if ($updatedAt) {
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($updatedAt, [ref] $parsed)) { $completedAt = $parsed }
}

Write-Result @{
    status                   = $stopError ? 'STOP_FAILED' : 'COMPLETED'
    demandId                 = $DemandId
    stage                    = $stage
    latchedStage             = $latchedStage
    latchedAtUtc             = $latchedAt.ToString('o')
    completedRecordedAtUtc   = $completedAt ? $completedAt.ToUniversalTime().ToString('o') : $updatedAt
    stopRequestedAtUtc       = $stopRequestedAt.ToString('o')
    serviceStoppedAtUtc      = $stoppedAt.ToString('o')
    reactionMs               = $completedAt ? [int]($stopRequestedAt - $completedAt).TotalMilliseconds : $null
    stopDurationMs           = [int]($stoppedAt - $stopRequestedAt).TotalMilliseconds
    serviceStatus            = $serviceStatus
    stopError                = $stopError
    acceptedDemandIdsAtLatch = $ledgerAtLatch.acceptedDemandIds
    orderIntentLegIdsAtLatch = $ledgerAtLatch.orderIntentLegIds
    acceptedDemandIdsAfter   = $ledgerAfterStop.acceptedDemandIds
    orderIntentLegIdsAfter   = $ledgerAfterStop.orderIntentLegIds
    message                  = $stopError ? "Journey $DemandId completed but the service could not be stopped: $stopError" : "Journey $DemandId completed; service stopped."
}
