#Requires -Version 7
<#
.SYNOPSIS
    Drives one WIRE_TO_GATE station operation on a real vehicle with nobody at
    the HMI. Runs ON the control host.

.DESCRIPTION
    The L2 rig already automates the operator, but only on one machine: both
    halves are local to it, so it drives the WPF client through UI Automation
    directly. In the production topology the client is on the vehicle and this
    script is somewhere else, and UI Automation cannot see a window in another
    machine's session. So the work is split:

        control host (this file)   read the sublot the SERVER asked for,
                                   deploy and launch the driver, collect the result
        vehicle (agv-drive-journey.ps1)   UI Automation scan + simulator cargo/door

    The driver runs in the vehicle's interactive session, started by the same
    scheduled-task mechanism 10-start-onboard-stack.ps1 uses, because that is the
    only session where the client's window exists.

    WHY NOT THE ONBOARD'S OWN AUTOMATION API. The client ships one, and it would
    make the scan a one-line POST. Turning it on hangs the client at startup --
    the process lives, no window is created, not one log line is written.
    Verified on agv01 2026-09-07 and reverted; see the issue. Until that is
    fixed, UI Automation is the route that works.

    The sublot is read from the server rather than guessed: whatever
    SublotEntryRequested currently carries is what the client will accept, and
    anything else is a negative test.

.PARAMETER Sublot
    Submit this instead of what the server asked for. Only useful for negative
    tests.

.PARAMETER CargoState
    OCCUPIED (default) completes the load. EMPTY reproduces a failed one.

.EXAMPLE
    ./11-drive-journey.ps1

.EXAMPLE
    ./11-drive-journey.ps1 -CargoState EMPTY
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SshAlias = 'agv01',
    [string] $ServerAlias = 'factory01',
    [string] $Sublot,
    [ValidateSet('OCCUPIED', 'EMPTY')]
    [string] $CargoState = 'OCCUPIED',
    [string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer\data\controlserver.db',
    [string] $ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer',
    [string] $VehicleWorkRoot = 'C:\8005\automation',
    [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

# Duplicated from 09-switch-io-module.ps1 rather than shared: these scripts are
# standalone by house style, and the contract is the ssh alias, not the helper.
function Invoke-Remote {
    param([string] $Alias, [string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $Alias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $Alias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Driving one operation on $SshAlias" -ForegroundColor Green

# --- what does the server want scanned? -----------------------------------

if (-not $Sublot) {
    # Read it from the outbox rather than the journey row: the entry request is
    # the message the client is actually answering, and it carries the sublot the
    # client will compare against.
    $expected = Invoke-Remote $ServerAlias @"
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly')
`$c.Open()
`$m = `$c.CreateCommand()
`$m.CommandText = "SELECT PayloadJson FROM ProtocolOutbox WHERE MessageType = 'SublotEntryRequested' AND AcknowledgedAt IS NULL ORDER BY CreatedAt DESC LIMIT 1"
`$p = [string]`$m.ExecuteScalar()
`$c.Close()
if (`$p -match '"expectedSublot"\s*:\s*"([^"]+)"') { `$matches[1] } else { '' }
"@
    if (-not $expected) { throw "The server has no unanswered SublotEntryRequested; there is nothing to drive." }
    $Sublot = $expected
}
Write-Step "Sublot to submit: $Sublot"

if (-not $PSCmdlet.ShouldProcess($SshAlias, "Submit sublot $Sublot and play the operator's part (cargo=$CargoState)")) { return }

# --- deploy the driver ------------------------------------------------------

$runId = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$resultPath = "$VehicleWorkRoot\result-$runId.json"
$driverLocal = Join-Path $PSScriptRoot 'agv-drive-journey.ps1'
if (-not (Test-Path -LiteralPath $driverLocal)) { throw "Driver not found: $driverLocal" }

$null = Invoke-Remote $SshAlias "New-Item -ItemType Directory -Path '$VehicleWorkRoot' -Force | Out-Null"
& scp -o BatchMode=yes $driverLocal "${SshAlias}:$VehicleWorkRoot/agv-drive-journey.ps1" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not copy the driver to $SshAlias" }
Write-Step "Driver deployed to $VehicleWorkRoot"

# --- launch it in the interactive session ----------------------------------

# sshd hands us session 0, and UI Automation there cannot see the client's
# window. Same mechanism as 10-start-onboard-stack.ps1: a scheduled task with an
# Interactive principal runs in the logged-on user's session, and the task is
# unregistered immediately so nothing outlives this run.
$taskName = "W2G-Drive-$runId"
$argumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$VehicleWorkRoot\agv-drive-journey.ps1`" " +
    "-Sublot `"$Sublot`" -CargoState $CargoState -ResultPath `"$resultPath`""
$null = Invoke-Remote $SshAlias @"
`$ErrorActionPreference = 'Stop'
`$console = (query session 2>&1 | Select-String -Pattern '^\s*>?console\s+(\S+)\s+(\d+)\s+Active').Matches
if (-not `$console) { throw 'No active console session on this vehicle.' }
`$user = `$console[0].Groups[1].Value
`$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '$argumentList' -WorkingDirectory '$VehicleWorkRoot'
`$principal = New-ScheduledTaskPrincipal -UserId `$user -LogonType Interactive -RunLevel Limited
`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
try {
    Register-ScheduledTask -TaskName '$taskName' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
    Start-ScheduledTask -TaskName '$taskName'
} finally {
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
}
"@
Write-Step 'Driver started in the interactive session'

# --- wait for its verdict ---------------------------------------------------

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
$lastStep = ''
while ($true) {
    $raw = Invoke-Remote $SshAlias "if (Test-Path -LiteralPath '$resultPath') { Get-Content -Raw -LiteralPath '$resultPath' } else { '' }"
    if ($raw) { break }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw "Timed out after ${TimeoutSeconds}s; the driver wrote no result to $resultPath on $SshAlias."
    }
    Start-Sleep -Seconds 3
}

# ssh writes its own banner to stderr and Invoke-Remote folds stderr in, so the
# payload arrives with whatever the server had to say in front of it. Take the
# JSON object and nothing else.
$jsonStart = $raw.IndexOf('{')
if ($jsonStart -lt 0) { throw "No JSON in the driver's result: $raw" }
$result = $raw.Substring($jsonStart) | ConvertFrom-Json
foreach ($s in $result.steps) {
    $line = "$($s.step): $($s.detail)"
    if ($line -ne $lastStep) { Write-Step $line; $lastStep = $line }
}

if ($result.status -ne 'OK') {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Driver FAILED: $($result.message)" -ForegroundColor Red
    throw $result.message
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($result.message)" -ForegroundColor Green
Write-Host '  The journey continues on the server; this script only played the operator.' -ForegroundColor Yellow
Write-Host "  Result on the vehicle: $resultPath" -ForegroundColor Yellow
