#Requires -Version 7
<#
    onboard-hmi#316, option (b) of Coordinator 10's ruling: the reader and its -CrossCheck against a real
    onboard WPF on the control host's own interactive desktop, never a vehicle. Proves the comparison does
    not report differences that are not there; the L2 cross-check at scenario pause points (T3 acceptance 4
    and 5) waits for control-server#653.

    Starts slots-simulator and the onboard client the way ws20-20261011-local-repro/repro.ps1 did (one-shot
    Interactive scheduled tasks, under Global\W2G-InteractiveDesktop for the whole run), with the onboard's
    published appsettings.json changed in three places only: screenState.enabled true, and the log directory
    and journal moved under -Root. wireToGate stays as shipped (off), so no server is involved and nothing
    moves anywhere.

    Then: one read with the timeline; -Iterations cross-checks, -IntervalSeconds apart; closes the onboard
    client and reads once more, which must be EXITED (the writer leaves no end marker; onboard-hmi#315 L2).

    -Root holds bin\hmi and bin\sim (published builds) and receives run\ and out\<timestamp>.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][string] $Root,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string] $Scripts,
    [Parameter(ParameterSetName = 'Run')][int] $Iterations = 12,
    [Parameter(ParameterSetName = 'Run')][int] $IntervalSeconds = 5,
    # Pure string checks of Test-UnderRoot; starts nothing.
    [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch] $SelfTest
)
$ErrorActionPreference = 'Stop'

<#
    Whether a process's executable lies under -Root, so the cleanup stops only what this run started.
    Both sides normalised first: on 2026-10-12 a -Root given with forward slashes never matched Windows'
    backslash process paths, and the run left the onboard client and the simulator running. The trailing
    separator keeps F:\x\hmi3160 from passing for F:\x\hmi316.
#>
function Test-UnderRoot([string] $Path, [string] $Root) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $base = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Root)) + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Path).StartsWith($base, [StringComparison]::OrdinalIgnoreCase)
}

if ($SelfTest) {
    $cases = @(
        @{ Path = 'F:\8005-scratch\hmi316\bin\hmi\SQCD.Agv.Wpf.exe'; Root = 'F:/8005-scratch/hmi316'; Expect = $true; Why = 'forward-slash root, backslash path (the 2026-10-12 miss)' }
        @{ Path = 'F:\8005-scratch\hmi316\bin\sim\SQCD_8005AGV_Simulator.exe'; Root = 'F:\8005-scratch\hmi316\'; Expect = $true; Why = 'root with a trailing separator' }
        @{ Path = 'f:\8005-SCRATCH\hmi316\bin\hmi\SQCD.Agv.Wpf.exe'; Root = 'F:\8005-scratch\hmi316'; Expect = $true; Why = 'case differs' }
        @{ Path = 'F:\8005-scratch\hmi3160\bin\hmi\SQCD.Agv.Wpf.exe'; Root = 'F:/8005-scratch/hmi316'; Expect = $false; Why = 'a sibling sharing the prefix' }
        @{ Path = 'C:\8005\OnboardHmi\SQCD.Agv.Wpf.exe'; Root = 'F:/8005-scratch/hmi316'; Expect = $false; Why = 'an installed client elsewhere' }
        @{ Path = 'F:\8005-scratch\hmi316'; Root = 'F:/8005-scratch/hmi316'; Expect = $false; Why = 'the root itself is not a file under it' }
        @{ Path = $null; Root = 'F:/8005-scratch/hmi316'; Expect = $false; Why = 'a process whose path cannot be read' }
    )
    $failed = 0
    foreach ($c in $cases) {
        $got = Test-UnderRoot $c.Path $c.Root
        if ($got -ne $c.Expect) { $failed++; "FAIL $($c.Why): got $got" } else { "PASS $($c.Why)" }
    }
    # The old filter, kept as the case the new one must differ from.
    if ('F:\8005-scratch\hmi316\bin\hmi\SQCD.Agv.Wpf.exe' -like 'F:/8005-scratch/hmi316*') { $failed++; 'FAIL the old -like filter now matches; this test no longer pins the miss' } else { 'PASS the old -like filter misses it, as on 2026-10-12' }
    "SELFTEST $($failed ? 'FAIL' : 'PASS') ($failed failed)"
    exit ($failed ? 1 : 0)
}

$Root = [System.IO.Path]::GetFullPath($Root)
$reader = Join-Path $Scripts '18-read-hmi-screen-state.ps1'
$out = Join-Path $Root "out\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$run = Join-Path $Root 'run'
$logs = Join-Path $run 'logs'
New-Item -ItemType Directory -Force -Path $out, $logs | Out-Null
$simExe = Join-Path $Root 'bin\sim\SQCD_8005AGV_Simulator.exe'
$hmiExe = Join-Path $Root 'bin\hmi\SQCD.Agv.Wpf.exe'
function Note([string] $Text) { $line = "$(Get-Date -Format 'HH:mm:ss.fff') $Text"; $line; Add-Content -LiteralPath (Join-Path $out 'log.txt') -Value $line }

function Start-Interactive([string] $Path, [string] $Label) {
    $name = "W2G-hmi316-$Label-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $action = New-ScheduledTaskAction -Execute $Path -WorkingDirectory (Split-Path -Parent $Path)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    try {
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $name
    } finally {
        Start-Sleep -Seconds 3
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}
function Get-Stack {
    [pscustomobject]@{
        Sim = @(Get-Process -Name SQCD_8005AGV_Simulator -ErrorAction SilentlyContinue | ForEach-Object Id)
        Hmi = @(Get-Process -Name SQCD.Agv.Wpf -ErrorAction SilentlyContinue | ForEach-Object Id)
    }
}
function Invoke-Reader([string] $Label, [string[]] $More) {
    $evidence = Join-Path $out $Label
    $text = @(& pwsh -NoProfile -NonInteractive -File $reader -Local -Directory $logs -EvidenceDirectory $evidence @More 2>&1 | ForEach-Object { "$_" })
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $out "$Label.txt") -Value $text -Encoding utf8NoBOM
    $record = Get-ChildItem -LiteralPath $evidence -Filter '*.json' | Where-Object Name -Match '-(read|crosscheck)\.json$' | Select-Object -First 1
    $parsed = $record ? (Get-Content -LiteralPath $record.FullName -Raw | ConvertFrom-Json) : $null
    $entry = [ordered]@{
        label = $Label; exit = $exit; outcome = ${parsed}?.outcome; detail = ${parsed}?.detail
        rows = @(${parsed}?.rows | Where-Object { $_ }).Count; differences = @(${parsed}?.rows | Where-Object { $_ -and -not $_.match } | ForEach-Object { "$($_.category) $($_.key) $($_.field): $($_.snapshot) / $($_.uia)" })
        captureSeconds = ${parsed}?.capture?.seconds; revision = ${parsed}?.read?.contentRevision
    }
    Add-Content -LiteralPath (Join-Path $out 'runs.jsonl') -Value ($entry | ConvertTo-Json -Compress -Depth 5)
    Note ("{0} exit={1} {2} rows={3} diffs={4} rev={5} capture={6}s {7}" -f $Label, $exit, $entry.outcome, $entry.rows, $entry.differences.Count, $entry.revision, $entry.captureSeconds, $entry.detail)
    return $entry
}

