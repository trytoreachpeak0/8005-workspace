#Requires -Version 7
<#
.SYNOPSIS
    Turns the ControlServer JourneyRuntime on or off on the factory server. Runs
    ON the control host and reaches the server over ssh.

.DESCRIPTION
    This switch is the moment a real vehicle starts working. There is no human
    trigger downstream of it: JourneyRuntimeWorker polls every PollInterval (2 s)
    the moment Enabled is true, and JourneyRuntimeEngine discovers demands from
    the MesIngest catalog, accepts the oldest eligible one, reconciles a RIoT
    order and dispatches movement -- with no further approval anywhere in that
    path. So "enable it and watch what happens" is not available: enabling IS the
    authorization, and RELEASE-CANDIDATE.md section 11 requires a per-occasion
    authorization AND an on-site physical safety GO, both, every time, never
    reusable.

    -Enable therefore prints what the next iteration will pick up -- how many
    WIRE_TO_GATE demands are waiting and which one is oldest -- and refuses to
    proceed without confirmation. Read that out loud at the vehicle before
    answering.

    Everything JourneyRuntime needs is already configured. appsettings.json
    carries the real site values (mapId 25, gateStationRiotId 210, dispatchZone,
    admissionPolicyDeploymentId, ...) and the service's registry environment
    already holds the RIoT, onboard and MesIngest secrets. Only the boolean in
    appsettings.Production.json is false, which is why this is a configuration
    change and not a redeployment.

.PARAMETER Disable
    Stops the runtime taking on anything new. It does NOT stop a vehicle that is
    already moving -- an in-flight journey is the vehicle's own business and the
    physical stop is the physical stop. Use this to close the intake, then let
    the current journey finish or handle it at the vehicle.

.PARAMETER Force
    Skip the confirmation prompt. Do not use this for -Enable at a real vehicle:
    the prompt is where the authorization is recorded.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Enable')]
