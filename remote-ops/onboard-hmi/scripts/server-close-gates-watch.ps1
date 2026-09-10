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

    Completed IS THE ONLY TERMINAL STAGE. The engine counts every other stage as
    an unresolved journey (JourneyRuntimeEngine.ExecuteOnceAsync), Blocked
    included: Blocked is where recovery runs, and a recovered journey leaves it.
    So a Blocked journey is latched like any other, then reported, and the
    service is left alone -- while it is unresolved the engine never reaches
    discovery, so there is no race to win, and recovery needs the loop a stop
    would take away. This watcher used to treat Blocked as terminal when
    latching, which is not the engine's view: started beside a Blocked journey it
    skipped it, announced the runtime idle, and latched onto whichever journey
    had been updated last.

    A JOURNEY, NOT A DEMAND. Since protocol 0.2.0 (migration
    MultiDemandJourneyStopSequence, 2026-09-08) a journey has its own id and
    carries its demands in JourneyDemands -- it may pick up more of them on the
    way. JourneyRuntimes has no DemandId column any more.

.PARAMETER Database
    The ControlServer SQLite file to watch. Pointing this at a copy is how the
    completion path is exercised without a real vehicle: the stop, the config
    write and the verification are all real, only the completion signal is not.

.PARAMETER DemandId
    Watch the journey carrying this demand instead of latching onto whichever
    one is unresolved.

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
# points is the acceptance evidence: a set that grew means the runtime slipped
# something through the window this script exists to close.
#
# It is DEMAND-level on purpose. A journey creates its own movement legs as it
# goes -- TO_PICKUP at intake, TO_GATE once the load is done -- so an OrderIntents
# row that appears mid-trip is this journey's own second leg and says nothing.
# Comparing leg ids made every real journey look like a lost race: the first real
# run on 2026-09-08 latched with one leg, finished with two, and reported a
# violation that had not happened. What must not appear is a leg belonging to
# some OTHER demand, or another accepted demand at all. The leg count is carried
# for the report, never asserted on.
# ASSIGN, then iterate. Read-Rows ends in `return , $rows` so that `$row[0][0]`
# works at the call sites below, and that same comma makes a PIPELINE see ONE
# object -- the whole row set -- instead of one object per row. Written as
# `Read-Rows ... | ForEach-Object { $_[0] }` the loop therefore ran once with
# `$_` bound to the entire array, and `$_[0]` yielded the FIRST ROW rather than
# the first column of each row. Every list here silently had exactly one element
# no matter how many rows the table held.
#
# It only misreported once a table held more than one row, which is why it
# survived two real journeys: with a single AcceptedDemands row the answer is
# accidentally right. On 2026-09-08, with two demands on the server, the latch
# ledger read 1 accepted / 1 leg against the true 2 and 3; the demand that fell
# out of the set then looked like one the runtime had just taken, and a fully
# successful journey was reported as a lost race and exited 1.
function Read-Ledger {
    $accepted = Read-Rows 'SELECT DemandId FROM AcceptedDemands ORDER BY DemandId'
    $intentDemands = Read-Rows 'SELECT DISTINCT DemandId FROM OrderIntents ORDER BY DemandId'
    $intentLegs = Read-Rows 'SELECT MovementLegId FROM OrderIntents'
    [pscustomobject]@{
        acceptedDemandIds    = @($accepted | ForEach-Object { $_[0] })
        orderIntentDemandIds = @($intentDemands | ForEach-Object { $_[0] })
        orderIntentLegCount  = $intentLegs.Count
    }
}

# The watched journey's own demands, which the caller must not count as taken
# through the window: a journey can pick up another demand at a later stop.
function Read-JourneyDemandIds {
    param([string] $Id)
    $rows = Read-Rows "SELECT DemandId FROM JourneyDemands WHERE JourneyId = '$($Id -replace "'", "''")' ORDER BY StopSequence, DemandId"
    # The comma keeps a one-demand journey an array, so the JSON says [id], not id.
    return , @($rows | ForEach-Object { $_[0] })
}

function Write-Heartbeat {
    param([string] $Message)
    Write-Output "[$([DateTime]::Now.ToString('HH:mm:ss'))] $Message"
}

function Write-Result {
    param([hashtable] $Fields)
    Write-Output ([pscustomobject]$Fields | ConvertTo-Json -Depth 5 -Compress)
}

# ------------------------------------------------------------------- latch ---

$journeyId = $null
$latchedStage = $null

if ($DemandId) {
    $row = Read-Rows "SELECT r.JourneyId, r.Stage FROM JourneyDemands d JOIN JourneyRuntimes r ON r.JourneyId = d.JourneyId WHERE d.DemandId = '$($DemandId -replace "'", "''")'"
    if ($row.Count -eq 0) {
        Write-Result @{ status = 'VANISHED'; demandId = $DemandId; message = "No journey carries demand $DemandId. Nothing was stopped." }
        return
    }
    $journeyId = $row[0][0]
    $latchedStage = $row[0][1]
}

