#Requires -Version 7
<#
.SYNOPSIS
    Read-only look at what a spare vehicle's onboard HMI screen shows: a screenshot, one image per HMI
    window, and the UI Automation tree with its visible text as JSON. workspace#16.

.DESCRIPTION
    Runs on the control host. In order:

      1. Preflight over SSH (session 0, read-only): is someone logged on at the console, is the
         desktop locked, is the onboard client running, is Windows Script Host usable, are there
         capture tasks left over from an earlier run.
      2. Copies agv-capture-hmi-screen.ps1 to C:\8005\capture\<runId> and runs it in the logged-on
         user's desktop session through a one-shot Interactive scheduled task, started hidden through
         wscript (window style 0) so nothing appears on the operator's screen and the foreground
         window does not change. The task is unregistered right after it starts.
      3. Waits for the vehicle-side JSON, copies the run directory back with scp, keeps the JSON and
         the PNGs in -EvidenceDirectory, deletes the run directory on the vehicle, and checks that no
         capture task is left registered.

    Read-only. It never clicks, types, focuses, switches windows, or starts or stops the onboard
    stack; the vehicle half only reads pixels and UIA properties (the self-test scans it for any call
    that would act). It moves nothing, so it needs no per-run authorization -- but agv02/agv03 only:
    agv01 is the production vehicle, and touching it needs the user first (Ask first, category 2).

    It never retries. Every run ends in one outcome code (exit code in brackets):

      CAPTURED [0]               screenshot, window images and UIA text all present
      HMI_NOT_RUNNING [2]        no onboard client in the console session; the desktop was still captured
      DESKTOP_LOCKED [3]         lock screen up; whatever could be read is kept (UIA usually is)
      SCREEN_BLANK [4]           the screenshot is one flat colour
      NO_INTERACTIVE_SESSION [5] nobody logged on at the console; nothing was launched
      TIMEOUT [6]                no result within -TimeoutSeconds
      PARTIAL [7]                ran, but an image or the UIA tree is missing (see errors in the JSON)
      FOCUS_DISTURBED [8]        the capture itself held the foreground; a defect of this tool
      WSH_DISABLED [9]           Windows Script Host is disabled; nothing was launched
      tool failure [1]           SSH, scp or the launch failed

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/17-capture-hmi-screen.ps1 -SshAlias agv02 -EvidenceDirectory evidence/field/<dir>

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/17-capture-hmi-screen.ps1 -SelfTest
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateSet('agv02', 'agv03', ErrorMessage = "'{0}' is refused. Only the spare vehicles agv02 and agv03; agv01 is production and needs the user first (Ask first, category 2).")]
    [string] $SshAlias,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string] $EvidenceDirectory,
    [Parameter(ParameterSetName = 'Run')][int] $TimeoutSeconds = 90,
    [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
$vehicleScript = Join-Path $PSScriptRoot 'agv-capture-hmi-screen.ps1'
$vehicleBase = 'C:\8005\capture'
$taskPrefix = 'W2G-CaptureHmi-'

$exitCodes = [ordered]@{
    CAPTURED = 0; HMI_NOT_RUNNING = 2; DESKTOP_LOCKED = 3; SCREEN_BLANK = 4; NO_INTERACTIVE_SESSION = 5
    TIMEOUT = 6; PARTIAL = 7; FOCUS_DISTURBED = 8; WSH_DISABLED = 9; TOOL_FAILURE = 1
}

<#
    The run's outcome from what the preflight saw and what the vehicle half wrote. Pure, so -SelfTest
    covers it. A focus disturbance outranks everything the vehicle reported: it means this tool touched
    the screen, which is the one thing it promises not to do.
#>
function Get-CaptureOutcome {
    param([object] $Preflight, [object] $Vehicle, [bool] $TimedOut)
    if (-not $Preflight.consoleSessionId) { return 'NO_INTERACTIVE_SESSION' }
    if ($Preflight.wshDisabled) { return 'WSH_DISABLED' }
    if ($TimedOut -or -not $Vehicle) { return 'TIMEOUT' }
    if ($Vehicle.focusDisturbed) { return 'FOCUS_DISTURBED' }
    if ($Vehicle.desktop.locked) { return 'DESKTOP_LOCKED' }
    if (-not $Vehicle.hmi.running) { return 'HMI_NOT_RUNNING' }
    if ($Vehicle.screenUniform) { return 'SCREEN_BLANK' }
    $windowImages = @($Vehicle.images | Where-Object { $_.kind -eq 'window' })
    if (@($Vehicle.errors).Count -or $null -eq $Vehicle.screenUniform -or $windowImages.Count -eq 0 -or -not $Vehicle.uiaNodeCount) { return 'PARTIAL' }
    return 'CAPTURED'
}

<# Preflight, run in session 0 over SSH. Reads only; prints one line of JSON. #>
function New-PreflightScript {
    param([string] $ProcessName = 'SQCD.Agv.Wpf')
    return @"
`$ErrorActionPreference = 'Stop'
`$console = (query session 2>&1 | Select-String -Pattern '^\s*>?console\s+(\S+)\s+(\d+)\s+Active').Matches
`$user = if (`$console) { `$console[0].Groups[1].Value } else { `$null }
`$sid = if (`$console) { [int] `$console[0].Groups[2].Value } else { `$null }
# Windows Script Host can be switched off machine-wide or per user; wscript then shows a dialog, which
# would land on the operator's screen. 0 under either key means off.
`$wsh = @((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' -ErrorAction SilentlyContinue).Enabled)
if (`$user) {
    try {
        `$userSid = ([System.Security.Principal.NTAccount]::new(`$user)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        `$wsh += (Get-ItemProperty -Path "Registry::HKEY_USERS\`$userSid\Software\Microsoft\Windows Script Host\Settings" -ErrorAction SilentlyContinue).Enabled
    } catch { }
}
[pscustomobject]@{
    consoleUser      = `$user
    consoleSessionId = `$sid
    logonUi          = [bool] @(Get-Process -Name LogonUI -ErrorAction SilentlyContinue | Where-Object SessionId -eq `$sid).Count
    hmiPids          = @(Get-Process -Name '$ProcessName' -ErrorAction SilentlyContinue | Where-Object SessionId -eq `$sid | ForEach-Object { `$_.Id })
    wshDisabled      = [bool] @(`$wsh | Where-Object { `$null -ne `$_ -and "`$_" -eq '0' }).Count
    leftoverTasks    = @(Get-ScheduledTask -TaskName '$taskPrefix*' -ErrorAction SilentlyContinue | ForEach-Object { `$_.TaskName })
    vehicleClock     = [DateTimeOffset]::Now.ToString('o')
} | ConvertTo-Json -Compress
"@
}

<#
    The VBScript the task runs: starts pwsh with window style 0 (hidden, not activated) and waits for it.
    A task that ran pwsh.exe directly would open a console window on the operator's screen and take
    the foreground. ASCII only: wscript reads the file in the ANSI code page.
#>
function New-HiddenRunner {
    param([string] $RunDirectory, [string] $Name)
    # VBScript doubles a quote inside a string literal.
    $q = '""'
    $command = "pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $q$RunDirectory\agv-capture-hmi-screen.ps1$q -OutputDirectory $q$RunDirectory$q -Stamp $q$Name$q"
    return 'CreateObject("WScript.Shell").Run "' + $command + '", 0, True' + "`r`n"
}

<#
    Registers and starts the one-shot Interactive task, then unregisters it whatever happens. Run on the
    vehicle with -File, never piped to `pwsh -Command -` (that mode silently drops a trailing multi-line
    block; 16-enter-sublot-uia.ps1, 2026-10-10). Its last line is LAUNCH_DONE.
#>
function New-LaunchScript {
    param([string] $RunDirectory, [string] $RunId)
    $taskName = "$taskPrefix$RunId"
    return @"
`$ErrorActionPreference = 'Stop'
try {
    `$console = (query session 2>&1 | Select-String -Pattern '^\s*>?console\s+(\S+)\s+(\d+)\s+Active').Matches
    if (-not `$console) { throw 'No active console session on this vehicle.' }
    `$action = New-ScheduledTaskAction -Execute "`$env:SystemRoot\System32\wscript.exe" -Argument '//B //Nologo "$RunDirectory\hidden-$RunId.vbs"' -WorkingDirectory '$RunDirectory'
    `$principal = New-ScheduledTaskPrincipal -UserId `$console[0].Groups[1].Value -LogonType Interactive -RunLevel Limited
    `$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
    try {
        Register-ScheduledTask -TaskName '$taskName' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
        Start-ScheduledTask -TaskName '$taskName'
        Start-Sleep -Seconds 3
        `$info = Get-ScheduledTaskInfo -TaskName '$taskName'
        'TASK_STARTED lastRunTime={0} lastTaskResult=0x{1:X}' -f `$info.LastRunTime, `$info.LastTaskResult
    } finally {
        Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
}
'LAUNCH_DONE'
"@
}

<#
    Whether the launch output proves the task started: the end marker and a TASK_STARTED line whose
    LastTaskResult is 0x41301 (running) or 0x0 (already finished).
#>
function Test-LaunchOutput {
    param([string[]] $Output)
    $text = $Output -join "`n"
    return ($text -match '(?m)^LAUNCH_DONE\s*$') -and ($text -match 'TASK_STARTED .*lastTaskResult=0x(41301|0)\b')
}

<# Calls the vehicle half would need to act on the screen. None may appear in it. #>
$forbiddenInVehicleScript = @(
    'SetFocus', 'SetForegroundWindow', 'SetActiveWindow', 'BringWindowToTop', 'ShowWindow', 'SwitchToThisWindow',
    'SendInput', 'keybd_event', 'mouse_event', 'SetCursorPos', 'PostMessage', 'SendMessage', 'SendKeys',
    'InvokePattern', 'SelectionItemPattern', 'ExpandCollapsePattern', 'WindowPattern', 'TransformPattern',
    '.SetValue(', '.Invoke()', '.Toggle()', '.Select()', '.Expand()', '.Close()',
    'Stop-Process', 'Start-Process', '.Kill(', 'CloseMainWindow', 'Restart-'
)

function Invoke-SelfTest {
    $failures = [System.Collections.Generic.List[string]]::new()
    function Check([string] $Name, [scriptblock] $Body) {
        try { & $Body; "PASS $Name" } catch { $failures.Add($Name); "FAIL $Name -- $($_.Exception.Message)" }
    }

    Check 'both scripts parse with zero errors' {
        foreach ($path in @($PSCommandPath, $vehicleScript)) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $errors)
            if ($errors.Count -ne 0) { throw "$path : $($errors[0].Message)" }
        }
    }
    Check 'neither script carries a control character' {
        foreach ($path in @($PSCommandPath, $vehicleScript)) {
            $bad = @([System.IO.File]::ReadAllBytes($path) | Where-Object { $_ -lt 32 -and $_ -notin 9, 10, 13 })
            if ($bad.Count -ne 0) { throw "$path carries $($bad.Count) control character(s)" }
        }
    }
    Check 'the vehicle half calls nothing that acts on the screen' {
        $text = [System.IO.File]::ReadAllText($vehicleScript)
        $hits = @($forbiddenInVehicleScript | Where-Object { $text.Contains($_) })
        if ($hits.Count) { throw "found: $($hits -join ', ')" }
    }
    Check 'the vehicle half imports only reading Win32 calls' {
        $allowed = 'EnumWindows', 'GetWindowThreadProcessId', 'IsWindowVisible', 'IsIconic', 'GetWindowText', 'GetClassName',
            'GetWindowRect', 'GetWindow', 'GetForegroundWindow', 'PrintWindow', 'SetProcessDpiAwarenessContext',
            'OpenInputDesktop', 'CloseDesktop', 'GetUserObjectInformation', 'GetSystemMetrics'
        $imported = [regex]::Matches([System.IO.File]::ReadAllText($vehicleScript), '(?s)\[DllImport\([^\]]*\]\s*static extern \S+ (\w+)\(') | ForEach-Object { $_.Groups[1].Value }
        $extra = @($imported | Where-Object { $_ -notin $allowed })
        if ($extra.Count) { throw "not on the reading list: $($extra -join ', ')" }
        if (@($imported).Count -lt 10) { throw "only $(@($imported).Count) imports found; the scan is not reading the file" }
    }
    Check 'the forbidden-call scan would catch an Invoke' {
        $probe = '$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()'
        if (-not @($forbiddenInVehicleScript | Where-Object { $probe.Contains($_) }).Count) { throw 'scan missed it' }
    }
    Check 'agv01 is refused before anything runs' {
        $out = & pwsh -NoProfile -File $PSCommandPath -SshAlias agv01 -EvidenceDirectory ([System.IO.Path]::GetTempPath()) 2>&1
        if ($LASTEXITCODE -eq 0 -or ($out -join "`n") -notmatch 'Only the spare vehicles agv02 and agv03') { throw "exit $LASTEXITCODE : $out" }
    }

    $launch = New-LaunchScript -RunDirectory 'C:\8005\capture\r1' -RunId 'r1'
    Check 'the generated launch and preflight scripts parse with zero errors' {
        foreach ($text in @($launch, (New-PreflightScript))) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $null, [ref] $errors)
            if ($errors.Count -ne 0) { throw $errors[0].Message }
        }
    }
    Check 'the launch script unregisters the task in a finally and ends with LAUNCH_DONE' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($launch, [ref] $null, [ref] $null)
        $unregister = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true) |
            Where-Object { $_.Finally -and $_.Finally.Extent.Text -match "Unregister-ScheduledTask -TaskName '$taskPrefix" })
        if ($unregister.Count -ne 1) { throw "finally blocks unregistering the task: $($unregister.Count)" }
        if ($ast.EndBlock.Statements[-1].Extent.Text -ne "'LAUNCH_DONE'") { throw "last statement is $($ast.EndBlock.Statements[-1].Extent.Text)" }
        if ($launch -notmatch 'wscript\.exe') { throw 'the task does not start through wscript' }
    }
    Check 'the hidden runner uses window style 0, waits, and is ASCII' {
        $vbs = New-HiddenRunner -RunDirectory 'C:\8005\capture\r1' -Name 'agv02-20261011T120000'
        if ($vbs -notmatch ', 0, True\r\n$') { throw "not hidden-and-wait: $vbs" }
        if ($vbs -notmatch [regex]::Escape('""C:\8005\capture\r1\agv-capture-hmi-screen.ps1""')) { throw "path not quoted for VBScript: $vbs" }
        if (@([System.Text.Encoding]::UTF8.GetBytes($vbs) | Where-Object { $_ -gt 127 }).Count) { throw 'non-ASCII' }
    }
    foreach ($case in @(
            @{ Name = 'launch output with marker and a running task passes'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41301', 'LAUNCH_DONE'); Expect = $true },
            @{ Name = 'empty launch output fails'; Out = @(); Expect = $false },
            @{ Name = 'launch output without the marker fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41301'); Expect = $false },
            @{ Name = 'launch output with a failed task result fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x80070002', 'LAUNCH_DONE'); Expect = $false })) {
        Check $case.Name {
            $got = Test-LaunchOutput $case.Out
            if ($got -ne $case.Expect) { throw "got $got" }
        }
    }

    $pre = [pscustomobject]@{ consoleSessionId = 1; wshDisabled = $false }
    function Vehicle([hashtable] $Over) {
        $v = @{
            focusDisturbed = $false; desktop = @{ locked = $false }; hmi = @{ running = $true }; screenUniform = $false
            errors = @(); uiaNodeCount = 120; images = @(@{ kind = 'screen' }, @{ kind = 'window' })
        }
        foreach ($k in $Over.Keys) { $v[$k] = $Over[$k] }
        return [pscustomobject]$v
    }
    foreach ($case in @(
            @{ Name = 'everything present is CAPTURED'; Pre = $pre; V = (Vehicle @{}); T = $false; Expect = 'CAPTURED' },
            @{ Name = 'no console session is NO_INTERACTIVE_SESSION'; Pre = [pscustomobject]@{ consoleSessionId = $null }; V = $null; T = $false; Expect = 'NO_INTERACTIVE_SESSION' },
            @{ Name = 'disabled script host is WSH_DISABLED'; Pre = [pscustomobject]@{ consoleSessionId = 1; wshDisabled = $true }; V = $null; T = $false; Expect = 'WSH_DISABLED' },
            @{ Name = 'no result is TIMEOUT'; Pre = $pre; V = $null; T = $true; Expect = 'TIMEOUT' },
            @{ Name = 'a focus disturbance outranks a lock'; Pre = $pre; V = (Vehicle @{ focusDisturbed = $true; desktop = @{ locked = $true } }); T = $false; Expect = 'FOCUS_DISTURBED' },
            @{ Name = 'a lock is DESKTOP_LOCKED even with UIA text'; Pre = $pre; V = (Vehicle @{ desktop = @{ locked = $true } }); T = $false; Expect = 'DESKTOP_LOCKED' },
            @{ Name = 'no client is HMI_NOT_RUNNING'; Pre = $pre; V = (Vehicle @{ hmi = @{ running = $false } }); T = $false; Expect = 'HMI_NOT_RUNNING' },
            @{ Name = 'a flat screenshot is SCREEN_BLANK'; Pre = $pre; V = (Vehicle @{ screenUniform = $true }); T = $false; Expect = 'SCREEN_BLANK' },
            @{ Name = 'an error is PARTIAL'; Pre = $pre; V = (Vehicle @{ errors = @('window 0x1: PrintWindow refused') }); T = $false; Expect = 'PARTIAL' },
            @{ Name = 'no window image is PARTIAL'; Pre = $pre; V = (Vehicle @{ images = @(@{ kind = 'screen' }) }); T = $false; Expect = 'PARTIAL' },
            @{ Name = 'an empty UIA tree is PARTIAL'; Pre = $pre; V = (Vehicle @{ uiaNodeCount = 0 }); T = $false; Expect = 'PARTIAL' },
            @{ Name = 'no screenshot is PARTIAL'; Pre = $pre; V = (Vehicle @{ screenUniform = $null }); T = $false; Expect = 'PARTIAL' })) {
        Check $case.Name {
            $got = Get-CaptureOutcome $case.Pre $case.V $case.T
            if ($got -ne $case.Expect) { throw "got $got" }
        }
    }

    "SELFTEST $(if ($failures.Count -eq 0) { 'PASS' } else { "FAIL ($($failures -join '; '))" })"
    if ($failures.Count -ne 0) { exit 1 }
}

