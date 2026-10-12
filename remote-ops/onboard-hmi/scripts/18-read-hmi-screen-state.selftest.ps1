#Requires -Version 7
<#
    The self-test of 18-read-hmi-screen-state.ps1 (onboard-hmi#316), dot-sourced by its Invoke-SelfTest:
    pwsh -File remote-ops/onboard-hmi/scripts/18-read-hmi-screen-state.ps1 -SelfTest

    Offline. SSH is a stand-in script that runs the encoded read script locally against a temporary
    directory; the UIA reading is a stand-in that writes a fixture. Uses $work, $failures and Check from
    Invoke-SelfTest, and the functions of the main script.

    The fixture's field names are those of the onboard client's records (HmiScreenStateDocument,
    HmiScreenState and its parts, serialised camelCase with SNAKE_CASE_UPPER enums, onboard-hmi
    w2g/fp-v2-impl af19f3e). A real file replaces nothing here: the local and field cross-checks are
    where the reader meets one.
#>
if ($MyInvocation.InvocationName -ne '.') { throw 'Dot-sourced by 18-read-hmi-screen-state.ps1 -SelfTest; run that.' }

$mainScript = Join-Path $PSScriptRoot '18-read-hmi-screen-state.ps1'

function ConvertTo-Object($Value) { return $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -DateKind String }

function New-FixtureState {
    $button = { param($key, $content, $visible, $enabled, $automationId = $null, $command = $null)
        [ordered]@{ key = $key; automationId = $automationId; content = $content; visibilityBinding = $null; isEnabledBinding = $null
            commandBinding = $command; visible = $visible; enabled = $enabled; options = $null } }
    $box = { param($key, $visible, $enabled, $hasText)
        [ordered]@{ key = $key; visibilityBinding = $null; isEnabledBinding = $null; textBinding = $key; keyCommandBinding = $null
            visible = $visible; enabled = $enabled; hasText = $hasText; keyCommandEnabled = $null } }
    $template = & $button 'OnConfirmUnableToChargeClick' $null $true $true
    $template.options = @([ordered]@{ automationId = 'UnableToChargeOption-A'; label = '桩故障' })
    return [ordered]@{
        builtAt = '2026-10-12T16:00:00.0000000+08:00'
        programVersion = '1.0.0+af19f3e'
        buttons = @(
            (& $button 'ManualSubmitCommand' '手动提交' $true $true $null 'ManualSubmitCommand')
            (& $button 'OnWireToGateRecoveryClick' '申请恢复' $true $true)
            (& $button 'OnLoadCancellationClick' '取消装货' $false $false)
            (& $button 'OnHardwareRepairReleaseClick' '维修放行' $true $false 'HardwareRepairRelease')
            $template
            (& $button 'ClearLogsCommand' '清空界面记录' $true $true $null 'ClearLogsCommand')
        )
        inputs = @(
            (& $box 'ScanTextBox' $true $true $false)
            (& $box 'RecoveryReason' $true $true $true)
            (& $box 'ForcedHandoffSublot' $false $true $false)
        )
        modals = [ordered]@{ depth = 0; open = @(); top = $null }
        banner = [ordered]@{ stateText = '需要恢复'; hasWarning = $true; hasError = $false; source = 'WIRE_TO_GATE_PRESENTATION'; guidanceHeldByOperatorNotice = $false }
        operatorNotice = $null
        rawCodes = @(
            [ordered]@{ automationId = 'BatteryStatus'; itemStatusBinding = 'BatteryStatus'; visibilityBinding = $null; value = 'NORMAL'; visible = $true }
            [ordered]@{ automationId = 'StationDepartureCountdown'; itemStatusBinding = 'StationDepartureCountdownTier'; visibilityBinding = 'HasStationDepartureCountdown'; value = 'None'; visible = $false }
        )
        journeyPlanLegs = @(); worklistRows = @(); recoveryDemandChoices = @(); selectedRecoveryDemandChoice = $null; lockers = @()
        stationDepartureCountdown = [ordered]@{ visible = $false; tier = 'None'; label = ''; isStationWorkCountdown = $false; deadlineAt = $null }
        cargoHolding = [ordered]@{ visible = $false; status = ''; latestDepartureAt = $null }
        recentOperatorRecords = @()
    }
}

function New-UiaNode([string] $Type, [string] $Name = '', [string] $Id = '', [bool] $Enabled = $true, $Value, $ItemStatus, $Children) {
    $node = [ordered]@{ controlType = $Type; name = $Name; automationId = $Id; itemStatus = $ItemStatus ?? ''; className = ''; isEnabled = $Enabled; isOffscreen = $false; hasFocus = $false; isPassword = $false; rect = @(0, 0, 10, 10) }
    if ($PSBoundParameters.ContainsKey('Value')) { $node.value = $Value }
    if ($Children) { $node.children = @($Children) }
    # A WPF button with string content has a Text child of the same name, as the real tree shows.
    elseif ($Type -eq 'Button' -and $Name) { $node.children = @([ordered]@{ controlType = 'Text'; name = $Name; automationId = ''; itemStatus = ''; className = ''; isEnabled = $Enabled; isOffscreen = $false; hasFocus = $false; isPassword = $false; rect = @(0, 0, 10, 10) }) }
    return $node
}

<# A UIA reading that agrees with New-FixtureState, as agv-capture-hmi-screen.ps1 writes it. -Edit changes the main window's children. #>
function New-FixtureUia([scriptblock] $Edit, [int] $ProcessId = 4242) {
    $children = [System.Collections.Generic.List[object]]::new()
    $children.Add((New-UiaNode 'Text' '物料条码'))
    $children.Add((New-UiaNode 'Edit' '' 'ScanTextBox' -Value ''))
    $children.Add((New-UiaNode 'Button' '手动提交'))
    $children.Add((New-UiaNode 'Text' '需要恢复'))
    $children.Add((New-UiaNode 'Edit' '异常处置原因' 'RecoveryReason' -Value 'SECRET-REASON-TEXT'))
    $children.Add((New-UiaNode 'Button' '申请恢复'))
    $children.Add((New-UiaNode 'Button' '维修放行' 'HardwareRepairRelease' -Enabled $false))
    $children.Add((New-UiaNode 'List' '' 'UnableToChargeOptions' -Children @((New-UiaNode 'Button' '桩故障' 'UnableToChargeOption-A'))))
    $children.Add((New-UiaNode 'Text' '电量正常' 'BatteryStatus' -ItemStatus 'NORMAL'))
    $children.Add((New-UiaNode 'Button' '清空界面记录'))
    $windows = [System.Collections.Generic.List[object]]::new()
    $main = [ordered]@{ handle = '0x10'; process = 'SQCD.Agv.Wpf'; processId = $ProcessId; title = '8005 AGV'; className = 'HwndWrapper[SQCD.Agv.Wpf;;1]'; visible = $true; minimized = $false; uia = $null }
    $windows.Add($main)
    if ($Edit) { & $Edit $children $windows }
    # Built after the edit: New-UiaNode copies the children, so an Add or RemoveAt must come first.
    $main.uia = New-UiaNode 'Window' '8005 AGV' -Children $children
    return ConvertTo-Object ([ordered]@{
            tool = 'agv-capture-hmi-screen'; errors = @(); focusDisturbed = $false; desktop = @{ locked = $false }; screenUniform = $false
            images = @(@{ kind = 'screen' }, @{ kind = 'window' }); uiaNodeCount = 12; uiaTruncated = $false
            hmi = [ordered]@{ running = $true; processes = @(@{ id = $ProcessId }) }; hmiWindows = $windows.ToArray()
        })
}

function Find-Child($Children, [string] $Name) { for ($i = 0; $i -lt $Children.Count; $i++) { if ($Children[$i].name -ceq $Name -or $Children[$i].automationId -ceq $Name) { return $i } }; throw "no fixture node $Name" }

function New-FixtureDocument([hashtable] $Over = @{}, [DateTimeOffset] $Now = [DateTimeOffset]::Now) {
    $doc = [ordered]@{
        schemaVersion = 1; status = 'ACTIVE'; contentRevision = 7; writtenAt = $Now.AddSeconds(-2).ToString('o')
        processStartId = 'a1b2c3'; processId = 4242; processStartedAt = $Now.AddHours(-1).ToString('o'); programVersion = '1.0.0+af19f3e'
        disabledEntry = $null; disabledReason = $null; disabledAt = $null; state = (New-FixtureState)
    }
    foreach ($key in $Over.Keys) { $doc[$key] = $Over[$key] }
    return $doc
}

function New-FixtureRead([hashtable] $Over = @{}, $Processes, [DateTimeOffset] $Now = [DateTimeOffset]::Now, [switch] $NoFile, [byte[]] $Bytes, [string] $Error) {
    $bytes = $Bytes ?? [System.Text.Encoding]::UTF8.GetBytes(((New-FixtureDocument $Over $Now) | ConvertTo-Json -Depth 20 -Compress))
    $read = [ordered]@{
        now = $Now.ToString('o'); directory = 'C:\x'; directoryExists = $true
        current = $NoFile ? $null : [ordered]@{ length = $bytes.Length; offset = 0; base64 = [Convert]::ToBase64String($bytes) }
        currentError = $Error; timeline = $null; timelineError = $null
        processes = @($Processes ?? @([ordered]@{ id = 4242; sessionId = 1; startTime = $Now.AddHours(-1).AddSeconds(-10).ToString('o') }))
    }
    return ConvertTo-Object $read
}

function Invoke-Main([string[]] $Arguments) {
    $out = @(& pwsh -NoProfile -NonInteractive -File $mainScript @Arguments 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ exit = $LASTEXITCODE; text = $out -join "`n" }
}

# --- the script itself --------------------------------------------------------------------------------

Check 'both files parse with zero errors and carry no control character' {
    foreach ($path in @($mainScript, $PSCommandPath)) {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $errors)
        if ($errors.Count -ne 0) { throw "$path : $($errors[0].Message)" }
        $bad = @([System.IO.File]::ReadAllBytes($path) | Where-Object { $_ -lt 32 -and $_ -notin 9, 10, 13 })
        if ($bad.Count) { throw "$path carries $($bad.Count) control character(s)" }
    }
}

