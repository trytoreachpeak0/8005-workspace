#Requires -Version 7
<#
.SYNOPSIS
    Sets the ControlServer journey gates on the factory server. Runs ON the
    control host and reaches the server over ssh.

.DESCRIPTION
    There are TWO gates, not one, and they carry different authorizations:

      JourneyRuntime.enabled     the engine runs at all -- polls the MesIngest
                                 catalog, accepts the oldest eligible
                                 WIRE_TO_GATE demand, resolves a route, applies
                                 the admission policy, reconciles RIoT orders.
      RiotCreateDispatch.enabled the engine may CREATE a RIoT order. This is the
                                 one that moves a vehicle.

    Hence three levels:

      -Off       both closed. Nothing is accepted, nothing moves.
      -Intake    runtime on, create gate closed. A real demand is accepted and
                 the whole decision chain runs, but no RIoT order is created and
                 no vehicle moves. This is the state issue 14's acceptance ran
                 in: 23 PASS, RiotDispatchAuditEvents finished at 0, no vehicle
                 moved. It is the honest rehearsal -- real data, real decisions,
                 no motion.
      -Dispatch  both open. A real vehicle will move.

    -Intake is not a dry run in the sense of being reversible in the outside
    world: accepting a demand writes an AcceptedDemands row, and a demand this
    server has accepted is bound to its one journey permanently and is never a
    candidate again. It just does not move anything.

    -Dispatch is where RELEASE-CANDIDATE.md section 11 applies: a per-occasion
    authorization AND an on-site physical safety GO, both, every time, never
    reusable. There is no human trigger downstream -- JourneyRuntimeWorker polls
    every PollInterval (2 s), so the vehicle starts within seconds of the
    restart. The prompt prints which sublot the next iteration will pick up;
    read it out loud at the vehicle before answering.

    CLOSING IS NOT INSTANT, AND AFTER A TRIP THAT MATTERS. Both booleans are read
    once at startup (Program.cs binds IOptions, not IOptionsMonitor), so this
    script has to restart the service for either to mean anything -- seconds, not
    milliseconds. JourneyRuntimeWorker polls every 2 s, so a journey that reaches
    Completed while a person is still walking to a keyboard is followed by an
    accepted demand and a created RIoT order before -Off can land. Measured on
    2026-09-07: Completed 13:52:14, next demand dispatched 13:52:16, -Off 13:53:23.
    Nobody wins that by hand. 13-close-gates-when-idle.ps1 watches from the server
    at 250 ms and stops the service the instant the journey completes, then calls
    this script to write the booleans once nothing is racing. Use it for any trip
    that is meant to be the last one.

    Everything else is already configured. appsettings.json carries the real site
    values (mapId 25, gateStationRiotId 210, dispatchZone,
    admissionPolicyDeploymentId, ...) and the service's registry environment
    holds the RIoT, onboard and MesIngest secrets. Only the two booleans in
    appsettings.Production.json are false, which is why this is a configuration
    change and not a redeployment.

.PARAMETER Off
    Closes both gates. It does NOT stop a vehicle that is already moving -- an
    in-flight journey is the vehicle's own business and the physical stop is the
    physical stop. This closes intake; the current journey is handled at the
    vehicle.

    That sentence is about the VEHICLE, and it has been read as more than it says.
    SERVER-SIDE, closing the runtime gate mid-journey does stop the journey: a
    disabled JourneyRuntimeWorker logs one warning and sleeps forever, and every
    remaining transition -- the gate worklist, the unload command, settling the
    result -- is made by that loop. Close it after the load and the vehicle
    reaches the gate with nothing opening. So -Off belongs after Completed, never
    between the load and the unload.

