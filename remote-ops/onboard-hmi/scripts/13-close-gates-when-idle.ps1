#Requires -Version 7
<#
.SYNOPSIS
    Closes both journey gates the moment the in-flight WIRE_TO_GATE journey
    reaches Completed, so the runtime cannot take the next demand. Runs ON the
    control host. Test environments only.

.DESCRIPTION
    THE RACE THIS EXISTS TO CLOSE. Set-JourneyRuntime.ps1 -Off is the only way to
    shut intake, and until now the only trigger for it was a person deciding the
    trip was over. JourneyRuntimeWorker polls every 2 s, so every second between
    the journey reaching Completed and the gate actually shutting is a second in
    which the next demand is accepted and a RIoT order is created. On 2026-09-07
    that was not theoretical:

        13:52:14  unload Committed, journey Q26091238-16 Completed
        13:52:16  runtime accepted aa3d6724 and created a real RIoT order
        13:53:23  a person ran -Off, 67 seconds too late

    agv01 drove a second trip nobody asked for, and it took a
    12-reset-journey-state.ps1 to get the rig back.

    HOW IT IS CLOSED, AND WHY IT IS SPLIT IN TWO. The window is two seconds wide,
    which is less than one ssh round trip, so the detection cannot live here. It
    lives on the server: server-close-gates-watch.ps1 polls the ControlServer
    SQLite file every 250 ms and, the instant the journey is Completed, calls
    Stop-Service locally. That is the whole of the time-critical part, and
    stopping is what makes it work -- JourneyRuntimeWorker reads IOptions once at
    startup, so the boolean in appsettings.Production.json means nothing to a
    running process, and the host's stoppingToken cancels an iteration that is
    already under way.

    Once the engine is down nothing is racing, and this script does the unhurried
    half: Set-JourneyRuntime.ps1 -Off writes the two booleans -- with its backup
    and its field-by-field verification, still the only writer of that file --
    and brings the service back with the gates shut. Then this verifies that they
    really are shut, because a close that quietly did not happen is worse than no
    mechanism at all: it is the same open gate with somebody trusting it.

    WHY IT DOES NOT CLOSE EARLIER. The obvious cheaper answer -- shut the gate
    during the journey, since -Off "does not stop an in-flight journey" -- breaks
    the trip. That sentence is about the VEHICLE. Server-side, a disabled
    JourneyRuntimeWorker logs one warning and sleeps forever, and every remaining
    transition of the journey (the gate worklist, the unload command, settling
    the result) is made by that loop. Close it after the load and the vehicle
    reaches the gate with nothing to open. So the wait is real, and the trip
    between load and unload is never interrupted.

    A journey that ends Blocked is reported and nothing is stopped. Blocked is
    still unresolved, so the engine never reaches discovery and there is no next
    demand to race for, while recovery needs the loop a stop would remove.

.PARAMETER ServerDatabase
    The SQLite file the watcher reads. Pointing it at a copy is how the
    completion path is rehearsed without moving a vehicle: the stop, the config
    write and the verification are real, only the completion signal is not.

.PARAMETER DemandId
    Watch this journey rather than latching onto whichever one is unresolved.

.PARAMETER Force
    Suppress the confirmation prompt by lowering $ConfirmPreference, the same way
    12-reset-journey-state.ps1 does. Needed to run this unattended: ConfirmImpact
    is High, and ShouldProcess throws rather than prompting when there is no host
    UI to prompt on.

.EXAMPLE
    # Start this first, in its own terminal. It waits for the journey to appear.
    ./13-close-gates-when-idle.ps1 -Force

