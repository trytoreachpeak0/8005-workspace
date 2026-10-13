#Requires -Version 7
<#
.SYNOPSIS
    Completes an automatic charging run the engine can never finish on its own, so intake is not held by it
    forever. Runs ON the control host and reaches the factory server over ssh.

.DESCRIPTION
    WHY IT EXISTS. While any AutoChargingRuns row of the vehicle is not Completed, JourneyRuntimeEngine drives
    that run and takes no demand; a run leaves Charging only when the battery reaches the resume level. A run
    standing on a charger that never engaged (CHARGER_NOT_ENGAGED) therefore holds the vehicle for good, and no
    product path ends it. Field window two left bc7244b5 in exactly that state on 2026-09-12
    (8005-agv-program#20; why it never engaged was fixed by #53).

    WHAT IT WRITES. One row, one transaction:

        AutoChargingRuns   Stage = Completed, BlockReasonCode = SETTLED_BY_OPERATOR, UpdatedAt

    ReleasedAtBatteryPercent stays NULL. Together with the code, that is how the row says it was closed by hand
    and not released at the resume level. Nothing else is written: a charging run holds no dispatch lease, and
    its TO_CHARGER row in OrderIntents is only ever read through the run, so it stays as the record of what RIoT
    was asked. RIoT itself is not touched; the survey prints the order id so a non-terminal order can be
    checked there by hand.

    HOW. Survey read-only first; -WhatIf stops there. Then stop the service, prove nothing else holds the
    database file (FileShare.None), copy db, -wal and -shm, re-read the row inside the transaction, write it
    with exactly one affected row, and put the service back as it was found. Any surprise rolls back.

.PARAMETER ChargingRunId
    The full id the survey prints. A prefix is refused on purpose: this writes production.

.PARAMETER ServiceName
    -ServerDatabase, -ServerInstallRoot and -ServiceName say which ControlServer instance is written, and their
    defaults are the production MVP service. Give all three or none (workspace#38): a partial set is refused with
    TARGET_PARTIAL, and a set where some name the MVP and others do not with TARGET_MIXED_MVP, before anything
    reaches the server. Then the server is asked which directory the service runs from and what
    <install root>\appsettings.Production.json names as its database; unless the service runs from
    -ServerInstallRoot and that database is -ServerDatabase, nothing is surveyed, stopped or written (TARGET_* codes
    in ControlServerTarget.psm1; a database that is not the instance's own is TARGET_DATABASE_NOT_OWN).
    -ServerBackupRoot is not one of the three.

    Before workspace#38, a v2 -ServerDatabase alone stopped the MVP service and started it again.

    The read-back is read-only. Run against the MVP it reads the MVP's service registration and appsettings on
    factory01, as part of the MVP run that needs the user's word anyway; run against a v2 instance it reads that
    service and that configuration, never the MVP's.

    THE STOP IS PER INSTANCE, NOT PER VEHICLE. A v2 instance serves more than one car, and every one of them loses
    its server for the length of the write: no dispatch, no supervision. Make sure the other vehicles of that
    instance are idle first; the service is started again afterwards if it was running.

.PARAMETER Force
    Suppresses the confirmation prompt by lowering $ConfirmPreference. Needed to run this from a
    non-interactive shell: ConfirmImpact is High, and ShouldProcess throws when there is no host UI.

.EXAMPLE
    ./Complete-ChargingRun.ps1 -WhatIf

.EXAMPLE
    ./Complete-ChargingRun.ps1 -ChargingRunId <full id from the survey> -Force

.EXAMPLE
    # A v2 instance: all three instance parameters, or it is refused before the server is touched.
    ./Complete-ChargingRun.ps1 -WhatIf -ServiceName '8005 AGV ControlServer V2' `
        -ServerInstallRoot 'C:\Program Files\8005 AGV\ControlServer.V2' `
        -ServerDatabase 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db'
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ChargingRunId,
    [string] $ServerAlias = 'factory01',
    [string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer\data\controlserver.db',
    [string] $ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer',
    [string] $ServerBackupRoot = 'D:\zhengyushao\control-server-ops',
    [string] $ServiceName = '8005 AGV ControlServer',
    [ValidateRange(1, 120)]
    [int] $TimeoutSec = 30,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# workspace#38: which instance, decided before anything reaches the server.
Import-Module (Join-Path $PSScriptRoot 'ControlServerTarget.psm1') -Force
$target = Assert-ControlServerTargetParameters -Bound @($PSBoundParameters.Keys) `
    -Values ([ordered]@{ ServerDatabase = $ServerDatabase; ServerInstallRoot = $ServerInstallRoot; ServiceName = $ServiceName }) `
    -Kinds ([ordered]@{ ServerDatabase = 'Database'; ServerInstallRoot = 'InstallRoot'; ServiceName = 'ServiceName' })

$marker = '@@W2G-CHARGING-RUN@@'

# Runs on the server. The caller prepends the variable assignments.
$remoteBody = @'
$ErrorActionPreference = 'Stop'

function Write-Result([hashtable] $Fields) {
    $marker + ([pscustomobject]$Fields | ConvertTo-Json -Depth 6 -Compress)
}

$dll = (Get-ChildItem -LiteralPath $installRoot -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
if (-not $dll) { throw "Microsoft.Data.Sqlite.dll not found under $installRoot." }
Add-Type -Path $dll
if (-not (Test-Path -LiteralPath $database)) { throw "Database not found: $database" }

# Pooling off: a pooled connection keeps its file handle after Close, and the exclusive-open check would then
# find this script holding the file.
function Open-Database([switch] $ReadOnly) {
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False$($ReadOnly ? ';Mode=ReadOnly' : '')")
    $connection.Open()
    return $connection
}

function Read-UnfinishedRuns($Connection, $Transaction) {
    $command = $Connection.CreateCommand()
    $command.Transaction = $Transaction
    $command.CommandText = @"
SELECT r.ChargingRunId, r.AgvId, r.Stage, r.BlockReasonCode, r.TriggeredAtBatteryPercent, r.ReleasedAtBatteryPercent,
       r.ChargerStationId, r.ChargerStationRiotId, r.UpperId, r.CreatedAt, r.UpdatedAt,
       o.Status AS IntentStatus, o.OrderId AS IntentOrderId
FROM AutoChargingRuns r LEFT JOIN OrderIntents o ON o.UpperId = r.UpperId
WHERE r.Stage <> 'Completed' ORDER BY r.CreatedAt
"@
    $reader = $command.ExecuteReader()
    $rows = [System.Collections.Generic.List[object]]::new()
    while ($reader.Read()) {
        $row = [ordered]@{}
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            $row[$reader.GetName($i)] = $reader.IsDBNull($i) ? $null : $reader.GetValue($i)
        }
        $rows.Add([pscustomobject]$row)
    }
    $reader.Close()
    $command.Dispose()
    return , $rows.ToArray()
}

$connection = Open-Database -ReadOnly
try { $survey = Read-UnfinishedRuns $connection $null } finally { $connection.Close() }
$serviceStatus = (Get-Service -Name $serviceName).Status.ToString()

if (-not $settle) {
    Write-Result @{ status = 'SURVEY'; runs = $survey; serviceStatus = $serviceStatus }
    return
}

if (@($survey | Where-Object { $_.ChargingRunId -ceq $runId }).Count -ne 1) {
    Write-Result @{
        status  = 'REFUSED'
        runs    = $survey
        message = "$runId is not an unfinished charging run. Nothing was touched; the service was not stopped."
    }
    return
}

$serviceWasRunning = $serviceStatus -eq 'Running'
$committed = $false
$backup = $null
$at = $null
$outcome = $null
try {
    if ($serviceStatus -ne 'Stopped') { Stop-Service -Name $serviceName -Force }

    # The service being Stopped says nothing about anyone else: a watcher or a second copy of this script may
    # still hold the file, and a write under a live engine is the one thing this must never do.
    foreach ($suffix in '', '-wal', '-shm') {
        $path = "$database$suffix"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try { [IO.File]::Open($path, 'Open', 'ReadWrite', 'None').Dispose() }
        catch { throw "Something still holds $path open: $($_.Exception.Message)" }
    }

    $backup = Join-Path $backupRoot "db-backup-charging-run-$([DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($suffix in '', '-wal', '-shm') {
        $path = "$database$suffix"
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup -Force }
    }

    # The text form EF Core's SQLite provider stores DateTimeOffset in.
    $at = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss.FFFFFFFzzz', [cultureinfo]::InvariantCulture)
    $connection = Open-Database
    try {
        $transaction = $connection.BeginTransaction()
        try {
            if (@(Read-UnfinishedRuns $connection $transaction | Where-Object { $_.ChargingRunId -ceq $runId }).Count -ne 1) {
                throw "$runId was no longer an unfinished charging run once the service was down."
            }
            $command = $connection.CreateCommand()
            $command.Transaction = $transaction
            $command.CommandText = "UPDATE AutoChargingRuns SET Stage = 'Completed', BlockReasonCode = 'SETTLED_BY_OPERATOR', UpdatedAt = @at WHERE ChargingRunId = @id AND Stage <> 'Completed'"
            $null = $command.Parameters.AddWithValue('@at', $at)
            $null = $command.Parameters.AddWithValue('@id', $runId)
            $affected = $command.ExecuteNonQuery()
            $command.Dispose()
            if ($affected -ne 1) { throw "AutoChargingRuns affected $affected row(s), expected 1." }
            $transaction.Commit()
            $committed = $true
        }
        catch {
            if (-not $committed) { $transaction.Rollback() }
            throw
        }
    }
    finally { $connection.Close() }
}
catch {
    $outcome = @{ status = 'FAILED'; message = "$($_.Exception.Message) Nothing was written."; backup = $backup }
}
finally {
    # Unlike a settled journey there is no vehicle journal to clear first, so the service goes back as found.
    if ($serviceWasRunning) { Start-Service -Name $serviceName }
}

if ($outcome) {
    Write-Result $outcome
    return
}

$connection = Open-Database -ReadOnly
try {
    $command = $connection.CreateCommand()
    $command.CommandText = 'SELECT Stage, BlockReasonCode, ReleasedAtBatteryPercent, UpdatedAt FROM AutoChargingRuns WHERE ChargingRunId = @id'
    $null = $command.Parameters.AddWithValue('@id', $runId)
    $reader = $command.ExecuteReader()
    $null = $reader.Read()
    $row = [pscustomobject]@{
        stage                    = $reader.GetString(0)
        blockReasonCode          = $reader.IsDBNull(1) ? $null : $reader.GetString(1)
        releasedAtBatteryPercent = $reader.IsDBNull(2) ? $null : $reader.GetValue(2)
        updatedAt                = $reader.GetString(3)
    }
    $reader.Close()
    $command.Dispose()
    $stillUnfinished = Read-UnfinishedRuns $connection $null
}
finally { $connection.Close() }

Write-Result @{
    status          = ($row.stage -eq 'Completed') ? 'SETTLED' : 'FAILED'
    chargingRunId   = $runId
    settledAt       = $at
    row             = $row
    backup          = $backup
    serviceStatus   = (Get-Service -Name $serviceName).Status.ToString()
    stillUnfinished = $stillUnfinished
}
'@

function Invoke-Server([bool] $Settle) {
    $quote = { param([string] $Value) "'" + $Value.Replace("'", "''") + "'" }
    $header = @(
        "`$marker = $(& $quote $marker)"
        "`$database = $(& $quote $ServerDatabase)"
        "`$installRoot = $(& $quote $ServerInstallRoot)"
        "`$backupRoot = $(& $quote $ServerBackupRoot)"
        "`$serviceName = $(& $quote $ServiceName)"
        "`$runId = $(& $quote ($ChargingRunId ?? ''))"
        "`$settle = `$$Settle"
    ) -join "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$header`n$remoteBody"))
    $raw = & ssh -o BatchMode=yes -o "ConnectTimeout=$TimeoutSec" $ServerAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    $text = ($raw | Out-String)
    $line = @($text -split "`r?`n" | Where-Object { $_.StartsWith($marker) }) | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or -not $line) { throw "ssh $ServerAlias failed (exit $LASTEXITCODE): $($text.Trim())" }
    return $line.Substring($marker.Length) | ConvertFrom-Json
}

