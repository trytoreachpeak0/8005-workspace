#Requires -Version 7
<#
    ws#20 local reproduction. Runs on the control host's own interactive desktop, never on a vehicle.
    Starts slots-simulator and the onboard WPF the way 10-start-onboard-stack.ps1 does (one-shot
    Interactive scheduled task), then launches the entry task again and again with the launch script
    that 16-enter-sublot-uia.ps1 itself generates, and records after each launch whether the simulator
    and the HMI are still alive, what Get-ScheduledTaskInfo reported, and whether the entry pwsh had a
    visible window.

    Deviations from the vehicle, all recorded in the output:
      * the active desktop here is an RDP session, so the launch script's 'console' match is widened
        to rdp-tcp#N;
      * -VehicleRoot is a scratch directory;
      * for the loop runs -WaitSeconds is appended to the vehicle arguments so one run takes seconds,
        not a minute (the 2026-10-11 kill happened within 3 s of the task start).
#>
param(
    [string] $Root = 'F:\8005-scratch\ws20',
    [int] $Iterations = 10,
    [switch] $VerifyOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -Namespace Ws20 -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);'

$out = Join-Path $Root "repro\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = Join-Path $out 'runs.jsonl'
function Note([string] $Text) { $line = "$(Get-Date -Format 'HH:mm:ss.fff') $Text"; $line; Add-Content -LiteralPath (Join-Path $out 'log.txt') -Value $line }

$simExe = Join-Path $Root 'bin\sim\SQCD_8005AGV_Simulator.exe'
$hmiExe = Join-Path $Root 'bin\hmi\SQCD.Agv.Wpf.exe'

function Start-Interactive([string] $Path, [string] $Label) {
    $name = "W2G-ws20-$Label-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
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

# The launch script generator, taken from a given copy of 16-enter-sublot-uia.ps1 without running that file.
function Get-LaunchGenerator([string] $Path) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-LaunchScript' }, $true)
    return [scriptblock]::Create(($fn.Body.Extent.Text -replace '^\{', '' -replace '\}$', ''))
}

