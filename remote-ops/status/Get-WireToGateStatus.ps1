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

    Four signal sources, all of which already existed:

      1. ControlServer HTTP on 58007 -- /health/live, /health/ready, /version,
         /api/runtime/sessions. /health/ready answers 503 with a useful body, so
         the request must NOT fail on a non-2xx status (-SkipHttpErrorCheck).
      2. ssh factory01 -- Windows service state and host clock.
      3. ssh agv01     -- whether SQCD.Agv.Wpf is running, plus host clock and
         the onboard recovery journal file.
      4. The site file -- the real agvId, which is what /api/runtime/sessions
         keys on. Never hardcode it; the value is per vehicle.

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

function New-Gate {
    param([string] $Name, [object] $Pass, [string] $Detail)
    [pscustomobject]@{
        name    = $Name
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

    $gates = @(
        New-Gate 'server-service-running' `
            ($server.reachable ? ($server.serviceState -eq 'Running') : $null) `
            ($server.reachable ? "$($server.serviceState), pid $($server.processId)" : "unreachable: $($server.error)")

        New-Gate 'server-live' `
            (($null -eq $live.status) ? $null : ($live.status -eq 200)) `
            ($live.error ?? "HTTP $($live.status)")

        New-Gate 'server-ready' `
            (($null -eq $ready.status) ? $null : ($ready.status -eq 200)) `
            ($ready.error ?? "HTTP $($ready.status) $(($ready.body.reason ?? $ready.body.status) ?? '')")

        New-Gate 'onboard-process-running' `
            ($onboard.reachable ? ($null -ne $onboard.processId) : $null) `
            ($onboard.reachable `
                ? ($onboard.processId ? "pid $($onboard.processId), started $($onboard.processStart)" : 'SQCD.Agv.Wpf not running') `
                : "unreachable: $($onboard.error)")

        New-Gate 'session-present' `
            (($sessions.status -eq 200) ? ($null -ne $session) : $null) `
            (($null -ne $session) ? "generation $($session.sessionGeneration), updated $($session.updatedAt)" : "no session for '$agvId'")

        New-Gate 'session-ready' `
            (($null -eq $session) ? $null : ($session.readiness -eq 'Ready')) `
            (($null -ne $session) ? "$($session.readiness) $($session.reasonCode)" : 'no session yet')

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
        mvpComplete  = -not @($gates | Where-Object { $_.verdict -ne 'PASS' })
        gates        = $gates
        pairSkewMs   = $pairSkewMs
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
        Write-Host ('  {0} {1,-26} {2}' -f $mark[$gate.verdict], $gate.name, $gate.detail) -ForegroundColor $colour[$gate.verdict]
    }
    if ($Snapshot.protocol) {
        Write-Host ('  protocol {0} / {1}' -f $Snapshot.protocol.protocolReleaseVersion, $Snapshot.protocol.profileId) -ForegroundColor DarkGray
    }
    Write-Host ('  clock vs this control host (upper bound, not gated): server {0} ms, onboard {1} ms' -f $Snapshot.server.clockSkewMs, $Snapshot.onboard.clockSkewMs) -ForegroundColor DarkGray
    if ($Snapshot.onboard.reachable -and -not $Snapshot.onboard.journalPath) {
        Write-Host '  onboard recovery journal absent -- the client has never completed a startup here' -ForegroundColor DarkGray
    }
    Write-Host ('  MVP: {0}' -f ($Snapshot.mvpComplete ? 'COMPLETE' : 'not complete')) -ForegroundColor ($Snapshot.mvpComplete ? 'Green' : 'Yellow')
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
