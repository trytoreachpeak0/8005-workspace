#Requires -Version 7
<#
.SYNOPSIS
    Clears an in-flight WIRE_TO_GATE journey from BOTH ends so the next one
    starts clean. Runs ON the control host. Test environments only.

.DESCRIPTION
    This exists because clearing one end is worse than clearing neither, and
    that is not a theory -- it happened on 2026-09-04.

    The server's journey rows were deleted so a stuck demand would stop blocking
    the vehicle. The server then started the next demand at
    `VehicleBusinessRevision = 1`. But the vehicle's journal lives in
    `%LOCALAPPDATA%` -- outside the install root, so neither the deletion nor a
    redeployment touches it -- and it still held revision 1 of the *previous*
    demand, with different content. The client did exactly what the contract
    says: `SNAPSHOT_REVISION_CONTENT_CONFLICT`, tear the session down. It then
    reconnected and hit the same message again, every seven seconds, until
    somebody noticed. The vehicle was right; the reset was half done.

    So this script resets the pair, or neither:

        server (factory01)  every row keyed to the in-flight demand or its
                            station operation, plus any unacknowledged outbox
                            message -- a queued command for a demand that no
                            longer exists would be replayed at the next session
        vehicle (agv01)     the whole onboard journal file, which the client
                            recreates empty on its next start
                            (SqliteWireToGateJournal uses CREATE TABLE IF NOT EXISTS)

    Both stores are backed up first, and both backups are kept: they are the
    evidence for whatever made the reset necessary.

    THIS IS NOT A PRODUCT FEATURE. Nothing here belongs in a plant that is
    running work. A real stuck journey is resolved through recovery, which is
    what the recovery state machine and `docs/defects/` are about. This is the
    blunt instrument for a test rig whose leftovers are in the way.

    The vehicle's client is stopped for the duration -- the journal is open
    while it runs -- and restarted at the end.

.PARAMETER KeepStackDown
    Leave the onboard client and simulator stopped at the end. Useful when the
    next thing you do is a deployment.

.PARAMETER Force
    Suppress the confirmation prompt by lowering $ConfirmPreference, the same way
    Set-JourneyRuntime.ps1 does. Needed to run this unattended: ConfirmImpact is
    High, and ShouldProcess throws rather than prompting when there is no host UI
    to prompt on.

.PARAMETER WhatIf
    Report what would be deleted on both ends and stop.

.EXAMPLE
    ./12-reset-journey-state.ps1 -WhatIf