function Write-Runs($Runs) {
    if (@($Runs).Count -eq 0) {
        Write-Host '  No unfinished charging run.' -ForegroundColor Green
        return
    }
    foreach ($run in @($Runs)) {
        Write-Host ("  {0}  agv {1}  {2}{3}  triggered {4}% -> {5} ({6})  created {7}  updated {8}" -f `
                $run.ChargingRunId, $run.AgvId, $run.Stage, ($run.BlockReasonCode ? " / $($run.BlockReasonCode)" : ''),
                $run.TriggeredAtBatteryPercent, $run.ChargerStationRiotId, $run.ChargerStationId, $run.CreatedAt, $run.UpdatedAt)
        Write-Host ("      RIoT order {0}: intent {1}, orderId {2}" -f $run.UpperId, ($run.IntentStatus ?? '(no intent row)'), ($run.IntentOrderId ?? '-'))
    }
}

# Read-only: the service's directory and the database its configuration names, before the survey and long before
# the stop.
$serverConfigPath = Join-Path $ServerInstallRoot 'appsettings.Production.json'
$readbackScript = Get-ControlServerTargetReadbackScript -ServiceName $ServiceName -ConfigPath $serverConfigPath
$raw = & ssh -o BatchMode=yes -o "ConnectTimeout=$TimeoutSec" $ServerAlias "pwsh -NoProfile -EncodedCommand $([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($readbackScript)))" 2>&1
$readbackLine = @(($raw | Out-String) -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
if ($LASTEXITCODE -ne 0 -or -not $readbackLine) { throw "ssh $ServerAlias failed reading back the target (exit $LASTEXITCODE): $(($raw | Out-String).Trim())" }
$null = Assert-ControlServerTargetReadback -Readback ($readbackLine | ConvertFrom-Json) -ServiceName $ServiceName -ConfigPath $serverConfigPath `
    -InstallRoot $ServerInstallRoot -Database $ServerDatabase -RequireOwnDatabase
Write-Host "Instance: '$ServiceName', $ServerDatabase ($($target.IsMvp ? 'the production MVP service' : 'not the MVP service'))"

$survey = Invoke-Server $false
Write-Host ''
Write-Host "Unfinished charging runs on $ServerAlias (service $($survey.serviceStatus)):"
Write-Runs $survey.runs
Write-Host ''

if (-not $ChargingRunId) {
    if (@($survey.runs).Count) { Write-Host 'Pass -ChargingRunId <full id> to complete one.' -ForegroundColor Yellow }
    return
}
if (@($survey.runs | Where-Object { $_.ChargingRunId -ceq $ChargingRunId }).Count -ne 1) {
    throw "$ChargingRunId is not one of the unfinished runs above (the full id, matched exactly)."
}

if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
$action = "Stop '$ServiceName', back up the database, mark charging run $ChargingRunId Completed (SETTLED_BY_OPERATOR), start the service again if it was running"
if (-not $PSCmdlet.ShouldProcess("$ServerAlias ($ServerDatabase)", $action)) {
    Write-Host 'Not changed.' -ForegroundColor Yellow
    return
}

$result = Invoke-Server $true
Write-Host "  $($result.status)$($result.message ? ": $($result.message)" : '')" -ForegroundColor ($result.status -eq 'SETTLED' ? 'Green' : 'Red')
if ($result.backup) { Write-Host "  backup: $($result.backup)" }
if ($result.row) {
    Write-Host "  row now: $($result.row.stage) / $($result.row.blockReasonCode) / released $($result.row.releasedAtBatteryPercent ?? 'NULL') / updated $($result.row.updatedAt)"
    Write-Host "  service: $($result.serviceStatus)"
    Write-Host '  still unfinished:'
    Write-Runs $result.stillUnfinished
}
if ($result.status -ne 'SETTLED') { exit 1 }
