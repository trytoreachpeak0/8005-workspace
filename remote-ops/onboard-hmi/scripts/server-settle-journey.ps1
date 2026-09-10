#Requires -Version 7
<#
.SYNOPSIS
    Surveys every in-flight WIRE_TO_GATE journey in a ControlServer SQLite file
    and, with -Settle, closes them the way the product closes a journey that
    never loaded anything. Runs ON the factory server;
    12-reset-journey-state.ps1 deploys and drives it.

.DESCRIPTION
    WHAT "IN FLIGHT" MEANS. Every JourneyRuntimes row whose Stage is not
    Completed. That is the engine's own test (JourneyRuntimeEngine.ExecuteOnceAsync):
    Blocked is not terminal -- it is where recovery happens -- and while any such
    row exists the engine never reaches discovery.

    WHAT SETTLING WRITES. The write set of WireToGateStore.CancelDemandBeforeLoadAsync
    plus SettleJourneyDemandAsync, applied to every demand the journey is still
    carrying, in one transaction:

        AcceptedDemands              Status = Cancelled
        TransportDemandSuppressions  one row per business key, with -ReasonCode
        JourneyDemands               State = Cancelled
        VehicleDispatchLeases        ReleasedAt, so intake is not blocked for good
        ProtocolOutbox               AcknowledgedAt on this journey's pending rows
        JourneyRuntimes              Stage = Completed, BlockReasonCode = -ReasonCode

    NOTHING IS DELETED, and that is the lesson of 2026-09-04 and the reason this
    replaced a DELETE. A new journey seeds its snapshot revisions from the MAX
    over the vehicle's JourneyRuntimes rows (WireToGateStore.SeedSnapshotRevisionsAsync),
    so a deleted row takes the revision history with it and the next journey
    republishes revisions the vehicle has already adopted.

    The suppression is PERMANENT. The product has no cancellation that does not
    raise one -- SuppressTransportDemandAsync refuses any other reason code --
    and no entry point that lifts one. The lot will never be dispatched by the
    system again, under this DemandId or a fresh one MesIngest allocates for the
    same business key. That is why the reason code is always explicit.

    PENDING OUTBOX ROWS ARE ATTRIBUTED, NOT SWEPT. A pending row belongs to the
    journey when its MessageId is one the journey stores (stop snapshot, plan and
    safety-check ids, load and unload command ids), or its payload names one of
    the journey's own identifiers (journey, operation session, demand, movement
    leg, upper id). The product itself settles only the current stop's sublot
    request, because in its path the session was Ready and everything else had
    been delivered; a journey stuck behind a session that never became Ready has
    its snapshots still queued, and replaying those into an empty onboard journal
    would hand the vehicle the abandoned journey back. Rows that cannot be
    attributed are reported and left alone.

    WHAT IT REFUSES. A demand still being carried with any StationOperations row:
    a slot operation was commanded, so a door may be open or cargo may be on
    board, and only the peer can settle that -- through recovery, not this
    script. Likewise a Loaded demand, a demand with no AcceptedDemands row or one
    already Succeeded, and a journey without a lease row. Each of these is
    exactly where the product method would have thrown.

    HOW -Settle RUNS. Survey read-only and refuse before touching anything; stop
    the service; prove nothing else holds the file; copy db, -wal and -shm; then
    survey again inside the transaction, refuse if the in-flight set is not the
    one the caller saw (-ExpectJourneyIds), and write with every statement
    checked for exactly one affected row. Any mismatch rolls back and the service
    is started again. On success the service is LEFT STOPPED: the caller still
    has the vehicle's journal to clear, and a running engine with a stale journal
    on the vehicle is the half-state the caller exists to avoid.

.PARAMETER ServiceName
    The Windows service that owns -Database. Omit it only for a copy of a
    database that no service owns -- a rehearsal. Either way, -Settle refuses a
    file some other process still holds open.