Check 'every outcome has an exit code; only ACTIVE and MATCH exit 0, and no two others share one' {
    $text = [System.IO.File]::ReadAllText($mainScript)
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $null, [ref] $null)
    $bodies = @('Get-SnapshotVerdict', 'Get-CrossCheckVerdict') | ForEach-Object {
        $fn = $_; $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true).Extent.Text
    }
    $returned = @([regex]::Matches(($bodies -join "`n"), "(?:Done '|outcome = ')([A-Z_]+)'") | ForEach-Object { $_.Groups[1].Value }) + 'TOOL_FAILURE' | Sort-Object -Unique
    # Computed independently: 7 read outcomes (TOOL_FAILURE from the main flow) + 4 cross-check ones.
    $expected = 'ABSENT', 'ACTIVE', 'CAPTURE_FAILED', 'DISABLED', 'EXITED', 'MATCH', 'MISMATCH', 'MOVING', 'STALE', 'TOOL_FAILURE', 'UNREADABLE'
    if (($returned -join ',') -ne ($expected -join ',')) { throw "outcome literals: $($returned -join ', ')" }
    $missing = @($returned | Where-Object { -not $exitCodes.Contains($_) })
    if ($missing.Count) { throw "no exit code for: $($missing -join ', ')" }
    $zero = @($exitCodes.Keys | Where-Object { $exitCodes[$_] -eq 0 } | Sort-Object)
    if (($zero -join ',') -ne 'ACTIVE,MATCH') { throw "exit 0 for: $($zero -join ', ')" }
    $others = @($exitCodes.Keys | Where-Object { $_ -notin 'ACTIVE', 'MATCH' } | ForEach-Object { $exitCodes[$_] })
    if (@($others | Sort-Object -Unique).Count -ne $others.Count) { throw 'two outcomes share an exit code' }
}

