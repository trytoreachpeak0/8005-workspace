#Requires -Version 7
<#
.SYNOPSIS
    Snapshots what the two WIRE_TO_GATE ends are actually doing right now, prints
    the verdict, and appends one JSON line to a local status journal.

.DESCRIPTION
    Runs ON the control host. Reads only -- it starts nothing, stops nothing and
    writes nothing to either target machine.

    The name is deliberate: this is a journal in the same sense as
    MesIngest.Watch's WatchConnectionEventJournal -- one append-only JSON Lines
    file per day, each line a complete observation. It is NOT the onboard
    recovery journal of ADR 0006 (that one lives on the vehicle, is written by
    the product, and carries the causal state the product needs to recover).
    This file carries nothing the product depends on: deleting it loses history
    and breaks nothing.

    Five signal sources, all of which already existed:

      1. ControlServer HTTP on 58007 -- /health/live, /health/ready, /version,
         /api/runtime/sessions. /health/ready answers 503 with a useful body, so
         the request must NOT fail on a non-2xx status (-SkipHttpErrorCheck).
      2. ssh factory01 -- Windows service state and host clock.
      3. ssh agv01     -- whether SQCD.Agv.Wpf is running, plus host clock and
         the onboard recovery journal file.
      4. The site file -- the real agvId, which is what /api/runtime/sessions
         keys on. Never hardcode it; the value is per vehicle.
      5. /api/onboard/v1/vehicle-safety, read with the onboard credential from
         the DPAPI store -- the four-part safety predicate RELEASE-CANDIDATE.md
         section 8 requires before the client is started. -SkipVehicleSafety
         turns it off; a missing secret store degrades it to UNKNOWN.

    Clock skew is a first-class gate, not a nicety. The onboard vehicle-safety
    gate compares the server's observedAt against the vehicle's own clock inside
    a 5-second window, so a machine whose clock has drifted can never leave
    RecoveryRequired -- and it presents as a handshake bug. agv01 was found 158
    days fast on 2026-09-03.

    What is gated is the skew BETWEEN the two machines, not either one against
    this control host. The control host takes no part in that comparison, and
    measured 3.2 s behind both plant machines on 2026-09-03 without that meaning
    anything for the product.

    Each machine's skew against the control host is still measured and recorded,
    but only as a difference: each carries the same systematic error, because the
    remote timestamp is taken after ssh authentication and a pwsh cold start
    rather than at the midpoint of the round trip, which inflates it by one to
    three seconds. Subtracting one from the other cancels most of that. Read the
    per-machine numbers as an upper bound, never as a measurement.

.PARAMETER SiteAlias
    Vehicle to check. Matches both remote-ops/onboard-hmi/config/site-<alias>.json
    and the ssh host alias.

.PARAMETER BaseUrl
    ControlServer's HTTP binding. The service binds a specific NIC address rather
    than 0.0.0.0, so this is neither localhost nor a wildcard.

.PARAMETER Watch
    Poll forever. Prints the full table on the first pass and again whenever any
    gate changes verdict; otherwise one summary line. Every pass is journalled
    either way -- the point of the journal is the transitions.

.PARAMETER JournalDirectory
    Where the JSON Lines files go. Outside the repository by default: they record
    live plant state and machine identities, the same reasoning that keeps
    probe-*.txt out of git.

.EXAMPLE
    ./Get-WireToGateStatus.ps1

.EXAMPLE
    ./Get-WireToGateStatus.ps1 -Watch -IntervalSeconds 30
