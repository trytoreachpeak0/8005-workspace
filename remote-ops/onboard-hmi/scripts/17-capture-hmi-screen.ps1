#Requires -Version 7
<#
.SYNOPSIS
    Read-only look at what a spare vehicle's onboard HMI screen shows: a screenshot, one image per HMI
    window, and the UI Automation tree with its visible text as JSON. workspace#16.

.DESCRIPTION
    Runs on the control host. In order:

      1. Preflight over SSH (session 0, read-only): is someone logged on at the console, is the
         desktop locked, is the onboard client running, is Windows Script Host usable, is the sublot
         entry tool on the desktop, are there capture tasks left over from an earlier run.
      2. Copies agv-capture-hmi-screen.ps1 to C:\8005\capture\<runId> and runs it in the logged-on
         user's desktop session through a one-shot Interactive scheduled task, started hidden through
         wscript (window style 0) so nothing appears on the operator's screen and the foreground
         window does not change. The task is unregistered right after it starts.
      3. Waits for the vehicle-side JSON, copies the run directory back with scp, keeps the JSON and
         the PNGs in -EvidenceDirectory, deletes the run directory on the vehicle, and records any
         capture task or capture process still there afterwards.

    Read-only. It never clicks, types, focuses, switches windows, or starts or stops the onboard
    stack; the vehicle half only reads pixels and UIA properties (the self-test scans it for calls
    that would act, by name -- a bounded check, see Invoke-SelfTest). It moves nothing, so it needs no
    per-run authorization -- but agv02/agv03 only: agv01 is the production vehicle, and touching it
    needs the user first (Ask first, category 2).

    It never retries, and the control host never hangs: every run ends within -TimeoutSeconds plus the
    SSH round trips, in one outcome code (exit code in brackets). It does not stop anything it finds
    left running on the vehicle; it lists it in the run record.

      CAPTURED [0]               screenshot, window images and UIA text all present
      HMI_NOT_RUNNING [2]        no onboard client in the console session; the desktop was still captured
      DESKTOP_LOCKED [3]         lock screen up; the screenshot shows it, the window image and UIA text
                                 still show the HMI (agv02, 2026-10-11)
      SCREEN_BLANK [4]           the screenshot is one flat colour
      NO_INTERACTIVE_SESSION [5] nobody logged on at the console; nothing was launched
      TIMEOUT [6]                launched, but no result within -TimeoutSeconds; the run record says
                                 whether the vehicle script ever started
      PARTIAL [7]                ran, but an image or the UIA tree is missing (see errors in the JSON)
      FOCUS_DISTURBED [8]        the capture itself held the foreground; a defect of this tool
      WSH_DISABLED [9]           Windows Script Host is disabled; nothing was launched
      DESKTOP_BUSY [10]          the sublot entry tool (16-enter-sublot-uia) is running; nothing was launched
      TOOL_FAILURE [1]           SSH, scp or the launch failed

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
$entryScript = Join-Path $PSScriptRoot '16-enter-sublot-uia.ps1'
$vehicleBase = 'C:\8005\capture'
$taskPrefix = 'W2G-CaptureHmi-'
# What 16-enter-sublot-uia leaves on the vehicle while it runs. -SelfTest generates 16's own launch script
# and checks both still match it, so a rename there cannot silently switch this check off.
$entryTaskPattern = 'W2G-EnterSublot-*'
$entryProcessPattern = '*agv-enter-sublot-uia*'