# The interesting case is being started BEFORE the journey exists, which is the
# only way to be sure the watcher is already in place when it completes. So an
# empty JourneyRuntimes table is a wait, not an answer -- unless something has
# already finished, in which case the runtime is idle right now and the gate
# should have been shut already.
$latchDeadline = [DateTime]::UtcNow.AddSeconds($LatchTimeoutSeconds)
$lastHeartbeat = [DateTime]::UtcNow
Write-Heartbeat "Watching $Database for a journey to latch onto (poll ${PollMilliseconds} ms)"
while (-not $journeyId) {
    $open = Read-Rows "SELECT JourneyId, Stage FROM JourneyRuntimes WHERE Stage <> 'Completed' ORDER BY CreatedAt"
    if ($open.Count -gt 1) {
        Write-Result @{
            status  = 'AMBIGUOUS'
            message = "More than one unresolved journey: $(($open | ForEach-Object { $_[0] }) -join ', '). Nothing was stopped."
        }
        return
    }
    if ($open.Count -eq 1) {
        $journeyId = $open[0][0]
        $latchedStage = $open[0][1]
        break
    }
    $finished = Read-Rows 'SELECT JourneyId, Stage FROM JourneyRuntimes ORDER BY UpdatedAt DESC LIMIT 1'
    if ($finished.Count -gt 0) {
        $journeyId = $finished[0][0]
        $latchedStage = $finished[0][1]
        Write-Heartbeat "No unresolved journey; newest is $journeyId at $latchedStage -- the runtime is idle already"
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

$latchedAt = [DateTimeOffset]::UtcNow
$ledgerAtLatch = Read-Ledger
$demandsAtLatch = Read-JourneyDemandIds $journeyId
Write-Heartbeat "Latched onto journey $journeyId at stage $latchedStage (demands $($demandsAtLatch -join ', ')); AcceptedDemands=$($ledgerAtLatch.acceptedDemandIds.Count) OrderIntent legs=$($ledgerAtLatch.orderIntentLegCount)"

# -------------------------------------------------------------------- wait ---

$idQuoted = $journeyId -replace "'", "''"
$journeyDeadline = [DateTime]::UtcNow.AddSeconds($JourneyTimeoutSeconds)
$lastHeartbeat = [DateTime]::UtcNow
$consecutiveFailures = 0
$stage = $latchedStage
$blockReason = $null
$updatedAt = $null

while ($true) {
    try {
        $row = Read-Rows "SELECT Stage, BlockReasonCode, UpdatedAt FROM JourneyRuntimes WHERE JourneyId = '$idQuoted'"
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
            status    = 'VANISHED'
            journeyId = $journeyId
            demandIds = $demandsAtLatch
            message   = "Journey $journeyId disappeared while being watched. Nothing was stopped."
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
            journeyId       = $journeyId
            demandIds       = $demandsAtLatch
            stage           = $stage
            blockReasonCode = $blockReason
            updatedAt       = $updatedAt
            message         = "Journey $journeyId is Blocked ($blockReason). The service was left running: a blocked journey is still unresolved, so no new demand can be accepted, and recovery needs the runtime loop."
        }
        return
    }

    if ([DateTime]::UtcNow -ge $journeyDeadline) {
        Write-Result @{
            status    = 'TIMEOUT'
            journeyId = $journeyId
            demandIds = $demandsAtLatch
            stage     = $stage
            message   = "Journey $journeyId was still at $stage after ${JourneyTimeoutSeconds}s. Nothing was stopped."
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
$demandsAfterStop = Read-JourneyDemandIds $journeyId
$completedAt = $null
if ($updatedAt) {
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($updatedAt, [ref] $parsed)) { $completedAt = $parsed }
}

Write-Result @{
    status                   = $stopError ? 'STOP_FAILED' : 'COMPLETED'
    journeyId                = $journeyId
    demandIds                = $demandsAfterStop
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
    acceptedDemandIdsAtLatch    = $ledgerAtLatch.acceptedDemandIds
    orderIntentDemandIdsAtLatch = $ledgerAtLatch.orderIntentDemandIds
    orderIntentLegsAtLatch      = $ledgerAtLatch.orderIntentLegCount
    acceptedDemandIdsAfter      = $ledgerAfterStop.acceptedDemandIds
    orderIntentDemandIdsAfter   = $ledgerAfterStop.orderIntentDemandIds
    orderIntentLegsAfter        = $ledgerAfterStop.orderIntentLegCount
    message                  = $stopError ? "Journey $journeyId completed but the service could not be stopped: $stopError" : "Journey $journeyId completed; service stopped."
}
