#Requires -Version 7
<#
.SYNOPSIS
    Starts (or stops) the two onboard WPF applications on one vehicle, in the
    interactive desktop session. Runs ON the control host.

.DESCRIPTION
    Until 2026-09-04 this step had no script at all: 06-deploy-onboard-hmi.ps1
    staged the client and stopped, and starting it meant walking to the vehicle
    and double-clicking. That rule is now narrowed rather than deleted, and the
    distinction is the whole point of this file.

    What has NOT changed: starting the onboard client is an action with a
    physical consequence. RELEASE-CANDIDATE.md section 11 requires a per-occasion
    authorisation and an on-site safety GO before the vehicle is allowed to move,
    and section 8 puts the readiness judgement on a person -- a clean session only
    reaches Ready when the vehicle-safety projection returns motionState=STOPPED
    with fresh evidence, and somebody has to be watching that.

    What HAS changed: the authorisation is no longer expressed by which building
    you are standing in. It is expressed by deliberately invoking this script.
    Nothing invokes it for you -- not deployment, not a logon trigger, not a
    scheduled task that outlives the run. It refuses to start a stack that is
    already up, and it never starts anything as a side effect of something else.

    Two things this script does that a person at the keyboard would get wrong:

      * ORDER. The simulator must be listening on 1502 before the client opens
        its Modbus connection. Started the other way round the client fails its
        startup IO snapshot and the session never leaves RecoveryRequired, which
        reads as a server problem.
      * WAITING. Each half is confirmed up -- ports for the simulator, process
        for the client -- before the next step, so a failure is reported against
        the half that actually failed.

.PARAMETER SshAlias
    Which vehicle. One alias per car; see remote-ops/fleet.md.

.PARAMETER Stop
    Stop both applications instead, client first so the vehicle is not left
    talking to an IO plane that has gone away.

.PARAMETER Force
    Start even though something is already running. Refuses by default: a
    running client means the vehicle may be mid-journey.

.PARAMETER SimulatorOnly
    Start only the slot IO simulator. The client stays down, so nothing that
    moves the vehicle is started. Useful when the person at the vehicle wants
    to open the client themselves.

.EXAMPLE
    ./10-start-onboard-stack.ps1

.EXAMPLE
    ./10-start-onboard-stack.ps1 -SimulatorOnly

.EXAMPLE
    ./10-start-onboard-stack.ps1 -Stop
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SshAlias = 'agv01',
    [switch] $Stop,
    [switch] $Force,
    [switch] $SimulatorOnly,
    [string] $OnboardExe = 'C:\8005\OnboardHmi\SQCD.Agv.Wpf.exe',
    [string] $SimulatorExe = 'C:\8005\SlotsSimulator\SQCD_8005AGV_Simulator.exe',
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Onboard {
    param([string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

# Names as the vehicle's own process list reports them, which is what every
# probe below matches on.
$onboardProcess   = [IO.Path]::GetFileNameWithoutExtension($OnboardExe)
$simulatorProcess = [IO.Path]::GetFileNameWithoutExtension($SimulatorExe)

function Get-StackState {
    $json = Invoke-Onboard @"
`$onboard   = @(Get-Process -Name '$onboardProcess' -ErrorAction SilentlyContinue)
`$simulator = @(Get-Process -Name '$simulatorProcess' -ErrorAction SilentlyContinue)
`$ports = @{}
foreach (`$p in 1502, 58006) {
    `$ports["`$p"] = [bool](Get-NetTCPConnection -State Listen -LocalPort `$p -ErrorAction SilentlyContinue)
}
# Project the ids through the pipeline, not with `@(`$procs.Id)`. On an empty
# result that member access yields `$null and `@(`$null)` is a ONE-element array
# holding it, so an idle vehicle reported one client and one simulator and the
# script refused to ever start anything.
[pscustomobject]@{
    OnboardPids   = @(`$onboard | ForEach-Object { `$_.Id })
    SimulatorPids = @(`$simulator | ForEach-Object { `$_.Id })
    Ports         = `$ports
} | ConvertTo-Json -Compress
"@
    return $json | ConvertFrom-Json
}

# Session 0 is where sshd puts us, and a WPF window started there is owned by a
# desktop nobody is looking at. A scheduled task with an Interactive principal
# runs in the logged-on user's session instead -- the same mechanism the
# golden-renderer runner uses on win11-01. It only works while that user IS
# logged on, which on these machines is what the autologon is for; the caller
# gets told plainly rather than getting a task that silently never fires.
function Start-InInteractiveSession {
    param([string] $Path, [string] $Label)

    $workingDirectory = Split-Path -Parent $Path
    $taskName = "W2G-Start-$Label-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Invoke-Onboard @"
`$ErrorActionPreference = 'Stop'
`$console = (query session 2>&1 | Select-String -Pattern '^\s*>?console\s+(\S+)\s+(\d+)\s+Active').Matches
if (-not `$console) { throw 'No active console session on this vehicle; the interactive desktop is not logged on.' }
`$user = `$console[0].Groups[1].Value
`$action = New-ScheduledTaskAction -Execute '$Path' -WorkingDirectory '$workingDirectory'
`$principal = New-ScheduledTaskPrincipal -UserId `$user -LogonType Interactive -RunLevel Limited
`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
try {
    Register-ScheduledTask -TaskName '$taskName' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
    Start-ScheduledTask -TaskName '$taskName'
} finally {
    # The task is a launcher, not a fixture. Leaving it behind would turn the
    # next logon into an unauthorised start, which is exactly the thing this
    # script exists to keep deliberate.
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
}
"@ | Out-Null
}

