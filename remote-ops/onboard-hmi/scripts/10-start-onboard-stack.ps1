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

.PARAMETER NoSimulator
    Start only the client, for a vehicle whose IO points at the real Modbus
    module (09-switch-io-module.ps1 -RealModule). The ORDER constraint above is
    about the simulator being the client's IO plane; when it is not, starting it
    is noise that still holds 1502 and 58006 and makes "which one is the real IO
    source" a question during troubleshooting.

    The two switches contradict each other and cannot be combined. Both are
    checked against the deployed ioModule.host rather than trusted: -NoSimulator
    against a loopback IO target would start a client with nothing to talk to,
    which is the RecoveryRequired trap the ORDER note describes, so it is
    refused rather than attempted.

.EXAMPLE
    ./10-start-onboard-stack.ps1

.EXAMPLE
    ./10-start-onboard-stack.ps1 -SimulatorOnly

.EXAMPLE
    ./10-start-onboard-stack.ps1 -NoSimulator

.EXAMPLE
    ./10-start-onboard-stack.ps1 -Stop
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SshAlias = 'agv01',
    [switch] $Stop,
    [switch] $Force,
    [switch] $SimulatorOnly,
    [switch] $NoSimulator,
    [string] $OnboardExe = 'C:\8005\OnboardHmi\SQCD.Agv.Wpf.exe',
    [string] $SimulatorExe = 'C:\8005\SlotsSimulator\SQCD_8005AGV_Simulator.exe',
    [string] $ConfigPath = 'C:\8005\OnboardHmi\appsettings.json',
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

if ($SimulatorOnly -and $NoSimulator) {
    throw '-SimulatorOnly and -NoSimulator ask for opposite halves of the stack. Pick one.'
}

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Onboard {
    param([string] $Script)

    # `pwsh -EncodedCommand` does not report a status of its own. When the script
    # ends without an explicit `exit`, it exits 1 if `$?` is False -- and `$?` is
    # whatever the LAST statement left behind. `-ErrorAction SilentlyContinue`
    # sets it False while printing nothing, so a block whose final statement is a
    # `Get-Process -ErrorAction SilentlyContinue` that matched nothing comes back
    # as "exit 1, no output". That is the empty `ssh agv01 failed:` which
    # interrupted 12-reset-journey-state.ps1 on 2026-09-20 *after* the stack had
    # already stopped cleanly, leaving the reset half done.
    #
    # So the status is made deliberate rather than inherited: a run that reaches
    # the end says so. This does not hide failures -- a terminating error never
    # reaches `exit 0` -- but it does mean a block that wants a non-terminating
    # error to count as failure has to say `$ErrorActionPreference = 'Stop'`
    # itself, as the blocks below do.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$Script`nexit 0"))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    $exit = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()
    # Never throw a bare colon again: say what the exit code was even when the
    # far end had nothing to say.
    if ($exit -ne 0) { throw "ssh $SshAlias failed (exit $exit): $(if ($text) { $text } else { '(no output)' })" }
    $text
}

# Names as the vehicle's own process list reports them, which is what every
# probe below matches on.
$onboardProcess   = [IO.Path]::GetFileNameWithoutExtension($OnboardExe)
$simulatorProcess = [IO.Path]::GetFileNameWithoutExtension($SimulatorExe)