Check 'agv01 is refused before anything runs' {
    $env:HMI316_SSH_LOG = Join-Path $work 'ssh-refused.log'
    $r = Invoke-Main @('-SshAlias', 'agv01', '-SshExecutable', (Join-Path $work 'standin-ssh.ps1'))
    if ($r.exit -eq 0 -or $r.text -notmatch 'Only the spare vehicles agv02 and agv03') { throw "exit $($r.exit): $($r.text)" }
    if (Test-Path -LiteralPath $env:HMI316_SSH_LOG) { throw 'ssh was called' }
}
Check 'there is no default vehicle: no -SshAlias and no -Local is refused' {
    $r = Invoke-Main @()
    if ($r.exit -eq 0 -or $r.text -notmatch 'SshAlias') { throw "exit $($r.exit): $($r.text)" }
}

# --- read-only ------------------------------------------------------------------------------------------

$readScript = New-ReadScript -Directory 'C:\Users\HT\AppData\Local\SQCD\8005AGV\logs' -TimelineLines 20 -ProcessName 'SQCD.Agv.Wpf'
Check 'the read script passes the read-only scan' { Test-ReadOnlyScript $readScript }
foreach ($probe in @(
        'Remove-Item -LiteralPath $path', 'Stop-Process -Id 1', 'Start-Process notepad', 'Register-ScheduledTask -TaskName x',
        'Set-Content -LiteralPath $path -Value x', 'New-Item -ItemType File -Path $path', '& schtasks /create', 'Invoke-Expression $x',
        '& ($a + $b)', '[System.IO.File]::WriteAllText($path, "x")', '[System.IO.File]::Delete($path)', '$process.Kill()')) {
    Check "the read-only scan catches: $probe" {
        $caught = $false
        try { Test-ReadOnlyScript "$readScript`n$probe" } catch { $caught = $true }
        if (-not $caught) { throw 'scan missed it' }
    }
}
foreach ($probe in @(
        @{ Name = 'an Open for writing'; From = '[System.IO.FileAccess]::Read'; To = '[System.IO.FileAccess]::ReadWrite' },
        @{ Name = 'an Open that creates'; From = '[System.IO.FileMode]::Open,'; To = '[System.IO.FileMode]::OpenOrCreate,' },
        @{ Name = 'a share mode without Delete'; From = "[System.IO.FileShare]'ReadWrite, Delete'"; To = "[System.IO.FileShare]'ReadWrite'" })) {
    Check "the read-only scan catches $($probe.Name)" {
        $mutated = $readScript.Replace($probe.From, $probe.To)
        if ($mutated -eq $readScript) { throw 'the probe did not apply' }
        $caught = $false
        try { Test-ReadOnlyScript $mutated } catch { $caught = $true }
        if (-not $caught) { throw 'scan missed it' }
    }
}
Check 'the only thing sent over SSH is the generated read script' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref] $null, [ref] $null)
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.CommandElements[0].Extent.Text -in '$SshExecutable', 'ssh', 'ssh.exe', 'scp' }, $true))
    if ($calls.Count -ne 1) { throw "SSH calls: $($calls.Count)" }
    $fn = $calls[0].Parent
    while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
    if ($fn.Name -ne 'Invoke-StateRead' -or $calls[0].Extent.Text -notmatch '-EncodedCommand \$encoded" 2>&1$') { throw "in $($fn.Name): $($calls[0].Extent.Text)" }
    if ($fn.Extent.Text -notmatch '\$text = New-ReadScript ') { throw 'Invoke-StateRead does not send New-ReadScript' }
}

# --- verdicts --------------------------------------------------------------------------------------------