#>
[CmdletBinding()]
param(
    [string] $SiteAlias = 'agv01',
    [string] $BaseUrl = 'http://172.19.205.222:58007',
    [string] $ServerAlias = 'factory01',
    [string] $ServiceName = '8005 AGV ControlServer',
    [switch] $Watch,
    [ValidateRange(5, 3600)]
    [int] $IntervalSeconds = 60,
    [ValidateRange(1, 120)]
    [int] $TimeoutSec = 10,
    [ValidateRange(100, 60000)]
    [int] $ClockWindowMs = 5000,
    [ValidateRange(100, 60000)]
    [int] $EvidenceMaxAgeMs = 5000,
    [switch] $SkipVehicleSafety,
    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\control-server-deployment.xml'),
    [string] $JournalDirectory = (Join-Path $env:LOCALAPPDATA 'AgvOpsStatus'),
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

$siteFile = Join-Path $PSScriptRoot "../onboard-hmi/config/site-$SiteAlias.json"
if (-not (Test-Path -LiteralPath $siteFile)) {
    throw "No site file for '$SiteAlias' at $siteFile. The agvId is per vehicle and is never guessed."
}
$site = Get-Content -LiteralPath $siteFile -Raw | ConvertFrom-Json
$agvId = $site.agvId
if ([string]::IsNullOrWhiteSpace($agvId)) {
    throw "Site file $siteFile has no agvId."
}

# Runs on the factory server. One round trip per machine: ssh setup costs more
# than everything it collects.
#
# Note the absence of ?. below. In PowerShell `?` is a legal variable-name
# character, so `$proc?.Id` parses as the variable `${proc?}` and yields null
# rather than short-circuiting. `${proc}?.Id` works but only guards one hop,
# and every field here is a two- or three-hop chain. Explicit if is correct
# and readable; ?. is neither.
$serverProbe = @"
`$svc = Get-Service -Name '$($ServiceName -replace "'", "''")' -ErrorAction SilentlyContinue
`$proc = Get-Process -Name 'ControlServer.Host' -ErrorAction SilentlyContinue | Select-Object -First 1
[pscustomobject]@{
    utcNowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    serviceState = if (`$svc) { `$svc.Status.ToString() } else { `$null }
    startType    = if (`$svc) { `$svc.StartType.ToString() } else { `$null }
    processId    = if (`$proc) { `$proc.Id } else { `$null }
    processStart = if (`$proc) { `$proc.StartTime.ToUniversalTime().ToString('o') } else { `$null }
} | ConvertTo-Json -Compress
"@

# Runs on the vehicle. The WPF client is started by a person at the vehicle under
# whichever account is logged in at the console, which is not necessarily the ssh
# account -- so scan every profile rather than trusting this session's LOCALAPPDATA.
$onboardProbe = @'
$proc = Get-Process -Name 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue | Select-Object -First 1
$exe = Get-Item 'C:\8005\OnboardHmi\SQCD.Agv.Wpf.exe' -ErrorAction SilentlyContinue
$journal = Get-ChildItem 'C:\Users\*\AppData\Local\SQCD\8005AGV\onboard-journal.db' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
# Which IO the client is configured to talk to, and -- when that is the local
# simulator -- whether the simulator is actually there. A simulator that is not
# running presents as the client failing to reach IO, which reads like a wiring
# fault rather than a missing process.
$io = $null
try {
    $cfg = Get-Content 'C:\8005\OnboardHmi\appsettings.json' -Raw -ErrorAction Stop | ConvertFrom-Json
    $io = $cfg.ioModule
} catch { }
$simProcess = Get-Process 'SQCD_8005AGV_Simulator' -ErrorAction SilentlyContinue | Select-Object -First 1

# With the simulator the IO plane is a local process, and a PID plus a listener
# is the whole story. With the real module it is a box on 192.168.71.0/24 that
# only this machine can see, so the reachability has to be measured from here --
# there is no equivalent of "the process is running" to stand in for it.
# TcpClient rather than Test-NetConnection: the module does not answer ICMP, and
# the cmdlet spends its time on a ping that proves nothing before it gets to the
# port.
$ioReachable = $null
if ($io -and $io.host -ne '127.0.0.1') {
    $client = $null
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $ioReachable = $client.ConnectAsync($io.host, [int]$io.port).Wait(3000) -and $client.Connected
    } catch {
        $ioReachable = $false
    } finally {
        $client?.Dispose()
    }
}
[pscustomobject]@{
    utcNowUnixMs     = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    processId        = if ($proc) { $proc.Id } else { $null }
    processStart     = if ($proc) { $proc.StartTime.ToUniversalTime().ToString('o') } else { $null }
    exePresent       = [bool]$exe
    exeBytes         = if ($exe) { $exe.Length } else { $null }
    exeWrittenAt     = if ($exe) { $exe.LastWriteTimeUtc.ToString('o') } else { $null }
    journalPath      = if ($journal) { $journal.FullName } else { $null }
    journalBytes     = if ($journal) { $journal.Length } else { $null }
    journalWrittenAt = if ($journal) { $journal.LastWriteTimeUtc.ToString('o') } else { $null }
    ioHost           = if ($io) { $io.host } else { $null }
    ioPort           = if ($io) { $io.port } else { $null }
    simulatorPid     = if ($simProcess) { $simProcess.Id } else { $null }
    modbusListening  = [bool](Get-NetTCPConnection -State Listen -LocalPort 1502 -ErrorAction SilentlyContinue)
    ioReachable      = $ioReachable
} | ConvertTo-Json -Compress
'@