function Get-StackState {
    $json = Invoke-Onboard @"
`$ErrorActionPreference = 'Stop'
`$onboard   = @(Get-Process -Name '$onboardProcess' -ErrorAction SilentlyContinue)
`$simulator = @(Get-Process -Name '$simulatorProcess' -ErrorAction SilentlyContinue)
`$ports = @{}
foreach (`$p in 1502, 58006) {
    `$ports["`$p"] = [bool](Get-NetTCPConnection -State Listen -LocalPort `$p -ErrorAction SilentlyContinue)
}
# Read rather than assume which IO plane this deployment is pointed at. A
# missing file is reported as an absent target instead of throwing: -Stop has
# to work on a vehicle that was never deployed to.
`$io = `$null
if (Test-Path -LiteralPath '$ConfigPath') {
    `$io = (Get-Content -LiteralPath '$ConfigPath' -Raw | ConvertFrom-Json).ioModule
}
# Project the ids through the pipeline, not with `@(`$procs.Id)`. On an empty
# result that member access yields `$null and `@(`$null)` is a ONE-element array
# holding it, so an idle vehicle reported one client and one simulator and the
# script refused to ever start anything.
[pscustomobject]@{
    OnboardPids   = @(`$onboard | ForEach-Object { `$_.Id })
    SimulatorPids = @(`$simulator | ForEach-Object { `$_.Id })
    Ports         = `$ports
    IoHost        = `$io.host
    IoPort        = `$io.port
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
`$ErrorActionPreference = 'Stop'
foreach (`$name in '$onboardProcess', '$simulatorProcess') {
    foreach (`$p in @(Get-Process -Name `$name -ErrorAction SilentlyContinue)) {
        # Errors are terminating here so that a Kill which is actually refused
        # says so, instead of being swallowed and rediscovered as "STILL RUNNING"
        # with no reason attached. The guard is what keeps that from turning into
        # the opposite failure: a process that exits on its own between the
        # enumeration and the call is the outcome being asked for, and aborting
        # on it would stop the client and leave the simulator up. So the verdict
        # is the process itself -- still alive, still a failure -- and the state
        # check below is what reports it either way.
        try {
            `$p.CloseMainWindow() | Out-Null
            if (-not `$p.WaitForExit(10000)) { `$p.Kill(); `$p.WaitForExit(10000) | Out-Null }
        } catch {
            if (-not `$p.HasExited) { throw }
        }
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

# Which IO plane the deployment is pointed at decides whether the simulator is
# this client's IO source or an idle process holding two ports. The switch says
# what the caller intends; this says what the vehicle is actually configured
# for, and a disagreement is worth stopping on rather than starting into.
$ioIsLoopback = $state.IoHost -eq '127.0.0.1'
if ($null -eq $state.IoHost) {
    Write-Step "No $ConfigPath on this vehicle; the IO target could not be read"
} else {
    Write-Step "Onboard IO target: $($state.IoHost):$($state.IoPort)$(if ($ioIsLoopback) { ' (simulator)' } else { ' (real module)' })"
}

if ($NoSimulator -and $ioIsLoopback) {
    throw ("Onboard IO points at $($state.IoHost):$($state.IoPort), which is the simulator. " +
        'Starting the client without it fails the startup IO snapshot and the session never leaves ' +
        'RecoveryRequired. Run 09-switch-io-module.ps1 -RealModule first, or drop -NoSimulator.')
}
if (-not $NoSimulator -and -not $SimulatorOnly -and $null -ne $state.IoHost -and -not $ioIsLoopback) {
    Write-Step 'IO is on the real module; the simulator would just hold 1502 and 58006. Consider -NoSimulator.'
}

$what = if ($SimulatorOnly) { 'the slot simulator' } elseif ($NoSimulator) { 'the onboard client' } else { 'the slot simulator and the onboard client' }
if (-not $PSCmdlet.ShouldProcess($SshAlias, "Start $what in the interactive desktop session")) { return }

if ($NoSimulator) {
    Write-Step 'Skipping the simulator; the client talks to the real module'
    # Not stopped here. Stopping something the caller did not ask about is how a
    # script becomes unpredictable -- but a simulator still up while the client
    # reads a different IO plane is worth saying out loud, because its snapshot
    # will look plausible and mean nothing.
    if ($state.SimulatorPids.Count) {
        Write-Step "Note: the simulator is still running (PID $($state.SimulatorPids -join ', ')) and is NOT this client's IO source."
    }
} elseif ($state.SimulatorPids.Count -eq 0) {
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
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $(if ($NoSimulator) { 'Client up' } else { 'Both up' }) on $SshAlias." -ForegroundColor Green
Write-Host '  The session is not Ready until the vehicle-safety projection returns' -ForegroundColor Yellow
Write-Host '  motionState=STOPPED with fresh evidence. That judgement is still a person''s.' -ForegroundColor Yellow