$exitCodes = [ordered]@{
    CAPTURED = 0; HMI_NOT_RUNNING = 2; DESKTOP_LOCKED = 3; SCREEN_BLANK = 4; NO_INTERACTIVE_SESSION = 5
    TIMEOUT = 6; PARTIAL = 7; FOCUS_DISTURBED = 8; WSH_DISABLED = 9; DESKTOP_BUSY = 10; TOOL_FAILURE = 1
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
    # Filtered, not @(...).Count: @($null) has one element, so a missing field would read as busy.
    if (@($Preflight.otherDesktopTools | Where-Object { $_ }).Count) { return 'DESKTOP_BUSY' }
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
`$tick = [Environment]::TickCount64
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
    # The sublot entry tool drives the same desktop; two interactive tools at once is not allowed (Coordinator 10, 2026-10-11).
    otherDesktopTools = @(@(Get-ScheduledTask -TaskName '$entryTaskPattern' -ErrorAction SilentlyContinue | ForEach-Object { 'task ' + `$_.TaskName }) +
        @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'pwsh.exe'" | Where-Object { `$_.CommandLine -like '$entryProcessPattern' -and `$_.ProcessId -ne `$PID } | ForEach-Object { 'process ' + `$_.ProcessId }))
    vehicleClock     = [DateTimeOffset]::Now.ToString('o')
    tickCount64      = `$tick
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
        `$startTick = [Environment]::TickCount64
        Start-ScheduledTask -TaskName '$taskName'
        Start-Sleep -Seconds 3
        `$info = Get-ScheduledTaskInfo -TaskName '$taskName'
        # TickCount64 next to LastRunTime: the system clock can be moved, the tick count cannot.
        'TASK_STARTED lastRunTime={0} lastTaskResult=0x{1:X} startTick={2} now={3} nowTick={4}' -f `$info.LastRunTime, `$info.LastTaskResult, `$startTick, [DateTimeOffset]::Now.ToString('o'), [Environment]::TickCount64
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
    Whether the launch output proves the task started. Same rule as 16-enter-sublot-uia.ps1 (8005-workspace#20):
    the end marker and a TASK_STARTED line whose LastTaskResult is 0x41301 (running) or any code a process
    that ran can end with (0x0, 0x1, 0xC000013A ...). A task that already ended is not a failed launch; the
    result file decides. Not started: the Task Scheduler's own status codes other than running (ready,
    disabled, has not run, no more runs, not scheduled, queued) and HRESULTs of a failed launch
    (0x8004xxxx, 0x8007xxxx).
#>
function Test-LaunchOutput {
    param([string[]] $Output)
    $text = $Output -join "`n"
    if ($text -notmatch '(?m)^LAUNCH_DONE\s*$') { return $false }
    if ($text -notmatch 'TASK_STARTED .*lastTaskResult=0x([0-9A-Fa-f]{1,8})\b') { return $false }
    $code = [uint32]::Parse($Matches[1], [System.Globalization.NumberStyles]::HexNumber)
    if ($code -eq 0x41301) { return $true }
    if ($code -in 0x41300, 0x41302, 0x41303, 0x41304, 0x41305, 0x41325) { return $false }
    # Compared as text: PowerShell reads 0x80040000 as a negative Int32, so a numeric mask silently never matches.
    if ($Matches[1].ToUpperInvariant().PadLeft(8, '0').Substring(0, 4) -in '8004', '8007') { return $false }
    return $true
}

<#
    What a run without a result file was. Pure. The vehicle script writes <name>.started as its first act,
    so its presence tells "ran and never finished" from "never ran".
#>
function Get-NoResultVerdict {
    param([bool] $LaunchProved, [bool] $StartedMarkerPresent, [int] $TimeoutSeconds)
    if ($StartedMarkerPresent) {
        return [ordered]@{ outcome = 'TIMEOUT'; detail = "The capture script started (its .started marker is there) but wrote no result within ${TimeoutSeconds}s. It may still be running; see leftoverProcessesAfter." }
    }
    if ($LaunchProved) {
        return [ordered]@{ outcome = 'TIMEOUT'; detail = "The task started but the capture script never reached its first line within ${TimeoutSeconds}s (no .started marker)." }
    }
    return [ordered]@{ outcome = 'TOOL_FAILURE'; detail = 'The launch did not prove a started task and the capture script never reached its first line (no .started marker).' }
}

<#
    Vehicle-side cleanup: delete the run directory, then list what is still there. Reads and deletes only
    this run's directory; it stops no process. Prints one line of JSON.
