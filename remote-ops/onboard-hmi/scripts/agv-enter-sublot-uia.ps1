#Requires -Version 7
<#
.SYNOPSIS
    Types one sublot into the v2 onboard HMI's loading entry through UI Automation and
    presses 「手动提交」 once. Runs ON the vehicle, inside the interactive desktop session.
    Deployed and launched by 16-enter-sublot-uia.ps1 on the control host.

.DESCRIPTION
    Test tooling only. It is never part of an onboard package and nothing starts it but an
    explicit 16-enter-sublot-uia.ps1 call.

    Why UI Automation and not the onboard automation face (POST 127.0.0.1:58007): the v2
    client refuses to start that face under environment=Production, with no exemption
    (SQCD.Agv.Infrastructure Configuration.cs), and the field vehicles run Production. Typing
    through the window is the one path that leaves the client's configuration untouched.

    The driver is a trimmed copy of New-L2OnboardDriver and Invoke-L2SublotEntry in
    8005-agv-control-server scripts/l2 (L2.psm1, MultiStopRigCommon.ps1): ValuePattern.SetValue on
    ScanTextBox and InvokePattern on 「手动提交」, both of which work on an unfocused window, then a
    read-back before submitting. The server records the entry as KEYBOARD, the same as a person
    pressing 「手动提交」; the protocol has no value for "automated", so the result file is what
    marks the entry as automatic.

    Three rules, each covered by 16-enter-sublot-uia.ps1 -SelfTest:
      * The box must read back exactly the sublot before anything is submitted. A mismatch is
        retyped at most MaxRetypes times; after that nothing is submitted.
      * Submit is pressed exactly once. What the product does with it -- accept or refuse -- is
        the product's answer and is never retried here.
      * The input must be open (CanSubmit) before typing; typing into a closed box is a timing
        error of this tool, not something to force.

    Writes a JSON result to -ResultPath whatever happens, so the control host never has to
    guess from silence, and exits non-zero unless the sublot was submitted: 0 submitted,
    2 not submitted (INPUT_NOT_OPEN, READBACK_MISMATCH), 1 error (no HMI process, no scan box).

    No keyboard input, no focus, no foreground (8005-workspace#20). Every write goes through a
    UIA pattern on an element found under the HMI process's own window, so nothing can land in
    another window, whatever is in the foreground. When the HMI or its scan box is not there the
    script fails without writing anything. 16-enter-sublot-uia.ps1 -SelfTest scans this file for
    keyboard, focus and foreground APIs and fails if one appears.
#>
param(
    [string] $Sublot,
    [string] $ResultPath,
    [int] $MaxRetypes = 2,
    [int] $WaitSeconds = 60,
    [string] $ProcessName = 'SQCD.Agv.Wpf'
)

$ErrorActionPreference = 'Stop'

function New-OnboardUiaDriver {
    param(
        [Parameter(Mandatory)][int] $ProcessId,
        [string] $ScanTextBoxAutomationId = 'ScanTextBox',
        [string] $SubmitButtonName = '手动提交'
    )
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $driver = [pscustomobject]@{
        ProcessId               = $ProcessId
        ScanTextBoxAutomationId = $ScanTextBoxAutomationId
        SubmitButtonName        = $SubmitButtonName
        Window                  = $null
    }
    # The main window is the one carrying the scan box, not whatever top-level window the
    # process shows first: a startup MessageBox would otherwise be adopted (see L2.psm1).
    $driver | Add-Member -MemberType ScriptMethod -Name Attach -Value {
        param([int] $TimeoutSeconds = 30)
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($true) {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $this.ProcessId)
            foreach ($window in [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Children, $condition)) {
                $this.Window = $window
                if ($this.Element('AutomationId', $this.ScanTextBoxAutomationId)) { return $window.Current.Name }
                $this.Window = $null
            }
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw "No window of pid $($this.ProcessId) carried '$($this.ScanTextBoxAutomationId)' within ${TimeoutSeconds}s."
            }
            Start-Sleep -Milliseconds 250
        }
    }
    $driver | Add-Member -MemberType ScriptMethod -Name Element -Value {
        param([string] $By, [string] $Value)
        if (-not $this.Window) { throw 'Attach() has not run yet.' }
        $property = if ($By -eq 'AutomationId') {
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty
        } else {
            [System.Windows.Automation.AutomationElement]::NameProperty
        }
        return $this.Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new($property, $Value))
    }
    $driver | Add-Member -MemberType ScriptMethod -Name CanSubmit -Value {
        $box = $this.Element('AutomationId', $this.ScanTextBoxAutomationId)
        return [bool]($box -and $box.Current.IsEnabled)
    }
    $driver | Add-Member -MemberType ScriptMethod -Name SubmitReady -Value {
        $button = $this.Element('Name', $this.SubmitButtonName)
        return [bool]($button -and $button.Current.IsEnabled)
    }
    $driver | Add-Member -MemberType ScriptMethod -Name SetSublot -Value {
        param([Parameter(Mandatory)][string] $Text)
        $box = $this.Element('AutomationId', $this.ScanTextBoxAutomationId)
        if (-not $box) { throw "No element with AutomationId '$($this.ScanTextBoxAutomationId)'." }
        $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Text)
    }
    $driver | Add-Member -MemberType ScriptMethod -Name ScanText -Value {
        $box = $this.Element('AutomationId', $this.ScanTextBoxAutomationId)
        if (-not $box) { return $null }
        return $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    }
    $driver | Add-Member -MemberType ScriptMethod -Name Submit -Value {
        $button = $this.Element('Name', $this.SubmitButtonName)
        if (-not $button) { throw "No button named '$($this.SubmitButtonName)'." }
        $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    return $driver
}

