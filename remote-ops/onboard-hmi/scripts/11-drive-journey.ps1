#Requires -Version 7
<#
.SYNOPSIS
    Drives one WIRE_TO_GATE journey on a real vehicle without a person at the
    HMI: submits the sublot the server asked for, then plays the operator's
    physical part on the slot simulator. Runs ON the control host.

.DESCRIPTION
    The L2 rig already automates this, but only on one machine: it drives the
    onboard WPF through UI Automation because both halves are local to it. Here
    the client runs on the vehicle and the control host is somewhere else, so
    this uses the two automation HTTP planes the products already ship instead:

        onboard    127.0.0.1:58007/api/v1   snapshot, sublots/submit
        simulator  127.0.0.1:58006/api/v1   snapshot, slots/{n}/cargo, slots/{n}/close-door

    Both bind loopback on purpose, so nothing here opens a tunnel -- every call
    is issued ON the vehicle over ssh. That is one round trip per poll and it is
    the reason this reads as a sequence of small ssh calls rather than a client.

    PREREQUISITE, and it is a configuration change on a production vehicle:
    the onboard automation plane is shipped disabled. `wireToGate` deployments
    set `automation.enabled = false`, and the client starts the plane only when
    it is true (App.xaml.cs). Turn it on, restart the client, and remember that
    a later 06-deploy-onboard-hmi.ps1 renders the file again and turns it back
    off.

    WHAT THIS DOES NOT DO. It never moves the vehicle and never opens a slot.
    Both of those belong to the server and the onboard client respectively --
    this only answers, with the vehicle already parked at the station and the
    door already opened by the client:

      * the scan the operator would have typed, and
      * the cargo the operator would have placed, plus closing the door.

    -CargoState EMPTY closes the door without placing anything, which is the
    honest way to reproduce a failed load: door shut, slot still empty. That is
    the state `real-onboard-recovery-entry-missing` builds, and the one the
    server judges RecoveryRequired.

.PARAMETER Sublot
    Submit this instead of whatever the server asked for. Only useful for
    negative tests; by default the script reads expectedSublot and echoes it.

.PARAMETER CargoState
    OCCUPIED (default) completes the load. EMPTY reproduces a failed one.

.EXAMPLE
    ./11-drive-journey.ps1

.EXAMPLE
    ./11-drive-journey.ps1 -CargoState EMPTY
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SshAlias = 'agv01',
    [string] $Sublot,
    [ValidateSet('OCCUPIED', 'EMPTY')]
    [string] $CargoState = 'OCCUPIED',
    [int] $OnboardPort = 58007,
    [int] $SimulatorPort = 58006,
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