#>
function New-CleanupScript {
    param([string] $RunDirectory, [string] $RunId)
    return @"
`$ErrorActionPreference = 'Stop'
Remove-Item -LiteralPath '$RunDirectory' -Recurse -Force -ErrorAction SilentlyContinue
[pscustomobject]@{
    vehicleCleanup = if (Test-Path -LiteralPath '$RunDirectory') { 'RUN_DIRECTORY_LEFT' } else { 'RUN_DIRECTORY_REMOVED' }
    leftoverTasksAfter = @(Get-ScheduledTask -TaskName '$taskPrefix*' -ErrorAction SilentlyContinue | ForEach-Object { `$_.TaskName })
    leftoverProcessesAfter = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'wscript.exe'" |
        Where-Object { `$_.ProcessId -ne `$PID -and (`$_.CommandLine -like '*agv-capture-hmi-screen*' -or `$_.CommandLine -like '*hidden-$RunId.vbs*') } |
        ForEach-Object { '{0} {1}' -f `$_.Name, `$_.ProcessId })
    tickCount64 = [Environment]::TickCount64
} | ConvertTo-Json -Compress
"@
}

<#
    Calls the vehicle half would need to act on the screen. A blacklist of names, matched as text: it
    catches a direct call, not a name built at run time or reached through reflection. Bounded on purpose
    (an AST allowlist is the stronger check, not done; see docs/hmi-screen-capture.md).
#>
$forbiddenInVehicleScript = @(
    'SetFocus', 'SetForegroundWindow', 'SetActiveWindow', 'BringWindowToTop', 'ShowWindow', 'SwitchToThisWindow',
    'SetWindowPos', 'AppActivate',
    'SendInput', 'keybd_event', 'mouse_event', 'SetCursorPos', 'PostMessage', 'SendMessage', 'SendKeys',
    'InvokePattern', 'SelectionItemPattern', 'ExpandCollapsePattern', 'WindowPattern', 'TransformPattern',
    'ScrollIntoView', 'DoDefaultAction', 'Realize',
    '.SetValue(', '.Invoke()', '.Toggle()', '.Select()', '.Expand()', '.Close()',
    'Stop-Process', 'Start-Process', '.Kill(', 'CloseMainWindow', 'Restart-'
)

<# Win32 functions imported by a C# source, whatever modifiers precede `extern`. #>
function Get-DllImportNames {
    param([string] $Source)
    $pattern = '(?s)\[DllImport\([^\]]*\]\s*(?:(?:public|private|internal|protected|static|unsafe|extern)\s+)*extern\s+[\w.<>\[\]]+\s+(\w+)\s*\('
    return @([regex]::Matches($Source, $pattern) | ForEach-Object { $_.Groups[1].Value })
}