# Dot-sourced by an off-vehicle test: define the functions and stop.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($PSCmdlet.ParameterSetName -eq 'SelfTest') { Invoke-SelfTest; return }

function Invoke-Vehicle {
    param([string] $Script)
    # An explicit exit 0, so the status is the script's and not whatever the last statement left in $?
    # (see 10-start-onboard-stack.ps1, Invoke-Onboard).
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$Script`nexit 0"))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    $exit = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()
    if ($exit -ne 0) { throw "ssh $SshAlias failed (exit $exit): $(if ($text) { $text } else { '(no output)' })" }
    return $text
}

New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
# Named by the control host's clock: the vehicles' clocks have been months off before (fleet.md, constraint 2).
$name = '{0}-{1}' -f $SshAlias, (Get-Date -Format 'yyyyMMdd\THHmmss')
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = "$vehicleBase\$runId"
$remoteDirectory = $runDirectory -replace '\\', '/'
$run = [ordered]@{
    tool = '17-capture-hmi-screen'; sshAlias = $SshAlias; name = $name; runId = $runId
    startedAt = [DateTimeOffset]::Now.ToString('o'); preflight = $null; launch = $null; outcome = $null
    files = @(); leftoverTasksAfter = $null; vehicleCleanup = $null; error = $null
}
$vehicle = $null
$timedOut = $false
$launched = $false

try {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Capturing the onboard HMI screen on $SshAlias ($name)" -ForegroundColor Green
    $run.preflight = Invoke-Vehicle (New-PreflightScript) | ConvertFrom-Json
    $p = $run.preflight
    Write-Host "  console: $($p.consoleUser ?? '(none)') session $($p.consoleSessionId ?? '-'); locked: $($p.logonUi); onboard client pid(s): $(if ($p.hmiPids) { $p.hmiPids -join ', ' } else { '(none)' })"
    if (@($p.leftoverTasks).Count) { Write-Host "  note: capture task(s) left by an earlier run: $($p.leftoverTasks -join ', ')" -ForegroundColor Yellow }

    if ($p.consoleSessionId -and -not $p.wshDisabled) {
        $null = Invoke-Vehicle "New-Item -ItemType Directory -Force -Path '$runDirectory' | Out-Null"
        $staging = Join-Path ([System.IO.Path]::GetTempPath()) "capture-hmi-$runId"
        New-Item -ItemType Directory -Force -Path $staging | Out-Null
        try {
            Copy-Item -LiteralPath $vehicleScript -Destination $staging
            Set-Content -LiteralPath (Join-Path $staging "launch-$runId.ps1") -Value (New-LaunchScript -RunDirectory $runDirectory -RunId $runId) -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $staging "hidden-$runId.vbs") -Value (New-HiddenRunner -RunDirectory $runDirectory -Name $name) -Encoding ascii -NoNewline
            scp -q -o BatchMode=yes -o ConnectTimeout=15 @(Get-ChildItem -LiteralPath $staging -File | ForEach-Object FullName) "${SshAlias}:$remoteDirectory/"
            if ($LASTEXITCODE -ne 0) { throw "Copying the capture scripts to $SshAlias failed (exit $LASTEXITCODE)." }
        } finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }

        $launchOutput = @(ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -File `"$runDirectory\launch-$runId.ps1`"" 2>&1 | ForEach-Object { "$_" })
        $run.launch = $launchOutput
        $launchOutput | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0 -or -not (Test-LaunchOutput $launchOutput)) {
            throw "Launching the capture task on $SshAlias did not report LAUNCH_DONE with a started task (exit $LASTEXITCODE)."
        }
        $launched = $true

        $resultFile = "$runDirectory\$name-uia.json"
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $present = Invoke-Vehicle "Test-Path -LiteralPath '$resultFile'"
        } until ($present -match 'True' -or [DateTimeOffset]::UtcNow -ge $deadline)
        $timedOut = $present -notmatch 'True'

        if (-not $timedOut) {
            # Fetched by scp, never printed through ssh: the console code page garbles the Chinese on the way back.
            $fetch = Join-Path ([System.IO.Path]::GetTempPath()) "capture-hmi-fetch-$runId"
            New-Item -ItemType Directory -Force -Path $fetch | Out-Null
            try {
                scp -q -r -o BatchMode=yes -o ConnectTimeout=15 "${SshAlias}:$remoteDirectory" $fetch
                if ($LASTEXITCODE -ne 0) { throw "Copying the capture back from $SshAlias failed (exit $LASTEXITCODE)." }
                $kept = @(Get-ChildItem -LiteralPath $fetch -Recurse -File | Where-Object { $_.Name -like "$name-*" -and $_.Extension -in '.json', '.png' })
                foreach ($file in $kept) { Copy-Item -LiteralPath $file.FullName -Destination $EvidenceDirectory -Force }
                $run.files = @($kept | ForEach-Object Name)
            } finally {
                Remove-Item -LiteralPath $fetch -Recurse -Force -ErrorAction SilentlyContinue
            }
            $vehicle = Get-Content -LiteralPath (Join-Path $EvidenceDirectory "$name-uia.json") -Raw -Encoding utf8 | ConvertFrom-Json
        }
    }
} catch {
    $run.error = $_.Exception.Message
} finally {
    if ($run.preflight -and $run.preflight.consoleSessionId -and -not $run.preflight.wshDisabled) {
        # The run directory goes whatever happened; on a timeout the hidden pwsh may still hold a file, which
        # is reported rather than retried.
        try {
            $run.vehicleCleanup = Invoke-Vehicle @"
Remove-Item -LiteralPath '$runDirectory' -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath '$runDirectory') { 'RUN_DIRECTORY_LEFT' } else { 'RUN_DIRECTORY_REMOVED' }
"@
            $run.leftoverTasksAfter = @((Invoke-Vehicle "@(Get-ScheduledTask -TaskName '$taskPrefix*' -ErrorAction SilentlyContinue | ForEach-Object { `$_.TaskName }) -join ','") -split ',' | Where-Object { $_ })
        } catch {
            $run.error = (@($run.error, "cleanup: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
        }
    }
}

$run.outcome = if ($run.error -and -not $vehicle -and -not ($run.preflight -and -not $run.preflight.consoleSessionId)) {
    if ($launched -and $timedOut) { 'TIMEOUT' } else { 'TOOL_FAILURE' }
} else {
    Get-CaptureOutcome $run.preflight $vehicle $timedOut
}
$run.finishedAt = [DateTimeOffset]::Now.ToString('o')
$runFile = Join-Path $EvidenceDirectory "$name-run.json"
$run | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $runFile -Encoding utf8NoBOM

$colour = if ($run.outcome -eq 'CAPTURED') { 'Green' } else { 'Yellow' }
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($run.outcome)$(if ($run.error) { ": $($run.error)" })" -ForegroundColor $colour
if ($vehicle) {
    Write-Host "  visible text: $((@($vehicle.visibleTexts) | Select-Object -First 30) -join ' | ')"
    if (@($vehicle.errors).Count) { Write-Host "  vehicle errors: $($vehicle.errors -join '; ')" -ForegroundColor Yellow }
}
if ($run.vehicleCleanup -and $run.vehicleCleanup -ne 'RUN_DIRECTORY_REMOVED') { Write-Host "  vehicle cleanup: $($run.vehicleCleanup)" -ForegroundColor Yellow }
if (@($run.leftoverTasksAfter).Count) { Write-Host "  capture task(s) still registered: $($run.leftoverTasksAfter -join ', ')" -ForegroundColor Yellow }
foreach ($file in @($run.files) + "$name-run.json") { Write-Host "  $(Join-Path $EvidenceDirectory $file)" }
exit $exitCodes[$run.outcome]
