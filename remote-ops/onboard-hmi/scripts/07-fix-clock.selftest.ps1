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

# The try of the interactive run: the one whose catch prints Get-FailureNotice (the -Periodic branch has a try too).
$mainTry = @($mainAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.CatchClauses.Count -and $n.CatchClauses[0].Body.Extent.Text.Contains('Get-FailureNotice') }, $false))
if ($mainTry.Count -ne 1) { throw "found $($mainTry.Count) interactive try blocks" }
$mainTry = $mainTry[0]

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
    $try = $mainTry
    $lastWrite = (Find-Commands $try.Body 'Set-W32TimeDword' | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Maximum).Maximum
    $touch = @($try.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ClockTouched' }, $true))[0].Extent.StartOffset
    $firstMove = @(@('Restart-Service', 'Invoke-Resync', 'Set-Date', 'Invoke-SubSecondCorrection') | ForEach-Object { Find-Commands $try.Body $_ } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
    if (-not ($lastWrite -lt $touch -and $touch -lt $firstMove)) { throw "last write $lastWrite, touched $touch, first move $firstMove" }
    if ($try.CatchClauses[0].Body.Extent.Text -notmatch 'Get-FailureNotice -ClockTouched \$script:ClockTouched' -or $try.CatchClauses[0].Body.Extent.Text -notmatch '\bthrow\b') { throw 'catch does not print the notice and rethrow' }
}

# --- ws#55: measuring --------------------------------------------------------------------------------------

# The sample lines as w32tm prints them without /dataonly (review M2; format read off a real run, ws55-rv stripchart-format.txt):
# "HH:mm:ss, d:<round trip>s o:<offset>s  [chart]".
function Sample([string] $RoundTrip, [string] $Offset) { "15:40:12, d:$($RoundTrip)s o:$($Offset)s  [                         * |                           ]" }
$header = @('Tracking 172.19.205.222 [172.19.205.222:123].', 'Collecting 3 samples.', 'The current time is 2026/10/18 15:40:12.')

foreach ($case in @(
        @{ Name = '10-18 agv02, 0.77 s slow'; Lines = $header + @((Sample '+00.0150000' '+00.7672419'), (Sample '+00.0180000' '+00.7689102'), (Sample '+00.0160000' '+00.7677313')); Expect = -0.7677313 },
        @{ Name = 'a decimal comma'; Lines = @((Sample '+00,0150000' '+00,7672419'), (Sample '+00,0150000' '+00,7680000')); Expect = -0.768 },
        @{ Name = 'workspace#5, 137 days fast'; Lines = @((Sample '+00.0200000' '-11873082.0000000'), (Sample '+00.0200000' '-11873082.0100000')); Expect = 11873082.0 },
        @{ Name = 'a sample with a slow round trip (a CPE roam) is dropped, the other two decide'; Lines = @((Sample '+00.0100000' '-00.3000000'), (Sample '+00.0120000' '-00.3100000'), (Sample '+00.4000000' '+00.0100000')); Expect = 0.3 },
        @{ Name = 'a round trip of exactly 0.1 s is kept'; Lines = @((Sample '+00.1000000' '-00.3000000'), (Sample '+00.1000000' '-00.3050000')); Expect = 0.3 },
        @{ Name = 'kept samples 0.099 s apart still decide'; Lines = @((Sample '+00.0100000' '-00.3000000'), (Sample '+00.0100000' '-00.3990000')); Expect = 0.3 },
        @{ Name = 'no server'; Lines = $header + @('15:40:12, error: 0x800705B4', '15:40:14, error: 0x800705B4', '15:40:16, error: 0x800705B4'); Expect = $null; Reason = 'no sample answered' },
        @{ Name = 'only one sample parses: it does not decide alone'; Lines = @('15:40:12, error: 0x800705B4', (Sample '+00.0150000' '+00.4500000'), '15:40:16, error: 0x800705B4'); Expect = $null; Reason = '1 of 1 sample' },
        @{ Name = 'two samples 0.46 s apart (+0.45 and -0.01): nothing decided, not the smaller one'; Lines = @('15:40:12, error: 0x800705B4', (Sample '+00.0150000' '+00.4500000'), (Sample '+00.0150000' '-00.0100000')); Expect = $null; Reason = 'spread 0.460 s' },
        @{ Name = 'kept samples exactly 0.1 s apart: nothing decided'; Lines = @((Sample '+00.0100000' '-00.3000000'), (Sample '+00.0100000' '-00.4000000')); Expect = $null; Reason = 'spread' },
        @{ Name = 'all round trips too slow (time.windows.com from here, 0.45 s)'; Lines = @('00:13:24, d:+00.4510483s o:-00.6114226s  [                         * |                           ]', '00:13:26, d:+00.4518798s o:-00.6114090s  [                         * |                           ]'); Expect = $null; Reason = '0 of 2 sample' },
        @{ Name = '/dataonly output carries no round trip and decides nothing'; Lines = @('15:40:12, +00.7672419s', '15:40:14, +00.7689102s', '15:40:16, +00.7677313s'); Expect = $null; Reason = 'no sample answered' })) {
    Check "stripchart: $($case.Name)" {
        $got = ConvertFrom-StripchartOutput -Lines $case.Lines
        if ($null -eq $case.Expect) {
            if ($null -ne $got.Offset) { throw "got $($got.Offset)" }
            if ($got.Reason -notmatch [regex]::Escape($case.Reason)) { throw "reason: $($got.Reason)" }
            return
        }
        if ($null -eq $got.Offset -or [Math]::Abs($got.Offset - $case.Expect) -gt 1e-6) { throw "got $($got.Offset) ($($got.Reason)), expected $($case.Expect)" }
    }
}
Check 'Get-ServerOffsetSeconds asks for the round trip (no /dataonly), 3 samples, and logs every raw sample' {
    $fn = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ServerOffsetSeconds' }, $true).Extent.Text
    if ($fn -match '/dataonly') { throw 'still /dataonly' }
    if ($fn -notmatch 'w32tm /stripchart /computer:\$Server /samples:3 2>&1') { throw 'not a 3-sample stripchart' }
    if ($fn -notmatch "Write-Step \(""stripchart: ") { throw 'raw samples not logged' }
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
    $waits = [System.Collections.Generic.List[string]]::new()
    $r = Invoke-StartupClockCheck -Resync $Resync -Measure $Clock.Measure -Adjust $Clock.Adjust -Sleep { $waits.Add('sleep') }.GetNewClosure() -Settle { $waits.Add('settle') }.GetNewClosure() -Rounds $Rounds 6>$null
    return [pscustomobject]@{ Result = $r; Sleeps = @($waits | Where-Object { $_ -eq 'sleep' }).Count; Settles = @($waits | Where-Object { $_ -eq 'settle' }).Count }
}

Check 'startup, 10-18 agv02: resync leaves 0.77 s, round 1 steps it, round 2 after the settle wait confirms it' {
    $clock = New-StandinClock -0.7677
    $s = Invoke-StandinStartup $clock { $true }
    if ($s.Result.Outcome -ne 'IN_RANGE' -or $clock.Adjusts.Count -ne 1 -or $s.Settles -ne 1 -or $s.Sleeps -ne 0) { throw "$($s.Result.Outcome), $($clock.Adjusts.Count) adjust(s), $($s.Settles) settle(s), $($s.Sleeps) sleep(s)" }
}
Check 'startup: w32time pulls the clock off again after the step -- the next round sees it and steps again' {
    $clock = New-StandinClock -0.77
    $pulled = [ref] $false
    $s = Invoke-StandinStartup $clock { if ($clock.Adjusts.Count -eq 1 -and -not $pulled.Value) { $clock.Offset -= 0.6; $pulled.Value = $true }; $true }.GetNewClosure()
    if ($s.Result.Outcome -ne 'IN_RANGE' -or $clock.Adjusts.Count -ne 2 -or [Math]::Abs($clock.Adjusts[1] - 0.6) -gt 1e-6) { throw "$($s.Result.Outcome), adjusts $($clock.Adjusts -join ', ')" }
}
Check 'startup: link down for two rounds, then 0.77 s slow -- stepped in round 3, confirmed in round 4' {
    $clock = New-StandinClock -0.77
    $clock.Reachable = $false
    $round = [ref] 0
    $s = Invoke-StandinStartup $clock { $round.Value++; if ($round.Value -ge 3) { $clock.Reachable = $true }; $clock.Reachable }.GetNewClosure()
    if ($s.Result.Outcome -ne 'IN_RANGE' -or $s.Sleeps -ne 2 -or $s.Settles -ne 1 -or $clock.Adjusts.Count -ne 1) { throw "$($s.Result.Outcome), $($s.Sleeps) sleep(s), $($s.Settles) settle(s), $($clock.Adjusts.Count) adjust(s)" }
}
Check 'startup: never measured -- UNMEASURED after every round, nothing stepped, exit would be 1' {
    $clock = New-StandinClock $null
    $s = Invoke-StandinStartup $clock { $false } -Rounds 4
    if ($s.Result.Outcome -ne 'UNMEASURED' -or $s.Sleeps -ne 3 -or $clock.Adjusts.Count -ne 0 -or (Test-ClockCorrectionSucceeded $s.Result)) { throw "$($s.Result.Outcome), $($s.Sleeps) sleep(s)" }
}
Check 'startup: the factory server answering only after 2 hours (plant-wide power cut) is still caught with the default rounds' {
    $clock = New-StandinClock -0.77
    $clock.Reachable = $false
    $round = [ref] 0
    $resync = { $round.Value++; if ($round.Value -gt 240) { $clock.Reachable = $true }; $clock.Reachable }.GetNewClosure()
    $r = Invoke-StartupClockCheck -Resync $resync -Measure $clock.Measure -Adjust $clock.Adjust -Sleep {} -Settle {} 6>$null
    if ($r.Outcome -ne 'IN_RANGE' -or $clock.Adjusts.Count -ne 1) { throw "$($r.Outcome) after $($round.Value) rounds" }
}
Check 'startup: the task time limit outlasts the default rounds at 30 s, and they cover at least 3 hours' {
    $fn = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-StartupClockCheck' }, $true)
    $param = @($fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Rounds' })[0]
    $sleep = @($fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Sleep' })[0].DefaultValue.Extent.Text
    if ($sleep -notmatch 'Start-Sleep -Seconds 30\b') { throw "sleep default: $sleep" }
    $roundsTime = [TimeSpan]::FromSeconds([int] $param.DefaultValue.Extent.Text * 30)
    $limit = [System.Xml.XmlConvert]::ToTimeSpan((New-StartupTaskSettings).ExecutionTimeLimit)
    if ($roundsTime -lt [TimeSpan]::FromHours(3)) { throw "rounds cover only $roundsTime" }
    if ($limit -le $roundsTime) { throw "time limit $limit, rounds take $roundsTime" }
}
Check 'startup: days off is left to the resync, which brings it in on round 2; the sub-second step never fires' {
    $clock = New-StandinClock 11873082.0
    $round = [ref] 0
    $s = Invoke-StandinStartup $clock { $round.Value++; if ($round.Value -eq 2) { $clock.Offset = 0.05 }; $round.Value -ge 2 }.GetNewClosure()
    if ($s.Result.Outcome -ne 'IN_RANGE' -or $clock.Adjusts.Count -ne 0) { throw "$($s.Result.Outcome), $($clock.Adjusts.Count) adjust(s)" }
}

# --- ws#55 (10-21 scope): the periodic check ------------------------------------------------------------------

function Invoke-StandinPeriodic($Clock, [bool] $Locked = $false) {
    # Built out here: a closure made inside another closure does not see what the outer one captured.
    $state = [pscustomobject]@{ Taken = 0; Released = 0; Settles = 0; ReleasedBeforeSettle = $false }
    $release = { $state.Released++ }.GetNewClosure()
    $settle = { $state.Settles++; if ($state.Released -ne 0) { $state.ReleasedBeforeSettle = $true } }.GetNewClosure()
    $r = Invoke-PeriodicClockCheck -Measure $Clock.Measure -Adjust $Clock.Adjust -Settle $settle -Lock { if ($Locked) { $null } else { $state.Taken++; $release } }.GetNewClosure() 6>$null
    return [pscustomobject]@{ Result = $r; Lock = $state }
}

foreach ($case in @(
        @{ Name = 'drift +0.12 s since the last check (10-21 agv02) is under the threshold: left to w32time'; Offset = 0.12; Outcome = 'IN_RANGE'; Adjusts = @() },
        @{ Name = 'drift -0.12 s is left alone too'; Offset = -0.12; Outcome = 'IN_RANGE'; Adjusts = @() },
        @{ Name = 'drift +0.25 s (fast) is stepped back by 0.25 s'; Offset = 0.25; Outcome = 'ADJUSTED'; Adjusts = @(-0.25) },
        @{ Name = 'drift -0.25 s (slow) is stepped forward by 0.25 s'; Offset = -0.25; Outcome = 'ADJUSTED'; Adjusts = @(0.25) },
        @{ Name = 'no server: the clock is not touched, and it is not a success'; Offset = $null; Outcome = 'UNMEASURED'; Adjusts = @() },
        @{ Name = 'seconds off is not stepped here (w32time steps anything over 1 s at its poll)'; Offset = 7.0; Outcome = 'COARSE'; Adjusts = @() })) {
    Check "periodic: $($case.Name)" {
        $clock = New-StandinClock $case.Offset
        $p = Invoke-StandinPeriodic $clock
        if ($p.Result.Outcome -ne $case.Outcome) { throw "outcome $($p.Result.Outcome)" }
        if ($clock.Adjusts.Count -ne $case.Adjusts.Count) { throw "$($clock.Adjusts.Count) adjust call(s): $($clock.Adjusts -join ', ')" }
        for ($i = 0; $i -lt $case.Adjusts.Count; $i++) { if ([Math]::Abs($clock.Adjusts[$i] - $case.Adjusts[$i]) -gt 1e-6) { throw "adjusted by $($clock.Adjusts[$i]), expected $($case.Adjusts[$i])" } }
        if ($p.Lock.Taken -ne 1 -or $p.Lock.Released -ne 1) { throw "lock taken $($p.Lock.Taken), released $($p.Lock.Released)" }
        $expectSettles = $case.Adjusts.Count
        if ($p.Lock.Settles -ne $expectSettles) { throw "$($p.Lock.Settles) settle wait(s), expected $expectSettles" }
    }
}
Check 'periodic, after a step: waits, measures once more for the log, holds the lock through the wait, and does not step again (review L1)' {
    $clock = New-StandinClock 0.25
    $measures = [ref] 0
    $measure = { $measures.Value++; & $clock.Measure }.GetNewClosure()
    # w32time's pending slew pulls the clock 0.3 s off again during the wait.
    $state = [pscustomobject]@{ Released = 0; ReleasedBeforeSettle = $false }
    $release = { $state.Released++ }.GetNewClosure()
    $settle = { if ($state.Released) { $state.ReleasedBeforeSettle = $true }; $clock.Offset += 0.3 }.GetNewClosure()
    $r = Invoke-PeriodicClockCheck -Measure $measure -Adjust $clock.Adjust -Settle $settle -Lock { $release }.GetNewClosure() 6>$null
    if ($r.Outcome -ne 'ADJUSTED' -or $measures.Value -ne 3 -or $clock.Adjusts.Count -ne 1) { throw "$($r.Outcome), $($measures.Value) measurement(s), $($clock.Adjusts.Count) adjust(s)" }
    if ($null -eq $r.Settled -or [Math]::Abs($r.Settled - 0.3) -gt 1e-6) { throw "settled $($r.Settled)" }
    if ($state.ReleasedBeforeSettle -or $state.Released -ne 1) { throw 'lock released before the settle wait' }
}
Check 'periodic: the default settle wait is 90 s, as at startup' {
    $fn = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PeriodicClockCheck' }, $true)
    $settle = @($fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Settle' })[0].DefaultValue.Extent.Text
    if ($settle -ne '{ Start-Sleep -Seconds 90 }') { throw "settle default: $settle" }
}
Check 'the step is logged, with milliseconds, before Set-Date runs (review L4)' {
    $log = Join-Path ([System.IO.Path]::GetTempPath()) "clock-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8)).log"
    $saved = $script:StepLog
    try {
        $script:StepLog = $log
        $seen = [ref] $null
        $adjust = { param($by) $seen.Value = [System.IO.File]::ReadAllText($log) }.GetNewClosure()
        $null = Invoke-SubSecondCorrection -Measure { 0.25 } -Adjust $adjust 6>$null
        if ($seen.Value -notmatch '\[\d\d:\d\d:\d\d\.\d{3}\] Stepping the clock by -0\.250 s now\.') { throw "log before the step: $($seen.Value)" }
    }
    finally { $script:StepLog = $saved; Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue }
}
Check 'periodic: while the startup task holds the clock lock, the periodic check neither measures nor steps' {
    $clock = New-StandinClock 0.77
    $measured = [ref] 0
    $measure = { $measured.Value++; & $clock.Measure }.GetNewClosure()
    $r = Invoke-PeriodicClockCheck -Measure $measure -Adjust $clock.Adjust -Lock { $null } 6>$null
    if ($r.Outcome -ne 'LOCKED' -or $measured.Value -ne 0 -or $clock.Adjusts.Count -ne 0) { throw "$($r.Outcome), measured $($measured.Value), $($clock.Adjusts.Count) adjust(s)" }
    if (Test-ClockCorrectionSucceeded $r) { throw 'LOCKED counted as success' }
}
Check 'periodic: the lock is released when the step throws' {
    $released = [ref] 0
    $release = { $released.Value++ }.GetNewClosure()
    try { Invoke-PeriodicClockCheck -Measure { 0.5 } -Adjust { throw 'Set-Date failed' } -Lock { $release }.GetNewClosure() 6>$null; throw 'no error' } catch { if ($_.Exception.Message -ne 'Set-Date failed') { throw } }
    if ($released.Value -ne 1) { throw "released $($released.Value) times" }
}
Check 'the startup check holds the same clock lock for its whole loop' {
    $taken = [ref] 0; $released = [ref] 0; $heldDuringMeasure = [ref] $true
    $clock = New-StandinClock 0.05
    $release = { $released.Value++ }.GetNewClosure()
    $measure = { if ($taken.Value -ne 1 -or $released.Value -ne 0) { $heldDuringMeasure.Value = $false }; & $clock.Measure }.GetNewClosure()
    $r = Invoke-StartupClockCheck -Resync { $true } -Measure $measure -Adjust $clock.Adjust -Sleep {} -Settle {} -Rounds 3 -Lock { $taken.Value++; $release }.GetNewClosure() 6>$null
    if ($r.Outcome -ne 'IN_RANGE' -or $taken.Value -ne 1 -or $released.Value -ne 1 -or -not $heldDuringMeasure.Value) { throw "$($r.Outcome), taken $($taken.Value), released $($released.Value), held $($heldDuringMeasure.Value)" }
}
# The clock lock, held by ANOTHER PROCESS (review L3): a mutex is re-entrant on the thread that owns it, so taking
# it twice from this process proves nothing. The holder takes the named mutex, writes $Ready, and then either keeps it
# for $HoldSeconds and releases it, or exits without releasing (-Abandon).
function Start-LockHolder([string] $Name, [int] $HoldSeconds, [switch] $Abandon) {
    $ready = Join-Path ([System.IO.Path]::GetTempPath()) "clock-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8)).ready"
    $tail = $Abandon ? 'exit 0' : "Start-Sleep -Seconds $HoldSeconds; `$m.ReleaseMutex()"
    $command = "`$m = [System.Threading.Mutex]::new(`$false, '$Name'); if (-not `$m.WaitOne(0)) { exit 9 }; Set-Content -LiteralPath '$ready' -Value 1; $tail"
    $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $command -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ($process.HasExited -and -not $Abandon) { throw "lock holder exited with $($process.ExitCode) before taking the lock" }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'lock holder never took the lock' }
        Start-Sleep -Milliseconds 100
    }
    Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
    return $process
}
function New-LockName { "Global\8005-clock-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8))" }

Check 'clock lock held by another process: Enter-ClockLock (no wait) is refused at once, and gets it after the holder releases' {
    $name = New-LockName
    $holder = Start-LockHolder -Name $name -HoldSeconds 3
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $got = Enter-ClockLock -Name $name
        if ($null -ne $got) { & $got; throw 'took a lock another process holds' }
        if ($sw.Elapsed -gt [TimeSpan]::FromSeconds(2)) { throw "refusal took $($sw.Elapsed)" }
    }
    finally { $holder.WaitForExit(20000) | Out-Null }
    $after = Enter-ClockLock -Name $name
    if ($null -eq $after) { throw 'refused after the holder released' }
    & $after
}
Check 'clock lock held by another process: Enter-ClockLock -Wait waits for it instead of giving up' {
    $name = New-LockName
    $holder = Start-LockHolder -Name $name -HoldSeconds 3
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $got = Enter-ClockLock -Name $name -Wait
        if ($null -eq $got) { throw "gave up after $($sw.Elapsed)" }
        & $got
        if ($sw.Elapsed -lt [TimeSpan]::FromSeconds(1)) { throw "got it after $($sw.Elapsed), before the holder could have released" }
    }
    finally { $holder.WaitForExit(20000) | Out-Null }
}
Check 'clock lock abandoned by a process that exited holding it: Enter-ClockLock takes it and does not throw' {
    $name = New-LockName
    # Keeps the named kernel object alive after the holder exits (an open handle, not an owner).
    $keeper = [System.Threading.Mutex]::new($false, $name)
    try {
        $holder = Start-LockHolder -Name $name -Abandon
        $holder.WaitForExit(20000) | Out-Null
        $got = Enter-ClockLock -Name $name
        if ($null -eq $got) { throw 'refused an abandoned lock' }
        & $got
    }
    finally { $keeper.Dispose() }
}
Check 'periodic task: runs the installed copy with -Periodic and the server' {
    $arguments = New-PeriodicTaskArguments -ScriptPath 'C:\Program Files\W2G-Clock\07-fix-clock.ps1' -Server '172.19.205.222'
    if ($arguments -notmatch '-File "C:\\Program Files\\W2G-Clock\\07-fix-clock\.ps1" -Periodic -TimeServer 172\.19\.205\.222$') { throw $arguments }
}
Check 'periodic task: repeats every hour, indefinitely' {
    $trigger = New-PeriodicTaskTrigger
    if ($trigger.Repetition.Interval -ne 'PT1H') { throw "interval $($trigger.Repetition.Interval)" }
    if (-not [string]::IsNullOrEmpty($trigger.Repetition.Duration)) { throw "duration $($trigger.Repetition.Duration) (should be indefinite)" }
}
Check 'periodic task: starts on a fixed date in the past, whatever the clock reads at install (review M1)' {
    $boundaries = foreach ($reads in @([datetime]'2026-10-22 09:30', [datetime]'2027-02-08 14:00')) {
        # What the image clock reads before the resync: 158 days fast on every car (workspace#5).
        function Get-Date { $reads }
        try { [datetimeoffset]::Parse((New-PeriodicTaskTrigger).StartBoundary, [cultureinfo]::InvariantCulture) }
        finally { Remove-Item -Path Function:\Get-Date -ErrorAction SilentlyContinue }
    }
    if ($boundaries[0] -ne $boundaries[1]) { throw "StartBoundary follows the clock: $($boundaries -join ' vs ')" }
    if ($boundaries[0] -gt [datetimeoffset]'2026-10-01T00:00:00+08:00') { throw "StartBoundary $($boundaries[0]) is not before any car was installed" }
}
Check 'periodic task: registered from the tested pieces, on battery too, one instance at a time, short time limit' {
    $fn = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Register-PeriodicClockTask' }, $true).Extent.Text
    foreach ($needle in 'New-PeriodicTaskArguments', 'New-PeriodicTaskTrigger', '-Settings (New-PeriodicTaskSettings)', "-UserId 'SYSTEM'") { if (-not $fn.Contains($needle)) { throw "missing: $needle" } }
    $settings = New-PeriodicTaskSettings
    if ($settings.DisallowStartIfOnBatteries -or $settings.StopIfGoingOnBatteries) { throw 'battery' }
    if ($settings.MultipleInstances -ne 'IgnoreNew') { throw "MultipleInstances $($settings.MultipleInstances)" }
    $limit = [System.Xml.XmlConvert]::ToTimeSpan($settings.ExecutionTimeLimit)
    if ($limit -gt [TimeSpan]::FromMinutes(30) -or $limit -le [TimeSpan]::Zero) { throw "time limit $limit" }
}
Check 'step 5 also registers the periodic task, with the installed path, before anything talks to the server' {
    $try = $mainTry
    $periodic = @(Find-Commands $try.Body 'Register-PeriodicClockTask')
    if ($periodic.Count -ne 1) { throw "$($periodic.Count) Register-PeriodicClockTask calls" }
    $startupPath = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand((Find-Commands $try.Body 'Register-StartupResyncTask')[0], $true).BoundParameters['ScriptPath'].Value.Extent.Text
    $periodicPath = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($periodic[0], $true).BoundParameters['ScriptPath'].Value.Extent.Text
    if ($periodicPath -ne $startupPath) { throw "periodic -ScriptPath $periodicPath, startup $startupPath" }
    $first = @(@('Restart-Service', 'Invoke-Resync', 'Invoke-SubSecondCorrection', 'Set-Date') | ForEach-Object { Find-Commands $try.Body $_ } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
    if ($periodic[0].Extent.StartOffset -gt $first) { throw 'registered after the first server/clock step' }
}
Check '-Periodic runs Invoke-PeriodicClockCheck with stripchart, Set-Date -Adjust and the machine-wide lock, and exits 0 only on IN_RANGE or ADJUSTED' {
    $if = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "'Periodic'" }, $false)
    if (-not $if) { throw 'no -Periodic branch' }
    $body = $if.Clauses[0].Item2.Extent.Text
    foreach ($needle in 'Invoke-PeriodicClockCheck', '-Measure { Get-ServerOffsetSeconds -Server $TimeServer }', '-Adjust { param($by) Set-Date -Adjust $by | Out-Null }', '-Lock { Enter-ClockLock }', 'exit ((Test-ClockCorrectionSucceeded $result) ? 0 : 1)') {
        if (-not $body.Contains($needle)) { throw "missing: $needle" }
    }
    $startup = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "'AtStartup'" }, $false).Clauses[0].Item2.Extent.Text
    if (-not $startup.Contains('-Lock { Enter-ClockLock -Wait }')) { throw 'the startup check does not take the lock' }
}
Check '-Periodic logs w32time status each round and catches a failure into periodic.log with exit 1 (review L4)' {
    $if = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "'Periodic'" }, $false)
    $try = $if.Clauses[0].Item2.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
    if (-not $try) { throw 'no try in the -Periodic branch' }
    if (-not $try.Body.Extent.Text.Contains('Write-W32TimeStatus') -or -not $try.Body.Extent.Text.Contains('Invoke-PeriodicClockCheck')) { throw 'status or check outside the try' }
    $catch = $try.CatchClauses[0].Body.Extent.Text
    if ($catch -notmatch 'Write-Step \("Periodic clock check FAILED: \{0\}' -or $catch -notmatch '\$_\.Exception\.Message' -or $catch -notmatch 'exit 1') { throw "catch: $catch" }
    $status = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-W32TimeStatus' }, $true).Extent.Text
    if ($status -notmatch 'w32tm /query /status /verbose' -or $status -notmatch 'Write-Step') { throw 'Write-W32TimeStatus does not log w32tm /query /status /verbose' }
}
Check 'the interactive run holds the clock lock (waiting) around steps 3 and 4, released in a finally (review L2)' {
    $outer = $mainTry
    $take = @($outer.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Right.Extent.Text -eq 'Enter-ClockLock -Wait' }, $true))
    if ($take.Count -ne 1) { throw "$($take.Count) Enter-ClockLock -Wait assignments" }
    $var = $take[0].Left.Extent.Text
    $inner = @($outer.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text.Contains("& $var") }, $true))
    if ($inner.Count -ne 1) { throw "no try whose finally runs $var" }
    if ($take[0].Extent.StartOffset -gt $inner[0].Extent.StartOffset) { throw 'lock taken after the try' }
    foreach ($name in 'Invoke-Resync', 'Invoke-SubSecondCorrection', 'Set-Date') {
        foreach ($call in (Find-Commands $outer.Body $name)) {
            if ($call.Extent.StartOffset -lt $inner[0].Body.Extent.StartOffset -or $call.Extent.EndOffset -gt $inner[0].Body.Extent.EndOffset) { throw "$name at $($call.Extent.StartLineNumber) is outside the lock" }
        }
    }
}