.EXAMPLE
    # ... then, elsewhere, the trip itself:
    #   Set-JourneyRuntime.ps1 -Dispatch      (per-occasion authorization + on-site GO)
    #   ./11-drive-journey.ps1                             load
    #   ./11-drive-journey.ps1 -SkipScan -CargoState EMPTY unload
    ./13-close-gates-when-idle.ps1 -DemandId Q26091238-16 -Force
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ServerAlias = 'factory01',
    [string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer\data\controlserver.db',
    [string] $ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer',
    [string] $ServerConfigPath = 'C:\Program Files\8005 AGV\ControlServer\appsettings.Production.json',
    [string] $ServerBackupRoot = 'D:\zhengyushao\control-server-ops',
    [string] $ServiceName = '8005 AGV ControlServer',
    [string] $BaseUrl = 'http://172.19.205.222:58007',
    [string] $DemandId,
    [ValidateRange(50, 5000)][int] $PollMilliseconds = 250,
    [ValidateRange(1, 86400)][int] $LatchTimeoutSeconds = 600,
    [ValidateRange(1, 86400)][int] $JourneyTimeoutSeconds = 3600,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
if ($Force) { $ConfirmPreference = 'None' }

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Remote {
    param([string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $ServerAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $ServerAlias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

# ssh folds its own stderr in, so the JSON is the last line that starts a object,
# not the whole output.
function ConvertFrom-RemoteJson {
    param([string[]] $Lines)
    $json = $Lines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
    if (-not $json) { throw "The remote script produced no JSON result:`n$($Lines -join "`n")" }
    return $json | ConvertFrom-Json
}

$sqlitePrelude = @"
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly')
`$c.Open()
function Read-Column { param(`$Sql) `$m = `$c.CreateCommand(); `$m.CommandText = `$Sql; `$v = @(); `$r = `$m.ExecuteReader(); while (`$r.Read()) { `$v += [string]`$r.GetValue(0) }; `$r.Close(); , `$v }
"@

function Get-ServerState {
    Invoke-Remote @"
$sqlitePrelude
`$state = [pscustomobject]@{
    accepted      = Read-Column 'SELECT DemandId FROM AcceptedDemands ORDER BY DemandId'
    intentDemands = Read-Column 'SELECT DISTINCT DemandId FROM OrderIntents ORDER BY DemandId'
    intentLegs    = Read-Column 'SELECT MovementLegId FROM OrderIntents'
    journeys = Read-Column "SELECT DemandId || ' ' || Stage || ' ' || COALESCE(BlockReasonCode, '-') FROM JourneyRuntimes ORDER BY CreatedAt"
    runtime  = [bool](Get-Content -LiteralPath '$ServerConfigPath' -Raw | ConvertFrom-Json).JourneyRuntime.enabled
    dispatch = [bool](Get-Content -LiteralPath '$ServerConfigPath' -Raw | ConvertFrom-Json).RiotCreateDispatch.enabled
    service  = (Get-Service -Name '$($ServiceName -replace "'", "''")').Status.ToString()
}
`$c.Close()
`$state | ConvertTo-Json -Depth 5 -Compress
"@ | ConvertFrom-Json
}

# ------------------------------------------------------------------ survey ---

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Watching $ServerAlias for the journey to finish" -ForegroundColor Green
$before = Get-ServerState
$beforeLevel = -not $before.runtime ? 'Off' : ($before.dispatch ? 'Dispatch' : 'Intake')
Write-Step "Gates are $beforeLevel (runtime=$($before.runtime), createDispatch=$($before.dispatch)); service is $($before.service)"
if (@($before.journeys).Count -eq 0) {
    Write-Step 'No journey on the server yet; the watcher will wait for one to appear.'
}
else {
    foreach ($j in @($before.journeys)) { Write-Step "Journey: $j" }
}
Write-Step "AcceptedDemands=$(@($before.accepted).Count) OrderIntent legs=$(@($before.intentLegs).Count)"
if (-not $before.runtime) {
    Write-Host '  NOTE: the runtime gate is already closed, so nothing can be accepted right now.' -ForegroundColor Yellow
    Write-Host '  The watch still runs; it will prove the close path rather than guard a real race.' -ForegroundColor Yellow
}

$target = $DemandId ? "$ServerAlias (journey $DemandId)" : "$ServerAlias (whichever journey is in flight)"
if (-not $PSCmdlet.ShouldProcess($target, 'Wait for Completed, then stop the service and close both journey gates')) {
    return
}

# ------------------------------------------------------------------- watch ---

$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')
$watcherLocal = Join-Path $PSScriptRoot 'server-close-gates-watch.ps1'
if (-not (Test-Path -LiteralPath $watcherLocal)) { throw "Watcher not found: $watcherLocal" }
$gateScript = Join-Path $PSScriptRoot '..\..\factory-server\scripts\control-server\Set-JourneyRuntime.ps1'
if (-not (Test-Path -LiteralPath $gateScript)) { throw "Set-JourneyRuntime.ps1 not found: $gateScript" }

$null = Invoke-Remote "New-Item -ItemType Directory -Path '$ServerBackupRoot' -Force | Out-Null"
$remoteScript = "$ServerBackupRoot\close-gates-watch-$stamp.ps1"
& scp -o BatchMode=yes $watcherLocal "${ServerAlias}:$remoteScript" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not copy the watcher to $ServerAlias" }
Write-Step "Watcher deployed to $remoteScript"

$remoteArgs = "-Database '$ServerDatabase' -InstallRoot '$ServerInstallRoot' -ServiceName '$ServiceName'" +
    " -PollMilliseconds $PollMilliseconds -LatchTimeoutSeconds $LatchTimeoutSeconds -JourneyTimeoutSeconds $JourneyTimeoutSeconds" +
    ($DemandId ? " -DemandId '$DemandId'" : '')

# ServerAliveInterval because this session is idle for as long as the journey
# takes, and a dropped one would look exactly like a journey that never ended.
$lines = [System.Collections.Generic.List[string]]::new()
& ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6 $ServerAlias `
    "pwsh -NoProfile -ExecutionPolicy Bypass -File '$remoteScript' $remoteArgs" 2>&1 |
    ForEach-Object {
        $line = [string]$_
        $lines.Add($line)
        if (-not $line.TrimStart().StartsWith('{')) { Write-Host "  $line" -ForegroundColor DarkGray }
    }
$watchExit = $LASTEXITCODE
$null = Invoke-Remote "Remove-Item -LiteralPath '$remoteScript' -Force -ErrorAction SilentlyContinue"
if ($watchExit -ne 0) { throw "The watcher failed on ${ServerAlias}:`n$($lines -join "`n")" }

$result = ConvertFrom-RemoteJson $lines

switch ($result.status) {
    'COMPLETED' { }
    'STOP_FAILED' {
        throw "Journey $($result.demandId) completed but the service could not be stopped: $($result.stopError). THE GATES ARE STILL OPEN -- close them yourself with Set-JourneyRuntime.ps1 -Off."
    }
    default {
        throw "$($result.status): $($result.message) THE GATES WERE NOT CHANGED."
    }
}

# ConvertFrom-Json turns an ISO-8601 string back into a DateTime, which then
# renders in local format and reads as if the server had recorded it in local
# time. Say which clock it is rather than letting the default decide.
$completedAt = $result.completedRecordedAtUtc -is [datetime] `
    ? ([datetime]$result.completedRecordedAtUtc).ToUniversalTime().ToString('o') `
    : [string]$result.completedRecordedAtUtc
Write-Step "Journey $($result.demandId) reached Completed at $completedAt (server record, UTC)"
Write-Step "Service stop requested $($result.reactionMs) ms after that record, stopped in $($result.stopDurationMs) ms; service is $($result.serviceStatus)"

# ------------------------------------------------------------------- close ---

# Nothing is racing any more -- the engine is down -- so the config change goes
# through the one script that owns that file.
Write-Step 'Closing both gates via Set-JourneyRuntime.ps1 -Off'
& $gateScript -Off -Force -ServerAlias $ServerAlias -ServiceName $ServiceName -ConfigPath $ServerConfigPath -BaseUrl $BaseUrl

# Set-JourneyRuntime.ps1 returns early when the booleans already say Off, and its
# early return does not start a service. Ours is stopped by then, so bringing it
# back is this script's job whenever that path was taken.
$after = Get-ServerState
if ($after.service -ne 'Running') {
    Write-Step "Service is $($after.service); starting it"
    $null = Invoke-Remote "Start-Service -Name '$($ServiceName -replace "'", "''")'"
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        Start-Sleep -Seconds 3
        $live = try { (Invoke-WebRequest -Uri "$BaseUrl/health/live" -TimeoutSec 5 -SkipHttpErrorCheck -NoProxy).StatusCode } catch { $null }
    } while ($live -ne 200 -and [DateTime]::UtcNow -lt $deadline)
    if ($live -ne 200) { throw "Service did not answer /health/live within 60 s after being started. Gates: runtime=$($after.runtime), createDispatch=$($after.dispatch)." }
    $after = Get-ServerState
}

# ------------------------------------------------------------------ verify ---

# A close that silently did not happen is the failure this whole script is
# supposed to remove, so it is asserted rather than reported.
$problems = @()
if ($after.runtime) { $problems += 'JourneyRuntime.enabled is still true' }
if ($after.dispatch) { $problems += 'RiotCreateDispatch.enabled is still true' }
if ($after.service -ne 'Running') { $problems += "the service is $($after.service), not Running" }
if ($problems.Count) {
    throw "THE GATES ARE NOT CLOSED: $($problems -join '; '). Fix this before leaving the rig."
}
Write-Step 'Verified on the server: runtime=False, createDispatch=False, service Running'

# Demand-level, not leg-level. The journey being watched grows its own second
# movement leg on the way -- TO_PICKUP at intake, TO_GATE after the load -- so a
# rising leg count is this trip working, not the runtime taking another one. The
# first real run on 2026-09-08 latched at one leg and finished at two, and a
# leg-id comparison called that a lost race when nothing had been taken. What
# must not appear is another accepted demand, or a movement leg for one.
$acceptedAtLatch = @($result.acceptedDemandIdsAtLatch)
$acceptedNow = @($after.accepted)
$intentDemandsAtLatch = @($result.orderIntentDemandIdsAtLatch)
$intentDemandsNow = @($after.intentDemands)
$newDemands = @($acceptedNow | Where-Object { $_ -notin $acceptedAtLatch })
$newIntentDemands = @($intentDemandsNow | Where-Object { $_ -notin $intentDemandsAtLatch })

Write-Host ''
Write-Host "AcceptedDemands $($acceptedAtLatch.Count) -> $($acceptedNow.Count); demands with a movement leg $($intentDemandsAtLatch.Count) -> $($intentDemandsNow.Count); legs $($result.orderIntentLegsAtLatch) -> $(@($after.intentLegs).Count) (this journey's own second leg is expected)" -ForegroundColor Green
if ($newDemands.Count -or $newIntentDemands.Count) {
    throw "The gate shut, but not before the runtime took another demand: accepted [$($newDemands -join ', ')]; dispatched [$($newIntentDemands -join ', ')]. The vehicle may be moving. Check it, then 12-reset-journey-state.ps1."
}
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Both gates closed after journey $($result.demandId); nothing new was accepted." -ForegroundColor Green
