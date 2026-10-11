#Requires -Version 7
<#
.SYNOPSIS
    Test tooling: enters one sublot on a spare vehicle's v2 onboard HMI through UI Automation,
    instead of a person typing it. control-server#566.

.DESCRIPTION
    Runs on the control host. In order:

      1. Reads the newest SublotEntryRequested that the v2 parallel instance on factory01 sent to
         this vehicle (read-only, from its ProtocolOutbox) and refuses unless -Sublot is one of
         its expectedSublots. The tool never enters a barcode the server did not ask for.
      2. Copies agv-enter-sublot-uia.ps1 to the vehicle and runs it in the logged-on user's
         desktop session through a one-shot Interactive scheduled task (sshd gives session 0,
         where the HMI window is not visible). The task is unregistered right after it starts.
      3. Waits for the vehicle-side result file and prints it; -EvidencePath keeps a copy.

    Boundaries (control-server#566, Coordinator 10, 2026-10-10):
      * test only: not part of any onboard package, changes nothing in the onboard client or its
        configuration, and runs only when someone types this command;
      * spare vehicles only: -SshAlias accepts agv02 or agv03 and nothing else;
      * it is used only inside a run the user has already authorized; entering the sublot may let
        the vehicle leave the station, and this tool is not an authorization of its own;
      * every result carries autoEntered=true and method=UIA. The server records the entry as
        KEYBOARD (the protocol has no value for automated entry), so the result file is the mark.

    A first use on a vehicle needs a person watching the screen. If the desktop is locked or the
    scheduled task is blocked (antivirus), fall back to typing by hand and record why.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/16-enter-sublot-uia.ps1 -SshAlias agv02 -Sublot W2-1010-A2-1 -EvidencePath <dir>/entry.json

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/16-enter-sublot-uia.ps1 -SelfTest
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidateSet('agv02', 'agv03')][string] $SshAlias,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string] $Sublot,
    [Parameter(ParameterSetName = 'Run')][string] $EvidencePath,
    [Parameter(ParameterSetName = 'Run')][string] $ServerAlias = 'factory01',
    [Parameter(ParameterSetName = 'Run')][string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db',
    [Parameter(ParameterSetName = 'Run')][string] $ServerSqliteTools = 'D:\zhengyushao\control-server-v2-ops\sqlite-tools',
    [Parameter(ParameterSetName = 'Run')][int] $RequestMaxAgeMinutes = 30,
    [Parameter(ParameterSetName = 'Run')][int] $TimeoutSeconds = 120,
    [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
$vehicleScript = Join-Path $PSScriptRoot 'agv-enter-sublot-uia.ps1'
$vehicleRoot = 'C:\8005\uia'

<#
    Refuses unless the request is this vehicle's, recent, and lists the sublot. Pure, so -SelfTest
    covers it. $Request is the parsed envelope of a SublotEntryRequested.
#>
function Assert-SublotRequested {
    param([object] $Request, [string] $AgvId, [string] $Sublot, [DateTimeOffset] $Now, [int] $MaxAgeMinutes)
    if (-not $Request) { throw "REFUSED: the server has sent no SublotEntryRequested to $AgvId." }
    if ($Request.agvId -cne $AgvId) { throw "REFUSED: the newest request is for '$($Request.agvId)', not $AgvId." }
    $sentAt = [DateTimeOffset] $Request.sentAt
    if ($Now - $sentAt -gt [TimeSpan]::FromMinutes($MaxAgeMinutes)) {
        throw "REFUSED: the newest request for $AgvId was sent at $($sentAt.ToString('o')), more than $MaxAgeMinutes min ago."
    }
    $expected = @($Request.payload.expectedSublots)
    if ($expected -cnotcontains $Sublot) {
        throw "REFUSED: '$Sublot' is not in expectedSublots [$($expected -join ', ')] of request $($Request.messageId) at station $($Request.payload.stationId)."
    }
    return [pscustomobject]@{ MessageId = $Request.messageId; StationId = $Request.payload.stationId; ExpectedSublots = $expected; SentAt = $sentAt }
}

<#
    Only the v2 parallel instance's database may be read. Pointing -ServerDatabase at the MVP database
    would be a query against the production database, which needs the user first (Ask first, category 2).
#>
function Assert-V2Database {
    param([string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = 'C:\ProgramData\8005\ControlServer.V2\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "REFUSED: -ServerDatabase '$Path' is not under $root. Only the v2 parallel instance's database is read."
    }
    return $full
}

<#
    The newest request for this vehicle, ordered by sentAt parsed as DateTimeOffset on this side.
    SQLite cannot order DateTimeOffset text correctly, so the SQL does not sort.
#>
function Select-LatestSublotRequest {
    param([string[]] $PayloadLines, [string] $AgvId)
    return @($PayloadLines | Where-Object { $_ -like '{*' } | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.agvId -ceq $AgvId } |
        Sort-Object -Property @{ Expression = { [DateTimeOffset] $_.sentAt } } -Descending) | Select-Object -First 1
}

<#
    The script that registers and starts the one-shot Interactive task on the vehicle. Run there with -File.
    The task stays Interactive in the console user's session, which is what lets UIA see the HMI window;
    -WindowStyle Hidden only hides pwsh's own console, so no console window sits over the HMI where a
    person can close it or where it takes the foreground (8005-workspace#20: the first entry of
    2026-10-11 18:03 ended 0xC000013A before its first line ran). pwsh still shows the console for a
    moment while it starts.
    It removes itself and any launch script an earlier run left behind, whatever happens, and its last line is
    LAUNCH_DONE: the caller treats output without that marker as a failure, so a launch that never ran can no
    longer look like a clean exit (2026-10-10: exit code 0, task never registered).
#>
function New-LaunchScript {
    param([string] $VehicleRoot, [string] $Sublot, [string] $ResultPath, [string] $RunId)
    return @"
`$ErrorActionPreference = 'Stop'
try {
    `$console = (query session 2>&1 | Select-String -Pattern '^\s*>?console\s+(\S+)\s+(\d+)\s+Active').Matches
    if (-not `$console) { throw 'No active console session on this vehicle.' }
    `$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$VehicleRoot\agv-enter-sublot-uia.ps1" -Sublot "$Sublot" -ResultPath "$ResultPath"'
    `$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument `$arguments -WorkingDirectory '$VehicleRoot'
    `$principal = New-ScheduledTaskPrincipal -UserId `$console[0].Groups[1].Value -LogonType Interactive -RunLevel Limited
    `$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
    try {
        Register-ScheduledTask -TaskName 'W2G-EnterSublot-$RunId' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
        Start-ScheduledTask -TaskName 'W2G-EnterSublot-$RunId'
        Start-Sleep -Seconds 3
        `$info = Get-ScheduledTaskInfo -TaskName 'W2G-EnterSublot-$RunId'
        'TASK_STARTED lastRunTime={0} lastTaskResult=0x{1:X}' -f `$info.LastRunTime, `$info.LastTaskResult
    } finally {
        Unregister-ScheduledTask -TaskName 'W2G-EnterSublot-$RunId' -Confirm:`$false -ErrorAction SilentlyContinue
    }
} finally {
    Get-ChildItem -LiteralPath '$VehicleRoot' -Filter 'launch-*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
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

<#
    Keyboard, focus and foreground APIs found in a script's code (comments excluded). The vehicle
    script must have none: a keystroke goes to whatever window has the focus, which is how input
    would reach another window while the HMI's scan box is not open (8005-workspace#20).
#>
function Get-InputApiViolation {
    param([string] $Text)
    $pattern = '(?i)(SendKeys|SendWait|SendInput|keybd_event|mouse_event|SetFocus|\.Focus\b|SetForegroundWindow|SetActiveWindow|BringWindowToTop|SwitchToThisWindow|AppActivate|PostMessage|SendMessage|WScript\.Shell|System\.Windows\.Forms|user32|DllImport|MemberDefinition)'
    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref] $tokens, [ref] $null)
    return @($tokens | Where-Object { $_.Kind -ne 'Comment' -and $_.Text -match $pattern } | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Text)" })
}

<#
    Where the vehicle script's UIA writes can reach. Every element search starts from the HMI's own
    window, except the one top-level search that finds that window by process id, and the only
    patterns used are ValuePattern (write the box, read it back) and InvokePattern (the submit button).
#>
function Get-UiaScopeViolation {
    param([string] $Text)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref] $null, [ref] $null)
    $violations = [System.Collections.Generic.List[string]]::new()
    $invokes = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
    foreach ($call in $invokes | Where-Object { $_.Member.Extent.Text -eq 'FindFirst' }) {
        if ($call.Expression.Extent.Text -ne '$this.Window') { $violations.Add("FindFirst on $($call.Expression.Extent.Text)") }
    }
    $findAll = @($invokes | Where-Object { $_.Member.Extent.Text -eq 'FindAll' })
    foreach ($call in $findAll) {
        $root = $call.Expression.Extent.Text -eq '[System.Windows.Automation.AutomationElement]::RootElement'
        $block = $call.Parent
        while ($block -and $block -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $block = $block.Parent }
        $condition = if ($call.Arguments.Count -eq 2) { [regex]::Escape($call.Arguments[1].Extent.Text) } else { '(?!)' }
        $byProcess = $block -and $block.Extent.Text -match "$condition\s*=\s*\[System\.Windows\.Automation\.PropertyCondition\]::new\(\s*\[System\.Windows\.Automation\.AutomationElement\]::ProcessIdProperty"
        if (-not ($root -and $byProcess)) { $violations.Add("FindAll on $($call.Expression.Extent.Text) without a process-id condition") }
    }
    $patterns = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Static -and $n.Member.Extent.Text -eq 'Pattern' }, $true))
    foreach ($p in $patterns) {
        if ($p.Expression.Extent.Text -notin '[System.Windows.Automation.ValuePattern]', '[System.Windows.Automation.InvokePattern]') {
            $violations.Add("pattern $($p.Expression.Extent.Text)")
        }
    }
    if ($patterns.Count -eq 0) { $violations.Add('no UIA pattern found: the scan did not see the driver') }
    return @($violations)
}

function Invoke-SelfTest {
    $failures = [System.Collections.Generic.List[string]]::new()
    function Check([string] $Name, [scriptblock] $Body) {
        try { & $Body; "PASS $Name" } catch { $failures.Add($Name); "FAIL $Name -- $($_.Exception.Message)" }
    }

    Check 'neither script carries a control character' {
        # 2026-10-10: a Python edit turned "\a" into BEL and "\b" into backspace in this file.
        foreach ($path in @($PSCommandPath, $vehicleScript)) {
            $bad = @([System.IO.File]::ReadAllBytes($path) | Where-Object { $_ -lt 32 -and $_ -notin 9, 10, 13 })
            if ($bad.Count -ne 0) { throw "$path carries $($bad.Count) control character(s)" }
        }
    }
    $launchText = New-LaunchScript -VehicleRoot 'C:\8005\uia' -Sublot 'S-1' -ResultPath 'C:\8005\uia\result-x.json' -RunId 'r1'
    Check 'the generated launch script parses with zero errors' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($launchText, [ref] $null, [ref] $errors)
        if ($errors.Count -ne 0) { throw $errors[0].Message }
    }
    Check 'the launch script removes launch-*.ps1 in a finally and ends with LAUNCH_DONE' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($launchText, [ref] $null, [ref] $null)
        $finallyRemoves = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true) |
            Where-Object { $_.Finally -and $_.Finally.Extent.Text -match "-Filter 'launch-\*\.ps1'" -and $_.Finally.Extent.Text -match 'Remove-Item' })
        if ($finallyRemoves.Count -ne 1) { throw "finally blocks removing launch-*.ps1: $($finallyRemoves.Count)" }
        if ($ast.EndBlock.Statements[-1].Extent.Text -ne "'LAUNCH_DONE'") { throw "last statement is $($ast.EndBlock.Statements[-1].Extent.Text)" }
        if ($launchText -notmatch [regex]::Escape('"C:\8005\uia\agv-enter-sublot-uia.ps1"')) { throw 'vehicle script path not in the launch script' }
    }
    foreach ($case in @(
            @{ Name = 'launch output with marker and a running task passes'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41301', 'LAUNCH_DONE'); Expect = $true },
            @{ Name = 'launch output with marker and a finished task passes'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x0', 'LAUNCH_DONE'); Expect = $true },
            @{ Name = 'empty launch output fails (the 2026-10-10 case)'; Out = @(); Expect = $false },
            @{ Name = 'launch output without the marker fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x41301'); Expect = $false },
            @{ Name = 'launch output with a failed task result fails'; Out = @('TASK_STARTED lastRunTime=x lastTaskResult=0x80070002', 'LAUNCH_DONE'); Expect = $false })) {
        Check $case.Name {
            $got = Test-LaunchOutput $case.Out
            if ($got -ne $case.Expect) { throw "got $got" }
        }
    }
    Check 'both scripts parse with zero errors' {
        foreach ($path in @($PSCommandPath, $vehicleScript)) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $errors)
            if ($errors.Count -ne 0) { throw "$path : $($errors[0].Message)" }
        }
    }

    $vehicleText = [System.IO.File]::ReadAllText($vehicleScript)
    Check 'the vehicle script sends no keyboard input and takes no focus' {
        $found = Get-InputApiViolation $vehicleText
        if ($found.Count -ne 0) { throw "found: $($found -join '; ')" }
    }
    Check 'the keyboard scan sees a keystroke API when there is one, and ignores comments' {
        # Positive control: a scan that never finds anything would pass the check above forever.
        $bad = "# SendKeys in a comment is fine`n`$box.SetFocus()`n[System.Windows.Forms.SendKeys]::SendWait('x')"
        $found = Get-InputApiViolation $bad
        if ($found -match '^line 1:' -or -not ($found -match '^line 2:') -or -not ($found -match '^line 3:')) { throw "found: $($found -join '; ')" }
    }
    Check 'every UIA write in the vehicle script is scoped to the HMI window' {
        $found = Get-UiaScopeViolation $vehicleText
        if ($found.Count -ne 0) { throw "found: $($found -join '; ')" }
    }
    Check 'the UIA scope scan sees a search from the desktop root and a foreign pattern' {
        $bad = $vehicleText.Replace('$this.Window.FindFirst(', '[System.Windows.Automation.AutomationElement]::RootElement.FindFirst(').
            Replace('[System.Windows.Automation.InvokePattern]::Pattern', '[System.Windows.Automation.WindowPattern]::Pattern')
        $found = Get-UiaScopeViolation $bad
        if (-not ($found -match 'FindFirst on') -or -not ($found -match 'WindowPattern')) { throw "found: $($found -join '; ')" }
    }
    Check 'the launch task stays Interactive in the console session and starts pwsh hidden' {
        if ($launchText -notmatch '-LogonType Interactive') { throw 'the task is no longer Interactive' }
        if ($launchText -notmatch "'-NoProfile -NonInteractive -WindowStyle Hidden [^']*-File ") { throw 'pwsh is not started with -WindowStyle Hidden before -File' }
    }

    $now = [DateTimeOffset]::Parse('2026-10-10T12:00:00Z')
    $request = [pscustomobject]@{
        messageId = 'm1'; agvId = 'A2'; sentAt = '2026-10-10T11:55:00Z'
        payload = [pscustomobject]@{ stationId = 'N1-15_N1-16'; expectedSublots = @('S-1', 'S-2') }
    }
    Check 'a sublot in expectedSublots is accepted' {
        $r = Assert-SublotRequested $request 'A2' 'S-2' $now 30
        if ($r.MessageId -ne 'm1') { throw 'wrong request' }
    }
    foreach ($case in @(
            @{ Name = 'a sublot not in expectedSublots is refused'; Sublot = 'S-3'; Agv = 'A2'; Req = $request },
            @{ Name = 'a sublot differing only in case is refused'; Sublot = 's-1'; Agv = 'A2'; Req = $request },
            @{ Name = 'a request for another vehicle is refused'; Sublot = 'S-1'; Agv = 'A3'; Req = $request },
            @{ Name = 'no request at all is refused'; Sublot = 'S-1'; Agv = 'A2'; Req = $null })) {
        Check $case.Name {
            try { $null = Assert-SublotRequested $case.Req $case.Agv $case.Sublot $now 30 } catch {
                if ($_.Exception.Message -like 'REFUSED:*') { return }
                throw
            }
            throw 'not refused'
        }
    }
    Check 'a stale request is refused' {
        try { $null = Assert-SublotRequested $request 'A2' 'S-1' $now.AddHours(2) 30 } catch {
            if ($_.Exception.Message -like 'REFUSED:*') { return }
            throw
        }
        throw 'not refused'
    }

    Check 'the MVP database path is refused' {
        try { $null = Assert-V2Database 'C:\ProgramData\8005\ControlServer\data\controlserver.db' } catch {
            if ($_.Exception.Message -like 'REFUSED:*') { return }
            throw
        }
        throw 'not refused'
    }
    Check 'a path escaping the v2 root through .. is refused' {
        try { $null = Assert-V2Database 'C:\ProgramData\8005\ControlServer.V2\..\ControlServer\data\controlserver.db' } catch {
            if ($_.Exception.Message -like 'REFUSED:*') { return }
            throw
        }
        throw 'not refused'
    }
    Check 'the v2 database path is accepted' {
        $null = Assert-V2Database 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db'
    }
    Check 'the newest request by time wins when text order disagrees' {
        # '+08:00' text sorts after '+00:00' text, but 10:00+08:00 is 02:00Z -- older than 09:00Z.
        $older = '{"messageId":"old","agvId":"A2","sentAt":"2026-10-10T10:00:00+08:00","payload":{"stationId":"X","expectedSublots":["OLD"]}}'
        $newer = '{"messageId":"new","agvId":"A2","sentAt":"2026-10-10T09:00:00+00:00","payload":{"stationId":"Y","expectedSublots":["NEW"]}}'
        $other = '{"messageId":"other","agvId":"A3","sentAt":"2026-10-10T11:00:00+00:00","payload":{"stationId":"Z","expectedSublots":["OTHER"]}}'
        $picked = Select-LatestSublotRequest @($older, $newer, $other) 'A2'
        if ($picked.messageId -ne 'new') { throw "picked $($picked.messageId)" }
        $picked = Select-LatestSublotRequest @($newer, $older) 'A2'
        if ($picked.messageId -ne 'new') { throw "picked $($picked.messageId) with the lines reversed" }
    }

    . $vehicleScript
    function New-FakeDriver([string[]] $ReadBacks, [bool] $Open = $true) {
        $fake = [pscustomobject]@{ Reads = [System.Collections.Generic.Queue[string]]::new($ReadBacks); Typed = 0; Submits = 0; Open = $Open }
        $fake | Add-Member ScriptMethod CanSubmit { $this.Open }
        $fake | Add-Member ScriptMethod SubmitReady { $true }
        $fake | Add-Member ScriptMethod SetSublot { param($t) $this.Typed++ }
        $fake | Add-Member ScriptMethod ScanText { if ($this.Reads.Count -gt 0) { $this.Reads.Dequeue() } else { '' } }
        $fake | Add-Member ScriptMethod Submit { $this.Submits++ }
        return $fake
    }
    Check 'a clean read-back submits exactly once' {
        $d = New-FakeDriver @('S-1', 'S-1')
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if (-not $r.Submitted -or $d.Submits -ne 1 -or $d.Typed -ne 1) { throw "submits=$($d.Submits) typed=$($d.Typed)" }
    }
    Check 'one bad read-back is retyped, then submitted once' {
        $d = New-FakeDriver @('S-', 'S-1', 'S-1')
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if (-not $r.Submitted -or $d.Submits -ne 1 -or $d.Typed -ne 2) { throw "submits=$($d.Submits) typed=$($d.Typed)" }
    }
    Check 'read-back never matching gives up after 2 retypes without submitting' {
        $d = New-FakeDriver @('x', 'x', 'x', 'x', 'x', 'x')
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -MaxRetypes 2 -WaitSeconds 1
        if ($r.Submitted -or $d.Submits -ne 0 -or $d.Typed -ne 3 -or $r.Outcome -ne 'READBACK_MISMATCH') {
            throw "submitted=$($r.Submitted) submits=$($d.Submits) typed=$($d.Typed) outcome=$($r.Outcome)"
        }
    }
    Check 'a closed input is not typed into' {
        $d = New-FakeDriver @('S-1') -Open $false
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if ($r.Submitted -or $d.Typed -ne 0 -or $r.Outcome -ne 'INPUT_NOT_OPEN') { throw "typed=$($d.Typed) outcome=$($r.Outcome)" }
    }
    Check 'the product refusing is not retried (one submit, whatever follows)' {
        # The tool has no view of the product's answer, so "not retried" is structural: one entry is one Submit.
        $d = New-FakeDriver @('S-1', 'S-1', 'S-1', 'S-1')
        $null = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if ($d.Submits -ne 1) { throw "submits=$($d.Submits)" }
    }
    foreach ($case in @(
            @{ Result = @{ submitted = $true; outcome = 'SUBMITTED_ONCE' }; Expect = 0 },
            @{ Result = @{ submitted = $false; outcome = 'INPUT_NOT_OPEN' }; Expect = 2 },
            @{ Result = @{ submitted = $false; outcome = 'READBACK_MISMATCH' }; Expect = 2 },
            @{ Result = @{ submitted = $false; outcome = 'ERROR' }; Expect = 1 })) {
        Check "exit code for $($case.Result.outcome) is $($case.Expect)" {
            $got = Get-EntryExitCode $case.Result
            if ($got -ne $case.Expect) { throw "got $got" }
        }
    }
    Check 'with no HMI process the vehicle script exits 1, writes ERROR and types nothing' {
        # The real script in a child pwsh, pointed at a process name that cannot exist on this host.
        $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) "ws20-selftest-$([guid]::NewGuid().ToString('N')).json"
        try {
            & pwsh -NoProfile -NonInteractive -File $vehicleScript -Sublot 'S-1' -ResultPath $resultFile -ProcessName 'ws20-no-such-hmi-process' | Out-Null
            $code = $LASTEXITCODE
            if ($code -ne 1) { throw "exit code $code" }
            $r = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json -AsHashtable
            if ($r.submitted -ne $false -or $r.outcome -ne 'ERROR' -or $r.ContainsKey('typings')) {
                throw "submitted=$($r.submitted) outcome=$($r.outcome) typings=$($r.typings)"
            }
        } finally {
            Remove-Item -LiteralPath $resultFile -ErrorAction SilentlyContinue
        }
    }

    "SELFTEST $(if ($failures.Count -eq 0) { 'PASS' } else { "FAIL ($($failures -join '; '))" })"
    if ($failures.Count -ne 0) { exit 1 }
}

if ($PSCmdlet.ParameterSetName -eq 'SelfTest') { Invoke-SelfTest; return }

$ServerDatabase = Assert-V2Database $ServerDatabase
$site = Get-Content (Join-Path $PSScriptRoot "..\config\site-$SshAlias.json") -Raw | ConvertFrom-Json
$agvId = $site.agvId

# 1. The request, read-only from the v2 instance's outbox.
$readRequest = @"
`$env:PATH = '$ServerSqliteTools;$ServerSqliteTools\runtimes\win-x64\native;' + `$env:PATH
foreach (`$a in 'SQLitePCLRaw.core.dll','SQLitePCLRaw.provider.e_sqlite3.dll','SQLitePCLRaw.batteries_v2.dll','Microsoft.Data.Sqlite.dll') { Add-Type -Path (Join-Path '$ServerSqliteTools' `$a) }
[SQLitePCL.Batteries_V2]::Init()
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly'); `$c.Open()
`$cmd = `$c.CreateCommand()
`$cmd.CommandText = "SELECT PayloadJson FROM ProtocolOutbox WHERE MessageType = 'SublotEntryRequested'"
`$r = `$cmd.ExecuteReader(); while (`$r.Read()) { `$r.GetString(0) }; `$r.Close(); `$c.Close()
"@
$lines = $readRequest | ssh $ServerAlias 'pwsh -NoProfile -Command -'
if ($LASTEXITCODE -ne 0) { throw "Reading the request from $ServerAlias failed (exit $LASTEXITCODE)." }
$request = Select-LatestSublotRequest $lines $agvId
$checked = Assert-SublotRequested $request $agvId $Sublot ([DateTimeOffset]::UtcNow) $RequestMaxAgeMinutes
Write-Host "Request $($checked.MessageId) at $($checked.StationId), sent $($checked.SentAt.ToString('o')): expectedSublots [$($checked.ExpectedSublots -join ', ')]"

# 2. Run the vehicle half in the interactive session.
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$resultPath = "$vehicleRoot\result-$runId.json"
ssh $SshAlias "pwsh -NoProfile -Command `"New-Item -ItemType Directory -Force -Path '$vehicleRoot' | Out-Null`""
if ($LASTEXITCODE -ne 0) { throw "Preparing $vehicleRoot on $SshAlias failed." }
scp -q $vehicleScript "${SshAlias}:$($vehicleRoot -replace '\\', '/')/agv-enter-sublot-uia.ps1"
if ($LASTEXITCODE -ne 0) { throw "Copying the vehicle script to $SshAlias failed." }
$launch = New-LaunchScript -VehicleRoot $vehicleRoot -Sublot $Sublot -ResultPath $resultPath -RunId $runId
# Copied and run with -File, never piped to `pwsh -Command -`: that mode reads statement by statement and
# silently drops a trailing multi-line block (this try/finally) at end of input. On 2026-10-10 the task was
# never registered that way, exit code 0, and the station deadline ran out (control-server#566 B 段).
$launchLocal = Join-Path ([System.IO.Path]::GetTempPath()) "enter-sublot-launch-$runId.ps1"
Set-Content -LiteralPath $launchLocal -Value $launch -Encoding utf8NoBOM
try {
    scp -q $launchLocal "${SshAlias}:$($vehicleRoot -replace '\\', '/')/launch-$runId.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Copying the launch script to $SshAlias failed." }
} finally {
    Remove-Item -LiteralPath $launchLocal -ErrorAction SilentlyContinue
}
$launchOutput = @(ssh $SshAlias "pwsh -NoProfile -File `"$vehicleRoot\launch-$runId.ps1`"" 2>&1 | ForEach-Object { "$_" })
$launchOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0 -or -not (Test-LaunchOutput $launchOutput)) {
    throw "Launching the entry task on $SshAlias did not report LAUNCH_DONE with a started task (exit $LASTEXITCODE). Nothing was typed; enter the sublot by hand."
}

# 3. The result.
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 2
    $present = ssh $SshAlias "pwsh -NoProfile -Command `"Test-Path '$resultPath'`""
} until (($present -join '') -match 'True' -or [DateTimeOffset]::UtcNow -ge $deadline)
if (($present -join '') -notmatch 'True') { throw "No result from $SshAlias within ${TimeoutSeconds}s ($resultPath). Nothing is known about the entry; check the screen." }
# Fetched by scp, not printed through ssh: the console code page garbles non-ASCII text on the way back.
$resultLocal = Join-Path ([System.IO.Path]::GetTempPath()) "enter-sublot-result-$runId.json"
scp -q "${SshAlias}:$($resultPath -replace '\\', '/')" $resultLocal
if ($LASTEXITCODE -ne 0) { throw "Copying the result back from $SshAlias failed ($resultPath)." }
$result = Get-Content -LiteralPath $resultLocal -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
Remove-Item -LiteralPath $resultLocal -ErrorAction SilentlyContinue
$result.request = [ordered]@{ messageId = $checked.MessageId; stationId = $checked.StationId; expectedSublots = $checked.ExpectedSublots }
$json = $result | ConvertTo-Json -Depth 5
if ($EvidencePath) { $json | Set-Content -LiteralPath $EvidencePath -Encoding utf8NoBOM }
$json
if (-not $result.submitted) { exit 2 }