param(
    [Parameter(ParameterSetName = 'Enable')]
    [switch] $Enable,

    [Parameter(ParameterSetName = 'Disable', Mandatory = $true)]
    [switch] $Disable,

    [string] $ServerAlias = 'factory01',
    [string] $ServiceName = '8005 AGV ControlServer',
    [string] $ConfigPath = 'C:\Program Files\8005 AGV\ControlServer\appsettings.Production.json',
    [string] $BaseUrl = 'http://172.19.205.222:58007',
    [string] $MesIngestUrl = 'http://172.19.205.222:5088',
    [string] $MesIngestSecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\mes-ingest-deployment.xml'),
    [ValidateRange(1, 120)]
    [int] $TimeoutSec = 20,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$targetState = -not $Disable

function Invoke-Server {
    param([string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o "ConnectTimeout=$TimeoutSec" $ServerAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $ServerAlias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

# ------------------------------------------------------------------ current ---

$current = Invoke-Server @"
`$c = Get-Content -LiteralPath '$ConfigPath' -Raw | ConvertFrom-Json
[pscustomobject]@{
    enabled = `$c.JourneyRuntime.enabled
    service = (Get-Service -Name '$($ServiceName -replace "'", "''")').Status.ToString()
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

Write-Host ''
Write-Host "JourneyRuntime is currently $($current.enabled); service is $($current.service)."

if ($current.enabled -eq $targetState) {
    Write-Host "Already $targetState. Nothing to do." -ForegroundColor Yellow
    return
}

# ------------------------------------------------------- what enabling means ---

if ($targetState) {
    # Read the catalog the engine itself will read, so the prompt names the real
    # sublot rather than a count. Same endpoint, same credential kind, read-only.
    $waiting = 'unknown'
    $oldest = 'unknown'
    try {
        $store = Import-Clixml -LiteralPath $MesIngestSecretPath
        $key = @($store.Keys | Where-Object { $_ -match 'Secret' })[0]
        $token = [System.Net.NetworkCredential]::new('', $store[$key]).Password
        $catalog = (Invoke-WebRequest -Uri "$MesIngestUrl/api/v2/externally-readable-demand-catalog" `
                -Headers @{ Authorization = "Bearer $token" } -TimeoutSec $TimeoutSec -NoProxy).Content | ConvertFrom-Json
        $w2g = @($catalog.items | Where-Object { $_.transportDemandKey.workType -eq 'WIRE_TO_GATE' } |
            Sort-Object createdAt)
        $waiting = $w2g.Count
        if ($w2g.Count) {
            $first = $w2g[0]
            $oldest = "$($first.transportDemandKey.sublot) (demandId $($first.demandId), area $($first.liveMesFields.area), created $($first.createdAt))"
        }
    }
    catch {
        Write-Warning "Could not read the MesIngest catalog: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host 'Enabling JourneyRuntime starts real vehicle work within one poll interval.' -ForegroundColor Yellow
    Write-Host "  WIRE_TO_GATE demands waiting: $waiting"
    Write-Host "  the next iteration will accept: $oldest"
    Write-Host '  RELEASE-CANDIDATE.md section 11: per-occasion authorization AND an on-site'
    Write-Host '  physical safety GO are both required, every time, and neither is reusable.'
    Write-Host ''
}

$action = $targetState ? 'Enable JourneyRuntime and start real vehicle work' : 'Disable JourneyRuntime intake'
# -Force suppresses the prompt by lowering ConfirmPreference, never by skipping
# ShouldProcess -- skipping it would make -Force -WhatIf perform the change.
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $ConfirmPreference = 'None'
}
if (-not $PSCmdlet.ShouldProcess("$ServerAlias ($ConfigPath)", $action)) {
    Write-Host 'Not changed.' -ForegroundColor Yellow
    return
}

# ------------------------------------------------------------------- change ---

# Round-tripping the JSON reformats it, so the change is verified field by field
# against the original rather than trusted. The backup is what a rollback needs
# if this machine loses power between write and restart.
$result = Invoke-Server @"
`$path = '$ConfigPath'
`$backup = "`$path.bak-`$([DateTime]::Now.ToString('yyyyMMddHHmmss'))"
Copy-Item -LiteralPath `$path -Destination `$backup
`$before = Get-Content -LiteralPath `$path -Raw
`$c = `$before | ConvertFrom-Json
`$c.JourneyRuntime.enabled = `$$targetState
`$after = `$c | ConvertTo-Json -Depth 12
Set-Content -LiteralPath `$path -Value `$after -Encoding utf8NoBOM

# Confirm exactly one field moved.
`$b = `$before | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress
`$a = (Get-Content -LiteralPath `$path -Raw | ConvertFrom-Json) | ConvertTo-Json -Depth 12 -Compress
`$expected = (`$before | ConvertFrom-Json)
`$expected.JourneyRuntime.enabled = `$$targetState
`$drift = (`$expected | ConvertTo-Json -Depth 12 -Compress) -ne `$a

Restart-Service -Name '$($ServiceName -replace "'", "''")' -Force
`$svc = Get-Service -Name '$($ServiceName -replace "'", "''")'
[pscustomobject]@{
    backup       = `$backup
    unexpectedDrift = `$drift
    enabledNow   = (Get-Content -LiteralPath `$path -Raw | ConvertFrom-Json).JourneyRuntime.enabled
    service      = `$svc.Status.ToString()
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

Write-Step "Backup: $($result.backup)"
if ($result.unexpectedDrift) {
    throw "The configuration changed in more than the JourneyRuntime.enabled field. Restore $($result.backup) on $ServerAlias."
}
Write-Step "JourneyRuntime.enabled is now $($result.enabledNow); service $($result.service)"

# ------------------------------------------------------------------- verify ---

$deadline = [DateTime]::UtcNow.AddSeconds(60)
do {
    Start-Sleep -Seconds 3
    $live = try {
        (Invoke-WebRequest -Uri "$BaseUrl/health/live" -TimeoutSec 5 -SkipHttpErrorCheck -NoProxy).StatusCode
    }
    catch { $null }
} while ($live -ne 200 -and [DateTime]::UtcNow -lt $deadline)

if ($live -ne 200) { throw "Service did not answer /health/live within 60 s after the restart." }
Write-Step '/health/live 200'

# The disabled runtime logs one warning and then sleeps forever; the enabled one
# logs an iteration failure per poll if anything fails closed. Either way the
# first seconds of log after a restart say which.
$log = Invoke-Server @"
`$f = Get-ChildItem 'C:\ProgramData\8005\ControlServer\logs' -Filter 'controlserver-*.ndjson' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content -LiteralPath `$f.FullName -Tail 25 | Where-Object { `$_ -match 'ourney|unway|iteration|Runtime' }
"@
Write-Host ''
Write-Host 'Recent runtime log lines:' -ForegroundColor DarkGray
if ($log) { $log -split "`n" | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
else { Write-Host '  (none matched)' -ForegroundColor DarkGray }

Write-Host ''
if ($targetState) {
    Write-Host 'JourneyRuntime is ENABLED. Watch the vehicle, and watch Get-WireToGateStatus.ps1 -Watch.' -ForegroundColor Yellow
}
else {
    Write-Host 'JourneyRuntime is DISABLED. No new demand will be accepted.' -ForegroundColor Green
}