function Invoke-RemoteProbe {
    param([string] $Alias, [string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    # Unix milliseconds on both ends, never a formatted timestamp: ConvertFrom-Json
    # silently rehydrates an ISO-8601 string into a local-Kind DateTime, and a
    # later ToUniversalTime() then subtracts the offset a second time. That showed
    # up as a fictitious -8 h skew on a machine whose clock was correct.
    $before = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $raw = & ssh -o BatchMode=yes -o "ConnectTimeout=$TimeoutSec" $Alias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    $after = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $ok = $LASTEXITCODE -eq 0

    $result = [ordered]@{
        reachable   = $ok
        roundTripMs = [int]($after - $before)
        clockSkewMs = $null
        error       = $null
    }
    if (-not $ok) {
        $result.error = ($raw | Out-String).Trim()
        return [pscustomobject]$result
    }

    $payload = @($raw | ForEach-Object { "$_" } | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    if (-not $payload) {
        $result.reachable = $false
        $result.error = "No JSON payload. Raw: $(($raw | Out-String).Trim())"
        return [pscustomobject]$result
    }

    $parsed = $payload | ConvertFrom-Json
    foreach ($property in $parsed.PSObject.Properties) { $result[$property.Name] = $property.Value }
    # Midpoint of the local clock across the round trip, so latency is not
    # charged to the remote machine as drift.
    $result.clockSkewMs = [int]([long]$parsed.utcNowUnixMs - [long](($before + $after) / 2))
    [pscustomobject]$result
}

function Invoke-ControlServerEndpoint {
    param([string] $Path)

    try {
        # -SkipHttpErrorCheck: /health/ready answers 503 and the body is the answer.
        # -NoProxy: without it these requests go through the control host's Clash
        # proxy, which answers on the server's behalf -- a wrong port came back as
        # a proxy 502 rather than a refused connection. 01-control-host-route.ps1
        # already routes 172.19.205.0/24 directly; this makes the client agree.
        $response = Invoke-WebRequest -Uri "$BaseUrl$Path" -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -NoProxy
        $body = $response.Content
        try { $body = $response.Content | ConvertFrom-Json } catch { }
        [pscustomobject]@{ status = [int]$response.StatusCode; body = $body; error = $null }
    }
    catch {
        [pscustomobject]@{ status = $null; body = $null; error = $_.Exception.Message }
    }
}

# The four-part predicate RELEASE-CANDIDATE.md section 8 requires to be checked
# BEFORE the onboard client is started, read with the same onboard credential the
# vehicle uses. It is the gate most likely to hold a clean session in
# RecoveryRequired, and the reason is never visible from the onboard side.
function Get-VehicleSafety {
    param([int] $OnboardClockSkewMs)

    if ($SkipVehicleSafety) {
        return [pscustomobject]@{ skipped = $true; reason = '-SkipVehicleSafety' }
    }
    if (-not (Test-Path -LiteralPath $SecretPath)) {
        return [pscustomobject]@{ skipped = $true; reason = "no secret store at $SecretPath" }
    }

    try {
        $store = Import-Clixml -LiteralPath $SecretPath
        $credential = [System.Net.NetworkCredential]::new('', $store['OnboardCredential']).Password
        $response = Invoke-WebRequest -Uri "$BaseUrl/api/onboard/v1/vehicle-safety" `
            -Headers @{ Authorization = "Bearer $credential" } `
            -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -NoProxy
        $body = if ($response.StatusCode -eq 200) { $response.Content | ConvertFrom-Json } else { $null }

        # Evidence age as the VEHICLE computes it -- the vehicle is the party that
        # applies maximumEvidenceAgeMs. Measuring it against this control host's
        # clock produced a negative age, because this host runs seconds behind.
        $ageMs = $null
        if ($body -and $null -ne $OnboardClockSkewMs) {
            $ageMs = [int](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $OnboardClockSkewMs) -
                [DateTimeOffset]::Parse($body.observedAt).ToUnixTimeMilliseconds())
        }

        [pscustomobject]@{
            skipped     = $false
            status      = [int]$response.StatusCode
            vehicleKey  = $body.vehicleKey
            motionState = $body.motionState
            observedAt  = $body.observedAt
            source      = $body.source
            reasonCodes = @($body.reasonCodes)
            ageMs       = $ageMs
            error       = $null
        }
    }
    catch {
        [pscustomobject]@{ skipped = $false; status = $null; error = $_.Exception.Message }
    }
}

# Stage 'link'    -- both ends are connected and the handshake is complete. These
#                    can all be green with the journey gates shut.
# Stage 'journey' -- a journey is actually in flight. These CANNOT be green while
#                    JourneyRuntime is disabled, by design: readiness reaches Ready
#                    only after the server sends PreDepartureSafetyCheck and the
#                    vehicle answers, and JourneyRuntimeEngine is the only sender.
#                    Reading them as failures with the gates shut is a mistake.
function New-Gate {
    param([string] $Name, [object] $Pass, [string] $Detail, [string] $Stage = 'link')
    [pscustomobject]@{
        name    = $Name
        stage   = $Stage
        verdict = ($null -eq $Pass) ? 'UNKNOWN' : ($Pass ? 'PASS' : 'FAIL')
        detail  = $Detail
    }
}

function Get-Snapshot {
    $server = Invoke-RemoteProbe -Alias $ServerAlias -Script $serverProbe
    $onboard = Invoke-RemoteProbe -Alias $SiteAlias -Script $onboardProbe
    $live = Invoke-ControlServerEndpoint -Path '/health/live'
    $ready = Invoke-ControlServerEndpoint -Path '/health/ready'
    $version = Invoke-ControlServerEndpoint -Path '/version'
    $sessions = Invoke-ControlServerEndpoint -Path '/api/runtime/sessions'

    $session = $null
    if ($sessions.status -eq 200 -and $sessions.body) {
        $session = @($sessions.body) | Where-Object { $_.agvId -eq $agvId } | Select-Object -First 1
    }

    # The difference of two skews, not either skew. See the clock note in the help.
    $pairSkewMs = $null
    if ($null -ne $server.clockSkewMs -and $null -ne $onboard.clockSkewMs) {
        $pairSkewMs = $onboard.clockSkewMs - $server.clockSkewMs
    }

    $safety = Get-VehicleSafety -OnboardClockSkewMs $onboard.clockSkewMs
    $safetyPass = $null
    $safetyDetail = ''
    if ($safety.skipped) {
        $safetyDetail = "skipped: $($safety.reason)"
    }
    elseif ($safety.error) {
        $safetyDetail = $safety.error
    }
    elseif ($safety.status -ne 200) {
        $safetyPass = $false
        $safetyDetail = "HTTP $($safety.status)"
    }
    else {
        # All four parts, in the order section 8 states them.
        $keyMatches = $safety.vehicleKey -eq $site.vehicleSafety.expectedVehicleKey
        $stopped = $safety.motionState -eq 'STOPPED'
        $noReasons = @($safety.reasonCodes).Count -eq 0
        # A NEGATIVE age is the failure that cost this deployment an afternoon.
        # VehicleSafetySignal.IsFresh rejects outright when ObservedAt > now, and
        # observedAt carries the SERVER's clock while the vehicle judges it with
        # its own: a vehicle running even 100 ms slow sees every fresh piece of
        # evidence as dated in the future, reports VEHICLE_STATE_UNKNOWN, and the
        # session never leaves RecoveryRequired -- surfacing as "no demand is ever
        # accepted", which points nowhere near a clock. Judge it the way the
        # vehicle does, so the next drift is visible here instead of six layers down.
        # See trytoreachpeak0/8005-agv-onboard-hmi#1.
        $notFuture = ($null -ne $safety.ageMs) -and ($safety.ageMs -gt 0)
        $fresh = $notFuture -and ($safety.ageMs -lt $EvidenceMaxAgeMs)
        $safetyPass = $keyMatches -and $stopped -and $noReasons -and $fresh
        $failed = @(
            if (-not $keyMatches) { 'vehicleKey mismatch' }
            if (-not $stopped) { "motionState=$($safety.motionState)" }
            if (-not $noReasons) { "reasonCodes=$($safety.reasonCodes -join ',')" }
            if (-not $notFuture) { "evidence is $([Math]::Abs($safety.ageMs)) ms in the FUTURE -- vehicle clock is behind the server; IsFresh rejects this" }
            elseif (-not $fresh) { "evidence $($safety.ageMs) ms old (max $EvidenceMaxAgeMs)" }
        )
        $safetyDetail = $safetyPass `
            ? "STOPPED, key matches, no reasons, evidence $($safety.ageMs) ms old" `
            : ($failed -join '; ')
    }

    $gates = @(
        New-Gate 'server-service-running' `
            ($server.reachable ? ($server.serviceState -eq 'Running') : $null) `
            ($server.reachable ? "$($server.serviceState), pid $($server.processId)" : "unreachable: $($server.error)")

        New-Gate 'server-live' `
            (($null -eq $live.status) ? $null : ($live.status -eq 200)) `
            ($live.error ?? "HTTP $($live.status)")

        # /health/ready requires some vehicle to be Ready, so it too waits on a journey.
        New-Gate 'server-ready' `
            (($null -eq $ready.status) ? $null : ($ready.status -eq 200)) `
            ($ready.error ?? "HTTP $($ready.status) $(($ready.body.reason ?? $ready.body.status) ?? '')") `
            'journey'

        New-Gate 'onboard-process-running' `
            ($onboard.reachable ? ($null -ne $onboard.processId) : $null) `
            ($onboard.reachable `
                ? ($onboard.processId ? "pid $($onboard.processId), started $($onboard.processStart)" : 'SQCD.Agv.Wpf not running') `
                : "unreachable: $($onboard.error)")

        New-Gate 'session-present' `
            (($sessions.status -eq 200) ? ($null -ne $session) : $null) `
            (($null -ne $session) ? "generation $($session.sessionGeneration), updated $($session.updatedAt)" : "no session for '$agvId'")

        # GetRecoveryReason checks in a fixed order, so DEPARTURE_SAFETY_NOT_READY
        # is positive evidence: CapabilityRevision, SafetyRevision, RecoveryReportId,
        # the forced-recovery generation and pending-fact reconciliation all passed
        # to get that far. It is the strongest signal available with no journey running.
        New-Gate 'session-handshake-complete' `
            (($null -eq $session) `
                ? $null `
                : ($session.readiness -eq 'Ready' -or $session.reasonCode -eq 'DEPARTURE_SAFETY_NOT_READY')) `
            (($null -ne $session) ? "$($session.readiness) $($session.reasonCode)" : 'no session yet')

        New-Gate 'session-ready' `
            (($null -eq $session) ? $null : ($session.readiness -eq 'Ready')) `
            (($null -ne $session) ? "$($session.readiness) $($session.reasonCode)" : 'no session yet') `
            'journey'

        # Both IO planes are gated, by the evidence each one can actually offer:
        # a local process plus a listener for the simulator, a TCP connect from
        # the vehicle for the real module. This used to return UNKNOWN for the
        # real module, which is not the same as "not applicable" -- UNKNOWN is
        # not PASS, so linkComplete below could never be reached on a vehicle
        # running against real IO, however healthy both ends were.
        New-Gate 'io-target-reachable' `
            ($onboard.reachable `
                ? (($onboard.ioHost -eq '127.0.0.1') `
                    ? ($onboard.modbusListening -and $null -ne $onboard.simulatorPid) `
                    : $onboard.ioReachable) `
                : $null) `
            ($onboard.reachable `
                ? (($onboard.ioHost -eq '127.0.0.1') `
                    ? ("simulator $($onboard.ioHost):$($onboard.ioPort), pid $($onboard.simulatorPid), 1502 listening=$($onboard.modbusListening)") `
                    : "real module $($onboard.ioHost):$($onboard.ioPort), tcp from vehicle=$($onboard.ioReachable)") `
                : 'onboard unreachable')

        New-Gate 'vehicle-safety-stopped' $safetyPass $safetyDetail

        New-Gate 'clock-onboard-vs-server' `
            (($null -eq $pairSkewMs) ? $null : ([Math]::Abs($pairSkewMs) -lt $ClockWindowMs)) `
            (($null -eq $pairSkewMs) `
                ? 'one end unreachable' `
                : "onboard is $pairSkewMs ms ahead of server (window $ClockWindowMs ms)")
    )

    [pscustomobject]@{
        observedAt   = [DateTime]::UtcNow.ToString('o')
        agvId        = $agvId
        siteAlias    = $SiteAlias
        linkComplete = -not @($gates | Where-Object { $_.stage -eq 'link' -and $_.verdict -ne 'PASS' })
        mvpComplete  = -not @($gates | Where-Object { $_.verdict -ne 'PASS' })
        gates        = $gates
        pairSkewMs   = $pairSkewMs
        vehicleSafety = $safety
        server       = $server
        onboard      = $onboard
        protocol     = ($version.status -eq 200) ? $version.body : $null
        session      = $session
        sessionCount = ($sessions.status -eq 200) ? @($sessions.body).Count : $null
    }
}

function Write-JournalLine {
    param([object] $Snapshot)

    if (-not (Test-Path -LiteralPath $JournalDirectory)) {
        New-Item -ItemType Directory -Path $JournalDirectory -Force | Out-Null
    }
    $file = Join-Path $JournalDirectory ('w2g-status-{0:yyyyMMdd}.jsonl' -f [DateTime]::Now)
    # Append-only. Never rewrite an earlier line: a past observation stays true
    # after the state it recorded has changed.
    Add-Content -LiteralPath $file -Value ($Snapshot | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8NoBOM
    $file
}

function Show-Snapshot {
    param([object] $Snapshot, [string] $JournalFile)

    $colour = @{ PASS = 'Green'; FAIL = 'Red'; UNKNOWN = 'Yellow' }
    $mark = @{ PASS = '[ok]  '; FAIL = '[FAIL]'; UNKNOWN = '[?]   ' }

    Write-Host ''
    Write-Host ('{0}  {1}  ({2})' -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $Snapshot.agvId, $Snapshot.siteAlias)
    foreach ($gate in $Snapshot.gates) {
        $suffix = ($gate.stage -eq 'journey') ? ' (needs a journey)' : ''
        Write-Host ('  {0} {1,-28} {2}{3}' -f $mark[$gate.verdict], $gate.name, $gate.detail, $suffix) -ForegroundColor $colour[$gate.verdict]
    }
    if ($Snapshot.protocol) {
        Write-Host ('  protocol {0} / {1}' -f $Snapshot.protocol.protocolReleaseVersion, $Snapshot.protocol.profileId) -ForegroundColor DarkGray
    }
    Write-Host ('  clock vs this control host (upper bound, not gated): server {0} ms, onboard {1} ms' -f $Snapshot.server.clockSkewMs, $Snapshot.onboard.clockSkewMs) -ForegroundColor DarkGray
    if ($Snapshot.onboard.reachable -and -not $Snapshot.onboard.journalPath) {
        Write-Host '  onboard recovery journal absent -- the client has never completed a startup here' -ForegroundColor DarkGray
    }
    Write-Host ('  LINK: {0}' -f ($Snapshot.linkComplete ? 'COMPLETE -- both ends connected, handshake done' : 'not complete')) -ForegroundColor ($Snapshot.linkComplete ? 'Green' : 'Yellow')
    Write-Host ('  MVP:  {0}' -f ($Snapshot.mvpComplete ? 'COMPLETE' : 'not complete -- needs a journey in flight')) -ForegroundColor ($Snapshot.mvpComplete ? 'Green' : 'Yellow')
    Write-Host ('  journal: {0}' -f $JournalFile) -ForegroundColor DarkGray
}

$previousSignature = $null
do {
    $snapshot = Get-Snapshot
    $journalFile = Write-JournalLine -Snapshot $snapshot
    $signature = ($snapshot.gates | ForEach-Object { "$($_.name)=$($_.verdict)" }) -join ';'

    if (-not $Quiet) {
        if (-not $Watch -or $signature -ne $previousSignature) {
            if ($Watch -and $previousSignature) {
                Write-Host ''
                Write-Host '  --- state changed ---' -ForegroundColor Cyan
            }
            Show-Snapshot -Snapshot $snapshot -JournalFile $journalFile
        }
        else {
            $failing = @($snapshot.gates | Where-Object { $_.verdict -ne 'PASS' }).Count
            Write-Host ('{0}  unchanged, {1} gate(s) not passing' -f [DateTime]::Now.ToString('HH:mm:ss'), $failing) -ForegroundColor DarkGray
        }
    }
    $previousSignature = $signature

    if ($PassThru) { $snapshot }
    if ($Watch) { Start-Sleep -Seconds $IntervalSeconds }
} while ($Watch)