# Every call runs on the vehicle: both planes are loopback-only by design, and
# tunnelling them would put a plant-network listener where the product
# deliberately did not put one.
function Invoke-Vehicle {
    param([string] $Method, [int] $Port, [string] $Path, $Body)

    $bodyJson = $null -eq $Body ? '$null' : "'" + (($Body | ConvertTo-Json -Compress) -replace "'", "''") + "'"
    $script = @"
`$ErrorActionPreference = 'Stop'
`$args = @{ Uri = 'http://127.0.0.1:$Port/api/v1$Path'; Method = '$Method'; TimeoutSec = 20; SkipHttpErrorCheck = `$true }
`$body = $bodyJson
if (`$null -ne `$body) { `$args.Body = `$body; `$args.ContentType = 'application/json' }
`$r = Invoke-WebRequest @args
"STATUS=`$(`$r.StatusCode)"
`$r.Content
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed: $(($raw | Out-String).Trim())" }
    $lines = ($raw | Out-String) -split "`r?`n"
    $status = ($lines | Where-Object { $_ -like 'STATUS=*' } | Select-Object -First 1) -replace 'STATUS=', ''
    $content = ($lines | Where-Object { $_ -notlike 'STATUS=*' }) -join "`n"
    if ([int]$status -ge 400) { throw "$Method $Path -> HTTP $status : $content" }
    return $content | ConvertFrom-Json
}

function Get-Onboard   { Invoke-Vehicle -Method GET -Port $OnboardPort   -Path '/snapshot' }
function Get-Simulator { Invoke-Vehicle -Method GET -Port $SimulatorPort -Path '/snapshot' }

function Wait-For {
    param([string] $Description, [scriptblock] $Probe)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $value = & $Probe
        if ($value) { return $value }
        Start-Sleep -Seconds 2
    }
    throw "Timed out after ${TimeoutSeconds}s waiting for: $Description"
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Driving one journey on $SshAlias" -ForegroundColor Green

# --- preflight ------------------------------------------------------------

$onboard = Get-Onboard
Write-Step "Onboard plane up: agvId=$($onboard.agvId) revision=$($onboard.revision)"
$null = Get-Simulator
Write-Step 'Simulator plane up'

$session = $onboard.state.wireToGateSession
if (-not $session -or -not $session.connected) { throw 'The onboard has no WIRE_TO_GATE session; nothing to drive.' }
Write-Step "Session: connected=$($session.connected) readiness=$($session.readiness)"

# --- 1. the scan ----------------------------------------------------------

$ready = Wait-For 'the server to ask this vehicle for a sublot' {
    $s = Get-Onboard
    $s.state.canSubmitSublot ? $s : $null
}
$expected = $ready.state.expectedSublot
$toSubmit = $Sublot ? $Sublot : $expected
Write-Step "Server expects sublot $expected"
if ($Sublot -and $Sublot -ne $expected) { Write-Step "Submitting $toSubmit instead (-Sublot given)" }

if (-not $PSCmdlet.ShouldProcess($SshAlias, "Submit sublot $toSubmit and play the operator's part")) { return }

$submit = Invoke-Vehicle -Method POST -Port $OnboardPort -Path '/sublots/submit' -Body @{
    commandId = [guid]::NewGuid().ToString('D')
    sublot    = $toSubmit
}
Write-Step "Submitted: accepted=$($submit.outcome.accepted) $($submit.outcome.reasonCode)"
if (-not $submit.outcome.accepted) { throw "The onboard refused the submission: $($submit.outcome.reasonCode)" }

# --- 2. the operator's hands ---------------------------------------------

# Which slot is the client working? Ask the simulator rather than the onboard:
# the door it opened is the fact, and the onboard snapshot does not carry the
# slot number. Exactly one door opens per operation.
$slotNo = Wait-For 'the onboard to open a slot door' {
    $open = @(( Get-Simulator ).slots | Where-Object { $_.doorState -eq 'OPEN' })
    $open.Count -eq 1 ? [int]$open[0].slotNo : $null
}
Write-Step "Slot $slotNo is open; the client is waiting for the operator"

if ($CargoState -eq 'OCCUPIED') {
    $null = Invoke-Vehicle -Method PUT -Port $SimulatorPort -Path "/slots/$slotNo/cargo" -Body @{
        commandId = [guid]::NewGuid().ToString('D')
        state     = 'OCCUPIED'
    }
    Write-Step "Placed cargo in slot $slotNo"
} else {
    Write-Step "Leaving slot $slotNo empty (-CargoState EMPTY): this load will fail"
}

$null = Invoke-Vehicle -Method POST -Port $SimulatorPort -Path "/slots/$slotNo/close-door" -Body @{
    commandId = [guid]::NewGuid().ToString('D')
}
Write-Step "Closed the door on slot $slotNo"

# --- 3. let the client finish --------------------------------------------

# A failed load is not reported until the client runs out its own operator
# timeout (workflow.operationTimeoutMs, 120 s on this deployment), so the wait
# here is deliberately longer than the happy path needs.
$final = Wait-For 'the operation to settle' {
    $s = Get-Onboard
    $null -eq $s.state.currentOperationPhase -or
    $s.state.currentOperationPhase -in @('COMPLETED', 'RECOVERY_REQUIRED') ? $s : $null
}
$slot = @(( Get-Simulator ).slots | Where-Object { [int]$_.slotNo -eq $slotNo })[0]

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Done." -ForegroundColor Green
Write-Step "Operation phase: $($final.state.currentOperationPhase ?? '(settled)')"
Write-Step "Slot $slotNo : door=$($slot.doorState) cargo=$($slot.cargoState)"
Write-Step "Session readiness: $($final.state.wireToGateSession.readiness)"
Write-Host '  The journey continues on the server; this script only played the operator.' -ForegroundColor Yellow
