#Requires -Version 7
<#
.SYNOPSIS
    One half of the operator's part of a WIRE_TO_GATE station operation. Runs ON
    the vehicle, inside the interactive desktop session. Deployed and launched by
    11-drive-journey.ps1 on the control host.

.DESCRIPTION
    Both halves drive a loopback-only HTTP face, and that is the whole reason
    this file exists rather than being part of the control-host script:

      * the onboard client's automation face binds 127.0.0.1 on purpose, so the
        sublot has to be submitted from this machine;
      * the slot simulator's automation plane binds 127.0.0.1 for the same
        reason, so the cargo and door calls have to originate here too.

    The scan used to go through UI Automation instead, matching controls by name
    (ScanTextBox, 手动提交) inside the client's own desktop session. That was a
    detour around 8005-agv-onboard-hmi#14 -- turning the automation face on used
    to stop the client dead at startup, with no window and not one line of log.
    #14 is fixed, so the scan is one POST against a contract now.

    It runs in two phases because the thing that separates them can only be seen
    from the server:

      Scan      type the sublot and click submit
      Operator  put the cargo in the named slot and close its door

    WHY THE SPLIT, and it cost a real journey to learn. The first version did
    both in one pass and triggered the second on the simulator reporting
    `doorState = OPEN`. That is true the instant the unlock pulse lands, before
    the client has watched the lock feedback settle and entered WAITING_OPERATOR.
    On 2026-09-07 the whole IO trace landed inside 0.4 s and the server judged
    the load LOAD_RESULT_REQUIRES_RECOVERY; the run before it, driven by hand,
    had 23 s between unlock and cargo. L2's own scenario says this in as many
    words -- "绝不能一看到 UNLOCKING 就动手" -- and the first version did exactly
    that anyway.

    WAITING_OPERATOR is reported by the client, reaches the server as
    OperationProgress, and names the slot in activeUnlockSlots. So the control
    host waits for it and passes the slot in. The onboard face does expose
    currentOperationPhase locally, which would save that round trip -- but only
    once it is confirmed to report the phase slot by slot in a multi-slot
    operation, so the split stays as it is.

    Driving only, never asserting. The one thing read back from the UI is whether
    input is accepted yet, which is a precondition for typing rather than a
    business fact.

.PARAMETER Phase
    Scan or Operator.

.PARAMETER Sublot
    Scan phase. What to type; the caller reads it from the server's own
    SublotEntryRequested rather than guessing.

.PARAMETER SlotNo
    Operator phase. Which slot the client actually opened, from the server's
    OperationProgress.

.PARAMETER CargoState
    Operator phase. OCCUPIED completes the load; EMPTY closes the door on an
    empty slot, which is how a failed load is reproduced honestly. Use EMPTY for
    an unload, where the operator takes the cargo out.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Scan', 'Operator')]
    [string] $Phase,
    [string] $Sublot,
    [int] $SlotNo,
    [ValidateSet('OCCUPIED', 'EMPTY')]
    [string] $CargoState = 'OCCUPIED',
    [Parameter(Mandatory)][string] $ResultPath,
    [int] $SimulatorPort = 58006,
    [int] $AutomationPort = 58007,
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$steps = [System.Collections.Generic.List[object]]::new()
$startedAt = [DateTimeOffset]::UtcNow

function Add-Step {
    param([string] $Name, [string] $Detail)
    $steps.Add([pscustomobject]@{ at = [DateTimeOffset]::UtcNow.ToString('o'); step = $Name; detail = $Detail })
}

function Write-Result {
    param([string] $Status, [string] $Message, $Extra)
    $payload = [ordered]@{
        schemaVersion = 1
        phase         = $Phase
        status        = $Status
        message       = $Message
        startedAt     = $startedAt.ToString('o')
        finishedAt    = [DateTimeOffset]::UtcNow.ToString('o')
        steps         = $steps
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] } }
    $dir = Split-Path -Parent $ResultPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
}

function Get-SimulatorSnapshot {
    (Invoke-WebRequest -Uri "http://127.0.0.1:$SimulatorPort/api/v1/snapshot" -TimeoutSec 20).Content |
        ConvertFrom-Json
}