function Wait-For {
    param([string] $Description, [scriptblock] $Probe)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if (& $Probe) { return }
        Start-Sleep -Seconds 2
    }
    throw "Timed out after ${TimeoutSeconds}s waiting for: $Description"
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Onboard stack on $SshAlias" -ForegroundColor Green
$state = Get-StackState

if ($Stop) {
    if ($state.OnboardPids.Count -eq 0 -and $state.SimulatorPids.Count -eq 0) {
        Write-Step 'Nothing is running.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($SshAlias, 'Stop the onboard client and the slot simulator')) { return }
    # Client first: stopping the IO plane under a running client is how you get
    # an IO trace nobody can explain afterwards.
    Invoke-Onboard @"
foreach (`$name in '$onboardProcess', '$simulatorProcess') {
    Get-Process -Name `$name -ErrorAction SilentlyContinue | ForEach-Object {
        `$_.CloseMainWindow() | Out-Null
        if (-not `$_.WaitForExit(10000)) { `$_.Kill(); `$_.WaitForExit(10000) | Out-Null }
    }
}
"@ | Out-Null
    $after = Get-StackState
    Write-Step "Onboard client: $(if ($after.OnboardPids.Count) { 'STILL RUNNING' } else { 'stopped' })"
    Write-Step "Simulator:      $(if ($after.SimulatorPids.Count) { 'STILL RUNNING' } else { 'stopped' })"
    if ($after.OnboardPids.Count -or $after.SimulatorPids.Count) { throw 'Something is still running on the vehicle.' }
    return
}

# Only the client blocks a start. The reason for refusing is that a running
# client means the vehicle may be mid-journey -- which says nothing about the
# simulator, and a simulator left up by an earlier -SimulatorOnly is a normal
# intermediate state that the start path below handles by leaving it alone.
if (-not $Force -and $state.OnboardPids.Count) {
    throw ("The onboard client is already running on ${SshAlias} (PID $($state.OnboardPids -join ', ')). " +
        'That may mean the vehicle is mid-journey. Use -Stop, or -Force if you are certain.')
}

$what = if ($SimulatorOnly) { 'the slot simulator' } else { 'the slot simulator and the onboard client' }
if (-not $PSCmdlet.ShouldProcess($SshAlias, "Start $what in the interactive desktop session")) { return }

if ($state.SimulatorPids.Count -eq 0) {
    Write-Step 'Starting the slot IO simulator'
    Start-InInteractiveSession -Path $SimulatorExe -Label 'Simulator'
    Wait-For 'the simulator to listen on 1502 and 58006' {
        $s = Get-StackState
        $s.Ports.'1502' -and $s.Ports.'58006'
    }
    Write-Step 'Simulator up: 1502 (Modbus) and 58006 (automation) listening'
} else {
    Write-Step 'Simulator already running; leaving it alone'
}

if ($SimulatorOnly) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Simulator only. The client was not started." -ForegroundColor Green
    return
}

Write-Step 'Starting the onboard client'
Start-InInteractiveSession -Path $OnboardExe -Label 'Onboard'
Wait-For 'the onboard client process to appear' { (Get-StackState).OnboardPids.Count -gt 0 }

$final = Get-StackState
Write-Step "Onboard client PID(s): $($final.OnboardPids -join ', ')"
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Both up on $SshAlias." -ForegroundColor Green
Write-Host '  The session is not Ready until the vehicle-safety projection returns' -ForegroundColor Yellow
Write-Host '  motionState=STOPPED with fresh evidence. That judgement is still a person''s.' -ForegroundColor Yellow