$now = [DateTimeOffset]::Parse('2027-02-01T08:00:00+08:00')  # a vehicle clock far from the control host's
foreach ($case in @(
        @{ Name = 'fresh, writer alive, on the vehicle clock'; Read = { New-FixtureRead -Now $now }; Expect = 'ACTIVE' },
        @{ Name = 'exactly the limit is still ACTIVE'; Read = { New-FixtureRead @{ writtenAt = $now.AddSeconds(-15).ToString('o') } -Now $now }; Expect = 'ACTIVE' },
        @{ Name = 'past the limit with the writer alive is STALE'; Read = { New-FixtureRead @{ writtenAt = $now.AddSeconds(-16).ToString('o') } -Now $now }; Expect = 'STALE'; Says = '16 s old' },
        @{ Name = 'a writtenAt far in the future is STALE'; Read = { New-FixtureRead @{ writtenAt = $now.AddSeconds(20).ToString('o') } -Now $now }; Expect = 'STALE'; Says = 'ahead of the vehicle clock' },
        @{ Name = 'no process with that id is EXITED'; Read = { New-FixtureRead -Now $now -Processes @([ordered]@{ id = 9; startTime = $null }) }; Expect = 'EXITED'; Says = 'no end marker' },
        @{ Name = 'no HMI process at all is EXITED'; Read = { New-FixtureRead -Now $now -Processes @() }; Expect = 'EXITED' },
        @{ Name = 'a reused process id is EXITED'; Read = { New-FixtureRead -Now $now -Processes @([ordered]@{ id = 4242; startTime = $now.AddHours(-1).AddSeconds(6).ToString('o') }) }; Expect = 'EXITED'; Says = 'now belongs to' },
        @{ Name = 'a process start within the tolerance is the writer'; Read = { New-FixtureRead -Now $now -Processes @([ordered]@{ id = 4242; startTime = $now.AddHours(-1).AddSeconds(4).ToString('o') }) }; Expect = 'ACTIVE' },
        @{ Name = 'an unreadable process start time does not count against it'; Read = { New-FixtureRead -Now $now -Processes @([ordered]@{ id = 4242; startTime = $null }) }; Expect = 'ACTIVE' },
        @{ Name = 'gone and old is EXITED, not STALE'; Read = { New-FixtureRead @{ writtenAt = $now.AddMinutes(-10).ToString('o') } -Now $now -Processes @() }; Expect = 'EXITED' },
        @{ Name = 'DISABLED is DISABLED'; Read = { New-FixtureRead @{ status = 'DISABLED'; state = $null; disabledEntry = 'OnFlushTick'; disabledReason = 'InvalidOperationException'; disabledAt = $now.ToString('o') } -Now $now }; Expect = 'DISABLED'; Says = 'OnFlushTick' },
        @{ Name = 'DISABLED stays DISABLED with the process gone and the file old'; Read = { New-FixtureRead @{ status = 'DISABLED'; state = $null; writtenAt = $now.AddDays(-1).ToString('o') } -Now $now -Processes @() }; Expect = 'DISABLED' },
        @{ Name = 'an unknown status is UNREADABLE'; Read = { New-FixtureRead @{ status = 'PAUSED' } -Now $now }; Expect = 'UNREADABLE' },
        @{ Name = 'another schema version is UNREADABLE'; Read = { New-FixtureRead @{ schemaVersion = 2 } -Now $now }; Expect = 'UNREADABLE'; Says = 'schemaVersion' },
        @{ Name = 'a missing writtenAt is UNREADABLE'; Read = { New-FixtureRead @{ writtenAt = $null } -Now $now }; Expect = 'UNREADABLE'; Says = 'writtenAt' },
        @{ Name = 'ACTIVE without a state is UNREADABLE'; Read = { New-FixtureRead @{ state = $null } -Now $now }; Expect = 'UNREADABLE' },
        @{ Name = 'bytes that are not UTF-8 are UNREADABLE'; Read = { New-FixtureRead -Now $now -Bytes ([byte[]] (0x7B, 0xFF, 0xFE, 0x7D)) }; Expect = 'UNREADABLE' },
        @{ Name = 'a whole JSON document with one byte that is not UTF-8 is UNREADABLE, not a replacement character'; Read = {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(((New-FixtureDocument @{ writtenAt = $now.AddSeconds(-2).ToString('o'); processStartedAt = $now.AddHours(-1).ToString('o') }) | ConvertTo-Json -Depth 20 -Compress).Replace('需要恢复', 'QQQQ'))
                $at = [System.Text.Encoding]::ASCII.GetString($bytes).IndexOf('QQQQ'); $bytes[$at] = 0xFF
                New-FixtureRead -Now $now -Bytes $bytes }; Expect = 'UNREADABLE' },
        @{ Name = 'a JSON array is UNREADABLE'; Read = { New-FixtureRead -Now $now -Bytes ([System.Text.Encoding]::UTF8.GetBytes('[1,2]')) }; Expect = 'UNREADABLE' },
        @{ Name = 'an open that failed is UNREADABLE'; Read = { New-FixtureRead -Now $now -Error 'The process cannot access the file' }; Expect = 'UNREADABLE' },
        @{ Name = 'no file with the HMI running is ABSENT and says so'; Read = { New-FixtureRead -Now $now -NoFile }; Expect = 'ABSENT'; Says = 'switched off' })) {
    Check "verdict: $($case.Name)" {
        $v = Get-SnapshotVerdict -Read (& $case.Read) -StaleAfterSeconds 15
        if ($v.outcome -ne $case.Expect -or ($case.Says -and $v.detail -notmatch [regex]::Escape($case.Says))) { throw "got $($v.outcome): $($v.detail)" }
    }
}

# --- comparison --------------------------------------------------------------------------------------------

