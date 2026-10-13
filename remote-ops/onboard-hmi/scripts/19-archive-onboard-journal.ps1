#Requires -Version 7
<#
.SYNOPSIS
    Checks one vehicle's onboard journal (which is also its outbox) read-only, refuses when it still owes its server
    anything or carries a load, and otherwise renames the whole journal directory aside, keeping it. Runs on the
    control host.

.DESCRIPTION
    program#170 section 3, control-server#565. The onboard client keeps its journal and its durable outbox in one
    SQLite file, %LOCALAPPDATA%\SQCD\8005AGV\onboard-journal.db under the vehicle's interactive user -- not in the
    install root C:\8005\OnboardHmi. The journal is bound to one server database: a client that reconnects to a
    new database with the old journal rejects the new plan snapshots (SNAPSHOT_REVISION_CONTENT_CONFLICT, 2026-10-09),
    and an unacknowledged outbox row sent to a server that does not know it is acknowledged as history and dropped
    (cs#481), so the server that owned it never receives it. The agv01 field line and the v2 onboard use the same path
    and the same four tables, so this applies to all three cars.

    What it does, in this order:

      1. Refuses unless the onboard client and the simulator are both stopped (10-start-onboard-stack.ps1 -Stop).
      2. Copies onboard-journal.db and its -wal/-shm to -EvidencePath and reads the COPY on the control host:
           pending  = WireToGateDurableOutbox rows with Acknowledged = 0 and AbandonedReasonCode IS NULL
           loads    = loadsOnBoard in WireToGateRecoveryState.ContentJson (absent or null counts as empty; the field
                      line's journal has no such field)
         plus the outbox grouped by state, pendingResults, the journal epoch and the applied snapshot revisions, all
         written to <EvidencePath>/journal-check.json.
      3. Refuses (exit 1, nothing renamed) when pending > 0 or loadsOnBoard is not empty. The fix is to let the client
         reconnect to the server that owns those rows and drain, not to archive them.
      4. With -CheckOnly, stops here. Otherwise renames the journal directory to <dir>.<Suffix> on the vehicle and reads
         the parent directory back.

    Nothing is deleted. Undo: Rename-Item <dir>.<Suffix> <dir> on the vehicle, with the client stopped.

    The workspace's "Ask first" rules decide whether a run needs the user's answer, not this script: on agv01 every run,
    -CheckOnly included, touches agv01 and needs it. -SshAlias has no default for that reason.

.PARAMETER SshAlias
    agv01, agv02 or agv03. No default.

.PARAMETER Suffix
    Appended to the directory name, e.g. pre-cutover-trial-20261013. Letters, digits, dot and dash only. The target
    must not exist yet.

.PARAMETER EvidencePath
    Local directory for the journal copy and journal-check.json. Created if missing; must be empty if it exists, so
    a second run never mixes its copy with the first one's.

.PARAMETER CheckOnly
    Copy, read and judge; rename nothing.

.PARAMETER SelfTest
    Offline: builds journals with python's sqlite3 in a temporary directory and runs the reader and the verdict over
    them. No ssh.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1 -SshAlias agv02 -Suffix pre-cutover-trial-20261013 -EvidencePath evidence/field/20261013-W3-S0-agv02/journal -CheckOnly

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1 -SelfTest
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidateSet('agv01', 'agv02', 'agv03')][string] $SshAlias,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,63}$')][string] $Suffix,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string] $EvidencePath,
    [Parameter(ParameterSetName = 'Run')][string] $JournalDirectory = 'C:\Users\HT\AppData\Local\SQCD\8005AGV',
    [Parameter(ParameterSetName = 'Run')][switch] $CheckOnly,
    [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$JournalFiles = @('onboard-journal.db', 'onboard-journal.db-wal', 'onboard-journal.db-shm')

# Reads a local COPY of the journal. Plain read-write open on purpose: a copy's -wal is only folded in that way, and
# the copy is ours. Prints one JSON object.
$ReaderPython = @'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
def rows(sql):
    return [list(r) for r in c.execute(sql).fetchall()]
tables = {r[0] for r in c.execute("select name from sqlite_master where type='table'")}
out = {"tables": sorted(tables)}
if "WireToGateDurableOutbox" in tables:
    out["pending"] = c.execute("select count(*) from WireToGateDurableOutbox where Acknowledged = 0 and AbandonedReasonCode is null").fetchone()[0]
    out["outboxByState"] = rows("select Acknowledged, AbandonedReasonCode, MessageType, count(*), max(CreatedAt) from WireToGateDurableOutbox group by 1, 2, 3 order by 1, 2, 3")
    out["pendingRows"] = rows("select MessageType, MessageId, CreatedAt from WireToGateDurableOutbox where Acknowledged = 0 and AbandonedReasonCode is null order by CreatedAt")
else:
    out["pending"] = None
state = None
if "WireToGateRecoveryState" in tables:
    r = c.execute("select ContentJson, UpdatedAt from WireToGateRecoveryState where Id = 1").fetchone()
    if r is not None:
        state = json.loads(r[0])
        out["recoveryStateUpdatedAt"] = r[1]
loads = None
if isinstance(state, dict):
    for k, v in state.items():
        if k.lower() == "loadsonboard":
            loads = v
    for k, v in state.items():
        if k.lower() == "pendingresults":
            out["pendingResultsCount"] = len(v) if isinstance(v, list) else None
out["recoveryStatePresent"] = state is not None
out["loadsOnBoard"] = loads
if "WireToGateJournalMetadata" in tables:
    r = c.execute("select JournalEpoch from WireToGateJournalMetadata where Id = 1").fetchone()
    out["journalEpoch"] = r[0] if r else None
if "WireToGateAppliedJourneySnapshots" in tables:
    out["appliedSnapshots"] = rows("select MessageType, Revision, AppliedAt from WireToGateAppliedJourneySnapshots order by 1")
print(json.dumps(out, ensure_ascii=False))
'@

function Read-JournalCopy {
    param([Parameter(Mandatory)][string] $DatabasePath)
    $json = & python -I -c $ReaderPython $DatabasePath
    if ($LASTEXITCODE -ne 0) { throw "JOURNAL_UNREADABLE: python could not read $DatabasePath (exit $LASTEXITCODE)." }
    return ($json | Out-String | ConvertFrom-Json -AsHashtable)
}

function Get-JournalArchiveRefusal {
    <#
        Pure. Why this journal must not be archived yet; empty when it may be. A journal with no outbox table is
        refused too: that is not the file this script was written for, and guessing it is empty would be the one way
        to lose a result.
    #>
    param([Parameter(Mandatory)][hashtable] $Reading)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Reading['pending']) {
        $reasons.Add('JOURNAL_NO_OUTBOX_TABLE: no WireToGateDurableOutbox table; not an onboard journal this script knows.')
    } elseif ([int] $Reading['pending'] -gt 0) {
        $reasons.Add("JOURNAL_OUTBOX_PENDING: $($Reading['pending']) unacknowledged outbox row(s). Start the stack against the server that owns them, let it drain, stop it and run again.")
    }
    $loads = $Reading['loadsOnBoard']
    if ($null -ne $loads -and @($loads).Count -gt 0) {
        $reasons.Add("JOURNAL_LOADS_ON_BOARD: loadsOnBoard has $(@($loads).Count) entr$(@($loads).Count -eq 1 ? 'y' : 'ies'); the vehicle believes it carries cargo. Settle that with its server first.")
    }
    return $reasons.ToArray()
}

