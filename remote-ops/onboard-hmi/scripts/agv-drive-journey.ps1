#Requires -Version 7
<#
.SYNOPSIS
    Plays the operator's part of one WIRE_TO_GATE station operation. Runs ON the
    vehicle, inside the interactive desktop session. Deployed and launched by
    11-drive-journey.ps1 on the control host.

.DESCRIPTION
    Two things have to happen on the vehicle itself, and that is the whole reason
    this file exists rather than being part of the control-host script:

      * the scan goes through UI Automation, which can only see a window in its
        own desktop session -- session 1 here, where the WPF client runs;
      * the slot simulator's automation plane binds 127.0.0.1 on purpose, so the
        cargo and door calls have to originate on this machine.

    The onboard client also ships an automation HTTP plane that would make the
    scan a one-line POST. It is NOT used: turning it on
    (`automation.enabled = true`) hangs the client at startup -- the process
    lives, no window is ever created and not one log line is written. Verified
    on agv01, 2026-09-07. UI Automation is the route that works today.

    The UIA driver is lifted from New-L2OnboardDriver in the ControlServer
    repository's scripts/l2/L2.psm1. It is duplicated rather than shared because
    the two repositories have no common package, and because the contract here is
    the control names (`ScanTextBox`, 「手动提交」), not the code.

    Driving only, never asserting. The one thing read back from the UI is whether
    input is accepted yet, which is a precondition for typing rather than a
    business fact. What the run proves is read from the server's database and the
    simulator's snapshot, by the caller.

.PARAMETER Sublot
    What to type. The caller reads it from the server's own SublotEntryRequested
    rather than having this script guess.

.PARAMETER CargoState
    OCCUPIED completes the load. EMPTY closes the door on an empty slot, which is
    the honest way to reproduce a failed load.

.PARAMETER ResultPath
    Where to write the machine-readable outcome. The caller polls this file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Sublot,
    [ValidateSet('OCCUPIED', 'EMPTY')]
    [string] $CargoState = 'OCCUPIED',
    [Parameter(Mandatory)][string] $ResultPath,
    [int] $SimulatorPort = 58006,
    [int] $TimeoutSeconds = 240,
    [string] $ScanTextBoxAutomationId = 'ScanTextBox',
    [string] $SubmitButtonName = '手动提交'
)

$ErrorActionPreference = 'Stop'
$steps = [System.Collections.Generic.List[object]]::new()
$startedAt = [DateTimeOffset]::UtcNow

function Add-Step {
    param([string] $Name, [string] $Detail)
    $steps.Add([pscustomobject]@{
        at     = [DateTimeOffset]::UtcNow.ToString('o')
        step   = $Name
        detail = $Detail
    })
}

function Write-Result {
    param([string] $Status, [string] $Message, $Extra)
    $payload = [ordered]@{
        schemaVersion = 1
        status        = $Status
        message       = $Message
        sublot        = $Sublot
        cargoState    = $CargoState
        startedAt     = $startedAt.ToString('o')
        finishedAt    = [DateTimeOffset]::UtcNow.ToString('o')
        steps         = $steps
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] } }
    $dir = Split-Path -Parent $ResultPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
}