.PARAMETER ChargeTriggerBatteryPercent
    With -ChargeResumeBatteryPercent, and only with -Intake or -Dispatch: writes a
    temporary charging threshold override into JourneyRuntime of
    appsettings.Production.json, so the charging errand can be watched on a
    vehicle whose battery is nowhere near the shipped 30 %. Field window two
    (8005-agv-program#20) runs it once, between two journeys: trigger just above
    the battery, resume a few percent higher.

    AN OVERRIDE NEVER OUTLIVES THE GATES. Every call that does not pass the two
    parameters removes any override it finds -- -Off above all, which is what
    13-close-gates-when-idle.ps1 calls after the journey -- so closing the gates
    also puts the shipped thresholds back. The base appsettings.json is never
    edited.

.PARAMETER ChargeResumeBatteryPercent
    See -ChargeTriggerBatteryPercent. Must exceed the trigger, and the trigger must
    be at least the base configuration's minimumBatteryPercent, or the service
    refuses to start -- the same two rules JourneyRuntimeOptionsValidator enforces
    since 8005-agv-program#53, checked here before anything is written. With the
    battery below that floor, pass the floor itself as the trigger.

.PARAMETER Force
    Suppresses the confirmation prompt by lowering $ConfirmPreference. Do not use
    it with -Dispatch at a real vehicle: the prompt is where the authorization is
    recorded.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Intake')]
param(
    [Parameter(ParameterSetName = 'Intake')]
    [switch] $Intake,

    [Parameter(ParameterSetName = 'Dispatch', Mandatory = $true)]
    [switch] $Dispatch,

    [Parameter(ParameterSetName = 'Off', Mandatory = $true)]
    [switch] $Off,

    [Parameter(ParameterSetName = 'Intake')]
    [Parameter(ParameterSetName = 'Dispatch')]
    [ValidateRange(1, 100)]
    [int] $ChargeTriggerBatteryPercent,

    [Parameter(ParameterSetName = 'Intake')]
    [Parameter(ParameterSetName = 'Dispatch')]
    [ValidateRange(1, 100)]
    [int] $ChargeResumeBatteryPercent,

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

$wantRuntime = -not $Off
$wantDispatch = [bool]$Dispatch
$levelName = $Off ? 'Off' : ($Dispatch ? 'Dispatch' : 'Intake')

$triggerGiven = $PSBoundParameters.ContainsKey('ChargeTriggerBatteryPercent')
$resumeGiven = $PSBoundParameters.ContainsKey('ChargeResumeBatteryPercent')
if ($triggerGiven -ne $resumeGiven) {
    throw 'Pass -ChargeTriggerBatteryPercent and -ChargeResumeBatteryPercent together, or neither.'
}
$wantOverride = $triggerGiven
if ($wantOverride -and $ChargeResumeBatteryPercent -le $ChargeTriggerBatteryPercent) {
    throw "ChargeResumeBatteryPercent ($ChargeResumeBatteryPercent) must exceed ChargeTriggerBatteryPercent ($ChargeTriggerBatteryPercent); the service refuses to start otherwise."
}
$wantTrigger = $wantOverride ? $ChargeTriggerBatteryPercent : $null
$wantResume = $wantOverride ? $ChargeResumeBatteryPercent : $null
$BaseConfigPath = Join-Path (Split-Path -Parent $ConfigPath) 'appsettings.json'

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
`$b = (Get-Content -LiteralPath '$BaseConfigPath' -Raw | ConvertFrom-Json).JourneyRuntime
[pscustomobject]@{
    runtime        = [bool]`$c.JourneyRuntime.enabled
    dispatch       = [bool]`$c.RiotCreateDispatch.enabled
    chargeTrigger  = `$c.JourneyRuntime.chargeTriggerBatteryPercent
    chargeResume   = `$c.JourneyRuntime.chargeResumeBatteryPercent
    autoCharging   = [bool]`$b.autoChargingEnabled
    baseTrigger    = `$b.chargeTriggerBatteryPercent
    baseResume     = `$b.chargeResumeBatteryPercent
    minimumBattery = `$b.minimumBatteryPercent
    service        = (Get-Service -Name '$($ServiceName -replace "'", "''")').Status.ToString()
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

$currentLevel = -not $current.runtime ? 'Off' : ($current.dispatch ? 'Dispatch' : 'Intake')
$currentOverride = ($null -ne $current.chargeTrigger -or $null -ne $current.chargeResume) `
    ? "charge override trigger=$($current.chargeTrigger) resume=$($current.chargeResume)" : 'no charge override'
Write-Host ''
Write-Host "Journey gates are currently $currentLevel (runtime=$($current.runtime), createDispatch=$($current.dispatch)); $currentOverride; service is $($current.service)."

if ($wantOverride) {
    if (-not $current.autoCharging) {
        throw "autoChargingEnabled is false in $BaseConfigPath; a threshold override would change nothing."
    }
    # JourneyRuntimeOptionsValidator since 8005-agv-program#53: a trigger below the demand floor leaves a
    # band where the vehicle is neither given work nor sent to charge. The resume level exceeds the
    # trigger, so it clears the floor too. A binary from before that fix only checks the resume level,
    # which this rule implies.
    if ($null -ne $current.minimumBattery -and $ChargeTriggerBatteryPercent -lt [int]$current.minimumBattery) {
        throw "ChargeTriggerBatteryPercent ($ChargeTriggerBatteryPercent) is below minimumBatteryPercent ($($current.minimumBattery)); the service refuses to start otherwise. At a battery below the floor, lift the trigger to the floor itself."
    }
}

if ($current.runtime -eq $wantRuntime -and $current.dispatch -eq $wantDispatch -and
    $current.chargeTrigger -eq $wantTrigger -and $current.chargeResume -eq $wantResume) {
    Write-Host "Already $levelName$($wantOverride ? " with that charge override" : ''). Nothing to do." -ForegroundColor Yellow
    return
}

# ------------------------------------------------------- what this will do ---

if ($wantRuntime) {
    # Read the catalog the engine itself reads, so the prompt names the real
    # sublot rather than a count. Same endpoint, read-only.
    $waiting = 'unknown'
    $oldest = 'unknown'
    try {
        $store = Import-Clixml -LiteralPath $MesIngestSecretPath
        $key = @($store.Keys | Where-Object { $_ -match 'Secret' })[0]
        $token = [System.Net.NetworkCredential]::new('', $store[$key]).Password
        $catalog = (Invoke-WebRequest -Uri "$MesIngestUrl/api/v2/externally-readable-demand-catalog" `
                -Headers @{ Authorization = "Bearer $token" } -TimeoutSec $TimeoutSec -NoProxy).Content | ConvertFrom-Json
        # Both filters, in the engine's own order. Work type alone is not the
        # eligibility rule: JourneyRuntimeEngine also requires the MES area to
        # start with 'N' (OUT_OF_SCOPE_AREA otherwise), and reporting the oldest
        # WIRE_TO_GATE demand without that check named a sublot the engine would
        # never touch. The remaining gates -- station resolution, package
        # capacity, box count, onboard facts -- need server state this script does
        # not have, so treat what is printed as an upper bound on what runs next.
        $w2g = @($catalog.items |
            Where-Object { $_.transportDemandKey.workType -eq 'WIRE_TO_GATE' -and
                           $_.liveMesFields.area -clike 'N*' } |
            Sort-Object createdAt)
        $waiting = $w2g.Count
        if ($w2g.Count) {
            $first = $w2g[0]
            $oldest = "$($first.transportDemandKey.sublot) (demandId $($first.demandId), area $($first.liveMesFields.area), created $($first.createdAt))"
        }
        else {
            $oldest = 'none in scope (work type WIRE_TO_GATE and area N*)'
        }
    }
    catch {
        Write-Warning "Could not read the MesIngest catalog: $($_.Exception.Message)"
    }

    Write-Host ''
    Write-Host "  WIRE_TO_GATE demands waiting: $waiting"
    Write-Host "  the next iteration will accept: $oldest"
    Write-Host ''
    if ($wantDispatch) {
        Write-Host '  DISPATCH: a real vehicle will start moving within seconds of the restart.' -ForegroundColor Red
        Write-Host '  RELEASE-CANDIDATE.md section 11 requires a per-occasion authorization AND an' -ForegroundColor Red
        Write-Host '  on-site physical safety GO. Both. Every time. Neither is reusable.' -ForegroundColor Red
    }
    else {
        Write-Host '  INTAKE only: the demand is accepted and the decision chain runs, but the RIoT' -ForegroundColor Yellow
        Write-Host '  create gate stays closed and no vehicle moves. Accepting is still permanent --' -ForegroundColor Yellow
        Write-Host '  that demand is bound to its journey and never becomes a candidate again.' -ForegroundColor Yellow
    }
    Write-Host ''
}

if ($wantOverride) {
    Write-Host "  CHARGE OVERRIDE: trigger $ChargeTriggerBatteryPercent %, resume $ChargeResumeBatteryPercent % (shipped $($current.baseTrigger) / $($current.baseResume))." -ForegroundColor Yellow
    Write-Host '  With no journey unresolved and the battery below the trigger, the engine sends the vehicle to the' -ForegroundColor Yellow
    Write-Host '  charger before it takes any demand. The next call without these parameters -- -Off included -- removes it.' -ForegroundColor Yellow
    Write-Host ''
}
elseif ($null -ne $current.chargeTrigger -or $null -ne $current.chargeResume) {
    Write-Host "  The charge override is removed; back to the shipped $($current.baseTrigger) / $($current.baseResume)." -ForegroundColor Cyan
    Write-Host ''
}

$action = switch ($levelName) {
    'Dispatch' { 'Open both gates and start real vehicle movement' }
    'Intake' { 'Open the runtime gate only; accept a real demand without moving' }
    'Off' { 'Close both journey gates' }
}
if ($wantOverride) { $action += " with charge thresholds $ChargeTriggerBatteryPercent / $ChargeResumeBatteryPercent" }

# The same edit applied to the file and to the expectation it is verified against. Removing first means a
# call without the parameters always leaves the shipped thresholds in force.
function Get-OverrideEdit([string] $Variable) {
    $lines = @(
        "`$$Variable.JourneyRuntime.PSObject.Properties.Remove('chargeTriggerBatteryPercent')",
        "`$$Variable.JourneyRuntime.PSObject.Properties.Remove('chargeResumeBatteryPercent')")
    if ($wantOverride) {
        $lines += "`$$Variable.JourneyRuntime | Add-Member -NotePropertyName 'chargeTriggerBatteryPercent' -NotePropertyValue $ChargeTriggerBatteryPercent"
        $lines += "`$$Variable.JourneyRuntime | Add-Member -NotePropertyName 'chargeResumeBatteryPercent' -NotePropertyValue $ChargeResumeBatteryPercent"
    }
    return $lines -join "`n"
}
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
`$c.JourneyRuntime.enabled = `$$wantRuntime
if (`$c.PSObject.Properties.Name -notcontains 'RiotCreateDispatch') {
    `$c | Add-Member -NotePropertyName 'RiotCreateDispatch' -NotePropertyValue ([pscustomobject]@{ enabled = `$$wantDispatch })
} else {
    `$c.RiotCreateDispatch.enabled = `$$wantDispatch
}
$(Get-OverrideEdit 'c')
Set-Content -LiteralPath `$path -Value (`$c | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM

`$expected = `$before | ConvertFrom-Json
`$expected.JourneyRuntime.enabled = `$$wantRuntime
if (`$expected.PSObject.Properties.Name -notcontains 'RiotCreateDispatch') {
    `$expected | Add-Member -NotePropertyName 'RiotCreateDispatch' -NotePropertyValue ([pscustomobject]@{ enabled = `$$wantDispatch })
} else {
    `$expected.RiotCreateDispatch.enabled = `$$wantDispatch
}
$(Get-OverrideEdit 'expected')
`$actual = (Get-Content -LiteralPath `$path -Raw | ConvertFrom-Json) | ConvertTo-Json -Depth 12 -Compress

Restart-Service -Name '$($ServiceName -replace "'", "''")' -Force
`$now = Get-Content -LiteralPath `$path -Raw | ConvertFrom-Json
[pscustomobject]@{
    backup      = `$backup
    drift       = (`$expected | ConvertTo-Json -Depth 12 -Compress) -ne `$actual
    runtimeNow  = [bool]`$now.JourneyRuntime.enabled
    dispatchNow = [bool]`$now.RiotCreateDispatch.enabled
    triggerNow  = `$now.JourneyRuntime.chargeTriggerBatteryPercent
    resumeNow   = `$now.JourneyRuntime.chargeResumeBatteryPercent
    service     = (Get-Service -Name '$($ServiceName -replace "'", "''")').Status.ToString()
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

Write-Step "Backup: $($result.backup)"
if ($result.drift) {
    throw "The configuration changed in more than the gate and charge-threshold fields. Restore $($result.backup) on $ServerAlias."
}
if ($result.triggerNow -ne $wantTrigger -or $result.resumeNow -ne $wantResume) {
    throw "The charge override reads trigger=$($result.triggerNow) resume=$($result.resumeNow), not $wantTrigger / $wantResume. Restore $($result.backup) on $ServerAlias."
}
Write-Step "runtime=$($result.runtimeNow), createDispatch=$($result.dispatchNow), charge override $(($null -eq $result.triggerNow) ? 'none' : "$($result.triggerNow) / $($result.resumeNow)"); service $($result.service)"

# ------------------------------------------------------------------- verify ---

$deadline = [DateTime]::UtcNow.AddSeconds(60)
do {
    Start-Sleep -Seconds 3
    $live = try {
        (Invoke-WebRequest -Uri "$BaseUrl/health/live" -TimeoutSec 5 -SkipHttpErrorCheck -NoProxy).StatusCode
    }
    catch { $null }
} while ($live -ne 200 -and [DateTime]::UtcNow -lt $deadline)

if ($live -ne 200) { throw 'Service did not answer /health/live within 60 s after the restart.' }
Write-Step '/health/live 200'

# A disabled runtime logs one warning and sleeps forever; an enabled one logs an
# iteration failure per poll if anything fails closed. The first seconds of log
# after a restart say which.
$log = Invoke-Server @"
`$f = Get-ChildItem 'C:\ProgramData\8005\ControlServer\logs' -Filter 'controlserver-*.ndjson' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content -LiteralPath `$f.FullName -Tail 40 | Where-Object { `$_ -match 'ourney|iteration|Runtime|ispatch|emand' }
"@
Write-Host ''
Write-Host 'Recent runtime log lines:' -ForegroundColor DarkGray
if ($log) { $log -split "`n" | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
else { Write-Host '  (none matched)' -ForegroundColor DarkGray }

Write-Host ''
switch ($levelName) {
    'Dispatch' { Write-Host 'DISPATCH is OPEN. A vehicle may be moving. Watch it.' -ForegroundColor Red }
    'Intake' { Write-Host 'INTAKE is open, create gate closed. A demand will be accepted; nothing moves.' -ForegroundColor Yellow }
    'Off' { Write-Host 'Both gates closed. No new demand will be accepted.' -ForegroundColor Green }
}