function Invoke-SelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("journal-selftest-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $builder = @'
import json, sqlite3, sys
path, pending, loads, field_line = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4] == "1"
c = sqlite3.connect(path)
c.executescript("""
CREATE TABLE WireToGateJournalMetadata (Id INTEGER NOT NULL PRIMARY KEY CHECK (Id = 1), JournalEpoch TEXT NOT NULL UNIQUE);
CREATE TABLE WireToGateRecoveryState (Id INTEGER NOT NULL PRIMARY KEY CHECK (Id = 1), ContentJson TEXT NOT NULL, UpdatedAt TEXT NOT NULL);
CREATE TABLE WireToGateDurableOutbox (DeduplicationKey TEXT NOT NULL PRIMARY KEY, MessageType TEXT NOT NULL, MessageId TEXT NOT NULL UNIQUE,
  ContentSha256 TEXT NOT NULL, WireLine TEXT NOT NULL, CreatedAt TEXT NOT NULL, Acknowledged INTEGER NOT NULL CHECK (Acknowledged IN (0, 1)), AbandonedReasonCode TEXT NULL);
CREATE TABLE WireToGateAppliedJourneySnapshots (MessageType TEXT NOT NULL PRIMARY KEY, MessageId TEXT NOT NULL, Revision INTEGER NOT NULL, AppliedAt TEXT NOT NULL);
""")
c.execute("insert into WireToGateJournalMetadata values (1, 'epoch-1')")
n = 0
def add(ack, abandoned):
    global n
    n += 1
    c.execute("insert into WireToGateDurableOutbox values (?, 'OperationResult', ?, 'x', '{}', '2026-10-13T00:00:00Z', ?, ?)", (f"k{n}", f"m{n}", ack, abandoned))