$state = ConvertTo-Object (New-FixtureState)
Check 'agreeing snapshot and UIA: 24 compared fields, no difference' {
    $rows = @(Compare-ScreenState $state (New-FixtureUia))
    # Counted from the fixture, not from the code: banner 1; buttons 2+2+1+2+2(options, enabled)+2 = 11;
    # inputs 3+3+1 = 7; modal 2; raw codes 2+1 = 3.
    if ($rows.Count -ne 24) { throw "$($rows.Count) rows: $(($rows | ForEach-Object { "$($_.key).$($_.field)" }) -join ' ')" }
    $diff = @($rows | Where-Object { -not $_.match })
    if ($diff.Count) { throw "differences: $(($diff | ForEach-Object { "$($_.key).$($_.field) $($_.snapshot)/$($_.uia)" }) -join '; ')" }
}
Check 'an input box''s text never enters the comparison' {
    $json = Compare-ScreenState $state (New-FixtureUia { param($c) $c[(Find-Child $c 'ScanTextBox')].value = 'SUBLOT-SECRET-42' }) | ConvertTo-Json -Depth 5
    if ($json -match 'SECRET') { throw 'input text leaked into the rows' }
}
foreach ($case in @(
        @{ Name = 'a button the snapshot shows but UIA does not'; Edit = { param($c) $c.RemoveAt((Find-Child $c '申请恢复')) }; Diff = 'button OnWireToGateRecoveryClick visible' },
        @{ Name = 'a button UIA shows but the snapshot hides'; Edit = { param($c) $c.Add((New-UiaNode 'Button' '取消装货')) }; Diff = 'button OnLoadCancellationClick visible' },
        @{ Name = 'a button enabled on screen but not in the snapshot'; Edit = { param($c) $c[(Find-Child $c 'HardwareRepairRelease')].isEnabled = $true }; Diff = 'button OnHardwareRepairReleaseClick enabled' },
        @{ Name = 'a command button disabled on screen'; Edit = { param($c) $c[(Find-Child $c '清空界面记录')].isEnabled = $false }; Diff = 'button ClearLogsCommand enabled' },
        @{ Name = 'two buttons with the same caption'; Edit = { param($c) $c.Add((New-UiaNode 'Button' '申请恢复')) }; Diff = 'button OnWireToGateRecoveryClick unique' },
        @{ Name = 'a missing template option'; Edit = { param($c) $c[(Find-Child $c 'UnableToChargeOptions')].children = @() }; Diff = 'button OnConfirmUnableToChargeClick options' },
        @{ Name = 'a disabled template option'; Edit = { param($c) $c[(Find-Child $c 'UnableToChargeOptions')].children[0].isEnabled = $false }; Diff = 'button OnConfirmUnableToChargeClick enabled' },
        @{ Name = 'a different banner'; Edit = { param($c) $c[(Find-Child $c '需要恢复')].name = '就绪' }; Diff = 'banner StateText text' },
        @{ Name = 'a banner text elsewhere on screen does not stand in for the banner'; Edit = { param($c) $i = Find-Child $c '需要恢复'; $c[$i].name = '就绪'; $c.Add((New-UiaNode 'Text' '需要恢复')) }; Diff = 'banner StateText text' },
        @{ Name = 'an input box with text the snapshot calls empty'; Edit = { param($c) $c[(Find-Child $c 'ScanTextBox')].value = 'S1' }; Diff = 'input ScanTextBox hasText' },
        @{ Name = 'a disabled input box'; Edit = { param($c) $c[(Find-Child $c 'RecoveryReason')].isEnabled = $false }; Diff = 'input RecoveryReason enabled' },
        @{ Name = 'an input box the snapshot hides'; Edit = { param($c) $c.Add((New-UiaNode 'Edit' '' 'ForcedHandoffSublot' -Value '')) }; Diff = 'input ForcedHandoffSublot visible' },
        @{ Name = 'a raw code with another value'; Edit = { param($c) $c[(Find-Child $c 'BatteryStatus')].itemStatus = 'LOW' }; Diff = 'rawCode BatteryStatus value' },
        @{ Name = 'a raw code element that is gone'; Edit = { param($c) $c.RemoveAt((Find-Child $c 'BatteryStatus')) }; Diff = 'rawCode BatteryStatus visible' },
        @{ Name = 'a raw code the snapshot hides'; Edit = { param($c) $c.Add((New-UiaNode 'Text' '00:45' 'StationDepartureCountdown' -ItemStatus 'Normal')) }; Diff = 'rawCode StationDepartureCountdown visible' },
        @{ Name = 'a dialog the snapshot does not know'; Edit = { param($c, $w) $w.Add([ordered]@{ className = '#32770'; visible = $true; title = '确认'; processId = 4242 }) }; Diff = 'modal dialogs depth|modal dialogs titles' },
        @{ Name = 'a hidden dialog window does not count'; Edit = { param($c, $w) $w.Add([ordered]@{ className = '#32770'; visible = $false; title = '确认'; processId = 4242 }) }; Diff = '' })) {
    Check "compare: $($case.Name)" {
        $diff = @(Compare-ScreenState $state (New-FixtureUia $case.Edit) | Where-Object { -not $_.match } | ForEach-Object { "$($_.category) $($_.key) $($_.field)" })
        if (($diff -join '|') -ne $case.Diff) { throw "differences: '$($diff -join '|')', expected '$($case.Diff)'" }
    }
}
Check 'compare: a dialog title that differs' {
    $withDialog = ConvertTo-Object (New-FixtureState)
    $withDialog.modals = ConvertTo-Object ([ordered]@{ depth = 1; open = @([ordered]@{ title = '确认取消'; callSite = 'OnLoadCancellationClick' }) })
    $diff = @(Compare-ScreenState $withDialog (New-FixtureUia { param($c, $w) $w.Add([ordered]@{ className = '#32770'; visible = $true; title = '确认交接'; processId = 4242 }) }) | Where-Object { -not $_.match } | ForEach-Object { "$($_.category) $($_.key) $($_.field)" })
    if (($diff -join '|') -ne 'modal dialogs titles') { throw "differences: $($diff -join '|')" }
}

# --- cross-check verdict -------------------------------------------------------------------------------------