# Every mutating call carries three things the simulator refuses without, and it
# refuses them one at a time: runId (its own, not ours), commandId, and
# expectedRevision. The revision is optimistic concurrency, so it is read fresh
# immediately before the call rather than cached.
function Invoke-SimulatorCommand {
    param([string] $Method, [string] $Path, [hashtable] $Extra)

    $snapshot = Get-SimulatorSnapshot
    $body = @{
        runId            = $snapshot.runId
        commandId        = [guid]::NewGuid().ToString('D')
        expectedRevision = $snapshot.revision
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] } }
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$SimulatorPort/api/v1$Path" -Method $Method `
        -Body ($body | ConvertTo-Json -Compress) -ContentType 'application/json' `
        -TimeoutSec 20 -SkipHttpErrorCheck
    if ([int]$r.StatusCode -ge 400) { throw "$Method $Path -> HTTP $($r.StatusCode): $($r.Content)" }
}

$onboardBase = "http://127.0.0.1:$AutomationPort/api/v1"

# The single most likely failure here is not a bug: 06-deploy-onboard-hmi.ps1
# renders appsettings.json from the production template on every deployment, and
# the template ships the face off. Say so rather than reporting a bare refused
# connection.
function Get-OnboardSnapshot {
    try {
        $r = Invoke-WebRequest -Uri "$onboardBase/snapshot" -TimeoutSec 20 -SkipHttpErrorCheck
    } catch {
        throw ("The onboard automation face at $onboardBase is not answering ($($_.Exception.Message)). " +
            'It stays off until appsettings.json carries automation.enabled true AND a non-placeholder ' +
            'automation.productionReviewReference -- and a deployment resets both.')
    }
    if ([int]$r.StatusCode -ge 400) { throw "GET /snapshot -> HTTP $($r.StatusCode): $($r.Content)" }
    $r.Content | ConvertFrom-Json
}

# Same three-field envelope as the simulator, for the same reasons: runId is the
# face's own, and expectedRevision is optimistic concurrency read fresh right
# before the call.
#
# Unlike the simulator, this revision fingerprints the whole vehicle snapshot --
# every slot's IO, the session, the worklist -- so it can move between the read
# and the post even while nobody is doing anything. REVISION_CONFLICT is the
# face telling us to read again, not a failure, so retry it. A new commandId per
# attempt, because the cached fingerprint includes expectedRevision and reusing
# the id would come back COMMAND_ID_CONFLICT. Retrying cannot double-submit: we
# only retry on a response that says the submit was refused.
function Invoke-OnboardSubmit {
    param([string] $Sublot, [int] $Attempts = 4)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $snapshot = Get-OnboardSnapshot
        $body = @{
            runId            = $snapshot.runId
            commandId        = [guid]::NewGuid().ToString('D')
            expectedRevision = $snapshot.revision
            sublot           = $Sublot
        }
        $r = Invoke-WebRequest -Uri "$onboardBase/sublots/submit" -Method POST `
            -Body ($body | ConvertTo-Json -Compress) -ContentType 'application/json' `
            -TimeoutSec 30 -SkipHttpErrorCheck
        $payload = $r.Content | ConvertFrom-Json

        if ([int]$r.StatusCode -lt 400 -and $payload.accepted) { return $payload }

        $reason = $payload.reasonCode ?? "HTTP $($r.StatusCode)"
        if ($reason -eq 'REVISION_CONFLICT' -and $attempt -lt $Attempts) {
            Add-Step 'revision-conflict' "attempt $attempt saw revision $($body.expectedRevision); re-reading"
            continue
        }
        throw "POST /sublots/submit refused: $reason $($payload.message)".Trim()
    }
}

function Wait-For {
    param([string] $Description, [scriptblock] $Probe)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $value = & $Probe
        if ($value) { return $value }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Timed out after ${TimeoutSeconds}s waiting for: $Description" }
        Start-Sleep -Milliseconds 500
    }
}

try {
    if ($Phase -eq 'Scan') {
        if (-not $Sublot) { throw 'Scan phase needs -Sublot.' }

        $snapshot = Get-OnboardSnapshot
        Add-Step 'attach' "automation face runId $($snapshot.runId), agvId $($snapshot.agvId)"

        # canSubmitSublot is WireToGateBusinessService.CanSubmitSublot -- the
        # same fact the scan box's IsEnabled used to stand for, read from the
        # source instead of from a control's visual state. So this still
        # replaces "an operator noticed the prompt", and it no longer breaks if
        # somebody renames a control.
        $ready = Wait-For 'the server to ask for a sublot (canSubmitSublot)' {
            $s = Get-OnboardSnapshot
            $s.state.canSubmitSublot ? $s : $null
        }
        # Recorded, not asserted: this file drives and never judges, and the
        # caller already takes the sublot from the server's own request. A
        # mismatch here is worth seeing in the evidence afterwards.
        Add-Step 'can-submit' "expectedSublot=$($ready.state.expectedSublot ?? '(none)') typed=$Sublot"

        $submit = Invoke-OnboardSubmit -Sublot $Sublot
        Add-Step 'submitted' "messageId=$($submit.messageId) replayed=$($submit.replayed) revision=$($submit.revision)"

        Write-Result 'OK' "Sublot $Sublot submitted." @{
            sublot           = $Sublot
            expectedSublot   = $ready.state.expectedSublot
            messageId        = $submit.messageId
            automationRunId  = $submit.runId
        }
    } else {
        if ($SlotNo -lt 1) { throw 'Operator phase needs -SlotNo.' }

        # The caller only gets here after the server reported WAITING_OPERATOR,
        # so the client has already watched the door open and settle. Confirming
        # the door is open is a sanity check, not the trigger.
        $slot = Wait-For "slot $SlotNo to be open" {
            $s = @((Get-SimulatorSnapshot).slots | Where-Object { [int]$_.slotNo -eq $SlotNo })[0]
            $s -and $s.doorState -eq 'OPEN' ? $s : $null
        }
        Add-Step 'door-open' "slot $SlotNo (cargo=$($slot.cargoState))"

        Invoke-SimulatorCommand PUT "/slots/$SlotNo/cargo" @{ state = $CargoState }

        # The client reads the raw light curtain, not the simulator's logical
        # cargoState, and the simulator models the feedback delay between them.
        # Closing the door before the curtain settles leaves cargoState=OCCUPIED
        # with lightCurtainRaw=0 -- the slot the client sees is empty, and the
        # load comes back LOAD_RESULT_REQUIRES_RECOVERY. The runs driven by hand
        # never hit this because each step was its own ssh round trip; the script
        # issues both calls inside one session and is fast enough to race it.
        # Do NOT test the raw level against a hard-coded 1. ObstructedActiveLevel
        # is per-slot configuration, so the polarity is not a contract -- the
        # first attempt asserted lightCurtainRaw == 1 for OCCUPIED and waited out
        # its whole timeout on a slot that was correctly obstructed at 0. What is
        # polarity-independent is the simulator's own consistency check: it
        # reports LIGHT_CURTAIN_MISMATCH while CargoPresent and IsObstructed
        # disagree, so the absence of that fault with the feedback settled is
        # exactly "the curtain now reflects the cargo".
        $settledCargo = Wait-For "the light curtain to catch up with cargo=$CargoState" {
            $s = @((Get-SimulatorSnapshot).slots | Where-Object { [int]$_.slotNo -eq $SlotNo })[0]
            ($s.cargoState -eq $CargoState -and -not $s.lightCurtainFeedbackPending -and
                $s.faults -notcontains 'LIGHT_CURTAIN_MISMATCH') ? $s : $null
        }
        Add-Step 'cargo' "slot $SlotNo set to $CargoState (lightCurtainRaw=$($settledCargo.lightCurtainRaw), settled)"

        Invoke-SimulatorCommand POST "/slots/$SlotNo/close-door" $null
        Add-Step 'door-closed' "slot $SlotNo"

        # Closed AND locked, with both feedbacks settled: that is the state the
        # server checks for (lockState LOCKED, unlockOutputState RESET), so
        # returning before it is reached would report success too early.
        # Same reasoning as the curtain: LockedActiveLevel is configuration, so
        # the settled feedback and the absence of LOCK_FEEDBACK_MISMATCH are what
        # can be asserted. unlockOutputRaw is a real 0/1 -- it is the output this
        # side drives, not a configurable input level.
        $settled = Wait-For 'the door to read closed with the lock feedback settled' {
            $s = @((Get-SimulatorSnapshot).slots | Where-Object { [int]$_.slotNo -eq $SlotNo })[0]
            ($s.doorState -eq 'CLOSED' -and -not $s.lockFeedbackPending -and
                $s.faults -notcontains 'LOCK_FEEDBACK_MISMATCH' -and
                [int]$s.unlockOutputRaw -eq 0) ? $s : $null
        }
        Add-Step 'settled' "door=$($settled.doorState) cargo=$($settled.cargoState)"

        Write-Result 'OK' "Slot $SlotNo closed with cargo=$($settled.cargoState)." @{
            slotNo = $SlotNo; finalSlot = $settled
        }
    }
} catch {
    Add-Step 'failed' $_.Exception.Message
    Write-Result 'FAILED' $_.Exception.Message @{ errorType = $_.Exception.GetType().FullName }
    exit 1
}