function Wait-Until {
    param([scriptblock] $Probe, [int] $TimeoutSeconds, [int] $IntervalMilliseconds = 250)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (& $Probe)) {
        if ([DateTimeOffset]::UtcNow -ge $deadline) { return $false }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
    return $true
}

<#
    Types, reads back, and submits once. Returns a record of what happened; never throws for a
    read-back mismatch (that is reported as Submitted = $false with the readings).
    $Driver only needs CanSubmit, SubmitReady, SetSublot, ScanText and Submit, so the self-test
    drives it with a stand-in.
#>
function Invoke-SublotEntry {
    param(
        [Parameter(Mandatory)][object] $Driver,
        [Parameter(Mandatory)][string] $Sublot,
        [int] $MaxRetypes = 2,
        [int] $WaitSeconds = 60
    )
    $readings = [System.Collections.Generic.List[string]]::new()
    if (-not (Wait-Until -Probe { $Driver.CanSubmit() } -TimeoutSeconds $WaitSeconds)) {
        return [pscustomobject]@{ Submitted = $false; Outcome = 'INPUT_NOT_OPEN'; Typings = 0; ReadBack = $null; Readings = @() }
    }
    for ($typing = 1; $typing -le 1 + $MaxRetypes; $typing++) {
        $Driver.SetSublot($Sublot)
        $text = $Driver.ScanText()
        if ($text -cne $Sublot) { $readings.Add("typing $typing after-type '$text'"); continue }
        if (-not (Wait-Until -Probe { $Driver.SubmitReady() } -TimeoutSeconds 15)) {
            $readings.Add("typing $typing submit-not-ready")
            continue
        }
        $text = $Driver.ScanText()
        if ($text -cne $Sublot) { $readings.Add("typing $typing before-submit '$text'"); continue }
        $submittedAt = [DateTimeOffset]::Now
        $Driver.Submit()
        return [pscustomobject]@{
            Submitted = $true; Outcome = 'SUBMITTED_ONCE'; Typings = $typing; ReadBack = $text
            SubmittedAt = $submittedAt.ToString('o'); Readings = @($readings)
        }
    }
    return [pscustomobject]@{ Submitted = $false; Outcome = 'READBACK_MISMATCH'; Typings = 1 + $MaxRetypes; ReadBack = $null; Readings = @($readings) }
}

<#
    The process exit code for a result: 0 only when the sublot was submitted, so a scheduled task
    result of 0x0 can no longer mean "nothing was entered".
#>
function Get-EntryExitCode {
    param([System.Collections.IDictionary] $Result)
    if ($Result.submitted -eq $true) { return 0 }
    if ($Result.outcome -eq 'ERROR') { return 1 }
    return 2
}

# Dot-sourced by the self-test: define the functions and stop.
if ($MyInvocation.InvocationName -eq '.') { return }

$result = [ordered]@{
    autoEntered = $true
    method      = 'UIA'
    host        = $env:COMPUTERNAME
    sessionId   = (Get-Process -Id $PID).SessionId
    sublot      = $Sublot
    startedAt   = [DateTimeOffset]::Now.ToString('o')
}
try {
    if ([string]::IsNullOrWhiteSpace($Sublot) -or [string]::IsNullOrWhiteSpace($ResultPath)) { throw '-Sublot and -ResultPath are required.' }
    $process = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object SessionId -eq $result.sessionId)
    if ($process.Count -ne 1) { throw "Expected one $ProcessName in session $($result.sessionId), found $($process.Count)." }
    $driver = New-OnboardUiaDriver -ProcessId $process[0].Id
    $result.window = $driver.Attach(30)
    $entry = Invoke-SublotEntry -Driver $driver -Sublot $Sublot -MaxRetypes $MaxRetypes -WaitSeconds $WaitSeconds
    $result.submitted = $entry.Submitted
    $result.outcome = $entry.Outcome
    $result.typings = $entry.Typings
    $result.readBack = $entry.ReadBack
    $result.submittedAt = $entry.SubmittedAt
    $result.readings = $entry.Readings
} catch {
    $result.submitted = $false
    $result.outcome = 'ERROR'
    $result.error = $_.Exception.Message
}
$result.finishedAt = [DateTimeOffset]::Now.ToString('o')
$result | ConvertTo-Json -Depth 4 -EscapeHandling EscapeNonAscii | Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
exit (Get-EntryExitCode $result)