$active = Get-SnapshotVerdict -Read (New-FixtureRead -Now $now) -StaleAfterSeconds 15
$matchRows = @(Compare-ScreenState $state (New-FixtureUia))
$mismatchRows = @(Compare-ScreenState $state (New-FixtureUia { param($c) $c[(Find-Child $c '需要恢复')].name = '就绪' }))
foreach ($case in @(
        @{ Name = 'nothing moved and no difference is MATCH'; Expect = 'MATCH' },
        @{ Name = 'a locked desktop still gives a UIA reading'; Capture = 'DESKTOP_LOCKED'; Expect = 'MATCH' },
        @{ Name = 'a difference is MISMATCH'; Rows = $mismatchRows; Expect = 'MISMATCH' },
        @{ Name = 'a moved revision is MOVING, even with a difference'; After = @{ contentRevision = 8 }; Rows = $mismatchRows; Expect = 'MOVING' },
        @{ Name = 'a restart is MOVING'; After = @{ processStartId = 'ffff' }; Expect = 'MOVING' },
        @{ Name = 'UIA reading another process is MOVING'; Uia = (New-FixtureUia -ProcessId 77); Expect = 'MOVING' },
        @{ Name = 'a second read that is not ACTIVE is MOVING'; AfterVerdict = (Get-SnapshotVerdict -Read (New-FixtureRead -Now $now -Processes @()) -StaleAfterSeconds 15); Expect = 'MOVING' },
        @{ Name = 'a first read that is STALE stays STALE'; BeforeVerdict = (Get-SnapshotVerdict -Read (New-FixtureRead @{ writtenAt = $now.AddMinutes(-1).ToString('o') } -Now $now) -StaleAfterSeconds 15); Expect = 'STALE' },
        @{ Name = 'a capture that timed out is CAPTURE_FAILED'; Capture = 'TIMEOUT'; Expect = 'CAPTURE_FAILED' },
        @{ Name = 'a truncated UIA walk is CAPTURE_FAILED'; Uia = (New-FixtureUia | ForEach-Object { $_.uiaTruncated = $true; $_ }); Expect = 'CAPTURE_FAILED' },
        @{ Name = 'an element that went away mid-walk is CAPTURE_FAILED'; Uia = (New-FixtureUia { param($c) $c[0].truncated = 'element-gone' }); Expect = 'CAPTURE_FAILED' },
        @{ Name = 'no main window is CAPTURE_FAILED'; Uia = (New-FixtureUia { param($c, $w) $w[0].visible = $false }); Expect = 'CAPTURE_FAILED' })) {
    Check "cross-check: $($case.Name)" {
        $before = $case.BeforeVerdict ?? $active
        $after = $case.AfterVerdict
        if (-not $after) { $after = [ordered]@{}; foreach ($k in $active.Keys) { $after[$k] = $active[$k] }; if ($case.After) { foreach ($k in $case.After.Keys) { $after[$k] = $case.After[$k] } } }
        $v = Get-CrossCheckVerdict -Before $before -After $after -CaptureOutcome ($case.Capture ?? 'CAPTURED') -Uia ($case.Uia ?? (New-FixtureUia)) -Rows ($case.Rows ?? $matchRows)
        if ($v.outcome -ne $case.Expect) { throw "got $($v.outcome): $($v.detail)" }
    }
}

Check '17''s capture outcome rule can be lifted and judges a complete local reading CAPTURED' {
    . ([scriptblock]::Create((Import-CaptureOutcomeRule)))
    $got = Get-CaptureOutcome ([pscustomobject]@{ consoleSessionId = 1; wshDisabled = $false; otherDesktopTools = @() }) (New-FixtureUia) $false
    if ($got -ne 'CAPTURED') { throw "got $got" }
}
Check 'the UIA reading carries ItemStatus, which the raw-code comparison needs' {
    if ([System.IO.File]::ReadAllText($vehicleCaptureScript) -notmatch 'itemStatus\s*=\s*\$c\.ItemStatus') { throw "agv-capture-hmi-screen.ps1 does not read ItemStatus" }
}

# --- end to end, offline ---------------------------------------------------------------------------------------