# --- ws#55: uninstalling (review L6) ---------------------------------------------------------------------------

Check 'Uninstall-ClockTasks removes both tasks, and skips one that is not there' {
    $removed = [System.Collections.Generic.List[string]]::new()
    $unregister = { param($name) $removed.Add($name) }.GetNewClosure()
    Uninstall-ClockTasks -TaskName 'W2G-ClockResyncAtStartup', 'W2G-ClockCheckPeriodic' -Find { param($name) [pscustomobject]@{ TaskName = $name } } -Unregister $unregister 6>$null
    if (($removed -join ',') -ne 'W2G-ClockResyncAtStartup,W2G-ClockCheckPeriodic') { throw "removed $($removed -join ',')" }
    $removed.Clear()
    Uninstall-ClockTasks -TaskName 'W2G-ClockResyncAtStartup', 'W2G-ClockCheckPeriodic' -Find { param($name) if ($name -eq 'W2G-ClockCheckPeriodic') { [pscustomobject]@{ TaskName = $name } } } -Unregister $unregister 6>$null
    if (($removed -join ',') -ne 'W2G-ClockCheckPeriodic') { throw "removed $($removed -join ',')" }
}
Check 'Uninstall-ClockTasks unregisters without a prompt by default' {
    $fn = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Uninstall-ClockTasks' }, $true)
    $default = @($fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Unregister' })[0].DefaultValue.Extent.Text
    if ($default -notmatch 'Unregister-ScheduledTask -TaskName \$name -Confirm:\$false') { throw "default: $default" }
}
Check '-Uninstall removes both task names behind ShouldProcess, and never reaches the fix' {
    $if = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "'Uninstall'" }, $false)
    if (-not $if) { throw 'no -Uninstall branch' }
    $body = $if.Clauses[0].Item2.Extent.Text
    if ($body -notmatch 'ShouldProcess' -or -not $body.Contains('Uninstall-ClockTasks -TaskName $startupTaskName, $periodicTaskName') -or $body -notmatch '\breturn\b') { throw $body }
    $outer = $mainTry
    if ($if.Extent.StartOffset -gt $outer.Extent.StartOffset) { throw 'the branch comes after the fix' }
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
Check 'step 5 wiring: the task is registered with exactly the path Install-StartupCopy returned, copied from this script into the install directory' {
    $try = $mainTry
    $register = @(Find-Commands $try.Body 'Register-StartupResyncTask')
    if ($register.Count -ne 1) { throw "$($register.Count) Register-StartupResyncTask calls" }
    $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($register[0], $true)
    $scriptPath = $bound.BoundParameters['ScriptPath'].Value
    if ($scriptPath -isnot [System.Management.Automation.Language.VariableExpressionAst]) { throw "-ScriptPath is $($scriptPath.Extent.Text)" }
    $name = $scriptPath.VariablePath.UserPath
    $assignments = @($mainAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$$name" }, $true))
    if ($assignments.Count -ne 1) { throw "`$$name is assigned $($assignments.Count) times" }
    $install = @(Find-Commands $assignments[0].Right 'Install-StartupCopy')
    if ($install.Count -ne 1 -or $assignments[0].Right.Extent.Text -ne $install[0].Parent.Extent.Text) { throw "`$$name = $($assignments[0].Right.Extent.Text)" }
    $args5 = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($install[0], $true).BoundParameters
    if ($args5['Source'].Value.Extent.Text -ne '$PSCommandPath' -or $args5['Directory'].Value.Extent.Text -ne '$installDirectory') { throw "Install-StartupCopy $($install[0].Extent.Text)" }
}
Check 'Install-StartupCopy copies into the directory, and re-running from the installed copy does not throw (review S4)' {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "clock-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        New-Item -ItemType Directory -Path (Join-Path $dir 'src') | Out-Null
        $source = Join-Path $dir 'src\07-fix-clock.ps1'
        Set-Content -LiteralPath $source -Value 'v1' -Encoding utf8NoBOM
        $installed = Install-StartupCopy -Source $source -Directory (Join-Path $dir 'inst') 6>$null
        if ($installed -ne (Join-Path $dir 'inst\07-fix-clock.ps1') -or (Get-Content -LiteralPath $installed -Raw).Trim() -ne 'v1') { throw "installed $installed" }
        $again = Install-StartupCopy -Source $installed -Directory (Join-Path $dir 'inst') 6>$null
        if ($again -ne $installed -or (Get-Content -LiteralPath $installed -Raw).Trim() -ne 'v1') { throw "re-run returned $again" }
        Set-Content -LiteralPath $source -Value 'v2' -Encoding utf8NoBOM
        $null = Install-StartupCopy -Source $source -Directory (Join-Path $dir 'inst') 6>$null
        if ((Get-Content -LiteralPath $installed -Raw).Trim() -ne 'v2') { throw 'a newer source did not replace the installed copy' }
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
Check 'step 5 runs before anything talks to the server, so a failure in steps 3 and 4 keeps the startup task (review S5)' {
    $try = $mainTry
    $register = (Find-Commands $try.Body 'Register-StartupResyncTask')[0].Extent.StartOffset
    $first = @(@('Restart-Service', 'Invoke-Resync', 'Invoke-SubSecondCorrection', 'Set-Date') | ForEach-Object { Find-Commands $try.Body $_ } | ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
    if ($register -gt $first) { throw "registered at $register, first server/clock step at $first" }
}
Check '-AtStartup runs Invoke-StartupClockCheck with the real resync, stripchart and Set-Date -Adjust, and exits 0 only on IN_RANGE' {
    $if = $mainAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "'AtStartup'" }, $false)
    $body = $if.Clauses[0].Item2.Extent.Text
    foreach ($needle in 'Invoke-StartupClockCheck', '-Resync { Invoke-Resync -Attempts 1 }', '-Measure { Get-ServerOffsetSeconds -Server $TimeServer }', '-Adjust { param($by) Set-Date -Adjust $by | Out-Null }', "exit ((`$result.Outcome -eq 'IN_RANGE') ? 0 : 1)") {
        if (-not $body.Contains($needle)) { throw "missing: $needle" }
    }
}
Check 'the interactive run steps a sub-second offset too, after the resync' {
    $try = $mainTry
    $resync = (Find-Commands $try.Body 'Invoke-Resync')[0].Extent.StartOffset
    $correct = @(Find-Commands $try.Body 'Invoke-SubSecondCorrection')
    if ($correct.Count -lt 1 -or $correct[0].Extent.StartOffset -lt $resync) { throw 'no sub-second correction after the resync' }
}
Check 'the interactive run ends with exit 2 when the offset is not confirmed (review S6)' {
    $last = $mainAst.EndBlock.Statements[-1].Extent.Text
    if ($last -ne 'if (-not (Test-ClockCorrectionSucceeded $correction)) { exit 2 }') { throw "last statement: $last" }
}