function Invoke-Entry([string] $Variant, [string] $LaunchSource, [string] $VehicleScript, [int] $Index, [int] $WaitSeconds) {
    $runId = "$Variant$Index-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $vroot = Join-Path $out "uia-$Variant"
    New-Item -ItemType Directory -Force -Path $vroot | Out-Null
    Copy-Item -LiteralPath $VehicleScript -Destination (Join-Path $vroot 'agv-enter-sublot-uia.ps1') -Force
    $resultPath = Join-Path $vroot "result-$runId.json"
    $text = & (Get-LaunchGenerator $LaunchSource) -VehicleRoot $vroot -Sublot 'WS20-1' -ResultPath $resultPath -RunId $runId
    $text = $text.Replace("'^\s*>?console\s+(\S+)\s+(\d+)\s+Active'", "'^\s*>?(?:console|rdp-tcp#\d+)\s+(\S+)\s+(\d+)\s+Active'")
    if ($WaitSeconds -gt 0) { $text = $text.Replace('-ResultPath "' + $resultPath + '"''', '-ResultPath "' + $resultPath + '" -WaitSeconds ' + $WaitSeconds + '''') }
    $launch = Join-Path $vroot "launch-$runId.ps1"
    Set-Content -LiteralPath $launch -Value $text -Encoding utf8NoBOM

    $before = Get-Stack
    $t0 = Get-Date
    $launchOut = @(& pwsh -NoProfile -File $launch 2>&1 | ForEach-Object { "$_" })
    $t1 = Get-Date
    # Window of the entry pwsh while it runs: is it visible?
    $visible = $null
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $deadline) {
        $p = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*$resultPath*" } | Select-Object -First 1
        if ($p) {
            $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            if ($proc -and $proc.MainWindowHandle -ne 0) { $visible = [Ws20.Native]::IsWindowVisible($proc.MainWindowHandle) }
            elseif ($null -eq $visible) { $visible = 'no-main-window' }
        }
        Start-Sleep -Milliseconds 500
    }
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Seconds 1
    $after = Get-Stack
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    $started = ($launchOut | Select-String 'TASK_STARTED lastRunTime=(.+) lastTaskResult=(0x[0-9A-F]+)').Matches
    $record = [ordered]@{
        variant = $Variant; index = $Index; runId = $runId
        launchCalledAt = $t0.ToString('HH:mm:ss.fff'); launchReturnedAt = $t1.ToString('HH:mm:ss.fff')
        lastRunTime = $started ? $started[0].Groups[1].Value : $null
        lastTaskResult = $started ? $started[0].Groups[2].Value : $null
        launchDone = [bool]($launchOut -match '^LAUNCH_DONE$')
        entryWindowVisible = $visible
        resultWindow = ${result}?.window; outcome = ${result}?.outcome; resultStartedAt = ${result}?.startedAt; error = ${result}?.error
        simBefore = $before.Sim -join ','; simAfter = $after.Sim -join ','
        hmiBefore = $before.Hmi -join ','; hmiAfter = $after.Hmi -join ','
        simSurvived = ($before.Sim.Count -eq 1 -and ($after.Sim -join ',') -eq ($before.Sim -join ','))
        hmiSurvived = ($before.Hmi.Count -eq 1 -and ($after.Hmi -join ',') -eq ($before.Hmi -join ','))
    }
    Add-Content -LiteralPath $log -Value ($record | ConvertTo-Json -Compress)
    Note ("{0}{1} task={2}@{3} called={4} visible={5} outcome={6} window={7} sim={8} hmi={9}" -f $Variant, $Index, $record.lastTaskResult, $record.lastRunTime, $record.launchCalledAt, $visible, $record.outcome, $record.resultWindow, $record.simSurvived, $record.hmiSurvived)
    return $record
}

$mutex = [System.Threading.Mutex]::new($false, 'Global\W2G-InteractiveDesktop')
if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(60))) { throw 'Desktop lock Global\W2G-InteractiveDesktop is held by someone else.' }
try {
    Note "query session: $((query session 2>&1 | Out-String).Trim() -replace '\s+', ' ')"
    $s = Get-Stack
    if ($s.Sim.Count -or $s.Hmi.Count) { throw "A simulator or HMI is already running here (sim $($s.Sim -join ','), hmi $($s.Hmi -join ','))." }
    Start-Interactive $simExe 'Simulator'
    $deadline = (Get-Date).AddSeconds(60)
    while (-not ((Get-NetTCPConnection -State Listen -LocalPort 1502 -ErrorAction SilentlyContinue) -and (Get-NetTCPConnection -State Listen -LocalPort 58006 -ErrorAction SilentlyContinue))) {
        if ((Get-Date) -gt $deadline) { throw 'simulator did not listen on 1502/58006' }
        Start-Sleep -Seconds 1
    }
    Note "simulator up pid=$((Get-Stack).Sim -join ',')"
    Start-Interactive $hmiExe 'Onboard'
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Get-Stack).Hmi.Count) { if ((Get-Date) -gt $deadline) { throw 'HMI did not start' }; Start-Sleep -Seconds 1 }
    Start-Sleep -Seconds 10
    Note "hmi up pid=$((Get-Stack).Hmi -join ',')"

    $new16 = 'F:\8005-wt\ws20-8005-workspace\remote-ops\onboard-hmi\scripts\16-enter-sublot-uia.ps1'
    $newVeh = 'F:\8005-wt\ws20-8005-workspace\remote-ops\onboard-hmi\scripts\agv-enter-sublot-uia.ps1'
    $old16 = Join-Path $Root 'old\16-enter-sublot-uia.ps1'
    $oldVeh = Join-Path $Root 'old\agv-enter-sublot-uia.ps1'

    # 1. The fix as shipped: hidden console, unmodified arguments. Does UIA still attach to the HMI?
    $null = Invoke-Entry 'verify' $new16 $newVeh 1 0
    if (-not $VerifyOnly) {
        for ($i = 1; $i -le $Iterations; $i++) {
            $null = Invoke-Entry 'old' $old16 $oldVeh $i 3
            $null = Invoke-Entry 'new' $new16 $newVeh $i 3
        }
    }
} finally {
    Note "final stack: sim=$((Get-Stack).Sim -join ',') hmi=$((Get-Stack).Hmi -join ',')"
    foreach ($name in 'SQCD.Agv.Wpf', 'SQCD_8005AGV_Simulator') {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root*" })) {
            try { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(10000)) { $p.Kill() } } catch { if (-not $p.HasExited) { throw } }
        }
    }
    Get-ScheduledTask -TaskName 'W2G-EnterSublot-*', 'W2G-ws20-*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    $mutex.ReleaseMutex(); $mutex.Dispose()
    Note "output: $out"
}