$standinSsh = Join-Path $work 'standin-ssh.ps1'
Set-Content -LiteralPath $standinSsh -Encoding utf8NoBOM -Value @'
# ssh stand-in: logs its arguments and runs the encoded command locally. No param block, so -o lands in $args.
Add-Content -LiteralPath $env:HMI316_SSH_LOG -Value ($args -join ' ')
if ([string] $args[-1] -notmatch '-EncodedCommand (\S+)') { 'standin: no encoded command'; exit 255 }
& pwsh -NoProfile -NonInteractive -EncodedCommand $Matches[1]
exit $LASTEXITCODE
'@
$standinCapture = Join-Path $work 'standin-capture.ps1'
Set-Content -LiteralPath $standinCapture -Encoding utf8NoBOM -Value @'
# 17-capture-hmi-screen stand-in: writes a run record and the UIA fixture; can bump the snapshot mid-capture.
param([string] $SshAlias, [string] $EvidenceDirectory, [int] $TimeoutSeconds)
$name = "$SshAlias-capture"
Copy-Item -LiteralPath $env:HMI316_UIA_FIXTURE -Destination (Join-Path $EvidenceDirectory "$name-uia.json")
if ($env:HMI316_BUMP) { $path = Join-Path $env:HMI316_BUMP 'hmi-state.json'; $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json; $doc.contentRevision++; [System.IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 20 -Compress)) }
@{ name = $name; outcome = 'CAPTURED' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$name-run.json")
exit 0
'@
$standinLocalCapture = Join-Path $work 'standin-local-capture.ps1'
Set-Content -LiteralPath $standinLocalCapture -Encoding utf8NoBOM -Value @'
# agv-capture-hmi-screen stand-in for -Local.
param([string] $OutputDirectory, [string] $Stamp, [string] $ProcessName, [int] $ProcessId)
Copy-Item -LiteralPath $env:HMI316_UIA_FIXTURE -Destination (Join-Path $OutputDirectory "$Stamp-uia.json")
'@
$env:HMI316_SSH_LOG = Join-Path $work 'ssh.log'
$self = Get-Process -Id $PID

function New-VehicleDirectory([hashtable] $Over = @{}, [switch] $Empty) {
    $dir = Join-Path $work ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    if (-not $Empty) {
        $base = @{ processId = $PID; processStartedAt = [DateTimeOffset]::Now.ToString('o'); writtenAt = [DateTimeOffset]::Now.ToString('o') }
        foreach ($k in $Over.Keys) { $base[$k] = $Over[$k] }
        [System.IO.File]::WriteAllText((Join-Path $dir 'hmi-state.json'), ((New-FixtureDocument $base) | ConvertTo-Json -Depth 20 -Compress))
    }
    return $dir
}
$remote = { param($dir, [string[]] $more) @('-SshAlias', 'agv02', '-VehicleDirectory', $dir, '-SshExecutable', $standinSsh, '-ProcessName', $self.ProcessName) + $more }

foreach ($case in @(
        @{ Name = 'ACTIVE exits 0'; Dir = { New-VehicleDirectory }; Exit = 0 },
        @{ Name = 'STALE exits 3'; Dir = { New-VehicleDirectory @{ writtenAt = [DateTimeOffset]::Now.AddMinutes(-2).ToString('o') } }; Exit = 3 },
        @{ Name = 'EXITED exits 4'; Dir = { New-VehicleDirectory @{ processId = 999999 } }; Exit = 4 },
        @{ Name = 'a reused id exits 4'; Dir = { New-VehicleDirectory @{ processStartedAt = $self.StartTime.AddMinutes(-5).ToString('o') } }; Exit = 4 },
        @{ Name = 'DISABLED exits 2'; Dir = { New-VehicleDirectory @{ status = 'DISABLED'; state = $null } }; Exit = 2 },
        @{ Name = 'ABSENT exits 5'; Dir = { New-VehicleDirectory -Empty }; Exit = 5 },
        @{ Name = 'a missing directory exits 5'; Dir = { Join-Path $work 'no-such-directory' }; Exit = 5 },
        @{ Name = 'UNREADABLE exits 6'; Dir = { $d = New-VehicleDirectory -Empty; Set-Content -LiteralPath (Join-Path $d 'hmi-state.json') -Value 'not json'; $d }; Exit = 6 })) {
    Check "end to end over the ssh stand-in: $($case.Name)" {
        Remove-Item -LiteralPath $env:HMI316_SSH_LOG -ErrorAction SilentlyContinue
        $r = Invoke-Main (& $remote (& $case.Dir) @())
        if ($r.exit -ne $case.Exit) { throw "exit $($r.exit): $($r.text)" }
        $log = Get-Content -LiteralPath $env:HMI316_SSH_LOG -Raw
        if ($log -notmatch '(^| )agv02 pwsh -NoProfile -NonInteractive -EncodedCommand ') { throw "ssh was called as: $log" }
    }
}
Check 'end to end: a failing ssh is TOOL_FAILURE' {
    $failing = Join-Path $work 'failing-ssh.ps1'
    Set-Content -LiteralPath $failing -Value "'ssh: connect to host agv02 port 22022: Connection timed out'; exit 255"
    $r = Invoke-Main @('-SshAlias', 'agv02', '-VehicleDirectory', 'C:\x', '-SshExecutable', $failing)
    if ($r.exit -ne 1 -or $r.text -notmatch 'TOOL_FAILURE') { throw "exit $($r.exit): $($r.text)" }
}
Check 'end to end: the evidence holds the file byte for byte and the timeline tail is the newest lines' {
    $dir = New-VehicleDirectory
    $lines = 1..3 | ForEach-Object { (New-FixtureDocument @{ contentRevision = $_ }) | ConvertTo-Json -Depth 20 -Compress }
    Set-Content -LiteralPath (Join-Path $dir 'hmi-state-20261011.ndjson') -Value 'old day' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $dir 'hmi-state-20261012.ndjson') -Value $lines -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $dir 'hmi-state-20261013.ndjson.tmp') -Value 'not a timeline' -Encoding utf8NoBOM
    $evidence = Join-Path $work 'evidence-read'
    $r = Invoke-Main (& $remote $dir @('-EvidenceDirectory', $evidence, '-TimelineLines', '2'))
    if ($r.exit -ne 0) { throw "exit $($r.exit): $($r.text)" }
    if ($r.text -notmatch 'hmi-state-20261012\.ndjson' -or $r.text -notmatch 'rev 3' -or $r.text -match 'rev 1\b') { throw "timeline: $($r.text)" }
    $saved = @(Get-ChildItem -LiteralPath $evidence -Filter 'agv02-*-state.json')
    if ($saved.Count -ne 1) { throw "saved state files: $($saved.Count)" }
    $same = [Linq.Enumerable]::SequenceEqual([System.IO.File]::ReadAllBytes($saved[0].FullName), [System.IO.File]::ReadAllBytes((Join-Path $dir 'hmi-state.json')))
    if (-not $same) { throw 'the saved copy differs from the file' }
    if (@(Get-ChildItem -LiteralPath $evidence -Filter 'agv02-*-read.json').Count -ne 1) { throw 'no read record' }
}