.EXAMPLE
    ./12-reset-journey-state.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $SshAlias = 'agv01',
    [string] $ServerAlias = 'factory01',
    [string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer\data\controlserver.db',
    [string] $ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer',
    [string] $ServerBackupRoot = 'D:\zhengyushao\control-server-ops',
    [string] $VehicleJournal = 'C:\Users\HT\AppData\Local\SQCD\8005AGV\onboard-journal.db',
    [string] $VehicleBackupRoot = 'C:\8005\journal-backup',
    [switch] $KeepStackDown,
    [switch] $Force,
    [int] $ReadyTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
if ($Force) { $ConfirmPreference = 'None' }

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Remote {
    param([string] $Alias, [string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $Alias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $Alias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss')

# ---------------------------------------------------------------- survey ---

# Which demand is in flight, and what would go? Discovered rather than passed
# in: the point of the script is that both ends agree afterwards, and a demand
# id typed by hand is one more thing that can be wrong.
#
# Tables are matched by column, not by name. The set of tables carrying a
# DemandId has grown twice already, and a reset that misses one leaves exactly
# the kind of half-state this script exists to prevent.
$surveyScript = @"
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly')
`$c.Open()
`$m = `$c.CreateCommand(); `$m.CommandText = 'SELECT DemandId FROM JourneyRuntimes'
`$demands = @(); `$r = `$m.ExecuteReader(); while (`$r.Read()) { `$demands += `$r.GetString(0) }; `$r.Close()
`$m2 = `$c.CreateCommand(); `$m2.CommandText = 'SELECT SlotOperationAttemptId FROM StationOperations'
`$attempts = @(); `$r2 = `$m2.ExecuteReader(); while (`$r2.Read()) { `$attempts += `$r2.GetString(0) }; `$r2.Close()
`$tables = @(); `$mt = `$c.CreateCommand()
`$mt.CommandText = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name <> '__EFMigrationsHistory' ORDER BY name"
`$rt = `$mt.ExecuteReader(); while (`$rt.Read()) { `$tables += `$rt.GetString(0) }; `$rt.Close()
`$plan = @()
foreach (`$t in `$tables) {
    `$ci = `$c.CreateCommand(); `$ci.CommandText = "PRAGMA table_info([`$t])"
    `$cols = @(); `$ri = `$ci.ExecuteReader(); while (`$ri.Read()) { `$cols += `$ri.GetString(1) }; `$ri.Close()
    `$where = @()
    if (`$cols -contains 'DemandId' -and `$demands.Count) {
        `$where += "DemandId IN ('" + (`$demands -join "','") + "')"
    }
    if (`$cols -contains 'SlotOperationAttemptId' -and `$attempts.Count) {
        `$where += "SlotOperationAttemptId IN ('" + (`$attempts -join "','") + "')"
    }
    if (`$t -eq 'ProtocolOutbox') { `$where += 'AcknowledgedAt IS NULL' }
    if (-not `$where.Count) { continue }
    `$clause = `$where -join ' OR '
    `$q = `$c.CreateCommand(); `$q.CommandText = "SELECT COUNT(*) FROM [`$t] WHERE `$clause"
    `$n = [int]`$q.ExecuteScalar()
    if (`$n -gt 0) { `$plan += [pscustomobject]@{ table = `$t; rows = `$n; where = `$clause } }
}
`$c.Close()
[pscustomobject]@{ demands = `$demands; attempts = `$attempts; plan = `$plan } | ConvertTo-Json -Depth 6 -Compress
"@

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Resetting journey state on $ServerAlias + $SshAlias" -ForegroundColor Green
$survey = Invoke-Remote $ServerAlias $surveyScript | ConvertFrom-Json

if (-not $survey.plan -or $survey.plan.Count -eq 0) {
    Write-Step 'Server has nothing to clear.'
} else {
    Write-Step "In-flight demands: $((@($survey.demands) -join ', ') ?? '(none)')"
    foreach ($p in $survey.plan) { Write-Step ("{0,-32} {1} row(s)" -f $p.table, $p.rows) }
}
$serverTotal = ($survey.plan | Measure-Object -Property rows -Sum).Sum ?? 0

$journalInfo = Invoke-Remote $SshAlias @"
if (Test-Path -LiteralPath '$VehicleJournal') {
    `$f = Get-Item -LiteralPath '$VehicleJournal'
    "`$(`$f.Length) bytes, last written `$(`$f.LastWriteTime.ToString('o'))"
} else { '(absent)' }
"@
Write-Step "Vehicle journal: $journalInfo"

if ($WhatIfPreference) {
    Write-Host '  WhatIf: nothing was changed on either end.' -ForegroundColor Yellow
    return
}
# Both strings are built first: ShouldProcess throws a bare null-reference when
# either argument is null, which says nothing about which one it was.
$target = '{0} ({1} rows) and {2} (the onboard journal)' -f $ServerAlias, $serverTotal, $SshAlias
$action = 'Delete journey state from both ends'
if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    return
}

# ------------------------------------------------------------- vehicle ---

# The client holds the journal open, and it must not be running while the
# server's rows go either: it would reconnect mid-delete and report facts about
# a demand that is half gone.
Write-Step 'Stopping the onboard stack'
& (Join-Path $PSScriptRoot '10-start-onboard-stack.ps1') -SshAlias $SshAlias -Stop | Out-Null

$vehicleResult = Invoke-Remote $SshAlias @"
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath '$VehicleJournal')) { '(no journal to reset)'; return }
`$dest = '$VehicleBackupRoot-$stamp'
New-Item -ItemType Directory -Path `$dest -Force | Out-Null
Get-ChildItem (Split-Path -Parent '$VehicleJournal') -Filter 'onboard-journal.db*' |
    ForEach-Object { Copy-Item `$_.FullName -Destination `$dest -Force }
