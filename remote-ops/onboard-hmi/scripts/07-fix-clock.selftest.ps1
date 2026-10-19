#Requires -Version 7
<#
    The self-test of 07-fix-clock.ps1 (workspace#54, workspace#55), dot-sourced by its Invoke-SelfTest:
    pwsh -File remote-ops/onboard-hmi/scripts/07-fix-clock.ps1 -SelfTest

    Offline and unelevated. The clock, w32tm and Set-Date are stand-ins; the registry cases write a
    temporary HKCU key ($work, removed by Invoke-SelfTest). Nothing here touches the machine's clock,
    w32time or the scheduled tasks. Uses $work, $failures and Check from Invoke-SelfTest, and the
    functions of the main script.
#>
if ($MyInvocation.InvocationName -ne '.') { throw 'Dot-sourced by 07-fix-clock.ps1 -SelfTest; run that.' }

$mainScript = Join-Path $PSScriptRoot '07-fix-clock.ps1'
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref] $null, [ref] $null)

function Find-Commands([System.Management.Automation.Language.Ast] $Ast, [string] $Name) {
    return @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
}

# A clock that is $Offset seconds ahead of the server; Measure and Adjust as the main script calls them.
function New-StandinClock([Nullable[double]] $Offset, [switch] $AdjustDoesNothing, [switch] $LoseServerAfterAdjust) {
    $clock = [pscustomobject]@{ Offset = $Offset; Adjusts = [System.Collections.Generic.List[double]]::new(); Reachable = ($null -ne $Offset) }
    $measure = { if ($clock.Reachable) { $clock.Offset } else { $null } }.GetNewClosure()
    $adjust = {
        param([TimeSpan] $by)
        $clock.Adjusts.Add($by.TotalSeconds)
        if (-not $AdjustDoesNothing) { $clock.Offset += $by.TotalSeconds }
        if ($LoseServerAfterAdjust) { $clock.Reachable = $false }
    }.GetNewClosure()
    $clock | Add-Member -NotePropertyName Measure -NotePropertyValue $measure
    $clock | Add-Member -NotePropertyName Adjust -NotePropertyValue $adjust
    return $clock
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

Check 'MaxAllowedPhaseOffset is still left alone (the guard of workspace#5 stands; workspace#55 steps by itself)' {
    if ([System.IO.File]::ReadAllText($mainScript) -match "-Name\s+'MaxAllowedPhaseOffset'") { throw 'the script writes MaxAllowedPhaseOffset' }
}

# --- ws#54: the registry writes ------------------------------------------------------------------------

Check 'precondition: on this pwsh, Get-ItemProperty reads REG_DWORD 0xFFFFFFFF back as UInt32 4294967295' {
    # If this ever stops being true the cases below still pass, but no longer exercise what broke on agv02.
    New-ItemProperty -Path $work -Name 'Probe' -PropertyType DWord -Value -1 -Force | Out-Null
    $read = (Get-ItemProperty -Path $work).Probe
    if ($read -isnot [uint32] -or $read -ne 4294967295) { throw "read back as $($read.GetType().FullName) $read" }
}

foreach ($case in @(
        @{ Name = 'absent'; Kind = $null; Value = $null; Was = '<unset>' },
        @{ Name = 'REG_DWORD 0xFFFFFFFF (agv02 since 09-21)'; Kind = 'DWord'; Value = -1; Was = '0xFFFFFFFF' },
        @{ Name = 'REG_DWORD 54000 (the image)'; Kind = 'DWord'; Value = 54000; Was = '0x0000D2F0' },
        @{ Name = 'REG_QWORD 4294967295'; Kind = 'QWord'; Value = [long] 4294967295; Was = 'REG_QWORD 4294967295' },
        @{ Name = 'REG_SZ "4294967295"'; Kind = 'String'; Value = '4294967295'; Was = 'REG_STRING 4294967295' })) {
    Check "Set-W32TimeDword over an old value that is $($case.Name): written as DWORD 0xFFFFFFFF, old value reported" {
        Remove-ItemProperty -Path $work -Name 'MaxPosPhaseCorrection' -ErrorAction SilentlyContinue
        if ($case.Kind) { New-ItemProperty -Path $work -Name 'MaxPosPhaseCorrection' -PropertyType $case.Kind -Value $case.Value | Out-Null }
        $out = (Set-W32TimeDword -Path $work -Name 'MaxPosPhaseCorrection' -Value 0xFFFFFFFF 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $key = Get-Item -LiteralPath $work
        if ($key.GetValueKind('MaxPosPhaseCorrection') -ne 'DWord') { throw "kind $($key.GetValueKind('MaxPosPhaseCorrection'))" }
        if ((Format-Dword $key.GetValue('MaxPosPhaseCorrection')) -ne '0xFFFFFFFF') { throw "bits $(Format-Dword $key.GetValue('MaxPosPhaseCorrection'))" }
        if ($out -notmatch [regex]::Escape("MaxPosPhaseCorrection = 0xFFFFFFFF (was $($case.Was))")) { throw "said: $out" }
    }
}
Check 'Set-W32TimeDword writes an ordinary value too (SpecialPollInterval 3600)' {
    Set-W32TimeDword -Path $work -Name 'SpecialPollInterval' -Value 3600 6>$null
    if ((Get-Item -LiteralPath $work).GetValue('SpecialPollInterval') -ne 3600) { throw 'not 3600' }
}
Check 'Format-Dword prints the same bits for -1, 4294967295 and 0xFFFFFFFF' {
    $all = @((Format-Dword -1), (Format-Dword ([uint32] 4294967295)), (Format-Dword ([long] 4294967295)), (Format-Dword 0xFFFFFFFF)) | Sort-Object -Unique
    if ($all -ne '0xFFFFFFFF') { throw "got $($all -join ', ')" }
}

# --- ws#54: the failure path says whether the clock moved ------------------------------------------------

Check 'a failure before the clock moves says THE CLOCK WAS NOT CHANGED (时钟未改)' {
    $script:ClockTouched = $false
    try { Set-W32TimeDword -Path "$work\no-such-key" -Name 'X' -Value 1 6>$null; throw 'no error' } catch { if ($_.Exception.Message -notmatch 'Missing registry key') { throw } }
    if ($script:ClockTouched) { throw 'a registry failure marked the clock as touched' }
    $notice = Get-FailureNotice -ClockTouched $script:ClockTouched
    if ($notice -notmatch 'THE CLOCK WAS NOT CHANGED' -or $notice -notmatch '时钟未改') { throw "said: $notice" }
}
Check 'a failure after the clock may have moved does not claim it was not changed' {
    $notice = Get-FailureNotice -ClockTouched $true
    if ($notice -match 'NOT CHANGED|时钟未改') { throw "said: $notice" }
}
Check 'main flow: every registry write comes before the first thing that can move the clock, and the catch prints the notice' {
    $try = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $false)
    $lastWrite = (Find-Commands $try.Body 'Set-W32TimeDword' | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Maximum).Maximum
    $touch = @($try.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ClockTouched' }, $true))[0].Extent.StartOffset
    $firstMove = @(@('Restart-Service', 'Invoke-Resync', 'Set-Date', 'Invoke-SubSecondCorrection') | ForEach-Object { Find-Commands $try.Body $_ } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
    if (-not ($lastWrite -lt $touch -and $touch -lt $firstMove)) { throw "last write $lastWrite, touched $touch, first move $firstMove" }
    if ($try.CatchClauses[0].Body.Extent.Text -notmatch 'Get-FailureNotice -ClockTouched \$script:ClockTouched' -or $try.CatchClauses[0].Body.Extent.Text -notmatch '\bthrow\b') { throw 'catch does not print the notice and rethrow' }
}

# --- ws#55: measuring --------------------------------------------------------------------------------------

foreach ($case in @(
        @{ Name = '10-18 agv02, 0.77 s slow'; Lines = @('Tracking 172.19.205.222 [172.19.205.222:123].', 'Collecting 3 samples.', 'The current time is 2026/10/18 15:40:12.', '15:40:12, +00.7672419s', '15:40:14, +00.7689102s', '15:40:16, +00.7677313s'); Expect = -0.7677313 },
        @{ Name = 'a decimal comma'; Lines = @('15:40:12, +00,7672419s'); Expect = -0.7672419 },
        @{ Name = 'workspace#5, 137 days fast'; Lines = @('10:00:00, -11873082.0000000s', '10:00:02, -11873082.0100000s'); Expect = 11873082.0 },
        @{ Name = 'the median, not one slow sample'; Lines = @('1, +00.0100000s', '2, +00.9000000s', '3, +00.0200000s'); Expect = -0.02 },
        @{ Name = 'no server'; Lines = @('Tracking 172.19.205.222 [172.19.205.222:123].', '15:40:12, error: 0x800705B4'); Expect = $null })) {
    Check "stripchart: $($case.Name)" {
        $got = ConvertFrom-StripchartOutput -Lines $case.Lines
        if ($null -eq $case.Expect) { if ($null -ne $got) { throw "got $got" }; return }
        if ($null -eq $got -or [Math]::Abs($got - $case.Expect) -gt 1e-6) { throw "got $got, expected $($case.Expect)" }
    }
}

# --- ws#55: deciding ---------------------------------------------------------------------------------------

foreach ($case in @(
        @{ Offset = $null; Action = 'Unknown' },
        @{ Offset = 0.1; Action = 'None' },
        @{ Offset = -0.1; Action = 'None' },
        @{ Offset = 0.2; Action = 'None' },
        @{ Offset = -0.2; Action = 'None' },
        @{ Offset = 0.2001; Action = 'Adjust'; By = -0.2001 },
        @{ Offset = -0.7677; Action = 'Adjust'; By = 0.7677 },
        @{ Offset = 0.77; Action = 'Adjust'; By = -0.77 },
        @{ Offset = 4.99; Action = 'Adjust'; By = -4.99 },
        @{ Offset = 5.0; Action = 'Coarse' },
        @{ Offset = 11873082.0; Action = 'Coarse' },
        @{ Offset = -259200.0; Action = 'Coarse' })) {
    Check "decision: offset $($case.Offset ?? 'unmeasured') s is $($case.Action)" {
        $d = Get-ClockCorrection -OffsetSeconds $case.Offset
        if ($d.Action -ne $case.Action) { throw "got $($d.Action)" }
        if ($case.ContainsKey('By') -and [Math]::Abs($d.AdjustSeconds - $case.By) -gt 1e-9) { throw "adjust by $($d.AdjustSeconds), expected $($case.By)" }
    }
}

# --- ws#55: correcting, with a stand-in clock ----------------------------------------------------------------

foreach ($case in @(
        @{ Name = '0.77 s slow (10-18 agv02) is stepped forward by 0.77 s'; Clock = { New-StandinClock -0.7677 }; Outcome = 'ADJUSTED'; Adjusts = @(0.7677) },
        @{ Name = '0.77 s fast is stepped back by 0.77 s'; Clock = { New-StandinClock 0.77 }; Outcome = 'ADJUSTED'; Adjusts = @(-0.77) },
        @{ Name = '0.1 s is left alone'; Clock = { New-StandinClock 0.1 }; Outcome = 'IN_RANGE'; Adjusts = @() },
        @{ Name = 'exactly 0.2 s is left alone'; Clock = { New-StandinClock -0.2 }; Outcome = 'IN_RANGE'; Adjusts = @() },
        @{ Name = 'no server: not stepped, and not a success'; Clock = { New-StandinClock $null }; Outcome = 'UNMEASURED'; Adjusts = @() },
        @{ Name = 'days off: not stepped here, and not a success'; Clock = { New-StandinClock 11873082.0 }; Outcome = 'COARSE'; Adjusts = @() },
        @{ Name = 'a step that does not take is NOT_CONFIRMED'; Clock = { New-StandinClock -0.77 -AdjustDoesNothing }; Outcome = 'NOT_CONFIRMED'; Adjusts = @(0.77) },
        @{ Name = 'a step that cannot be re-measured is NOT_CONFIRMED'; Clock = { New-StandinClock -0.77 -LoseServerAfterAdjust }; Outcome = 'NOT_CONFIRMED'; Adjusts = @(0.77) })) {
    Check "correction: $($case.Name)" {
        $clock = & $case.Clock
        $r = Invoke-SubSecondCorrection -Measure $clock.Measure -Adjust $clock.Adjust 6>$null
        if ($r.Outcome -ne $case.Outcome) { throw "outcome $($r.Outcome)" }
        if ($clock.Adjusts.Count -ne $case.Adjusts.Count) { throw "$($clock.Adjusts.Count) adjust call(s): $($clock.Adjusts -join ', ')" }
        for ($i = 0; $i -lt $case.Adjusts.Count; $i++) { if ([Math]::Abs($clock.Adjusts[$i] - $case.Adjusts[$i]) -gt 1e-6) { throw "adjusted by $($clock.Adjusts[$i]), expected $($case.Adjusts[$i])" } }
        $success = Test-ClockCorrectionSucceeded $r
        if ($success -ne ($case.Outcome -in 'IN_RANGE', 'ADJUSTED')) { throw "success $success for $($r.Outcome)" }
        if ($case.Outcome -eq 'ADJUSTED' -and [Math]::Abs($clock.Offset) -gt 1e-6) { throw "clock left $($clock.Offset) s off" }
    }
}

# --- ws#55: the startup task ----------------------------------------------------------------------------------

function Invoke-StandinStartup($Clock, [scriptblock] $Resync, [int] $Rounds = 10) {
    $sleeps = [System.Collections.Generic.List[int]]::new()
    $r = Invoke-StartupClockCheck -Resync $Resync -Measure $Clock.Measure -Adjust $Clock.Adjust -Sleep { $sleeps.Add(1) }.GetNewClosure() -Rounds $Rounds 6>$null
    return [pscustomobject]@{ Result = $r; Sleeps = $sleeps.Count }
}

Check 'startup, 10-18 agv02: resync succeeds and leaves 0.77 s, the task steps it out in round 1' {
    $clock = New-StandinClock -0.7677
    $s = Invoke-StandinStartup $clock { $true }
    if ($s.Result.Outcome -ne 'ADJUSTED' -or $clock.Adjusts.Count -ne 1 -or $s.Sleeps -ne 0) { throw "$($s.Result.Outcome), $($clock.Adjusts.Count) adjust(s), $($s.Sleeps) sleep(s)" }
}
Check 'startup: link down for two rounds, then 0.77 s slow -- stepped in round 3' {
    $clock = New-StandinClock -0.77
    $clock.Reachable = $false
    $round = [ref] 0
    $s = Invoke-StandinStartup $clock { $round.Value++; if ($round.Value -ge 3) { $clock.Reachable = $true }; $clock.Reachable }.GetNewClosure()
    if ($s.Result.Outcome -ne 'ADJUSTED' -or $s.Sleeps -ne 2 -or $clock.Adjusts.Count -ne 1) { throw "$($s.Result.Outcome), $($s.Sleeps) sleep(s), $($clock.Adjusts.Count) adjust(s)" }
}
Check 'startup: never measured -- UNMEASURED after every round, nothing stepped, exit would be 1' {
    $clock = New-StandinClock $null
    $s = Invoke-StandinStartup $clock { $false } -Rounds 4
    if ($s.Result.Outcome -ne 'UNMEASURED' -or $s.Sleeps -ne 3 -or $clock.Adjusts.Count -ne 0 -or (Test-ClockCorrectionSucceeded $s.Result)) { throw "$($s.Result.Outcome), $($s.Sleeps) sleep(s)" }
}
Check 'startup: days off is left to the resync, which brings it in on round 2; the sub-second step never fires' {
    $clock = New-StandinClock 11873082.0
    $round = [ref] 0
    $s = Invoke-StandinStartup $clock { $round.Value++; if ($round.Value -eq 2) { $clock.Offset = 0.05 }; $round.Value -ge 2 }.GetNewClosure()
    if ($s.Result.Outcome -ne 'IN_RANGE' -or $clock.Adjusts.Count -ne 0) { throw "$($s.Result.Outcome), $($clock.Adjusts.Count) adjust(s)" }
}

Check 'startup task: runs the installed copy with -AtStartup and the server' {
    $arguments = New-StartupTaskArguments -ScriptPath 'C:\Program Files\W2G-Clock\07-fix-clock.ps1' -Server '172.19.205.222'
    if ($arguments -notmatch '-File "C:\\Program Files\\W2G-Clock\\07-fix-clock\.ps1" -AtStartup -TimeServer 172\.19\.205\.222$') { throw $arguments }
    if ($arguments -match '-Command') { throw 'still an inline command' }
}
Check 'startup task: allowed to start, and not stopped, on battery' {
    $settings = New-StartupTaskSettings
    if ($settings.DisallowStartIfOnBatteries -or $settings.StopIfGoingOnBatteries) { throw "DisallowStartIfOnBatteries=$($settings.DisallowStartIfOnBatteries) StopIfGoingOnBatteries=$($settings.StopIfGoingOnBatteries)" }
}
Check 'startup task: registered from New-StartupTaskArguments and New-StartupTaskSettings, from Program Files' {
    $fn = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Register-StartupResyncTask' }, $true).Extent.Text
    if ($fn -notmatch 'New-StartupTaskArguments' -or $fn -notmatch '-Settings \(New-StartupTaskSettings\)') { throw 'not built from the tested pieces' }
    if ([System.IO.File]::ReadAllText($mainScript) -notmatch "\`$installDirectory = Join-Path \`$env:ProgramFiles 'W2G-Clock'") { throw 'not installed under Program Files' }
}
Check '-AtStartup runs Invoke-StartupClockCheck with the real resync, stripchart and Set-Date -Adjust, and exits by its outcome' {
    $if = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "'AtStartup'" }, $false)
    $body = $if.Clauses[0].Item2.Extent.Text
    foreach ($needle in 'Invoke-StartupClockCheck', '-Resync { Invoke-Resync -Attempts 1 }', '-Measure { Get-ServerOffsetSeconds -Server $TimeServer }', '-Adjust { param($by) Set-Date -Adjust $by | Out-Null }', 'exit ((Test-ClockCorrectionSucceeded $result) ? 0 : 1)') {
        if (-not $body.Contains($needle)) { throw "missing: $needle" }
    }
}
Check 'the interactive run steps a sub-second offset too, after the resync' {
    $try = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $false)
    $resync = (Find-Commands $try.Body 'Invoke-Resync')[0].Extent.StartOffset
    $correct = @(Find-Commands $try.Body 'Invoke-SubSecondCorrection')
    if ($correct.Count -lt 1 -or $correct[0].Extent.StartOffset -lt $resync) { throw 'no sub-second correction after the resync' }
}