.PARAMETER ExpectJourneyIds
    Comma-separated. The in-flight journey ids the caller surveyed. -Settle
    refuses when the server's set is different by the time the service is down.

.OUTPUTS
    Exactly one line of compact JSON, with status SURVEY, SETTLED, REFUSED or
    FAILED. The caller reads the last line beginning with '{'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Database,
    [Parameter(Mandatory = $true)][string] $InstallRoot,
    [string] $ServiceName,
    [string] $BackupRoot,
    [string] $ReasonCode,
    [string] $ExpectJourneyIds,
    [string] $Stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss'),
    [switch] $Settle
)

$ErrorActionPreference = 'Stop'

# WireToGateStore.SuppressingReasonCodes. MES_DISAPPEARED and GONE are not here
# on purpose: a demand vanishing from the catalog does not ban it.
$suppressingReasonCodes = @(
    'CANCELLED_BY_OPERATOR'
    'CANCELLED_BY_LOAD_COMPENSATION'
    'CANCELLED_BY_STOP_COMPLETE'
    'CANCELLED_BY_STATION_TIMEOUT'
    'TERMINATED_BY_FAULT_CARGO_HANDOFF'
)

function Write-Result {
    param([hashtable] $Fields)
    Write-Output ([pscustomobject]$Fields | ConvertTo-Json -Depth 8 -Compress)
}

if ($Settle) {
    if ($ReasonCode -cnotin $suppressingReasonCodes) {
        throw "-Settle needs -ReasonCode, one of: $($suppressingReasonCodes -join ', ')."
    }
    if (-not $BackupRoot) { throw '-Settle needs -BackupRoot.' }
    if (-not $ExpectJourneyIds) { throw '-Settle needs -ExpectJourneyIds: survey first, then settle what you saw.' }
}

$dll = (Get-ChildItem -LiteralPath $InstallRoot -Filter 'Microsoft.Data.Sqlite.dll' -Recurse |
    Select-Object -First 1).FullName
if (-not $dll) { throw "Microsoft.Data.Sqlite.dll not found under $InstallRoot." }
Add-Type -Path $dll
if (-not (Test-Path -LiteralPath $Database)) { throw "Database not found: $Database" }

# Pooling off: a pooled connection keeps its file handle after Close, and the
# exclusive-open check below would then find this script holding the file.
function Open-Database {
    param([switch] $ReadOnly)
    $mode = $ReadOnly ? ';Mode=ReadOnly' : ''
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$Database;Pooling=False$mode")
    $connection.Open()
    return $connection
}

function New-Command {
    param($Connection, $Transaction, [string] $Sql, [hashtable] $Parameters)
    $command = $Connection.CreateCommand()
    $command.Transaction = $Transaction
    $command.CommandText = $Sql
    foreach ($name in @($Parameters.Keys)) {
        $null = $command.Parameters.AddWithValue($name, $Parameters[$name] ?? [DBNull]::Value)
    }
    return $command
}

# Returns the rows as one array. Assign the result, then loop with foreach: the
# leading comma keeps a single row an array, and makes a pipeline see the whole
# set as one object (see Read-Rows in server-close-gates-watch.ps1).
function Invoke-Query {
    param($Connection, $Transaction, [string] $Sql, [hashtable] $Parameters = @{})
    $reader = (New-Command $Connection $Transaction $Sql $Parameters).ExecuteReader()
    $rows = [System.Collections.Generic.List[object]]::new()
    while ($reader.Read()) {
        $row = [ordered]@{}
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            $row[$reader.GetName($i)] = $reader.IsDBNull($i) ? $null : $reader.GetValue($i)
        }
        $rows.Add([pscustomobject]$row)
    }
    $reader.Close()
    return , $rows.ToArray()
}