# The onboard's configuration: the published file with three changes, recorded.
$settingsPath = Join-Path (Split-Path -Parent $hmiExe) 'appsettings.json'
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
$settings.screenState = @{ enabled = $true }
$settings.logging.directory = $logs
$settings.wireToGate.journalPath = Join-Path $run 'onboard-journal.db'
$settings | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $settingsPath -Encoding utf8NoBOM
Note "onboard settings: screenState.enabled=true, logging.directory=<Root>\run\logs, journalPath=<Root>\run\onboard-journal.db, wireToGate.enabled=$($settings.wireToGate.enabled)"

$mutex = [System.Threading.Mutex]::new($false, 'Global\W2G-InteractiveDesktop')
if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(60))) { throw 'Desktop lock Global\W2G-InteractiveDesktop is held by someone else.' }
try {
    $s = Get-Stack
    if ($s.Sim.Count -or $s.Hmi.Count) { throw "A simulator or HMI is already running here (sim $($s.Sim -join ','), hmi $($s.Hmi -join ','))." }
    Start-Interactive $simExe 'Simulator'
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Get-NetTCPConnection -State Listen -LocalPort 1502 -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { throw 'simulator did not listen on 1502' }
        Start-Sleep -Seconds 1
    }
    Note "simulator up pid=$((Get-Stack).Sim -join ',')"
    Start-Interactive $hmiExe 'Onboard'
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path -LiteralPath (Join-Path $logs 'hmi-state.json'))) { if ((Get-Date) -gt $deadline) { throw 'no hmi-state.json within 90 s' }; Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 10
    Note "hmi up pid=$((Get-Stack).Hmi -join ',')"

    $null = Invoke-Reader 'read-1' @('-TimelineLines', '10')
    for ($i = 1; $i -le $Iterations; $i++) {
        $null = Invoke-Reader ("crosscheck-{0:d2}" -f $i) @('-CrossCheck')
        Start-Sleep -Seconds $IntervalSeconds
    }

    # Close the onboard client the way an operator would, then the file must read EXITED.
    foreach ($p in @(Get-Process -Name SQCD.Agv.Wpf -ErrorAction SilentlyContinue | Where-Object { Test-UnderRoot $_.Path $Root })) {
        $p.CloseMainWindow() | Out-Null
        if (-not $p.WaitForExit(15000)) { Note "hmi $($p.Id) did not close in 15 s, killed"; $p.Kill() }
    }
    Note 'hmi closed'
    $null = Invoke-Reader 'read-after-exit' @()
} finally {
    Note "final stack: sim=$((Get-Stack).Sim -join ',') hmi=$((Get-Stack).Hmi -join ',')"
    foreach ($name in 'SQCD.Agv.Wpf', 'SQCD_8005AGV_Simulator') {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { Test-UnderRoot $_.Path $Root })) {
            try { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(10000)) { $p.Kill() } } catch { if (-not $p.HasExited) { throw } }
        }
    }
    Get-ScheduledTask -TaskName 'W2G-hmi316-*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    $mutex.ReleaseMutex(); $mutex.Dispose()
    Note "output: $out"
}
