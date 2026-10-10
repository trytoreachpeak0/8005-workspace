#Requires -Version 7
<#
.SYNOPSIS
    Test tooling: enters one sublot on a spare vehicle's v2 onboard HMI through UI Automation,
    instead of a person typing it. control-server#566.

.DESCRIPTION
    Runs on the control host. In order:

      1. Reads the newest SublotEntryRequested that the v2 parallel instance on factory01 sent to
         this vehicle (read-only, from its ProtocolOutbox) and refuses unless -Sublot is one of
         its expectedSublots. The tool never enters a barcode the server did not ask for.
      2. Copies agv-enter-sublot-uia.ps1 to the vehicle and runs it in the logged-on user's
         desktop session through a one-shot Interactive scheduled task (sshd gives session 0,
         where the HMI window is not visible). The task is unregistered right after it starts.
      3. Waits for the vehicle-side result file and prints it; -EvidencePath keeps a copy.

    Boundaries (control-server#566, Coordinator 10, 2026-10-10):
      * test only: not part of any onboard package, changes nothing in the onboard client or its
        configuration, and runs only when someone types this command;
      * spare vehicles only: -SshAlias accepts agv02 or agv03 and nothing else;
      * it is used only inside a run the user has already authorized; entering the sublot may let
        the vehicle leave the station, and this tool is not an authorization of its own;
      * every result carries autoEntered=true and method=UIA. The server records the entry as
        KEYBOARD (the protocol has no value for automated entry), so the result file is the mark.

    A first use on a vehicle needs a person watching the screen. If the desktop is locked or the
    scheduled task is blocked (antivirus), fall back to typing by hand and record why.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/16-enter-sublot-uia.ps1 -SshAlias agv02 -Sublot W2-1010-A2-1 -EvidencePath <dir>/entry.json

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/16-enter-sublot-uia.ps1 -SelfTest
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidateSet('agv02', 'agv03')][string] $SshAlias,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string] $Sublot,
    [Parameter(ParameterSetName = 'Run')][string] $EvidencePath,
    [Parameter(ParameterSetName = 'Run')][string] $ServerAlias = 'factory01',
    [Parameter(ParameterSetName = 'Run')][string] $ServerDatabase = 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db',
    [Parameter(ParameterSetName = 'Run')][string] $ServerSqliteTools = 'D:\zhengyushao\control-server-v2-ops\sqlite-tools',
    [Parameter(ParameterSetName = 'Run')][int] $RequestMaxAgeMinutes = 30,
    [Parameter(ParameterSetName = 'Run')][int] $TimeoutSeconds = 120,
    [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
$vehicleScript = Join-Path $PSScriptRoot 'agv-enter-sublot-uia.ps1'
$vehicleRoot = 'C:\8005\uia'

<#
    Refuses unless the request is this vehicle's, recent, and lists the sublot. Pure, so -SelfTest
    covers it. $Request is the parsed envelope of a SublotEntryRequested.
#>
function Assert-SublotRequested {
    param([object] $Request, [string] $AgvId, [string] $Sublot, [DateTimeOffset] $Now, [int] $MaxAgeMinutes)
    if (-not $Request) { throw "REFUSED: the server has sent no SublotEntryRequested to $AgvId." }
    if ($Request.agvId -cne $AgvId) { throw "REFUSED: the newest request is for '$($Request.agvId)', not $AgvId." }
    $sentAt = [DateTimeOffset] $Request.sentAt
    if ($Now - $sentAt -gt [TimeSpan]::FromMinutes($MaxAgeMinutes)) {
        throw "REFUSED: the newest request for $AgvId was sent at $($sentAt.ToString('o')), more than $MaxAgeMinutes min ago."
    }
    $expected = @($Request.payload.expectedSublots)
    if ($expected -cnotcontains $Sublot) {
        throw "REFUSED: '$Sublot' is not in expectedSublots [$($expected -join ', ')] of request $($Request.messageId) at station $($Request.payload.stationId)."
    }
    return [pscustomobject]@{ MessageId = $Request.messageId; StationId = $Request.payload.stationId; ExpectedSublots = $expected; SentAt = $sentAt }
}

<#
    Only the v2 parallel instance's database may be read. Pointing -ServerDatabase at the MVP database
    would be a query against the production database, which needs the user first (Ask first, category 2).
#>
function Assert-V2Database {
    param([string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = 'C:\ProgramData\8005\ControlServer.V2\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "REFUSED: -ServerDatabase '$Path' is not under $root. Only the v2 parallel instance's database is read."
    }
    return $full
}

<#
    The newest request for this vehicle, ordered by sentAt parsed as DateTimeOffset on this side.
    SQLite cannot order DateTimeOffset text correctly, so the SQL does not sort.
#>
function Select-LatestSublotRequest {
    param([string[]] $PayloadLines, [string] $AgvId)
    return @($PayloadLines | Where-Object { $_ -like '{*' } | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.agvId -ceq $AgvId } |
        Sort-Object -Property @{ Expression = { [DateTimeOffset] $_.sentAt } } -Descending) | Select-Object -First 1
}

function Invoke-SelfTest {
    $failures = [System.Collections.Generic.List[string]]::new()
    function Check([string] $Name, [scriptblock] $Body) {
        try { & $Body; "PASS $Name" } catch { $failures.Add($Name); "FAIL $Name -- $($_.Exception.Message)" }
    }

    Check 'both scripts parse with zero errors' {
        foreach ($path in @($PSCommandPath, $vehicleScript)) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $null, [ref] $errors)
            if ($errors.Count -ne 0) { throw "$path : $($errors[0].Message)" }
        }
    }

    $now = [DateTimeOffset]::Parse('2026-10-10T12:00:00Z')
    $request = [pscustomobject]@{
        messageId = 'm1'; agvId = 'A2'; sentAt = '2026-10-10T11:55:00Z'
        payload = [pscustomobject]@{ stationId = 'N1-15_N1-16'; expectedSublots = @('S-1', 'S-2') }
    }
    Check 'a sublot in expectedSublots is accepted' {
        $r = Assert-SublotRequested $request 'A2' 'S-2' $now 30
        if ($r.MessageId -ne 'm1') { throw 'wrong request' }
    }
    foreach ($case in @(
            @{ Name = 'a sublot not in expectedSublots is refused'; Sublot = 'S-3'; Agv = 'A2'; Req = $request },
            @{ Name = 'a sublot differing only in case is refused'; Sublot = 's-1'; Agv = 'A2'; Req = $request },
            @{ Name = 'a request for another vehicle is refused'; Sublot = 'S-1'; Agv = 'A3'; Req = $request },
            @{ Name = 'no request at all is refused'; Sublot = 'S-1'; Agv = 'A2'; Req = $null })) {
        Check $case.Name {
            try { $null = Assert-SublotRequested $case.Req $case.Agv $case.Sublot $now 30 } catch {
                if ($_.Exception.Message -like 'REFUSED:*') { return }
                throw
            }
            throw 'not refused'
        }
    }
    Check 'a stale request is refused' {
        try { $null = Assert-SublotRequested $request 'A2' 'S-1' $now.AddHours(2) 30 } catch {
            if ($_.Exception.Message -like 'REFUSED:*') { return }
            throw
        }
        throw 'not refused'
    }

    Check 'the MVP database path is refused' {
        try { $null = Assert-V2Database 'C:\ProgramData\8005\ControlServer\data\controlserver.db' } catch {
            if ($_.Exception.Message -like 'REFUSED:*') { return }
            throw
        }
        throw 'not refused'
    }
    Check 'a path escaping the v2 root through .. is refused' {
        try { $null = Assert-V2Database 'C:\ProgramData\8005\ControlServer.V2\..\ControlServer\data\controlserver.db' } catch {
            if ($_.Exception.Message -like 'REFUSED:*') { return }
            throw
        }
        throw 'not refused'
    }
    Check 'the v2 database path is accepted' {
        $null = Assert-V2Database 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db'
    }
    Check 'the newest request by time wins when text order disagrees' {
        # '+08:00' text sorts after '+00:00' text, but 10:00+08:00 is 02:00Z -- older than 09:00Z.
        $older = '{"messageId":"old","agvId":"A2","sentAt":"2026-10-10T10:00:00+08:00","payload":{"stationId":"X","expectedSublots":["OLD"]}}'
        $newer = '{"messageId":"new","agvId":"A2","sentAt":"2026-10-10T09:00:00+00:00","payload":{"stationId":"Y","expectedSublots":["NEW"]}}'
        $other = '{"messageId":"other","agvId":"A3","sentAt":"2026-10-10T11:00:00+00:00","payload":{"stationId":"Z","expectedSublots":["OTHER"]}}'
        $picked = Select-LatestSublotRequest @($older, $newer, $other) 'A2'
        if ($picked.messageId -ne 'new') { throw "picked $($picked.messageId)" }
        $picked = Select-LatestSublotRequest @($newer, $older) 'A2'
        if ($picked.messageId -ne 'new') { throw "picked $($picked.messageId) with the lines reversed" }
    }

    . $vehicleScript
    function New-FakeDriver([string[]] $ReadBacks, [bool] $Open = $true) {
        $fake = [pscustomobject]@{ Reads = [System.Collections.Generic.Queue[string]]::new($ReadBacks); Typed = 0; Submits = 0; Open = $Open }
        $fake | Add-Member ScriptMethod CanSubmit { $this.Open }
        $fake | Add-Member ScriptMethod SubmitReady { $true }
        $fake | Add-Member ScriptMethod SetSublot { param($t) $this.Typed++ }
        $fake | Add-Member ScriptMethod ScanText { if ($this.Reads.Count -gt 0) { $this.Reads.Dequeue() } else { '' } }
        $fake | Add-Member ScriptMethod Submit { $this.Submits++ }
        return $fake
    }
    Check 'a clean read-back submits exactly once' {
        $d = New-FakeDriver @('S-1', 'S-1')
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if (-not $r.Submitted -or $d.Submits -ne 1 -or $d.Typed -ne 1) { throw "submits=$($d.Submits) typed=$($d.Typed)" }
    }
    Check 'one bad read-back is retyped, then submitted once' {
        $d = New-FakeDriver @('S-', 'S-1', 'S-1')
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if (-not $r.Submitted -or $d.Submits -ne 1 -or $d.Typed -ne 2) { throw "submits=$($d.Submits) typed=$($d.Typed)" }
    }
    Check 'read-back never matching gives up after 2 retypes without submitting' {
        $d = New-FakeDriver @('x', 'x', 'x', 'x', 'x', 'x')
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -MaxRetypes 2 -WaitSeconds 1
        if ($r.Submitted -or $d.Submits -ne 0 -or $d.Typed -ne 3 -or $r.Outcome -ne 'READBACK_MISMATCH') {
            throw "submitted=$($r.Submitted) submits=$($d.Submits) typed=$($d.Typed) outcome=$($r.Outcome)"
        }
    }
    Check 'a closed input is not typed into' {
        $d = New-FakeDriver @('S-1') -Open $false
        $r = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if ($r.Submitted -or $d.Typed -ne 0 -or $r.Outcome -ne 'INPUT_NOT_OPEN') { throw "typed=$($d.Typed) outcome=$($r.Outcome)" }
    }
    Check 'the product refusing is not retried (one submit, whatever follows)' {
        # The tool has no view of the product's answer, so "not retried" is structural: one entry is one Submit.
        $d = New-FakeDriver @('S-1', 'S-1', 'S-1', 'S-1')
        $null = Invoke-SublotEntry -Driver $d -Sublot 'S-1' -WaitSeconds 1
        if ($d.Submits -ne 1) { throw "submits=$($d.Submits)" }
    }

    "SELFTEST $(if ($failures.Count -eq 0) { 'PASS' } else { "FAIL ($($failures -join '; '))" })"
    if ($failures.Count -ne 0) { exit 1 }
}