$readingWin32 = 'EnumWindows', 'GetWindowThreadProcessId', 'IsWindowVisible', 'IsIconic', 'GetWindowText', 'GetClassName',
    'GetWindowRect', 'GetWindow', 'GetForegroundWindow', 'PrintWindow', 'SetProcessDpiAwarenessContext',
    'OpenInputDesktop', 'CloseDesktop', 'GetUserObjectInformation', 'GetSystemMetrics'

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
    Check 'the vehicle half calls nothing on the blacklist' {
        $text = [System.IO.File]::ReadAllText($vehicleScript)
        $hits = @($forbiddenInVehicleScript | Where-Object { $text.Contains($_) })
        if ($hits.Count) { throw "found: $($hits -join ', ')" }
    }
    foreach ($probe in @(
            '$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()',
            '$shell.AppActivate($title)', 'SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 3)', '$item.ScrollIntoView()',
            '$legacy.DoDefaultAction()', '$virtualized.Realize()')) {
        Check "the blacklist catches: $probe" {
            if (-not @($forbiddenInVehicleScript | Where-Object { $probe.Contains($_) }).Count) { throw 'scan missed it' }
        }
    }
    Check 'the vehicle half imports only reading Win32 calls' {
        $imported = Get-DllImportNames ([System.IO.File]::ReadAllText($vehicleScript))
        $extra = @($imported | Where-Object { $_ -notin $readingWin32 })
        if ($extra.Count) { throw "not on the reading list: $($extra -join ', ')" }
        if ($imported.Count -ne $readingWin32.Count) { throw "found $($imported.Count) imports, the reading list has $($readingWin32.Count); the scan is not reading the file" }
    }
    Check 'the import scan sees a public static extern' {
        $probe = '[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);'
        if ((Get-DllImportNames $probe) -notcontains 'SetCursorPos') { throw 'missed' }
        $probe = "[DllImport(`"user32.dll`", SetLastError = true)]`n        private static extern IntPtr SetFocus(IntPtr h);"
        if ((Get-DllImportNames $probe) -notcontains 'SetFocus') { throw 'missed across a line break' }
    }
    Check 'agv01 is refused before anything runs' {
        $out = & pwsh -NoProfile -File $PSCommandPath -SshAlias agv01 -EvidenceDirectory ([System.IO.Path]::GetTempPath()) 2>&1
        if ($LASTEXITCODE -eq 0 -or ($out -join "`n") -notmatch 'Only the spare vehicles agv02 and agv03') { throw "exit $LASTEXITCODE : $out" }
    }

    Check 'every outcome has a distinct exit code' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref] $null, [ref] $null)
        $sources = @('Get-CaptureOutcome', 'Get-NoResultVerdict') | ForEach-Object {
            $fn = $_
            $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
        }
        $returned = @($sources | ForEach-Object {
                $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -cmatch '^[A-Z]+(_[A-Z]+)+$|^[A-Z]{5,}$' }, $true) | ForEach-Object Value
            }) + 'TOOL_FAILURE' | Sort-Object -Unique
        if ($returned.Count -lt 11) { throw "only $($returned.Count) outcome literals found: $($returned -join ', ')" }
        $missing = @($returned | Where-Object { -not $exitCodes.Contains($_) })
        if ($missing.Count) { throw "no exit code for: $($missing -join ', ')" }
        if (@($exitCodes.Values | Sort-Object -Unique).Count -ne $exitCodes.Count) { throw 'two outcomes share an exit code' }
        if ($exitCodes['CAPTURED'] -ne 0 -or @($exitCodes.Keys | Where-Object { $_ -ne 'CAPTURED' -and $exitCodes[$_] -eq 0 }).Count) { throw 'only CAPTURED may exit 0' }
    }

    Check '16-enter-sublot-uia still leaves what the preflight looks for' {
        # 16 has no dot-source exit, so its launch-script generator is lifted out of its syntax tree.
        $ast16 = [System.Management.Automation.Language.Parser]::ParseFile($entryScript, [ref] $null, [ref] $null)
        $fn = $ast16.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-LaunchScript' }, $true)
        if (-not $fn) { throw "no New-LaunchScript in $entryScript" }
        $text16 = & ([scriptblock]::Create("$($fn.Extent.Text)`nNew-LaunchScript -VehicleRoot 'C:\8005\uia' -Sublot 'S-1' -ResultPath 'C:\8005\uia\result-r1.json' -RunId 'r1'"))
        $tasks = @([regex]::Matches($text16, "-TaskName '([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if ($tasks.Count -ne 1) { throw "task names in 16's launch script: $($tasks -join ', ')" }
        if ($tasks[0] -notlike $entryTaskPattern) { throw "16 registers '$($tasks[0])', which '$entryTaskPattern' misses" }
        if ($text16 -notmatch "`\`$arguments = '([^']+)'") { throw "no `$arguments line in 16's launch script" }
        if ("pwsh.exe $($Matches[1])" -notlike $entryProcessPattern) { throw "16's pwsh command line '$($Matches[1])' is missed by '$entryProcessPattern'" }
    }

    $launch = New-LaunchScript -RunDirectory 'C:\8005\capture\r1' -RunId 'r1'
    Check 'the generated launch, preflight and cleanup scripts parse with zero errors' {
        foreach ($text in @($launch, (New-PreflightScript), (New-CleanupScript -RunDirectory 'C:\8005\capture\r1' -RunId 'r1'))) {
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
        if ($launch -notmatch 'startTick=\{2\}') { throw 'the TASK_STARTED line carries no tick count' }
    }
    Check 'the hidden runner uses window style 0, waits, and is ASCII' {
        $vbs = New-HiddenRunner -RunDirectory 'C:\8005\capture\r1' -Name 'agv02-20261011T120000'
        if ($vbs -notmatch ', 0, True\r\n$') { throw "not hidden-and-wait: $vbs" }
        if ($vbs -notmatch [regex]::Escape('""C:\8005\capture\r1\agv-capture-hmi-screen.ps1""')) { throw "path not quoted for VBScript: $vbs" }
        if (@([System.Text.Encoding]::UTF8.GetBytes($vbs) | Where-Object { $_ -gt 127 }).Count) { throw 'non-ASCII' }
    }
    Check 'the main flow fetches a result before it deletes the run directory' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref] $null, [ref] $null)
        $try = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Finally }) | Select-Object -Last 1
        if (-not $try) { throw 'no top-level try/finally' }
        $finally = $try.Finally.Extent.Text
        $fetch = $finally.IndexOf('Save-RunResult'); $cleanup = $finally.IndexOf('New-CleanupScript')
        if ($fetch -lt 0 -or $cleanup -lt 0 -or $fetch -gt $cleanup) { throw "in the finally block Save-RunResult is at $fetch and New-CleanupScript at $cleanup" }
    }

    foreach ($case in @(
            @{ Name = 'launch output with marker and a running task passes'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41301 startTick=1', 'LAUNCH_DONE'); Expect = $true },
            @{ Name = 'launch output with marker and a finished task passes'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x0 startTick=1', 'LAUNCH_DONE'); Expect = $true },
            @{ Name = 'empty launch output fails'; Out = @(); Expect = $false },
            @{ Name = 'launch output without the marker fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41301'); Expect = $false },
            @{ Name = 'a failed launch (0x80070002) fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x80070002', 'LAUNCH_DONE'); Expect = $false },
            @{ Name = 'a scheduler error (0x8004131F) fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x8004131F', 'LAUNCH_DONE'); Expect = $false },
            @{ Name = 'a task that has not run yet (0x41303) fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41303', 'LAUNCH_DONE'); Expect = $false },
            @{ Name = 'a queued task (0x41325) fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41325', 'LAUNCH_DONE'); Expect = $false },
            @{ Name = 'a task already ended with 0x1 counts as started'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x1', 'LAUNCH_DONE'); Expect = $true },
            @{ Name = 'a task already ended with 0xC000013A counts as started'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0xC000013A', 'LAUNCH_DONE'); Expect = $true })) {
        Check $case.Name {
            $got = Test-LaunchOutput $case.Out
            if ($got -ne $case.Expect) { throw "got $got" }
        }
    }
    foreach ($case in @(
            @{ Name = 'no result with a started marker is TIMEOUT and says it started'; Proved = $true; Started = $true; Expect = 'TIMEOUT'; Says = 'started \(its \.started' },
            @{ Name = 'no result, a proved launch and no marker is TIMEOUT that never reached its first line'; Proved = $true; Started = $false; Expect = 'TIMEOUT'; Says = 'never reached its first line' },
            @{ Name = 'no result, an unproved launch and no marker is TOOL_FAILURE'; Proved = $false; Started = $false; Expect = 'TOOL_FAILURE'; Says = 'did not prove' },
            @{ Name = 'a marker outranks an unproved launch'; Proved = $false; Started = $true; Expect = 'TIMEOUT'; Says = 'started \(its \.started' })) {
        Check $case.Name {
            $v = Get-NoResultVerdict -LaunchProved $case.Proved -StartedMarkerPresent $case.Started -TimeoutSeconds 90
            if ($v.outcome -ne $case.Expect -or $v.detail -notmatch $case.Says) { throw "got $($v.outcome): $($v.detail)" }
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
            @{ Name = 'a running sublot entry is DESKTOP_BUSY'; Pre = [pscustomobject]@{ consoleSessionId = 1; wshDisabled = $false; otherDesktopTools = @('task W2G-EnterSublot-ab12') }; V = $null; T = $false; Expect = 'DESKTOP_BUSY' },
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

    . $vehicleScript
    foreach ($case in @(
            @{ Name = 'an unlocked desktop is not locked'; D = 'Default'; L = $false; F = 'SQCD.Agv.Wpf'; Expect = $false },
            @{ Name = 'the 2026-10-11 20:04 agv02 lock is locked'; D = 'Default'; L = $true; F = 'LockApp'; Expect = $true },
            @{ Name = 'LogonUI alone is a lock'; D = 'Default'; L = $true; F = 'SQCD.Agv.Wpf'; Expect = $true },
            @{ Name = 'LockApp in the foreground alone is a lock'; D = 'Default'; L = $false; F = 'LockApp'; Expect = $true },
            @{ Name = 'the secure desktop alone is a lock'; D = 'Winlogon'; L = $false; F = 'SQCD.Agv.Wpf'; Expect = $true },
            @{ Name = 'an unreadable input desktop is a lock'; D = $null; L = $false; F = $null; Expect = $true })) {
        Check $case.Name {
            $state = Get-LockState -InputDesktop $case.D -OpenError 0 -LogonUiInSession $case.L -ForegroundProcess $case.F
            if ($state.locked -ne $case.Expect) { throw "locked=$($state.locked) signals=$($state.lockSignals -join ',')" }
        }
    }

    "SELFTEST $(if ($failures.Count -eq 0) { 'PASS' } else { "FAIL ($($failures -join '; '))" }) ($($failures.Count) failed)"
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

<#
    Copies the run directory back and keeps this run's JSON and PNGs. Fetched by scp, never printed through
    ssh: the console code page garbles the Chinese on the way back. Returns the parsed vehicle JSON.
#>
function Save-RunResult {
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
    return Get-Content -LiteralPath (Join-Path $EvidenceDirectory "$name-uia.json") -Raw -Encoding utf8 | ConvertFrom-Json
}

New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
# Named by the control host's clock: the vehicles' clocks have been months off before (fleet.md, constraint 2).
$name = '{0}-{1}' -f $SshAlias, (Get-Date -Format 'yyyyMMdd\THHmmss')
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$runDirectory = "$vehicleBase\$runId"
$remoteDirectory = $runDirectory -replace '\\', '/'
$resultFile = "$runDirectory\$name-uia.json"
$startedFile = "$runDirectory\$name.started"
$run = [ordered]@{
    tool = '17-capture-hmi-screen'; sshAlias = $SshAlias; name = $name; runId = $runId
    startedAt = [DateTimeOffset]::Now.ToString('o'); preflight = $null; launch = $null; launchProved = $false
    startedMarker = $null; outcome = $null; detail = $null; files = @()
    vehicleCleanup = $null; leftoverTasksAfter = $null; leftoverProcessesAfter = $null; cleanupTickCount64 = $null; error = $null
}
$vehicle = $null
$runDirectoryCreated = $false

try {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Capturing the onboard HMI screen on $SshAlias ($name)" -ForegroundColor Green
    $run.preflight = Invoke-Vehicle (New-PreflightScript) | ConvertFrom-Json
    $p = $run.preflight
    Write-Host "  console: $($p.consoleUser ?? '(none)') session $($p.consoleSessionId ?? '-'); locked: $($p.logonUi); onboard client pid(s): $(if ($p.hmiPids) { $p.hmiPids -join ', ' } else { '(none)' })"
    if (@($p.otherDesktopTools | Where-Object { $_ }).Count) { Write-Host "  another interactive tool is on the desktop, not launching: $($p.otherDesktopTools -join ', ')" -ForegroundColor Yellow }
    if (@($p.leftoverTasks).Count) { Write-Host "  note: capture task(s) left by an earlier run: $($p.leftoverTasks -join ', ')" -ForegroundColor Yellow }

    if ($p.consoleSessionId -and -not $p.wshDisabled -and -not @($p.otherDesktopTools | Where-Object { $_ }).Count) {
        $null = Invoke-Vehicle "New-Item -ItemType Directory -Force -Path '$runDirectory' | Out-Null"
        $runDirectoryCreated = $true
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
        $launchExit = $LASTEXITCODE
        $run.launch = $launchOutput
        $launchOutput | ForEach-Object { Write-Host "  $_" }
        $run.launchProved = $launchExit -eq 0 -and (Test-LaunchOutput $launchOutput)
        if (-not $run.launchProved) {
            Write-Host "  the launch did not prove a started task (exit $launchExit); checking for a result once, not waiting" -ForegroundColor Yellow
        }

        # An unproved launch is looked at once, not waited on: the result file, if any, still decides.
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($run.launchProved ? $TimeoutSeconds : 0)
        do {
            Start-Sleep -Seconds 2
            $present = Invoke-Vehicle "Test-Path -LiteralPath '$resultFile'"
        } until ($present -match 'True' -or [DateTimeOffset]::UtcNow -ge $deadline)

        if ($present -match 'True') {
            $vehicle = Save-RunResult
        } else {
            $run.startedMarker = (Invoke-Vehicle "if (Test-Path -LiteralPath '$startedFile') { Get-Content -LiteralPath '$startedFile' -Raw } else { 'ABSENT' }").Trim()
            $verdict = Get-NoResultVerdict -LaunchProved $run.launchProved -StartedMarkerPresent ($run.startedMarker -ne 'ABSENT') -TimeoutSeconds $TimeoutSeconds
            $run.outcome = $verdict.outcome
            $run.detail = $verdict.detail
        }
    }
} catch {
    $run.error = $_.Exception.Message
} finally {
    if ($runDirectoryCreated) {
        try {
            # A result written before an error above is fetched before the directory goes.
            if (-not $vehicle -and (Invoke-Vehicle "Test-Path -LiteralPath '$resultFile'") -match 'True') {
                $vehicle = Save-RunResult
                $run.outcome = $null
                $run.detail = 'Fetched in cleanup, after an earlier step failed.'
            }
        } catch {
            $run.error = (@($run.error, "fetch in cleanup: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
        }
        try {
            # Deletes this run's directory and lists what is left; on a timeout the hidden pwsh may still be
            # running and hold a file. Reported, not retried, and nothing is stopped.
            $cleanup = Invoke-Vehicle (New-CleanupScript -RunDirectory $runDirectory -RunId $runId) | ConvertFrom-Json
            $run.vehicleCleanup = $cleanup.vehicleCleanup
            $run.leftoverTasksAfter = @($cleanup.leftoverTasksAfter)
            $run.leftoverProcessesAfter = @($cleanup.leftoverProcessesAfter)
            $run.cleanupTickCount64 = $cleanup.tickCount64
        } catch {
            $run.error = (@($run.error, "cleanup: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
        }
    }
}

if (-not $run.outcome) {
    $run.outcome = if ($vehicle) { Get-CaptureOutcome $run.preflight $vehicle $false }
        elseif ($run.error) { 'TOOL_FAILURE' }
        # Nothing failed and nothing was launched: the preflight said no (no session, no WSH, entry running).
        elseif ($run.preflight -and -not $runDirectoryCreated) { Get-CaptureOutcome $run.preflight $null $false }
        else { 'TOOL_FAILURE' }
}
$run.finishedAt = [DateTimeOffset]::Now.ToString('o')
$runFile = Join-Path $EvidenceDirectory "$name-run.json"
$run | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $runFile -Encoding utf8NoBOM

$colour = if ($run.outcome -eq 'CAPTURED') { 'Green' } else { 'Yellow' }
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($run.outcome)$(if ($run.detail) { ": $($run.detail)" })$(if ($run.error) { " ($($run.error))" })" -ForegroundColor $colour
if ($vehicle) {
    Write-Host "  visible text: $((@($vehicle.visibleTexts) | Select-Object -First 30) -join ' | ')"
    if (@($vehicle.errors).Count) { Write-Host "  vehicle errors: $($vehicle.errors -join '; ')" -ForegroundColor Yellow }
}
if ($run.vehicleCleanup -and $run.vehicleCleanup -ne 'RUN_DIRECTORY_REMOVED') { Write-Host "  vehicle cleanup: $($run.vehicleCleanup)" -ForegroundColor Yellow }
if (@($run.leftoverTasksAfter).Count) { Write-Host "  capture task(s) still registered: $($run.leftoverTasksAfter -join ', ')" -ForegroundColor Yellow }
if (@($run.leftoverProcessesAfter).Count) { Write-Host "  capture process(es) still running: $($run.leftoverProcessesAfter -join ', ')" -ForegroundColor Yellow }
foreach ($file in @($run.files) + "$name-run.json") { Write-Host "  $(Join-Path $EvidenceDirectory $file)" }
# ?? 1: a missing key must never exit 0 (exit $null does). -SelfTest also checks every outcome has a key.
exit ($exitCodes[$run.outcome] ?? 1)