foreach ($case in @(
        @{ Name = 'agreeing screens are MATCH'; Uia = { New-FixtureUia -ProcessId $PID }; Exit = 0 },
        @{ Name = 'a different banner is MISMATCH'; Uia = { New-FixtureUia { param($c) $c[(Find-Child $c '需要恢复')].name = '就绪' } -ProcessId $PID }; Exit = 10 },
        @{ Name = 'a revision that moves during the capture is MOVING'; Uia = { New-FixtureUia -ProcessId $PID }; Bump = $true; Exit = 11 })) {
    Check "end to end -CrossCheck over the stand-ins: $($case.Name)" {
        $dir = New-VehicleDirectory
        $fixture = Join-Path $work "uia-$([guid]::NewGuid().ToString('N').Substring(0, 6)).json"
        (& $case.Uia) | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $fixture -Encoding utf8NoBOM
        $env:HMI316_UIA_FIXTURE = $fixture
        $env:HMI316_BUMP = $case.Bump ? $dir : ''
        $evidence = Join-Path $work "evidence-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        $r = Invoke-Main (& $remote $dir @('-CrossCheck', '-EvidenceDirectory', $evidence, '-CaptureScript', $standinCapture, '-SettleMilliseconds', '50'))
        $env:HMI316_BUMP = ''
        if ($r.exit -ne $case.Exit) { throw "exit $($r.exit): $($r.text)" }
        $record = Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $evidence -Filter '*-crosscheck.json')[0].FullName) -Raw | ConvertFrom-Json
        if ($case.Exit -in 0, 10 -and @($record.rows).Count -ne 24) { throw "rows in the record: $(@($record.rows).Count)" }
        if (@(Get-ChildItem -LiteralPath $evidence -Filter '*-state-before.json').Count -ne 1 -or @(Get-ChildItem -LiteralPath $evidence -Filter '*-state-after.json').Count -ne 1) { throw 'before/after copies missing' }
    }
}
Check 'end to end -Local -CrossCheck: same comparison, no SSH, judged by 17''s rule' {
    $dir = New-VehicleDirectory
    $fixture = Join-Path $work 'uia-local.json'
    New-FixtureUia -ProcessId $PID | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $fixture -Encoding utf8NoBOM
    $env:HMI316_UIA_FIXTURE = $fixture
    Remove-Item -LiteralPath $env:HMI316_SSH_LOG -ErrorAction SilentlyContinue
    $evidence = Join-Path $work 'evidence-local'
    $r = Invoke-Main @('-Local', '-Directory', $dir, '-ProcessName', $self.ProcessName, '-CrossCheck', '-EvidenceDirectory', $evidence, '-CaptureScript', $standinLocalCapture, '-SettleMilliseconds', '50')
    if ($r.exit -ne 0) { throw "exit $($r.exit): $($r.text)" }
    if (Test-Path -LiteralPath $env:HMI316_SSH_LOG) { throw 'ssh was called in local mode' }
    if (@(Get-ChildItem -LiteralPath $evidence -Filter 'local-*-uia-uia.json').Count -ne 1) { throw 'no local UIA reading in the evidence' }
}

<#
    Measured 2026-10-12 on Windows 11 26200 (scratch experiment, 4 s each): while a reader holds hmi-state.json
    open, File.Move(tmp, current, overwrite) fails whether or not the reader shares Delete (no reader 0/467
    replaces failed; ReadWrite|Delete 97/211; ReadWrite 89/204). MoveFileEx does not use POSIX rename, so the
    share mode does not buy the replace; what keeps the writer whole is its own retry (HmiScreenStateFileWriter:
    5 attempts, 10 ms apart) and a read that holds the handle for well under a millisecond. This test holds
    that the worst case is one lost write, never a blocked writer: with the writer's retry verbatim and a
    reader 50 times a second (the script reads once per run), every read is a whole document and no two
    replaces in a row give up. A single give-up does happen: 1 in 2064 on 2026-10-12 under Invoke-HeavyLocal's
    BelowNormal priority (0 in 3280 at normal priority); the product then logs one line and the next
    heartbeat writes again.
#>
Check 'reading while the writer replaces the file: every read is whole, and the writer never gives up twice in a row' {
    $dir = New-VehicleDirectory
    # 7 is the file New-VehicleDirectory wrote, read before the first replace.
    $a = [System.Text.Encoding]::UTF8.GetBytes(((New-FixtureDocument @{ contentRevision = 1 }) | ConvertTo-Json -Depth 20 -Compress))
    $b = [System.Text.Encoding]::UTF8.GetBytes(((New-FixtureDocument @{ contentRevision = 2; state = $null; status = 'DISABLED' }) | ConvertTo-Json -Depth 20 -Compress))
    $sync = [hashtable]::Synchronized(@{ stop = $false; replaces = 0; retried = 0; exhausted = 0; streak = 0; maxStreak = 0; lastError = $null })
    $writer = Start-ThreadJob -ArgumentList $dir, $sync, $a, $b -ScriptBlock {
        param($dir, $sync, $a, $b)
        $current = Join-Path $dir 'hmi-state.json'; $tmp = "$current.tmp"; $i = 0
        while (-not $sync.stop) {
            [System.IO.File]::WriteAllBytes($tmp, (($i++ % 2) ? $a : $b))
            for ($attempt = 1; ; $attempt++) {
                try { [System.IO.File]::Move($tmp, $current, $true); $sync.replaces++; $sync.streak = 0; break }
                catch {
                    $sync.lastError = $_.Exception.Message
                    if ($attempt -ge 5) { $sync.exhausted++; $sync.streak++; $sync.maxStreak = [Math]::Max($sync.maxStreak, $sync.streak); break }
                    $sync.retried++
                    Start-Sleep -Milliseconds 10
                }
            }
        }
    }
    $block = [scriptblock]::Create((New-ReadScript -Directory $dir -TimelineLines 0 -ProcessName 'no-such-process-hmi316'))
    $reads = 0; $broken = 0; $why = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            $answer = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((& $block))) | ConvertFrom-Json
            try { $doc = ConvertFrom-Base64Utf8 $answer.current.base64 | ConvertFrom-Json; if ($doc.contentRevision -notin 1, 2, 7) { $broken++; $why = "revision $($doc.contentRevision)" } }
            catch { $broken++; $why = $answer.currentError ?? "no file: $($_.Exception.Message)" }
            $reads++
            Start-Sleep -Milliseconds 20
        }
    } finally {
        $sync.stop = $true
        $writer | Wait-Job -Timeout 10 | Out-Null
        $writer | Remove-Job -Force
    }
    if ($reads -lt 20 -or $sync.replaces -lt 100) { throw "too little overlap to prove anything: $reads reads, $($sync.replaces) replaces" }
    if ($broken) { throw "$broken of $reads reads were not a whole document (last: $why)" }
    if ($sync.maxStreak -ge 2) { throw "$($sync.maxStreak) replaces in a row gave up after the writer's 5 attempts ($($sync.lastError)): the reader blocked the writer, not one heartbeat" }
    Write-Host "  ($reads reads, $($sync.replaces) replaces, $($sync.retried) retries, $($sync.exhausted) single give-up(s), longest run $($sync.maxStreak))"
}
