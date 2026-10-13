#Requires -Version 7
<#
.SYNOPSIS
    Checks one vehicle's onboard journal (which is also its outbox) read-only, refuses when it still owes its server
    anything, may carry a load or has a slot unlocked, and otherwise renames the whole journal directory aside,
    keeping it. Runs on the control host.

.DESCRIPTION
    program#170 section 3, control-server#565. The onboard client keeps its journal and its durable outbox in one
    SQLite file, by default %LOCALAPPDATA%\SQCD\8005AGV\onboard-journal.db under the vehicle's interactive user (HT) --
    not in the install root C:\8005\OnboardHmi. The journal is bound to one server database: a client that reconnects
    to a new database with the old journal rejects the new plan snapshots (SNAPSHOT_REVISION_CONTENT_CONFLICT,
    2026-10-09), and an unacknowledged outbox row sent to a server that does not know it is acknowledged as history and
    dropped (cs#481), so the server that owned it never receives it.

    The two lines' journals are NOT the same shape (PR #42 review M1, M2):
      * the agv01 field line (w2g/field-agv01-6b8a0b0, eec9364) has no WireToGateDurableOutbox.AbandonedReasonCode
        column -- the v2 line adds it -- so "pending" is Acknowledged = 0 there, and Acknowledged = 0 AND
        AbandonedReasonCode IS NULL on the v2 line. The column is detected, not assumed;
      * the field line has no loadsOnBoard in its recovery state, and keeps lastCompletedLoadOperationContext after an
        unload, so its journal cannot say "no cargo". On the v2 line loadsOnBoard = null means "written before the
        field existed", and the client then falls back to lastCompletedLoadOperationContext. Both cases are
        JOURNAL_LOADS_UNKNOWN and refused unless -ConfirmNoCargo names where the "no cargo" fact comes from.

    What it does, in this order:

      1. Reads wireToGate.journalPath from the installed appsettings.json on the vehicle (%LOCALAPPDATA% means the
         interactive user's, -InteractiveLocalAppData), the default path when the key is absent. Refuses unless the
         onboard client and the simulator are both stopped (10-start-onboard-stack.ps1 -Stop).
      2. Copies the journal and its -wal/-shm to <EvidencePath>, records their SHA-256, and reads a SECOND copy under
         <EvidencePath>/read (reading folds the WAL in, so the first copy stays byte-identical to the vehicle's files).
      3. Judges (Get-JournalArchiveRefusal, pure) and writes <EvidencePath>/journal-check.json either way:
           JOURNAL_NO_OUTBOX_TABLE    not a journal this script knows
           JOURNAL_OUTBOX_PENDING     unacknowledged rows (all of them are copied, WireLine included, into the evidence)
           JOURNAL_LOADS_ON_BOARD     loadsOnBoard lists cargo -- no switch overrides this
           JOURNAL_LOADS_UNKNOWN      the journal cannot say "no cargo" (above); -ConfirmNoCargo '<source>' accepts it
           JOURNAL_UNLOCK_ACTIVE      activeUnlockSlots is not empty -- no switch overrides this
           U6_*                       see -ArchivePendingPerU6
      4. With -CheckOnly, stops here. Otherwise, on the vehicle and with $ErrorActionPreference = 'Stop': the client
         must still be stopped, the files' SHA-256 must equal the copied ones, the target must not exist; then the
         directory is renamed and the parent listed back. renamed = true is written only after the listing shows it.

    Nothing is deleted. Undo: Rename-Item <dir>.<Suffix> <dir> on the vehicle, with the client stopped.

    The workspace's "Ask first" rules decide whether a run needs the user's answer, not this script: on agv01 every run,
    -CheckOnly included, touches agv01. -SshAlias has no default for that reason.

.PARAMETER SshAlias
    agv01, agv02 or agv03. No default.

.PARAMETER Suffix
    Appended to the directory name, e.g. pre-cutover-trial-20261013. Letters, digits, dot and dash only.

.PARAMETER EvidencePath
    Local directory for the copies and journal-check.json. Created if missing; must be empty if it exists.

.PARAMETER CheckOnly
    Copy, read and judge; rename nothing.

.PARAMETER ConfirmNoCargo
    Where the "this vehicle carries no cargo" fact comes from when the journal cannot tell (JOURNAL_LOADS_UNKNOWN),
    e.g. the MVP database reading or an on-site visual check with who and when. Recorded verbatim in the evidence. It
    does not override a non-empty loadsOnBoard.

.PARAMETER ArchivePendingPerU6
    agv03 only (program#170 U6, user decision 2026-10-13): archive although rows are pending, because they belong to
    the 10-11 two-car experiment against the fake MesIngest and are not to be delivered. Every pending row must have
    CreatedAt at or before -PendingCutoff, and every demandId found anywhere in its WireLine must match
    -FakeDemandIdPattern; a row of a type other than SafetyStateChanged or RecoveryStateReport that names no demandId
    cannot be checked and is refused. Any failure refuses; ask the user then.

.PARAMETER PendingCutoff
    With -ArchivePendingPerU6: the end of the fake-MES experiment, e.g. 2026-10-11T23:59:59+08:00.

.PARAMETER FakeDemandIdPattern
    With -ArchivePendingPerU6: a regular expression every demandId must match, derived from the fake MesIngest seed
    (D:\zhengyushao\control-server-v2-ops\fake-mes-ingest-seed.json and its backups), e.g. '^c1000566-'.

.PARAMETER SelfTest
    Offline: builds journals with python's sqlite3 (v2 and the field line's verbatim DDL) and runs the reader and the
    verdict over them. No ssh.

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
    [Parameter(ParameterSetName = 'Run')][string] $InstallRoot = 'C:\8005\OnboardHmi',
    [Parameter(ParameterSetName = 'Run')][string] $InteractiveLocalAppData = 'C:\Users\HT\AppData\Local',
    [Parameter(ParameterSetName = 'Run')][switch] $CheckOnly,
    [Parameter(ParameterSetName = 'Run')][string] $ConfirmNoCargo,
    [Parameter(ParameterSetName = 'Run')][switch] $ArchivePendingPerU6,
    [Parameter(ParameterSetName = 'Run')][Nullable[DateTimeOffset]] $PendingCutoff,
    [Parameter(ParameterSetName = 'Run')][string] $FakeDemandIdPattern,
    [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$DefaultJournalPath = '%LOCALAPPDATA%\SQCD\8005AGV\onboard-journal.db'
# Pending rows of these types carry no demand; every other type must name one for -ArchivePendingPerU6 to check it.
$DemandFreeMessageTypes = @('SafetyStateChanged', 'RecoveryStateReport')

# Reads a local copy of the journal and prints one JSON object. Plain read-write open: it is our copy.
$ReaderPython = @'
import json, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
def rows(sql):
    return [list(r) for r in c.execute(sql).fetchall()]
def columns(table):
    return [r[1] for r in c.execute("select * from pragma_table_info(?)", (table,)).fetchall()]
def demand_ids(node, found):
    if isinstance(node, dict):
        for k, v in node.items():
            if k.lower() == "demandid" and isinstance(v, str):
                found.append(v)
            demand_ids(v, found)
    elif isinstance(node, list):
        for v in node:
            demand_ids(v, found)
    return found
tables = {r[0] for r in c.execute("select name from sqlite_master where type='table'")}
out = {"tables": sorted(tables)}
if "WireToGateDurableOutbox" in tables:
    has_abandoned = "AbandonedReasonCode" in columns("WireToGateDurableOutbox")
    out["outboxHasAbandonedReasonCode"] = has_abandoned
    pending_where = "Acknowledged = 0" + (" and AbandonedReasonCode is null" if has_abandoned else "")
    out["pending"] = c.execute("select count(*) from WireToGateDurableOutbox where " + pending_where).fetchone()[0]
    out["outboxByState"] = rows("select Acknowledged, " + ("AbandonedReasonCode" if has_abandoned else "null") +
                                ", MessageType, count(*), max(CreatedAt) from WireToGateDurableOutbox group by 1, 2, 3 order by 1, 2, 3")
    pending_rows = []
    for message_type, message_id, created_at, wire_line in c.execute(
            "select MessageType, MessageId, CreatedAt, WireLine from WireToGateDurableOutbox where " + pending_where + " order by CreatedAt"):
        row = {"messageType": message_type, "messageId": message_id, "createdAt": created_at, "wireLine": wire_line}
        try:
            row["demandIds"] = sorted(set(demand_ids(json.loads(wire_line), [])))
        except ValueError as e:
            row["demandIds"] = None
            row["wireLineError"] = str(e)
        pending_rows.append(row)
    out["pendingRows"] = pending_rows
else:
    out["pending"] = None
state = None
if "WireToGateRecoveryState" in tables:
    r = c.execute("select ContentJson, UpdatedAt from WireToGateRecoveryState where Id = 1").fetchone()
    if r is not None:
        state = json.loads(r[0])
        out["recoveryStateUpdatedAt"] = r[1]
out["recoveryStatePresent"] = state is not None
wanted = {"loadsonboard": "loadsOnBoard", "lastcompletedloadoperationcontext": "lastCompletedLoadOperationContext",
          "unsettledslotoperationattemptid": "unsettledSlotOperationAttemptId", "activeunlockslots": "activeUnlockSlots",
          "recoveryvector": "recoveryVector", "pendingloadcancellation": "pendingLoadCancellation"}
out["loadsOnBoardPresent"] = False
for name in wanted.values():
    out[name] = None
if isinstance(state, dict):
    for k, v in state.items():
        key = wanted.get(k.lower())
        if key:
            out[key] = v
            if key == "loadsOnBoard":
                out["loadsOnBoardPresent"] = True
        if k.lower() == "pendingresults":
            out["pendingResultsCount"] = len(v) if isinstance(v, list) else None
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
    return ($json | Out-String | ConvertFrom-Json -AsHashtable -DateKind String)
}

function Get-JournalArchiveRefusal {
    <#
        Pure. Why this journal must not be archived yet; nothing when it may be. Each entry starts with its code.
    #>
    param(
        [Parameter(Mandatory)][hashtable] $Reading,
        [Parameter(Mandatory)][string] $Alias,
        [string] $ConfirmNoCargo,
        [switch] $ArchivePendingPerU6,
        [Nullable[DateTimeOffset]] $PendingCutoff,
        [string] $FakeDemandIdPattern
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $count = { param($v) ($null -eq $v) ? 0 : @($v).Count }

    if ($null -eq $Reading['pending']) {
        $reasons.Add('JOURNAL_NO_OUTBOX_TABLE: no WireToGateDurableOutbox table; not an onboard journal this script knows.')
    } elseif ([int] $Reading['pending'] -gt 0) {
        if (-not $ArchivePendingPerU6) {
            $reasons.Add("JOURNAL_OUTBOX_PENDING: $($Reading['pending']) unacknowledged outbox row(s), copied into the evidence. Start the stack against the server that owns them, let it drain, stop it and run again.")
        } elseif ($Alias -cne 'agv03') {
            $reasons.Add("U6_NOT_ALLOWED: -ArchivePendingPerU6 is program#170 U6 for agv03 only, not $Alias.")
        } elseif ($null -eq $PendingCutoff -or [string]::IsNullOrWhiteSpace($FakeDemandIdPattern)) {
            $reasons.Add('U6_ARGUMENTS_MISSING: -ArchivePendingPerU6 needs -PendingCutoff and -FakeDemandIdPattern.')
        } else {
            foreach ($row in @($Reading['pendingRows'])) {
                $label = "$($row['messageType']) $($row['messageId'])"
                $created = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse([string] $row['createdAt'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $created)) {
                    $reasons.Add("U6_CREATED_AT_UNREADABLE: $label has CreatedAt '$($row['createdAt'])'.")
                } elseif ($created -gt $PendingCutoff) {
                    $reasons.Add("U6_PENDING_AFTER_CUTOFF: $label was created $($row['createdAt']), after $($PendingCutoff.ToString("o")).")
                }
                $ids = $row['demandIds']
                if ($null -eq $ids) {
                    $reasons.Add("U6_WIRELINE_UNREADABLE: $label WireLine is not JSON; its demand cannot be checked.")
                } elseif (@($ids).Count -eq 0) {
                    if ($DemandFreeMessageTypes -cnotcontains [string] $row['messageType']) {
                        $reasons.Add("U6_DEMAND_UNVERIFIABLE: $label names no demandId; whether it belongs to the fake MesIngest cannot be checked.")
                    }
                } else {
                    foreach ($id in @($ids)) {
                        if ([string] $id -notmatch $FakeDemandIdPattern) {
                            $reasons.Add("U6_DEMAND_NOT_FAKE: $label names demand $id, which does not match '$FakeDemandIdPattern'.")
                        }
                    }
                }
            }
        }
    }

    $loads = $Reading['loadsOnBoard']
    if ((& $count $loads) -gt 0) {
        $reasons.Add("JOURNAL_LOADS_ON_BOARD: loadsOnBoard has $(& $count $loads) entr$((& $count $loads) -eq 1 ? 'y' : 'ies'); the vehicle believes it carries cargo. Settle that with its server first.")
    } elseif ($Reading['recoveryStatePresent']) {
        $unknown = if (-not $Reading['loadsOnBoardPresent']) {
            'the recovery state has no loadsOnBoard field (the agv01 field line never had one)'
        } elseif ($null -eq $loads -and $null -ne $Reading['lastCompletedLoadOperationContext']) {
            'loadsOnBoard is null (written before the field existed) and lastCompletedLoadOperationContext is set'
        }
        if ($unknown -and [string]::IsNullOrWhiteSpace($ConfirmNoCargo)) {
            $reasons.Add("JOURNAL_LOADS_UNKNOWN: $unknown, so this journal cannot say the vehicle is empty. Establish it elsewhere (the server database, or someone looking at the slots) and pass -ConfirmNoCargo '<where that comes from>'.")
        }
    }

    if ((& $count $Reading['activeUnlockSlots']) -gt 0) {
        $reasons.Add("JOURNAL_UNLOCK_ACTIVE: activeUnlockSlots is [$(@($Reading['activeUnlockSlots']) -join ', ')]; a slot operation is open on this vehicle.")
    }
    return $reasons.ToArray()
}

function Invoke-SelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("journal-selftest-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    # The field line's DDL is copied verbatim from w2g/field-agv01-6b8a0b0 (eec9364) SqliteWireToGateJournal.cs; the v2
    # line's outbox has AbandonedReasonCode on top (w2g/fp-v2-impl).
    $builder = @'
import json, sqlite3, sys
path, spec = sys.argv[1], json.loads(sys.argv[2])
field = spec.get("field", False)
c = sqlite3.connect(path)
c.executescript("""
CREATE TABLE IF NOT EXISTS WireToGateJournalMetadata (
    Id INTEGER NOT NULL PRIMARY KEY CHECK (Id = 1),
    JournalEpoch TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS WireToGateRecoveryState (
    Id INTEGER NOT NULL PRIMARY KEY CHECK (Id = 1),
    ContentJson TEXT NOT NULL,
    UpdatedAt TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS WireToGateDurableOutbox (
    DeduplicationKey TEXT NOT NULL PRIMARY KEY,
    MessageType TEXT NOT NULL,
    MessageId TEXT NOT NULL UNIQUE,
    ContentSha256 TEXT NOT NULL,
    WireLine TEXT NOT NULL,
    CreatedAt TEXT NOT NULL,
    Acknowledged INTEGER NOT NULL CHECK (Acknowledged IN (0, 1))
);
CREATE TABLE IF NOT EXISTS WireToGateAppliedJourneySnapshots (
    MessageType TEXT NOT NULL PRIMARY KEY,
    MessageId TEXT NOT NULL,
    Revision INTEGER NOT NULL CHECK (Revision >= 0),
    ContentSha256 TEXT NOT NULL,
    PayloadJson TEXT NOT NULL,
    AppliedAt TEXT NOT NULL
);
""")
if not field:
    c.execute("ALTER TABLE WireToGateDurableOutbox ADD COLUMN AbandonedReasonCode TEXT NULL")
c.execute("insert into WireToGateJournalMetadata values (1, 'epoch-1')")
n = 0
def add(ack, abandoned=None, mtype="OperationResult", created="2026-10-11T10:00:00+00:00", payload=None):
    global n
    n += 1
    line = json.dumps(payload if payload is not None else {"messageType": mtype})
    if field:
        c.execute("insert into WireToGateDurableOutbox values (?, ?, ?, 'x', ?, ?, ?)", (f"k{n}", mtype, f"m{n}", line, created, ack))
    else:
        c.execute("insert into WireToGateDurableOutbox values (?, ?, ?, 'x', ?, ?, ?, ?)", (f"k{n}", mtype, f"m{n}", line, created, ack, abandoned))
for _ in range(3): add(1)
if not field: add(0, "SUPERSEDED")
for p in spec.get("pending", []):
    add(0, None, p.get("type", "OperationResult"), p.get("created", "2026-10-11T10:00:00+00:00"), p.get("payload"))
state = {"unsettledSlotOperationAttemptId": None, "activeUnlockSlots": spec.get("unlock", []), "pendingResults": []}
if "loads" in spec:
    state["loadsOnBoard"] = spec["loads"]
if spec.get("lastLoad"):
    state["lastCompletedLoadOperationContext"] = {"slots": [1]}
if spec.get("state", True):
    c.execute("insert into WireToGateRecoveryState values (1, ?, '2026-10-13T00:00:00Z')", (json.dumps(state),))
c.commit()
'@
    $fake = @{ type = 'OperationResult'; payload = @{ payload = @{ demandId = 'c1000566-0000-0000-0000-000000000003' } } }
    $u6 = @{ ArchivePendingPerU6 = $true; PendingCutoff = [DateTimeOffset]'2026-10-11T23:59:59+08:00'; FakeDemandIdPattern = '^c1000566-' }
    $cases = @(
        @{ Name = 'v2, loadsOnBoard []'; Spec = @{ loads = @() }; Expect = @() }
        @{ Name = 'v2, loadsOnBoard null, no last load'; Spec = @{ loads = $null }; Expect = @() }
        @{ Name = 'v2, no recovery state row'; Spec = @{ state = $false }; Expect = @() }
        @{ Name = 'v2, loadsOnBoard null + last load'; Spec = @{ loads = $null; lastLoad = $true }; Expect = @('JOURNAL_LOADS_UNKNOWN') }
        @{ Name = 'v2, loadsOnBoard null + last load, -ConfirmNoCargo'; Spec = @{ loads = $null; lastLoad = $true }; Args = @{ ConfirmNoCargo = 'MVP db read 12:30' }; Expect = @() }
        @{ Name = 'v2, one pending (acknowledged and abandoned rows do not count)'; Spec = @{ loads = @(); pending = @(@{}) }; Expect = @('JOURNAL_OUTBOX_PENDING') }
        @{ Name = 'v2, cargo on board even with -ConfirmNoCargo'; Spec = @{ loads = @(@{ load = @{ slots = @(1) } }) }; Args = @{ ConfirmNoCargo = 'x' }; Expect = @('JOURNAL_LOADS_ON_BOARD') }
        @{ Name = 'v2, slot unlocked'; Spec = @{ loads = @(); unlock = @(3) }; Expect = @('JOURNAL_UNLOCK_ACTIVE') }
        @{ Name = 'field line (eec9364 DDL), clean'; Spec = @{ field = $true; lastLoad = $true }; Expect = @('JOURNAL_LOADS_UNKNOWN') }
        @{ Name = 'field line, clean, -ConfirmNoCargo'; Spec = @{ field = $true; lastLoad = $true }; Args = @{ ConfirmNoCargo = 'MVP db read 12:30' }; Expect = @() }
        @{ Name = 'field line, one pending (no AbandonedReasonCode column)'; Spec = @{ field = $true; pending = @(@{}) }; Args = @{ ConfirmNoCargo = 'x' }; Expect = @('JOURNAL_OUTBOX_PENDING') }
        @{ Name = 'U6 agv03: fake demand before cutoff, plus a safety row'; Alias = 'agv03'; Spec = @{ loads = @(); pending = @($fake, @{ type = 'SafetyStateChanged' }) }; Args = $u6; Expect = @() }
        @{ Name = 'U6 agv03: created after cutoff'; Alias = 'agv03'; Spec = @{ loads = @(); pending = @(($fake + @{ created = '2026-10-12T05:00:00+00:00' })) }; Args = $u6; Expect = @('U6_PENDING_AFTER_CUTOFF') }
        @{ Name = 'U6 agv03: real-looking demand'; Alias = 'agv03'; Spec = @{ loads = @(); pending = @(@{ payload = @{ demandId = 'D-REAL-1' } }) }; Args = $u6; Expect = @('U6_DEMAND_NOT_FAKE') }
        @{ Name = 'U6 agv03: OperationResult naming no demand'; Alias = 'agv03'; Spec = @{ loads = @(); pending = @(@{}) }; Args = $u6; Expect = @('U6_DEMAND_UNVERIFIABLE') }
        @{ Name = 'U6 on agv02'; Alias = 'agv02'; Spec = @{ loads = @(); pending = @($fake) }; Args = $u6; Expect = @('U6_NOT_ALLOWED') }
        @{ Name = 'U6 without cutoff'; Alias = 'agv03'; Spec = @{ loads = @(); pending = @($fake) }; Args = @{ ArchivePendingPerU6 = $true }; Expect = @('U6_ARGUMENTS_MISSING') }
    )
    $failed = 0
    try {
        $i = 0
        foreach ($case in $cases) {
            $i++
            $db = Join-Path $root "case$i.db"
            & python -I -c $builder $db ($case.Spec | ConvertTo-Json -Depth 8 -Compress)
            if ($LASTEXITCODE -ne 0) { throw "building $db failed" }
            $reading = Read-JournalCopy -DatabasePath $db
            $extra = $case['Args'] ?? @{}
            $codes = @(Get-JournalArchiveRefusal -Reading $reading -Alias ($case['Alias'] ?? 'agv02') @extra | ForEach-Object { ($_ -split ':')[0] })
            $ok = ($codes -join ',') -ceq ($case.Expect -join ',') -and $reading['journalEpoch'] -ceq 'epoch-1'
            Write-Host ("{0} {1} -> [{2}] pending={3}" -f ($ok ? 'PASS' : 'FAIL'), $case.Name, ($codes -join ','), $reading['pending'])
            if (-not $ok) { $failed++ }
        }
        $other = Join-Path $root 'other.db'
        & python -I -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table T (x)'); c.commit()" $other
        $codes = @(Get-JournalArchiveRefusal -Reading (Read-JournalCopy -DatabasePath $other) -Alias agv02 | ForEach-Object { ($_ -split ':')[0] })
        $ok = ($codes -join ',') -ceq 'JOURNAL_NO_OUTBOX_TABLE'
        Write-Host ("{0} not a journal -> [{1}]" -f ($ok ? 'PASS' : 'FAIL'), ($codes -join ','))
        if (-not $ok) { $failed++ }
        $paths = @(
            @{ In = $null; Want = 'C:\Users\HT\AppData\Local\SQCD\8005AGV\onboard-journal.db' }
            @{ In = '%LOCALAPPDATA%\SQCD\8005AGV\onboard-journal.db'; Want = 'C:\Users\HT\AppData\Local\SQCD\8005AGV\onboard-journal.db' }
            @{ In = 'D:\j\x.db'; Want = 'D:\j\x.db' }
        )
        foreach ($p in $paths) {
            $got = Resolve-JournalPath -Configured $p.In -LocalAppData 'C:\Users\HT\AppData\Local'
            $ok = $got -ceq $p.Want
            Write-Host ("{0} journalPath '{1}' -> {2}" -f ($ok ? 'PASS' : 'FAIL'), $p.In, $got)
            if (-not $ok) { $failed++ }
        }
        $refused = $false
        try { Resolve-JournalPath -Configured '%APPDATA%\x.db' -LocalAppData 'C:\x' | Out-Null } catch { $refused = $_.Exception.Message -like 'JOURNAL_PATH_UNSUPPORTED*' }
        Write-Host ("{0} journalPath with another variable is refused" -f ($refused ? 'PASS' : 'FAIL'))
        if (-not $refused) { $failed++ }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    $total = $cases.Count + 5
    if ($failed) { Write-Host "SELFTEST FAILED ($failed of $total)"; exit 1 }
    Write-Host "SELFTEST PASS ($total cases)"
    exit 0
}

function Resolve-JournalPath {
    <# Pure. The journal file on the vehicle from the installed wireToGate.journalPath (null: the client's default). #>
    param([AllowNull()][string] $Configured, [Parameter(Mandatory)][string] $LocalAppData)
    $path = [string]::IsNullOrWhiteSpace($Configured) ? $DefaultJournalPath : $Configured.Trim()
    $path = $path -ireplace [regex]::Escape('%LOCALAPPDATA%'), $LocalAppData.Replace('$', '$$')
    if ($path -match '%[^%]+%') {
        throw "JOURNAL_PATH_UNSUPPORTED: journalPath '$Configured' uses an environment variable other than %LOCALAPPDATA%; this script will not guess what the client resolves it to."
    }
    if (-not [IO.Path]::IsPathRooted($path)) {
        throw "JOURNAL_PATH_UNSUPPORTED: journalPath '$Configured' is relative; this script will not guess the client's working directory."
    }
    return $path
}

if ($SelfTest) { Invoke-SelfTest }

function Invoke-Vehicle {
    param([Parameter(Mandatory)][string] $Script)
    $full = "`$ErrorActionPreference = 'Stop'`n" + $Script
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    $output = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -NonInteractive -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed (exit $LASTEXITCODE): $($output -join ' ')" }
    return $output
}

if ($ArchivePendingPerU6 -and $SshAlias -cne 'agv03') { throw "U6_NOT_ALLOWED: -ArchivePendingPerU6 is for agv03 only." }
if ($ArchivePendingPerU6 -and $CheckOnly) { throw '-ArchivePendingPerU6 archives; it does not go with -CheckOnly.' }

if (Test-Path -LiteralPath $EvidencePath) {
    if (@(Get-ChildItem -LiteralPath $EvidencePath -Force).Count -gt 0) {
        throw "EVIDENCE_NOT_EMPTY: $EvidencePath already has files; give each run its own directory."
    }
} else {
    New-Item -ItemType Directory -Path $EvidencePath | Out-Null
}
$EvidencePath = (Resolve-Path -LiteralPath $EvidencePath).Path
$started = Get-Date -Format o

# 1. Where the journal is, and that nothing holds it. Read-only.
$configLine = Invoke-Vehicle @"
`$p = Join-Path '$InstallRoot' 'appsettings.json'
`$v = `$null
if (Test-Path -LiteralPath `$p) { `$c = Get-Content -Raw -LiteralPath `$p | ConvertFrom-Json -AsHashtable; `$v = `$c['wireToGate']?['journalPath'] }
'JOURNAL-PATH ' + (@{ value = `$v } | ConvertTo-Json -Compress)
"@
$configured = ((@($configLine) | Where-Object { $_ -like 'JOURNAL-PATH *' } | Select-Object -Last 1) -replace '^JOURNAL-PATH ', '' | ConvertFrom-Json -AsHashtable)['value']
$journalPath = Resolve-JournalPath -Configured $configured -LocalAppData $InteractiveLocalAppData
$journalDirectory = Split-Path -Parent $journalPath
$journalLeaf = Split-Path -Leaf $journalPath
$journalFiles = @($journalLeaf, "$journalLeaf-wal", "$journalLeaf-shm")
$target = "$journalDirectory.$Suffix"
Write-Host "[$SshAlias] journal $journalPath (journalPath in appsettings: $($configured ?? '(absent, client default)')) -> $(Split-Path -Leaf $target)$($CheckOnly ? ' (check only)' : '')"

$probe = Invoke-Vehicle @"
`$procs = @(Get-Process -Name 'SQCD*' -ErrorAction SilentlyContinue | ForEach-Object { `$_.Name + ':' + `$_.Id })
`$files = @(foreach (`$n in '$($journalFiles -join "','")') { if (Test-Path -LiteralPath (Join-Path '$journalDirectory' `$n)) { `$n } })
'PROBE ' + ([pscustomobject]@{ processes = `$procs; directory = (Test-Path -LiteralPath '$journalDirectory'); files = `$files; targetExists = (Test-Path -LiteralPath '$target') } | ConvertTo-Json -Compress)
"@
$state = ((@($probe) | Where-Object { $_ -like 'PROBE *' } | Select-Object -Last 1) -replace '^PROBE ', '') | ConvertFrom-Json -AsHashtable
if (@($state['processes']).Count -gt 0) {
    throw "CLIENT_RUNNING: $($state['processes'] -join ', ') on $SshAlias. Stop the stack first: 10-start-onboard-stack.ps1 -SshAlias $SshAlias -Stop."
}
if (-not $state['directory']) { throw "JOURNAL_DIRECTORY_MISSING: $journalDirectory does not exist on $SshAlias; nothing to check or archive." }
if ($state['targetExists']) { throw "ARCHIVE_TARGET_EXISTS: $target already exists on $SshAlias; choose another -Suffix." }
if (@($state['files']) -notcontains $journalLeaf) { throw "JOURNAL_FILE_MISSING: $journalDirectory has no $journalLeaf on $SshAlias." }

# 2. Copy, hash the copy, read a second copy.
$hashes = [ordered]@{}
$readDirectory = Join-Path $EvidencePath 'read'
New-Item -ItemType Directory -Path $readDirectory | Out-Null
foreach ($name in @($state['files'])) {
    $local = Join-Path $EvidencePath $name
    & scp -q "${SshAlias}:$(($journalDirectory -replace '\\', '/'))/$name" $local
    if ($LASTEXITCODE -ne 0) { throw "scp of $name from $SshAlias failed (exit $LASTEXITCODE)." }
    $hashes[$name] = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $local -Destination (Join-Path $readDirectory $name)
}
$reading = Read-JournalCopy -DatabasePath (Join-Path $readDirectory $journalLeaf)
$verdictArgs = @{ Reading = $reading; Alias = $SshAlias; ConfirmNoCargo = $ConfirmNoCargo; ArchivePendingPerU6 = $ArchivePendingPerU6; PendingCutoff = $PendingCutoff; FakeDemandIdPattern = $FakeDemandIdPattern }
$refusal = @(Get-JournalArchiveRefusal @verdictArgs)
$record = [ordered]@{
    vehicle = $SshAlias; startedAt = $started; journalPath = $journalPath; journalPathConfigured = $configured; archiveTo = $target
    checkOnly = [bool] $CheckOnly; copiedFiles = $hashes; confirmNoCargo = $ConfirmNoCargo
    archivePendingPerU6 = [bool] $ArchivePendingPerU6; pendingCutoff = ${PendingCutoff}?.ToString('o'); fakeDemandIdPattern = $FakeDemandIdPattern
    reading = $reading; refusal = $refusal; renamed = $false
}
$write = { $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $EvidencePath 'journal-check.json') }
& $write
$loadsText = $reading['loadsOnBoardPresent'] ? (($null -eq $reading['loadsOnBoard']) ? 'null' : @($reading['loadsOnBoard']).Count) : '(no field)'
Write-Host "  pending=$($reading['pending']) loadsOnBoard=$loadsText lastCompletedLoad=$($null -ne $reading['lastCompletedLoadOperationContext']) activeUnlockSlots=[$(@($reading['activeUnlockSlots']) -join ',')] epoch=$($reading['journalEpoch'])"
foreach ($row in @($reading['outboxByState'])) { Write-Host "  outbox $($row -join ' | ')" }

# 3. Verdict.
if ($refusal.Count -gt 0) {
    $refusal | ForEach-Object { Write-Host "  REFUSED $_" -ForegroundColor Red }
    Write-Host "  Nothing was renamed. Evidence: $EvidencePath"
    exit 1
}
if ($ConfirmNoCargo) { Write-Host "  no cargo taken from: $ConfirmNoCargo" }
if ($ArchivePendingPerU6) { Write-Host "  $($reading['pending']) pending row(s) archived under program#170 U6; their WireLine is in journal-check.json" }
if ($CheckOnly) { Write-Host "  CHECK OK: may be archived. Nothing was renamed (-CheckOnly). Evidence: $EvidencePath"; exit 0 }

# 4. Still stopped, still the same bytes, then rename and read back.
$expected = ($hashes.GetEnumerator() | ForEach-Object { "'$($_.Key)'='$($_.Value)'" }) -join '; '
$after = Invoke-Vehicle @"
if (Get-Process -Name 'SQCD*' -ErrorAction SilentlyContinue) { throw 'CLIENT_RUNNING: the stack was started after the check; nothing renamed.' }
if (Test-Path -LiteralPath '$target') { throw 'ARCHIVE_TARGET_EXISTS: $target appeared after the check; nothing renamed.' }
`$expected = @{ $expected }
`$now = @(foreach (`$n in '$($journalFiles -join "','")') { if (Test-Path -LiteralPath (Join-Path '$journalDirectory' `$n)) { `$n } })
if ((@(`$now | Sort-Object) -join ',') -cne (@(`$expected.Keys | Sort-Object) -join ',')) { throw "JOURNAL_CHANGED: files are now `$(`$now -join ',') ; nothing renamed." }
foreach (`$n in `$now) {
    `$h = (Get-FileHash -LiteralPath (Join-Path '$journalDirectory' `$n) -Algorithm SHA256).Hash
    if (`$h -cne `$expected[`$n]) { throw "JOURNAL_CHANGED: `$n hashes `$h on the vehicle, `$(`$expected[`$n]) when copied; nothing renamed." }
}
Rename-Item -LiteralPath '$journalDirectory' -NewName '$(Split-Path -Leaf $target)'
Get-ChildItem -LiteralPath '$(Split-Path -Parent $journalDirectory)' -Force | ForEach-Object { 'LISTED ' + `$_.Name + ' ' + `$_.LastWriteTime.ToString('o') }
"@
$listing = @($after | Where-Object { $_ -like 'LISTED *' } | ForEach-Object { $_ -replace '^LISTED ', '' })
$listing | ForEach-Object { Write-Host "  $_" }
$names = @($listing | ForEach-Object { ($_ -split ' ')[0] })
if ($names -cnotcontains (Split-Path -Leaf $target) -or $names -ccontains (Split-Path -Leaf $journalDirectory)) {
    $record['afterListing'] = $listing
    & $write
    throw "ARCHIVE_NOT_VISIBLE: after the rename the listing does not show $(Split-Path -Leaf $target) alone. Look on the vehicle."
}
$record['renamed'] = $true
$record['afterListing'] = $listing
& $write
Write-Host "  ARCHIVED to $target. Undo with the client stopped: Rename-Item '$target' '$(Split-Path -Leaf $journalDirectory)'. Evidence: $EvidencePath"
exit 0