if ($PSCmdlet.ParameterSetName -eq 'SelfTest') { Invoke-SelfTest; return }

$ServerDatabase = Assert-V2Database $ServerDatabase
$site = Get-Content (Join-Path $PSScriptRoot "..\config\site-$SshAlias.json") -Raw | ConvertFrom-Json
$agvId = $site.agvId

# 1. The request, read-only from the v2 instance's outbox.
$readRequest = @"
`$env:PATH = '$ServerSqliteTools;$ServerSqliteTools\runtimes\win-x64\native;' + `$env:PATH
foreach (`$a in 'SQLitePCLRaw.core.dll','SQLitePCLRaw.provider.e_sqlite3.dll','SQLitePCLRaw.batteries_v2.dll','Microsoft.Data.Sqlite.dll') { Add-Type -Path (Join-Path '$ServerSqliteTools' `$a) }
[SQLitePCL.Batteries_V2]::Init()
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly'); `$c.Open()
`$cmd = `$c.CreateCommand()
`$cmd.CommandText = "SELECT PayloadJson FROM ProtocolOutbox WHERE MessageType = 'SublotEntryRequested'"
`$r = `$cmd.ExecuteReader(); while (`$r.Read()) { `$r.GetString(0) }; `$r.Close(); `$c.Close()
"@
$lines = $readRequest | ssh $ServerAlias 'pwsh -NoProfile -Command -'
if ($LASTEXITCODE -ne 0) { throw "Reading the request from $ServerAlias failed (exit $LASTEXITCODE)." }
$request = Select-LatestSublotRequest $lines $agvId
$checked = Assert-SublotRequested $request $agvId $Sublot ([DateTimeOffset]::UtcNow) $RequestMaxAgeMinutes
Write-Host "Request $($checked.MessageId) at $($checked.StationId), sent $($checked.SentAt.ToString('o')): expectedSublots [$($checked.ExpectedSublots -join ', ')]"

# 2. Run the vehicle half in the interactive session.
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$resultPath = "$vehicleRoot\result-$runId.json"
ssh $SshAlias "pwsh -NoProfile -Command `"New-Item -ItemType Directory -Force -Path '$vehicleRoot' | Out-Null`""
if ($LASTEXITCODE -ne 0) { throw "Preparing $vehicleRoot on $SshAlias failed." }
scp -q $vehicleScript "${SshAlias}:$($vehicleRoot -replace '\\', '/')/agv-enter-sublot-uia.ps1"
if ($LASTEXITCODE -ne 0) { throw "Copying the vehicle script to $SshAlias failed." }
$launch = @"
`$ErrorActionPreference = 'Stop'
`$console = (query session 2>&1 | Select-String -Pattern '^\s*>?console\s+(\S+)\s+(\d+)\s+Active').Matches
if (-not `$console) { throw 'No active console session on this vehicle.' }
`$arguments = '-NoProfile -ExecutionPolicy Bypass -File "$vehicleRoot\agv-enter-sublot-uia.ps1" -Sublot "$Sublot" -ResultPath "$resultPath"'
`$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument `$arguments -WorkingDirectory '$vehicleRoot'
`$principal = New-ScheduledTaskPrincipal -UserId `$console[0].Groups[1].Value -LogonType Interactive -RunLevel Limited
`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
try {
    Register-ScheduledTask -TaskName 'W2G-EnterSublot-$runId' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
    Start-ScheduledTask -TaskName 'W2G-EnterSublot-$runId'
    Start-Sleep -Seconds 3
    `$info = Get-ScheduledTaskInfo -TaskName 'W2G-EnterSublot-$runId'
    'TASK_STARTED lastRunTime={0} lastTaskResult=0x{1:X}' -f `$info.LastRunTime, `$info.LastTaskResult
} finally {
    Unregister-ScheduledTask -TaskName 'W2G-EnterSublot-$runId' -Confirm:`$false -ErrorAction SilentlyContinue
}
"@
# Copied and run with -File, never piped to `pwsh -Command -`: that mode reads statement by statement and
# silently drops a trailing multi-line block (this try/finally) at end of input. On 2026-10-10 the task was
# never registered that way, exit code 0, and the station deadline ran out (control-server#566 B 段).
$launchLocal = Join-Path ([System.IO.Path]::GetTempPath()) "enter-sublot-launch-$runId.ps1"
Set-Content -LiteralPath $launchLocal -Value $launch -Encoding utf8NoBOM
try {
    scp -q $launchLocal "${SshAlias}:$($vehicleRoot -replace '\\', '/')/launch-$runId.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Copying the launch script to $SshAlias failed." }
} finally {
    Remove-Item -LiteralPath $launchLocal -ErrorAction SilentlyContinue
}
ssh $SshAlias "pwsh -NoProfile -File `"$vehicleRoot\launch-$runId.ps1`""
if ($LASTEXITCODE -ne 0) { throw "Launching the entry task on $SshAlias failed (exit $LASTEXITCODE)." }

# 3. The result.
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 2
    $present = ssh $SshAlias "pwsh -NoProfile -Command `"Test-Path '$resultPath'`""
} until (($present -join '') -match 'True' -or [DateTimeOffset]::UtcNow -ge $deadline)
if (($present -join '') -notmatch 'True') { throw "No result from $SshAlias within ${TimeoutSeconds}s ($resultPath). Nothing is known about the entry; check the screen." }
# Fetched by scp, not printed through ssh: the console code page garbles non-ASCII text on the way back.
$resultLocal = Join-Path ([System.IO.Path]::GetTempPath()) "enter-sublot-result-$runId.json"
scp -q "${SshAlias}:$($resultPath -replace '\\', '/')" $resultLocal
if ($LASTEXITCODE -ne 0) { throw "Copying the result back from $SshAlias failed ($resultPath)." }
$result = Get-Content -LiteralPath $resultLocal -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
Remove-Item -LiteralPath $resultLocal -ErrorAction SilentlyContinue
$result.request = [ordered]@{ messageId = $checked.MessageId; stationId = $checked.StationId; expectedSublots = $checked.ExpectedSublots }
$json = $result | ConvertTo-Json -Depth 5
if ($EvidencePath) { $json | Set-Content -LiteralPath $EvidencePath -Encoding utf8NoBOM }
$json
if (-not $result.submitted) { exit 2 }