function Get-Survey {
    param($Connection, $Transaction)

    $journeys = Invoke-Query $Connection $Transaction @'
SELECT JourneyId, Stage, BlockReasonCode, AgvId, VehicleKey, OperationSessionId,
       VehicleBusinessRevision, WorklistRevision, PlanRevision, UpdatedAt
FROM JourneyRuntimes WHERE Stage <> 'Completed' ORDER BY CreatedAt
'@
    $pending = Invoke-Query $Connection $Transaction @'
SELECT MessageId, MessageType, CreatedAt, PayloadJson
FROM ProtocolOutbox WHERE AcknowledgedAt IS NULL ORDER BY CreatedAt, MessageId
'@
    $attributed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $report = [System.Collections.Generic.List[object]]::new()

    foreach ($journey in $journeys) {
        $key = @{ '@j' = $journey.JourneyId }
        $demands = Invoke-Query $Connection $Transaction @'
SELECT d.DemandId, d.StopSequence, d.State, d.LoadCommandMessageId, d.UnloadCommandMessageId,
       a.Status AS AcceptedStatus, a.TransportDemandKey,
       EXISTS (SELECT 1 FROM TransportDemandSuppressions s WHERE s.TransportDemandKey = a.TransportDemandKey) AS Suppressed,
       (SELECT COUNT(*) FROM StationOperations o WHERE o.DemandId = d.DemandId) AS StationOperations,
       (SELECT COUNT(*) FROM RecoveryWorkflows w WHERE w.DemandId = d.DemandId) AS RecoveryWorkflows
FROM JourneyDemands d LEFT JOIN AcceptedDemands a ON a.DemandId = d.DemandId
WHERE d.JourneyId = @j ORDER BY d.StopSequence, d.DemandId
'@ $key
        $stops = Invoke-Query $Connection $Transaction @'
SELECT Sequence, MovementLegId, UpperId, VehicleBusinessMessageId, PlanMessageId, PreDepartureSafetyCheckMessageId
FROM JourneyStops WHERE JourneyId = @j ORDER BY Sequence
'@ $key
        $lease = Invoke-Query $Connection $Transaction `
            'SELECT AcquiredAt, ReleasedAt FROM VehicleDispatchLeases WHERE JourneyId = @j' $key
        $legs = Invoke-Query $Connection $Transaction @'
SELECT o.MovementLegId, o.Purpose, o.Status, o.OrderId
FROM OrderIntents o JOIN JourneyStops s ON s.MovementLegId = o.MovementLegId
WHERE s.JourneyId = @j ORDER BY s.Sequence
'@ $key

        $ownIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $tokens = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $journey.JourneyId, $journey.OperationSessionId) { $tokens.Add("`"$id`"") }
        foreach ($stop in $stops) {
            foreach ($id in $stop.VehicleBusinessMessageId, $stop.PlanMessageId, $stop.PreDepartureSafetyCheckMessageId) {
                $null = $ownIds.Add($id)
            }
            foreach ($id in $stop.MovementLegId, $stop.UpperId) { $tokens.Add("`"$id`"") }
        }
        foreach ($demand in $demands) {
            foreach ($id in $demand.LoadCommandMessageId, $demand.UnloadCommandMessageId) { $null = $ownIds.Add($id) }
            $tokens.Add("`"$($demand.DemandId)`"")
        }
        $outbox = [System.Collections.Generic.List[object]]::new()
        foreach ($message in $pending) {
            $mine = $ownIds.Contains($message.MessageId)
            if (-not $mine) {
                foreach ($token in $tokens) {
                    if ($message.PayloadJson.Contains($token, [StringComparison]::Ordinal)) { $mine = $true; break }
                }
            }
            if ($mine) {
                $null = $attributed.Add($message.MessageId)
                $outbox.Add([pscustomobject]@{
                        messageId   = $message.MessageId
                        messageType = $message.MessageType
                        createdAt   = $message.CreatedAt
                    })
            }
        }

        # Still being carried: the demands the product would cancel one by one.
        $carried = @(foreach ($demand in $demands) { if ($demand.State -in 'Planned', 'Loaded') { $demand } })
        $refusals = [System.Collections.Generic.List[string]]::new()
        foreach ($demand in $carried) {
            if ($demand.StationOperations -gt 0) {
                $refusals.Add("demand $($demand.DemandId) has $($demand.StationOperations) StationOperations row(s): a slot operation was commanded, so a door may be open or cargo on board, and only the peer can settle that (recovery)")
            }
            elseif ($demand.State -eq 'Loaded') {
                $refusals.Add("demand $($demand.DemandId) is Loaded: its cargo is on board")
            }
            if (-not $demand.AcceptedStatus) {
                $refusals.Add("demand $($demand.DemandId) has no AcceptedDemands row")
            }
            elseif ($demand.AcceptedStatus -eq 'Succeeded') {
                $refusals.Add("demand $($demand.DemandId) already Succeeded and cannot be cancelled as if nothing had been loaded")
            }
        }
        if ($lease.Count -eq 0) {
            $refusals.Add("journey $($journey.JourneyId) has no VehicleDispatchLeases row")
        }

        $cancel = @(foreach ($demand in $carried) { if ($demand.AcceptedStatus -notin 'Cancelled', 'Succeeded') { $demand } })
        $report.Add([pscustomobject]@{
                journeyId       = $journey.JourneyId
                stage           = $journey.Stage
                blockReasonCode = $journey.BlockReasonCode
                agvId           = $journey.AgvId
                vehicleKey      = $journey.VehicleKey
                updatedAt       = $journey.UpdatedAt
                revisions       = "vehicleBusiness=$($journey.VehicleBusinessRevision) worklist=$($journey.WorklistRevision) plan=$($journey.PlanRevision)"
                demands         = @(foreach ($demand in $demands) {
                        [pscustomobject]@{
                            demandId           = $demand.DemandId
                            stopSequence       = $demand.StopSequence
                            state              = $demand.State
                            acceptedStatus     = $demand.AcceptedStatus
                            transportDemandKey = $demand.TransportDemandKey
                            suppressed         = [bool]$demand.Suppressed
                            stationOperations  = $demand.StationOperations
                            recoveryWorkflows  = $demand.RecoveryWorkflows
                        }
                    })
                lease           = $lease.Count ? [pscustomobject]@{ acquiredAt = $lease[0].AcquiredAt; releasedAt = $lease[0].ReleasedAt } : $null
                outbox          = $outbox.ToArray()
                riotLegs        = @(foreach ($leg in $legs) {
                        [pscustomobject]@{ movementLegId = $leg.MovementLegId; purpose = $leg.Purpose; status = $leg.Status; orderId = $leg.OrderId }
                    })
                refusals        = $refusals.ToArray()
                # What -Settle will write for this journey, one statement per row.
                cancelDemandIds   = @($cancel | ForEach-Object { $_.DemandId })
                suppressDemandIds = @($cancel | Where-Object { -not $_.Suppressed } | ForEach-Object { $_.DemandId })
                settleDemandIds   = @($carried | ForEach-Object { $_.DemandId })
                releaseLease      = $lease.Count -gt 0 -and $null -eq $lease[0].ReleasedAt
            })
    }

    $journeyReports = $report.ToArray()
    [pscustomobject]@{
        journeys           = $journeyReports
        unattributedOutbox = @(foreach ($message in $pending) {
                if (-not $attributed.Contains($message.MessageId)) {
                    [pscustomobject]@{ messageId = $message.MessageId; messageType = $message.MessageType; createdAt = $message.CreatedAt }
                }
            })
        refusals           = @($journeyReports | ForEach-Object { $_.refusals })
    }
}

# ------------------------------------------------------------------ survey ---

$connection = Open-Database -ReadOnly
try { $survey = Get-Survey $connection $null } finally { $connection.Close() }

if (-not $Settle) {
    Write-Result @{
        status             = 'SURVEY'
        journeys           = $survey.journeys
        unattributedOutbox = $survey.unattributedOutbox
        refusals           = $survey.refusals
    }
    return
}

$expected = @($ExpectJourneyIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object)
function Test-SameJourneys {
    param($Survey)
    $actual = @($Survey.journeys | ForEach-Object { $_.journeyId } | Sort-Object)
    return ($actual -join ',') -ceq ($expected -join ',')
}

if ($survey.refusals.Count -or -not (Test-SameJourneys $survey)) {
    Write-Result @{
        status   = 'REFUSED'
        journeys = $survey.journeys
        refusals = $survey.refusals
        message  = $survey.refusals.Count `
            ? 'Refused before anything was touched; the service was not stopped.' `
            : "In flight now: [$(@($survey.journeys | ForEach-Object { $_.journeyId }) -join ', ')]; surveyed: [$($expected -join ', ')]. Nothing was touched."
    }
    return
}

# ------------------------------------------------------------------ settle ---

$serviceWasRunning = $false
$committed = $false
$backup = $null
$writes = [ordered]@{
    AcceptedDemands             = 0
    TransportDemandSuppressions = 0
    JourneyDemands              = 0
    VehicleDispatchLeases       = 0
    ProtocolOutbox              = 0
    JourneyRuntimes             = 0
}
$outcome = $null

try {
    if ($ServiceName) {
        $service = Get-Service -Name $ServiceName
        $serviceWasRunning = $service.Status -eq 'Running'
        if ($service.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
    }

    # The service being Stopped says nothing about anyone else. FileShare.None
    # fails while any process -- the service, a watcher, a second copy of this
    # script -- still has the file open, and a write under a live engine is the
    # one thing this must never do.
    foreach ($suffix in '', '-wal', '-shm') {
        $path = "$Database$suffix"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try { [IO.File]::Open($path, 'Open', 'ReadWrite', 'None').Dispose() }
        catch { throw "Something still holds $path open: $($_.Exception.Message)" }
    }

    $backup = Join-Path $BackupRoot "db-backup-settle-$Stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($suffix in '', '-wal', '-shm') {
        $path = "$Database$suffix"
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup -Force }
    }

    # One timestamp for the whole settlement, in the text form EF Core's SQLite
    # provider stores DateTimeOffset in.
    $at = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss.FFFFFFFzzz', [cultureinfo]::InvariantCulture)

    $connection = Open-Database
    try {
        $transaction = $connection.BeginTransaction()
        try {
            $inside = Get-Survey $connection $transaction
            if ($inside.refusals.Count -or -not (Test-SameJourneys $inside)) {
                $transaction.Rollback()
                $outcome = @{
                    status   = 'REFUSED'
                    journeys = $inside.journeys
                    refusals = $inside.refusals
                    message  = 'The state changed between the survey and the stop. Rolled back; nothing was written.'
                }
            }
            else {
                function Invoke-Write {
                    param([string] $Table, [string] $Sql, [hashtable] $Parameters)
                    $affected = (New-Command $connection $transaction $Sql $Parameters).ExecuteNonQuery()
                    if ($affected -ne 1) {
                        throw "$Table affected $affected row(s) for $(($Parameters.Values | ForEach-Object { "$_" }) -join ' / '), expected 1."
                    }
                    $writes[$Table]++
                }

                foreach ($journey in $inside.journeys) {
                    foreach ($demand in $journey.demands) {
                        $d = @{ '@d' = $demand.demandId }
                        if ($demand.demandId -in $journey.cancelDemandIds) {
                            Invoke-Write 'AcceptedDemands' `
                                "UPDATE AcceptedDemands SET Status = 'Cancelled' WHERE DemandId = @d AND Status NOT IN ('Cancelled', 'Succeeded')" $d
                        }
                        if ($demand.demandId -in $journey.suppressDemandIds) {
                            Invoke-Write 'TransportDemandSuppressions' @'
INSERT INTO TransportDemandSuppressions (TransportDemandKey, DemandId, ReasonCode, SuppressedAt)
SELECT @k, @d, @r, @at WHERE NOT EXISTS (SELECT 1 FROM TransportDemandSuppressions WHERE TransportDemandKey = @k)
'@ @{ '@k' = $demand.transportDemandKey; '@d' = $demand.demandId; '@r' = $ReasonCode; '@at' = $at }
                        }
                        if ($demand.demandId -in $journey.settleDemandIds) {
                            Invoke-Write 'JourneyDemands' `
                                "UPDATE JourneyDemands SET State = 'Cancelled' WHERE JourneyId = @j AND DemandId = @d AND State = 'Planned'" `
                                @{ '@j' = $journey.journeyId; '@d' = $demand.demandId }
                        }
                    }
                    if ($journey.releaseLease) {
                        Invoke-Write 'VehicleDispatchLeases' `
                            'UPDATE VehicleDispatchLeases SET ReleasedAt = @at WHERE JourneyId = @j AND ReleasedAt IS NULL' `
                            @{ '@j' = $journey.journeyId; '@at' = $at }
                    }
                    foreach ($message in $journey.outbox) {
                        Invoke-Write 'ProtocolOutbox' `
                            'UPDATE ProtocolOutbox SET AcknowledgedAt = @at WHERE MessageId = @m AND AcknowledgedAt IS NULL' `
                            @{ '@m' = $message.messageId; '@at' = $at }
                    }
                    # The row stays: its revisions are where the next journey on
                    # this vehicle continues from.
                    Invoke-Write 'JourneyRuntimes' @'
UPDATE JourneyRuntimes SET Stage = 'Completed', BlockReasonCode = @r, UpdatedAt = @at
WHERE JourneyId = @j AND Stage <> 'Completed'
'@ @{ '@j' = $journey.journeyId; '@r' = $ReasonCode; '@at' = $at }
                }
                $transaction.Commit()
                $committed = $true
            }
        }
        catch {
            if (-not $committed) { $transaction.Rollback() }
            throw
        }
    }
    finally { $connection.Close() }
}
catch {
    $outcome = @{
        status  = 'FAILED'
        message = "$($_.Exception.Message) Rolled back; nothing was written."
        backup  = $backup
    }
}
finally {
    # Unchanged database, so put the service back the way it was found. A
    # committed settlement leaves it stopped for the caller (see DESCRIPTION).
    if (-not $committed -and $serviceWasRunning) { Start-Service -Name $ServiceName }
}

if ($outcome) {
    Write-Result $outcome
    return
}

# ------------------------------------------------------------------ verify ---

$connection = Open-Database -ReadOnly
try {
    $after = Get-Survey $connection $null
    $ids = @($expected)
    $stillInFlight = @($after.journeys | Where-Object { $_.journeyId -in $ids } | ForEach-Object { $_.journeyId })
    $unreleased = [long](New-Command $connection $null `
            "SELECT COUNT(*) FROM VehicleDispatchLeases WHERE ReleasedAt IS NULL AND JourneyId IN ('$($ids -join "','")')" @{}).ExecuteScalar()
}
finally { $connection.Close() }

Write-Result @{
    status             = ($stillInFlight.Count -or $unreleased) ? 'FAILED' : 'SETTLED'
    journeyIds         = $ids
    reasonCode         = $ReasonCode
    settledAt          = $at
    writes             = $writes
    backup             = $backup
    serviceName        = $ServiceName
    serviceWasRunning  = $serviceWasRunning
    serviceStatus      = $ServiceName ? (Get-Service -Name $ServiceName).Status.ToString() : $null
    stillInFlight      = $stillInFlight
    unreleasedLeases   = $unreleased
    unattributedOutbox = $after.unattributedOutbox
    message            = ($stillInFlight.Count -or $unreleased) `
        ? "Committed, but verification found in-flight [$($stillInFlight -join ', ')] and $unreleased unreleased lease(s). Backup at $backup." `
        : "Committed. Backup at $backup."
}