Get-ChildItem (Split-Path -Parent '$VehicleJournal') -Filter 'onboard-journal.db*' |
    ForEach-Object { Remove-Item `$_.FullName -Force }
"backed up to `$dest and removed; the client recreates it empty on next start"
"@
Write-Step "Journal: $vehicleResult"

# -------------------------------------------------------------- server ---

if ($serverTotal -gt 0) {
    $deleteScript = @"
`$ErrorActionPreference = 'Stop'
Stop-Service -Name '8005 AGV ControlServer' -Force
`$dest = '$ServerBackupRoot\db-backup-$stamp'
New-Item -ItemType Directory -Path `$dest -Force | Out-Null
foreach (`$suffix in '', '-wal', '-shm') {
    `$p = '$ServerDatabase' + `$suffix
    if (Test-Path -LiteralPath `$p) { Copy-Item -LiteralPath `$p -Destination `$dest -Force }
}
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase')
`$c.Open()
`$tx = `$c.BeginTransaction()
`$total = 0
$(($survey.plan | ForEach-Object {
    "`$m = `$c.CreateCommand(); `$m.Transaction = `$tx; `$m.CommandText = `"DELETE FROM [$($_.table)] WHERE $($_.where -replace '"', '`"')`"; `$n = `$m.ExecuteNonQuery(); `$total += `$n; `"  $($_.table) -> `$n`""
}) -join "`n")
if (`$total -ne $serverTotal) { `$tx.Rollback(); `$c.Close(); throw "expected $serverTotal rows, deleted `$total -- rolled back" }
`$tx.Commit()
`$c.Close()
"  committed `$total rows; backup at `$dest"
Start-Service -Name '8005 AGV ControlServer'
"@
    $deleted = Invoke-Remote $ServerAlias $deleteScript
    $deleted -split "`r?`n" | ForEach-Object { if ($_.Trim()) { Write-Step $_.Trim() } }
} else {
    Write-Step 'Server: nothing to delete'
}

# ------------------------------------------------------------- restart ---

if ($KeepStackDown) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Both ends cleared. Onboard stack left down (-KeepStackDown)." -ForegroundColor Green
    return
}

Write-Step 'Restarting the onboard stack'
& (Join-Path $PSScriptRoot '10-start-onboard-stack.ps1') -SshAlias $SshAlias | Out-Null

# A clean pair should reach Ready on its own. If it does not, say so here rather
# than letting the next run discover it.
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
$readiness = $null
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $readiness = Invoke-Remote $ServerAlias @"
`$dll = (Get-ChildItem '$ServerInstallRoot' -Filter 'Microsoft.Data.Sqlite.dll' -Recurse | Select-Object -First 1).FullName
Add-Type -Path `$dll
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly')
`$c.Open()
`$m = `$c.CreateCommand(); `$m.CommandText = 'SELECT Readiness || '' / '' || ReasonCode FROM SessionRecoveries'
`$v = `$m.ExecuteScalar()
`$c.Close()
if (`$v) { `$v } else { '(no session yet)' }
"@
    if ($readiness -like 'Ready*') { break }
    Start-Sleep -Seconds 3
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Session: $readiness" -ForegroundColor Green
if ($readiness -notlike 'Ready*') {
    Write-Host "  Not Ready within ${ReadyTimeoutSeconds}s. Check the onboard log before running anything else." -ForegroundColor Yellow
}
