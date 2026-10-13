#Requires -Version 7
<#
.SYNOPSIS
    Settles every in-flight WIRE_TO_GATE journey on the server and clears the
    vehicle's onboard journal -- both ends or neither -- so the next journey
    starts clean. Runs ON the control host.

.DESCRIPTION
    This exists because clearing one end is worse than clearing neither, and
    that is not a theory -- it happened on 2026-09-04.

    The server's journey rows were deleted so a stuck demand would stop blocking
    the vehicle. The server then started the next demand at
    `VehicleBusinessRevision = 1`. But the vehicle's journal lives in
    `%LOCALAPPDATA%` -- outside the install root, so neither the deletion nor a
    redeployment touches it -- and it still held revision 1 of the *previous*
    demand, with different content. The client did exactly what the contract
    says: `SNAPSHOT_REVISION_CONTENT_CONFLICT`, tear the session down. It then
    reconnected and hit the same message again, every seven seconds, until
    somebody noticed. The vehicle was right; the reset was half done.

    So this script resets the pair, or neither:

        server (factory01)  every journey whose Stage is not Completed is SETTLED
                            the way the product settles a journey that never
                            loaded: its demands cancelled and permanently
                            suppressed, its lease released, its pending outbox
                            acknowledged, and the journey row marked Completed and
                            KEPT. server-settle-journey.ps1 does the work and
                            documents the write set.
        vehicle (agv01)     the whole onboard journal file, which the client
                            recreates empty on its next start
                            (SqliteWireToGateJournal uses CREATE TABLE IF NOT EXISTS)

    WHY SETTLE, NOT DELETE. Until 2026-09-10 this script deleted rows, and by
    then it was both broken and wrong. Broken, because protocol 0.2.0 gave the
    journey its own identity (migration MultiDemandJourneyStopSequence,
    2026-09-08): JourneyRuntimes has no DemandId column any more, and the survey
    threw before anything was deleted. Wrong, because a delete that matched
    tables by a DemandId column could never reach JourneyRuntimes, JourneyStops
    or VehicleDispatchLeases -- and an unreleased lease blocks every future
    intake -- and because deleting a JourneyRuntimes row takes the vehicle's
    revision history with it: a new journey seeds its snapshot revisions from the
    MAX over that vehicle's rows. That is the 2026-09-04 failure again. A settled
    row keeps the history, so a settled server and an emptied journal agree: the
    new journal accepts whatever revision comes next. The settlement was first
    done by hand on production on 2026-09-10 (8005-agv-program#19); this is that
    procedure made repeatable.

    WHAT IT REFUSES. A journey still carrying a demand with a commanded slot
    operation -- any StationOperations row. A door may be open or cargo on board,
    and only the peer can settle that, through recovery. The refusal comes from
    the survey, before either end is touched, and -WhatIf reports it too.

    THE ORDER, AND WHY THE SERVER GOES FIRST. The server's half is the one that
    can be undone: one transaction, rolled back on any surprise, service put back
    as it was found. So it runs first, and the journal is removed only after a
    committed settlement. (The old order was journal first; on 2026-09-07 the
    server half then failed, and the journal was already gone.) The service is
    left stopped until the journal is gone, so a settled server never runs
    against a vehicle still holding the abandoned journey. If the journal step
    fails, the script stops there, says so, and leaves the service stopped on
    purpose.

    WHAT IT DOES NOT DO. Cancel RIoT orders -- the server has no way to; the
    survey lists the journey's legs so they can be checked by hand. Reset
    SessionRecoveries -- the vehicle's next handshake recomputes readiness. Touch
    JourneyStops -- the product leaves them as they are, too.

    THIS IS NOT A PRODUCT FEATURE. A stuck journey the product can still reach --
    operator cancellation, station timeout, recovery -- goes through the product.
    This is for a journey none of those can reach, typically one behind a session
    that never became Ready.

    The vehicle's client is stopped for the duration -- the journal is open
    while it runs -- and restarted at the end.

.PARAMETER ServiceName
    -ServerDatabase, -ServerInstallRoot and -ServiceName say which ControlServer
    instance is settled -- its service stopped, its database written -- and their
    defaults are the production MVP service. Give all three or none
    (workspace#38): a partial set is refused with TARGET_PARTIAL, and a set where
    some name the MVP and others do not with TARGET_MIXED_MVP. -SshAlias must be a
    vehicle of that instance: its site file's controlServerLine "mvp" with the MVP,
    "v2" with any other (TARGET_VEHICLE_INSTANCE_MISMATCH; agv01 "mvp" and
    agv02/agv03 "v2" until the cutover, control-server#564). All of that before anything reaches either
    machine. Then the server is asked which directory the service runs from and
    what <install root>\appsettings.Production.json names as its database; unless
    the service runs from -ServerInstallRoot and that database is -ServerDatabase,
    nothing is copied, stopped or written (TARGET_* codes in
    factory-server/scripts/control-server/ControlServerTarget.psm1). A rehearsal
    copy of the database is refused here (TARGET_DATABASE_NOT_OWN): the
    settlement stops the service before it writes. -ServerBackupRoot is not one of
    the three.

    Before workspace#38, -ServerDatabase and -ServerInstallRoot of a v2 instance
    alone stopped the MVP service and then settled whichever database was free.

    The read-back is read-only. Run against the MVP it reads the MVP's service
    registration and appsettings on factory01, as part of the MVP run that
    needs the user's word anyway; run against a v2 instance it reads that
    service and that configuration, never the MVP's.

.PARAMETER SiteConfigPath
    The vehicle's site file; its vehicleSafety.expectedVehicleKey is the key of
    the one vehicle this run may settle for. The survey covers every in-flight
    journey of the INSTANCE, but only -SshAlias's journal is cleared, and a v2
    instance serves more than one car. So every in-flight journey must carry
    this key: one of another vehicle -- or no readable key while anything is in
    flight -- is a refusal, reported with the survey's own, before either end is
    touched (workspace#38 review M1). Settling it would cancel and permanently
    suppress that car's demands, release its lease and stop watching it while
    its RIoT order still runs, and leave its journal behind.

.PARAMETER ReasonCode
    Recorded on each suppression and on the journey. One of the codes
    WireToGateStore.SuppressingReasonCodes accepts, matched exactly. There is no
    default: the suppression is permanent -- no entry point lifts it, and it also
    catches the fresh DemandId MesIngest allocates if the same lot leaves the
    catalog and returns -- so the reason is the lasting explanation of why a lot
    is never moved again. A person abandoning the lots is CANCELLED_BY_OPERATOR,
    which is what 2026-09-10 recorded. Not needed for -WhatIf, or when nothing is
    in flight.

.PARAMETER KeepStackDown
    Leave the onboard client and simulator stopped at the end. Useful when the
    next thing you do is a deployment.

.PARAMETER NoSimulator
    Passed through to 10-start-onboard-stack.ps1 when the stack is restarted, for
    a vehicle whose IO points at the real Modbus module. Without it the restart
    starts the simulator too, which on such a vehicle is a process holding 1502
    and 58006 that nothing talks to. The restart is the only reason this matters
    here: clearing the two stores has nothing to do with which IO plane is in use.

.PARAMETER Force
    Suppress the confirmation prompt by lowering $ConfirmPreference, the same way
    Set-JourneyRuntime.ps1 does. Needed to run this unattended: ConfirmImpact is
    High, and ShouldProcess throws rather than prompting when there is no host UI
    to prompt on.

.PARAMETER WhatIf
    Report what would be settled on both ends, and what would be refused, then
    stop. The survey script is copied to the server's ops directory and removed
    again; neither store is changed.

.EXAMPLE
    ./12-reset-journey-state.ps1 -WhatIf

.EXAMPLE
    ./12-reset-journey-state.ps1 -ReasonCode CANCELLED_BY_OPERATOR

.EXAMPLE
    # A v2 instance and its spare car: all three instance parameters, or it is refused before either machine is touched.
    ./12-reset-journey-state.ps1 -WhatIf -SshAlias agv02 -ServiceName '8005 AGV ControlServer V2' `
        -ServerInstallRoot 'C:\Program Files\8005 AGV\ControlServer.V2' `
        -ServerDatabase 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db'
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $SshAlias = 'agv01',
    [string] $ServerAlias = 'factory01',
    [string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer\data\controlserver.db',
    [string] $ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer',
    [string] $ServerBackupRoot = 'D:\zhengyushao\control-server-ops',
    [string] $ServiceName = '8005 AGV ControlServer',
    [string] $VehicleJournal = 'C:\Users\HT\AppData\Local\SQCD\8005AGV\onboard-journal.db',
    [string] $VehicleBackupRoot = 'C:\8005\journal-backup',
    [string] $SiteConfigPath = (Join-Path $PSScriptRoot "..\config\site-$SshAlias.json"),
    # WireToGateStore.SuppressingReasonCodes; server-settle-journey.ps1 checks it again.
    [ValidateSet('CANCELLED_BY_OPERATOR', 'CANCELLED_BY_LOAD_COMPENSATION', 'CANCELLED_BY_STOP_COMPLETE',
        'CANCELLED_BY_STATION_TIMEOUT', 'TERMINATED_BY_FAULT_CARGO_HANDOFF', IgnoreCase = $false)]
    [string] $ReasonCode,
    [switch] $KeepStackDown,
    [switch] $NoSimulator,
    [switch] $Force,
    [int] $ReadyTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
if ($Force) { $ConfirmPreference = 'None' }

# workspace#38: which instance and which vehicle, decided before anything reaches either machine.
Import-Module (Join-Path $PSScriptRoot '..\..\factory-server\scripts\control-server\ControlServerTarget.psm1') -Force
$target = Assert-ControlServerTargetParameters -Bound @($PSBoundParameters.Keys) `
    -Values ([ordered]@{ ServerDatabase = $ServerDatabase; ServerInstallRoot = $ServerInstallRoot; ServiceName = $ServiceName }) `
    -Kinds ([ordered]@{ ServerDatabase = 'Database'; ServerInstallRoot = 'InstallRoot'; ServiceName = 'ServiceName' })
$null = Assert-ControlServerVehicleTarget -SshAlias $SshAlias -IsMvp $target.IsMvp

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Remote {
    param([string] $Alias, [string] $Script)

    # Same contract as Invoke-Onboard in 10-start-onboard-stack.ps1, for the same
    # reason: without a trailing `exit`, the remote pwsh reports `$?` from
    # whatever statement ran last, and `-ErrorAction SilentlyContinue` leaves that
    # False while printing nothing. A block that wants a non-terminating error to
    # count as failure sets `$ErrorActionPreference = 'Stop'` itself; a
    # terminating error never reaches `exit 0`.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$Script`nexit 0"))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $Alias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    $exit = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()
    if ($exit -ne 0) { throw "ssh $Alias failed (exit $exit): $(if ($text) { $text } else { '(no output)' })" }
    $text
}

$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')

# The settlement runs from a file copied to the server, never from an encoded
# command line or stdin. An interpolated remote script grew with its input, and
# on 2026-09-07 the encoded command came back "not properly encoded" halfway
# through a reset; stdin silently skips multi-line blocks. The file is fixed
# size, takes plain arguments, and does its own discovery.
$settleLocal = Join-Path $PSScriptRoot 'server-settle-journey.ps1'
if (-not (Test-Path -LiteralPath $settleLocal)) { throw "Settlement script not found: $settleLocal" }
$settleRemote = "$ServerBackupRoot\server-settle-journey-$stamp.ps1"
$settleArgs = "-Database '$ServerDatabase' -InstallRoot '$ServerInstallRoot'"

function Invoke-Settlement {
    param([string] $Arguments)

    $lines = @(& ssh -o BatchMode=yes -o ConnectTimeout=15 $ServerAlias `
            "pwsh -NoProfile -ExecutionPolicy Bypass -File '$settleRemote' $settleArgs $Arguments" 2>&1 |
            ForEach-Object { [string]$_ })
    $exit = $LASTEXITCODE
    # ssh folds its own stderr in, so the result is the last line that starts an
    # object, not the whole output.
    $json = $lines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
    if ($exit -ne 0 -or -not $json) {
        throw "server-settle-journey.ps1 failed on $ServerAlias (exit $exit):`n$($lines -join "`n")"
    }
    return $json | ConvertFrom-Json
}

# ---------------------------------------------------------------- survey ---

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Settling journey state on $ServerAlias + $SshAlias" -ForegroundColor Green

# Read-only: the service's directory and the database its configuration names. Nothing is copied, stopped or
# written on either end unless they are -ServerInstallRoot and -ServerDatabase.
$serverConfigPath = Join-Path $ServerInstallRoot 'appsettings.Production.json'
$readbackText = Invoke-Remote $ServerAlias (Get-ControlServerTargetReadbackScript -ServiceName $ServiceName -ConfigPath $serverConfigPath)
$readback = @($readbackText -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') })[-1] | ConvertFrom-Json
$null = Assert-ControlServerTargetReadback -Readback $readback -ServiceName $ServiceName -ConfigPath $serverConfigPath `
    -InstallRoot $ServerInstallRoot -Database $ServerDatabase -RequireOwnDatabase
Write-Step "Server instance: '$ServiceName', $ServerDatabase ($($target.IsMvp ? 'the production MVP service' : 'not the MVP service'))"

$null = Invoke-Remote $ServerAlias "New-Item -ItemType Directory -Path '$ServerBackupRoot' -Force | Out-Null"
& scp -o BatchMode=yes $settleLocal "${ServerAlias}:$settleRemote" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not copy the settlement script to $ServerAlias" }

try {
    # Which journeys are in flight, and what would be written? Discovered rather
    # than passed in: the point of the script is that both ends agree afterwards,
    # and an id typed by hand is one more thing that can be wrong.
    $survey = Invoke-Settlement ''
    $journeys = @($survey.journeys)

    if (-not $journeys.Count) { Write-Step 'Server: no journey in flight.' }
    foreach ($journey in $journeys) {
        $blocked = $journey.blockReasonCode ? " / $($journey.blockReasonCode)" : ''
        Write-Step "Journey $($journey.journeyId): $($journey.stage)$blocked on $($journey.agvId), updated $($journey.updatedAt)"
        Write-Step "  revisions $($journey.revisions) (kept; the next journey continues from here)"
        foreach ($demand in @($journey.demands)) {
            $facts = @("stop $($demand.stopSequence)", $demand.state, "accepted $($demand.acceptedStatus ?? '(no row)')")
            if ($demand.suppressed) { $facts += 'already suppressed' }
            if ($demand.stationOperations) { $facts += "$($demand.stationOperations) station operation(s)" }
            if ($demand.recoveryWorkflows) { $facts += "$($demand.recoveryWorkflows) recovery workflow(s)" }
            Write-Step "  demand $($demand.demandId): $($facts -join ', ')"
        }
        $lease = $journey.lease ? ($journey.lease.releasedAt ? "released $($journey.lease.releasedAt)" : "HELD since $($journey.lease.acquiredAt)") : '(no row)'
        Write-Step "  lease: $lease"
        # A script block, not `ForEach-Object messageType`: the member-name form
        # honours ShouldProcess, so under -WhatIf it announces itself instead of
        # returning anything.
        Write-Step "  pending outbox of this journey: $(@($journey.outbox).Count) [$((@($journey.outbox) | ForEach-Object { $_.messageType }) -join ', ')]"
        foreach ($leg in @($journey.riotLegs)) {
            Write-Step "  RIoT leg $($leg.purpose) $($leg.movementLegId): $($leg.status) order $($leg.orderId ?? '-') (not cancelled by this script)"
        }
        if (@($journey.refusals).Count) {
            Write-Step '  would refuse this journey (below); nothing would be written'
        }
        else {
            Write-Step ("  would write: AcceptedDemands {0}, TransportDemandSuppressions {1}, JourneyDemands {2}, VehicleDispatchLeases {3}, ProtocolOutbox {4}, JourneyRuntimes 1" -f
                @($journey.cancelDemandIds).Count, @($journey.suppressDemandIds).Count, @($journey.settleDemandIds).Count,
                ($journey.releaseLease ? 1 : 0), @($journey.outbox).Count)
        }
    }
    foreach ($message in @($survey.unattributedOutbox)) {
        Write-Step "Pending outbox row not attributable to a journey, left alone: $($message.messageType) $($message.messageId)"
    }

    $journalInfo = Invoke-Remote $SshAlias @"
if (Test-Path -LiteralPath '$VehicleJournal') {
    `$f = Get-Item -LiteralPath '$VehicleJournal'
    "`$(`$f.Length) bytes, last written `$(`$f.LastWriteTime.ToString('o'))"
} else { '(absent)' }
"@
    Write-Step "Vehicle journal: $journalInfo"

    $refusals = @($survey.refusals)
    if ($journeys.Count) {
        # workspace#38 review M1: the survey is per instance, the journal is per vehicle.
        $expectedKey = $null
        if (Test-Path -LiteralPath $SiteConfigPath -PathType Leaf) {
            $expectedKey = (Get-Content -Raw -LiteralPath $SiteConfigPath | ConvertFrom-Json).vehicleSafety.expectedVehicleKey
        }
        if (-not $expectedKey) {
            $refusals += "no vehicleSafety.expectedVehicleKey for $SshAlias in $SiteConfigPath, so the journeys in flight cannot be shown to be its own"
        }
        else {
            foreach ($journey in $journeys) {
                if ([string]$journey.vehicleKey -cne $expectedKey) {
                    $refusals += "journey $($journey.journeyId) belongs to vehicle $($journey.vehicleKey) ($($journey.agvId)), not to $SshAlias ($expectedKey); only $SshAlias's journal would be cleared"
                }
            }
        }
    }
    foreach ($refusal in $refusals) { Write-Host "  REFUSED: $refusal" -ForegroundColor Red }

    if ($WhatIfPreference) {
        Write-Host "  WhatIf: nothing was changed on either end$($refusals.Count ? '; a real run would refuse' : '')." -ForegroundColor Yellow
        return
    }
    if ($refusals.Count) {
        throw "Refused before touching either end: $($refusals -join '; ')."
    }
    if (-not $journeys.Count -and $journalInfo -eq '(absent)') {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Nothing to do on either end." -ForegroundColor Green
        return
    }
    if ($journeys.Count -and -not $ReasonCode) {
        throw '-ReasonCode is required to settle: every demand still carried is suppressed PERMANENTLY under it. Run with -WhatIf to see which demands those are.'
    }

    # Both strings are built first: ShouldProcess throws a bare null-reference when
    # either argument is null, which says nothing about which one it was.
    $cancelled = @($journeys | ForEach-Object { @($_.cancelDemandIds) }).Count
    $processTarget = $journeys.Count `
        ? ('{0} ({1} journey(s) settled; {2} demand(s) cancelled and PERMANENTLY suppressed as {3}) and {4} (the onboard journal)' -f
            $ServerAlias, $journeys.Count, $cancelled, $ReasonCode, $SshAlias) `
        : ('{0} (the onboard journal; nothing is in flight on {1})' -f $SshAlias, $ServerAlias)
    $action = 'Settle journey state on both ends'
    if (-not $PSCmdlet.ShouldProcess($processTarget, $action)) {
        return
    }

    # ------------------------------------------------------ onboard stop ---

    # The client holds the journal open, and it must not be running while the
    # server settles either: it would reconnect mid-way and report facts about a
    # journey that is half closed.
    Write-Step 'Stopping the onboard stack'
    & (Join-Path $PSScriptRoot '10-start-onboard-stack.ps1') -SshAlias $SshAlias -Stop | Out-Null

    # ---------------------------------------------------------- server ---

    $settled = $null
    if ($journeys.Count) {
        $ids = @($journeys | ForEach-Object { $_.journeyId }) -join ','
        $settled = Invoke-Settlement ("-Settle -ServiceName '{0}' -BackupRoot '{1}' -ReasonCode {2} -Stamp {3} -ExpectJourneyIds '{4}'" -f
            ($ServiceName -replace "'", "''"), $ServerBackupRoot, $ReasonCode, $stamp, $ids)
        switch ($settled.status) {
            'SETTLED' {
                foreach ($table in $settled.writes.PSObject.Properties) { Write-Step ("{0,-28} {1}" -f $table.Name, $table.Value) }
                Write-Step "Server settled as $ReasonCode; backup at $($settled.backup); service is $($settled.serviceStatus)"
            }
            'REFUSED' {
                throw "$ServerAlias refused the settlement: $($settled.message) $(@($settled.refusals) -join '; ') Nothing changed on either end; the onboard stack is stopped."
            }
            default {
                throw "Settlement on $ServerAlias ended $($settled.status): $($settled.message) The onboard journal was NOT touched and the onboard stack is stopped. Check '$ServiceName' on $ServerAlias before anything else."
            }
        }
    }
    else {
        Write-Step 'Server: nothing to settle'
    }

    # --------------------------------------------------------- vehicle ---

    try {
        $vehicleResult = Invoke-Remote $SshAlias @"
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath '$VehicleJournal')) { '(no journal to reset)'; return }
`$dest = '$VehicleBackupRoot-$stamp'
New-Item -ItemType Directory -Path `$dest -Force | Out-Null
Get-ChildItem (Split-Path -Parent '$VehicleJournal') -Filter 'onboard-journal.db*' |
    ForEach-Object { Copy-Item `$_.FullName -Destination `$dest -Force }
Get-ChildItem (Split-Path -Parent '$VehicleJournal') -Filter 'onboard-journal.db*' |
    ForEach-Object { Remove-Item `$_.FullName -Force }
"backed up to `$dest and removed; the client recreates it empty on next start"
"@
    }
    catch {
        if ($settled) {
            throw "HALF DONE. $ServerAlias is settled (backup $($settled.backup)) and '$ServiceName' is left STOPPED on purpose, but the journal on $SshAlias was not cleared: $($_.Exception.Message) Clear $VehicleJournal by hand, then start the service."
        }
        throw
    }
    Write-Step "Journal: $vehicleResult"

    if ($settled -and $settled.serviceWasRunning) {
        # -ErrorAction Stop, not by default: the settlement leaves the service
        # deliberately stopped, so "started again" must not be printed over a
        # non-terminating failure that Invoke-Remote now lets through.
        $null = Invoke-Remote $ServerAlias "Start-Service -Name '$($ServiceName -replace "'", "''")' -ErrorAction Stop"
        Write-Step "Service '$ServiceName' started again"
    }
}
finally {
    & ssh -o BatchMode=yes -o ConnectTimeout=15 $ServerAlias "Remove-Item -LiteralPath '$settleRemote' -Force -ErrorAction SilentlyContinue" 2>&1 | Out-Null
}

# ------------------------------------------------------------- restart ---

if ($KeepStackDown) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Both ends cleared. Onboard stack left down (-KeepStackDown)." -ForegroundColor Green
    return
}

Write-Step "Restarting the onboard stack$(if ($NoSimulator) { ' (client only; IO is on the real module)' })"
& (Join-Path $PSScriptRoot '10-start-onboard-stack.ps1') -SshAlias $SshAlias -NoSimulator:$NoSimulator | Out-Null

# A clean pair should reach Ready on its own. If it does not, say so here rather
# than letting the next run discover it.
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
$readiness = $null
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $readiness = Invoke-Remote $ServerAlias @"
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly')
`$c.Open()
`$m = `$c.CreateCommand(); `$m.CommandText = 'SELECT Readiness || '' / '' || ReasonCode FROM SessionRecoveries'
`$v = `$m.ExecuteScalar()
`$c.Close()
if (`$v) { `$v } else { '(no session yet)' }
"@
    if ($readiness -like 'Ready*') { break }
    Start-Sleep -Seconds 3
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Session: $readiness" -ForegroundColor Green
if ($readiness -notlike 'Ready*') {
    Write-Host "  Not Ready within ${ReadyTimeoutSeconds}s. Check the onboard log before running anything else." -ForegroundColor Yellow
}