function Invoke-Simulator {
    param([string] $Method, [string] $Path, $Body)
    $args = @{
        Uri                = "http://127.0.0.1:$SimulatorPort/api/v1$Path"
        Method             = $Method
        TimeoutSec         = 20
        SkipHttpErrorCheck = $true
    }
    if ($Body) { $args.Body = ($Body | ConvertTo-Json -Compress); $args.ContentType = 'application/json' }
    $r = Invoke-WebRequest @args
    if ([int]$r.StatusCode -ge 400) { throw "$Method $Path -> HTTP $($r.StatusCode): $($r.Content)" }
    return $r.Content | ConvertFrom-Json
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
    # --- attach to the client's window -----------------------------------
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

    $client = Get-Process -Name 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue
    if (-not $client) { throw 'The onboard client is not running on this vehicle.' }
    if ($client.Count -gt 1) { throw "More than one onboard client is running ($($client.Count))." }
    $processId = $client.Id
    Add-Step 'attach' "client pid $processId"

    # Attaching to *a* top-level window is not enough: when startup fails the
    # only window is a modal MessageBox, and adopting it would make every later
    # wait time out on a criterion that says nothing about the real error. The
    # main window is identified by the control this script needs.
    $window = $null
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $null = Wait-For 'the client window carrying the scan box' {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $processId)
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $condition)
        foreach ($w in $windows) {
            $null = $seen.Add($w.Current.Name)
            $box = $w.FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                    $ScanTextBoxAutomationId))
            if ($box) { $script:window = $w; return $true }
        }
        return $false
    }
    $window = $script:window
    Add-Step 'window' "title '$($window.Current.Name)' (seen: $($seen -join ' / '))"

    function Get-Element {
        param([string] $By, [string] $Value)
        $property = $By -eq 'AutomationId' `
            ? [System.Windows.Automation.AutomationElement]::AutomationIdProperty `
            : [System.Windows.Automation.AutomationElement]::NameProperty
        return $window.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new($property, $Value))
    }

    # --- 1. the scan ------------------------------------------------------
    # The text box is enabled exactly when WireToGateBusinessService.CanSubmitSublot
    # is true, so this wait is what replaces "an operator noticed the prompt".
    $null = Wait-For 'the server to ask for a sublot (scan box enabled)' {
        $box = Get-Element 'AutomationId' $ScanTextBoxAutomationId
        $box -and $box.Current.IsEnabled
    }
    Add-Step 'can-submit' 'scan box is enabled'

    $box = Get-Element 'AutomationId' $ScanTextBoxAutomationId
    $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Sublot)
    Add-Step 'typed' $Sublot

    # The button additionally requires non-empty text, which is why setting and
    # invoking are separate steps with a wait between them.
    $null = Wait-For 'the submit button to become enabled' {
        $b = Get-Element 'Name' $SubmitButtonName
        $b -and $b.Current.IsEnabled
    }
    (Get-Element 'Name' $SubmitButtonName).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Add-Step 'submitted' "clicked $SubmitButtonName"

    # --- 2. the operator's hands -----------------------------------------
    # Which slot? Ask the simulator: the door the client opened is the fact.
    # Exactly one door opens per operation.
    $slotNo = Wait-For 'the client to open a slot door' {
        $open = @((Invoke-Simulator GET '/snapshot').slots | Where-Object { $_.doorState -eq 'OPEN' })
        $open.Count -eq 1 ? [int]$open[0].slotNo : $null
    }
    Add-Step 'door-open' "slot $slotNo"

    if ($CargoState -eq 'OCCUPIED') {
        $null = Invoke-Simulator PUT "/slots/$slotNo/cargo" @{
            commandId = [guid]::NewGuid().ToString('D'); state = 'OCCUPIED'
        }
        Add-Step 'cargo' "placed in slot $slotNo"
    } else {
        Add-Step 'cargo' "left slot $slotNo empty on purpose"
    }

    $null = Invoke-Simulator POST "/slots/$slotNo/close-door" @{
        commandId = [guid]::NewGuid().ToString('D')
    }
    Add-Step 'door-closed' "slot $slotNo"

    # --- 3. let the client finish ----------------------------------------
    # A failed load is not reported until the client runs out its own operator
    # timeout (workflow.operationTimeoutMs, 120 s on this deployment), so this
    # wait is deliberately longer than the happy path needs.
    $settled = Wait-For 'the slot to come to rest (door closed, lock reported)' {
        $slot = @((Invoke-Simulator GET '/snapshot').slots | Where-Object { [int]$_.slotNo -eq $slotNo })[0]
        $slot.doorState -eq 'CLOSED' ? $slot : $null
    }
    Add-Step 'settled' "door=$($settled.doorState) cargo=$($settled.cargoState)"

    Write-Result 'OK' "Sublot $Sublot submitted; slot $slotNo closed with cargo=$($settled.cargoState)." @{
        slotNo     = $slotNo
        finalSlot  = $settled
        clientPid  = $processId
    }
} catch {
    Add-Step 'failed' $_.Exception.Message
    Write-Result 'FAILED' $_.Exception.Message @{ errorType = $_.Exception.GetType().FullName }
    exit 1
}