for _ in range(3): add(1, None)
add(0, "SUPERSEDED")
for _ in range(pending): add(0, None)
state = {"pendingResults": []}
if not field_line:
    state["loadsOnBoard"] = None if loads == "null" else json.loads(loads)
c.execute("insert into WireToGateRecoveryState values (1, ?, '2026-10-13T00:00:00Z')", (json.dumps(state),))
c.commit()
'@
    $cases = @(
        @{ Name = 'clean v2 journal, loadsOnBoard null'; Pending = 0; Loads = 'null'; Field = '0'; Expect = @() }
        @{ Name = 'clean v2 journal, loadsOnBoard []'; Pending = 0; Loads = '[]'; Field = '0'; Expect = @() }
        @{ Name = 'field-line journal without loadsOnBoard'; Pending = 0; Loads = 'null'; Field = '1'; Expect = @() }
        @{ Name = 'one pending row (abandoned and acknowledged rows do not count)'; Pending = 1; Loads = 'null'; Field = '0'; Expect = @('JOURNAL_OUTBOX_PENDING') }
        @{ Name = 'cargo on board'; Pending = 0; Loads = '[{"load":{"slots":[1]}}]'; Field = '0'; Expect = @('JOURNAL_LOADS_ON_BOARD') }
        @{ Name = 'both'; Pending = 2; Loads = '[{"load":{"slots":[1]}},{"load":{"slots":[2]}}]'; Field = '0'; Expect = @('JOURNAL_OUTBOX_PENDING', 'JOURNAL_LOADS_ON_BOARD') }
    )
    $failed = 0
    try {
        $i = 0
        foreach ($case in $cases) {
            $i++
            $db = Join-Path $root "case$i.db"
            & python -I -c $builder $db $case.Pending $case.Loads $case.Field
            if ($LASTEXITCODE -ne 0) { throw "building $db failed" }
            $reading = Read-JournalCopy -DatabasePath $db
            $codes = @(Get-JournalArchiveRefusal -Reading $reading | ForEach-Object { ($_ -split ':')[0] })
            $ok = ($codes -join ',') -ceq ($case.Expect -join ',') -and [int] $reading['pending'] -eq $case.Pending -and $reading['journalEpoch'] -ceq 'epoch-1'
            Write-Host ("{0} {1} -> [{2}] pending={3}" -f ($ok ? 'PASS' : 'FAIL'), $case.Name, ($codes -join ','), $reading['pending'])
            if (-not $ok) { $failed++ }
        }
        # A file that is not a journal is refused rather than read as empty.
        $other = Join-Path $root 'other.db'
        & python -I -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table T (x)'); c.commit()" $other
        $codes = @(Get-JournalArchiveRefusal -Reading (Read-JournalCopy -DatabasePath $other) | ForEach-Object { ($_ -split ':')[0] })
        $ok = ($codes -join ',') -ceq 'JOURNAL_NO_OUTBOX_TABLE'
        Write-Host ("{0} not a journal -> [{1}]" -f ($ok ? 'PASS' : 'FAIL'), ($codes -join ','))
        if (-not $ok) { $failed++ }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($failed) { Write-Host "SELFTEST FAILED ($failed)"; exit 1 }
    Write-Host "SELFTEST PASS ($($cases.Count + 1) cases)"
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

function Invoke-Vehicle {
    param([Parameter(Mandatory)][string] $Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $output = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -NonInteractive -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed (exit $LASTEXITCODE): $($output -join ' ')" }
    return $output
}

if (Test-Path -LiteralPath $EvidencePath) {
    if (@(Get-ChildItem -LiteralPath $EvidencePath -Force).Count -gt 0) {
        throw "EVIDENCE_NOT_EMPTY: $EvidencePath already has files; give each run its own directory."
    }
} else {
    New-Item -ItemType Directory -Path $EvidencePath | Out-Null
}
$EvidencePath = (Resolve-Path -LiteralPath $EvidencePath).Path
$target = "$JournalDirectory.$Suffix"
$started = Get-Date -Format o
Write-Host "[$SshAlias] journal $JournalDirectory -> $(Split-Path -Leaf $target)$($CheckOnly ? ' (check only)' : '')"

# 1. Stopped, present, target free. Read-only.
$probe = Invoke-Vehicle @"
`$procs = @(Get-Process -Name 'SQCD*' -ErrorAction SilentlyContinue | ForEach-Object { `$_.Name + ':' + `$_.Id })
`$files = @(foreach (`$n in '$($JournalFiles -join "','")') { `$p = Join-Path '$JournalDirectory' `$n; if (Test-Path -LiteralPath `$p) { `$n } })
[pscustomobject]@{ processes = `$procs; directory = (Test-Path -LiteralPath '$JournalDirectory'); files = `$files; targetExists = (Test-Path -LiteralPath '$target') } | ConvertTo-Json -Compress
"@
$state = ($probe | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
if (@($state['processes']).Count -gt 0) {
    throw "CLIENT_RUNNING: $($state['processes'] -join ', ') on $SshAlias. Stop the stack first: 10-start-onboard-stack.ps1 -SshAlias $SshAlias -Stop."
}
if (-not $state['directory']) { throw "JOURNAL_DIRECTORY_MISSING: $JournalDirectory does not exist on $SshAlias; nothing to check or archive." }
if ($state['targetExists']) { throw "ARCHIVE_TARGET_EXISTS: $target already exists on $SshAlias; choose another -Suffix." }
if (@($state['files']) -notcontains 'onboard-journal.db') { throw "JOURNAL_FILE_MISSING: $JournalDirectory has no onboard-journal.db on $SshAlias." }

# 2. Copy and read the copy.
foreach ($name in @($state['files'])) {
    & scp -q "${SshAlias}:$(($JournalDirectory -replace '\\', '/'))/$name" (Join-Path $EvidencePath $name)
    if ($LASTEXITCODE -ne 0) { throw "scp of $name from $SshAlias failed (exit $LASTEXITCODE)." }
}
$reading = Read-JournalCopy -DatabasePath (Join-Path $EvidencePath 'onboard-journal.db')
$refusal = @(Get-JournalArchiveRefusal -Reading $reading)
$record = [ordered]@{
    vehicle = $SshAlias; startedAt = $started; journalDirectory = $JournalDirectory; archiveTo = $target
    checkOnly = [bool] $CheckOnly; copiedFiles = @($state['files']); reading = $reading; refusal = $refusal; renamed = $false
}
$write = { $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidencePath 'journal-check.json') }
& $write
Write-Host "  pending=$($reading['pending']) loadsOnBoard=$(($null -eq $reading['loadsOnBoard']) ? 'null' : @($reading['loadsOnBoard']).Count) epoch=$($reading['journalEpoch'])"
foreach ($row in @($reading['outboxByState'])) { Write-Host "  outbox $($row -join ' | ')" }

# 3. Verdict.
if ($refusal.Count -gt 0) {
    $refusal | ForEach-Object { Write-Host "  REFUSED $_" -ForegroundColor Red }
    Write-Host "  Nothing was renamed. Evidence: $EvidencePath"
    exit 1
}
if ($CheckOnly) { Write-Host "  CHECK OK: may be archived. Nothing was renamed (-CheckOnly). Evidence: $EvidencePath"; exit 0 }

# 4. Rename and read back. The process check is repeated: the stack may have been started since step 1.
$after = Invoke-Vehicle @"
if (Get-Process -Name 'SQCD*' -ErrorAction SilentlyContinue) { throw 'CLIENT_RUNNING: the stack was started after the check; nothing renamed.' }
Rename-Item -LiteralPath '$JournalDirectory' -NewName '$(Split-Path -Leaf $target)'
Get-ChildItem -LiteralPath '$(Split-Path -Parent $JournalDirectory)' -Force | ForEach-Object { `$_.Name + ' ' + `$_.LastWriteTime.ToString('o') }
"@
$record['renamed'] = $true
$record['afterListing'] = @($after)
& $write
$after | ForEach-Object { Write-Host "  $_" }
if ((@($after) -join "`n") -notmatch [regex]::Escape((Split-Path -Leaf $target))) { throw "ARCHIVE_NOT_VISIBLE: $target is not in the listing after the rename." }
Write-Host "  ARCHIVED to $target. Undo with the client stopped: Rename-Item '$target' '$(Split-Path -Leaf $JournalDirectory)'. Evidence: $EvidencePath"
exit 0
