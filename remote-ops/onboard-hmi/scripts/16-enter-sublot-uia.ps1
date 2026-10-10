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

$site = Get-Content (Join-Path $PSScriptRoot "..\config\site-$SshAlias.json") -Raw | ConvertFrom-Json
$agvId = $site.agvId

# 1. The request, read-only from the v2 instance's outbox.
$readRequest = @"
`$env:PATH = '$ServerSqliteTools;$ServerSqliteTools\runtimes\win-x64\native;' + `$env:PATH
foreach (`$a in 'SQLitePCLRaw.core.dll','SQLitePCLRaw.provider.e_sqlite3.dll','SQLitePCLRaw.batteries_v2.dll','Microsoft.Data.Sqlite.dll') { Add-Type -Path (Join-Path '$ServerSqliteTools' `$a) }
[SQLitePCL.Batteries_V2]::Init()
`$c = [Microsoft.Data.Sqlite.SqliteConnection]::new('Data Source=$ServerDatabase;Mode=ReadOnly'); `$c.Open()
`$cmd = `$c.CreateCommand()
`$cmd.CommandText = "SELECT PayloadJson FROM ProtocolOutbox WHERE MessageType = 'SublotEntryRequested' ORDER BY CreatedAt DESC LIMIT 20"
`$r = `$cmd.ExecuteReader(); while (`$r.Read()) { `$r.GetString(0) }; `$r.Close(); `$c.Close()
"@
$lines = $readRequest | ssh $ServerAlias 'pwsh -NoProfile -Command -'
if ($LASTEXITCODE -ne 0) { throw "Reading the request from $ServerAlias failed (exit $LASTEXITCODE)." }
$request = @($lines | Where-Object { $_ -like '{*' } | ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.agvId -ceq $agvId }) | Select-Object -First 1
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
try {
    Register-ScheduledTask -TaskName 'W2G-EnterSublot-$runId' -Action `$action -Principal `$principal -Force | Out-Null
    Start-ScheduledTask -TaskName 'W2G-EnterSublot-$runId'
} finally {
    Start-Sleep -Seconds 3
    Unregister-ScheduledTask -TaskName 'W2G-EnterSublot-$runId' -Confirm:`$false -ErrorAction SilentlyContinue
}
"@
$launch | ssh $SshAlias 'pwsh -NoProfile -Command -'
if ($LASTEXITCODE -ne 0) { throw "Launching the entry task on $SshAlias failed (exit $LASTEXITCODE)." }

# 3. The result.
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 2
    $raw = ssh $SshAlias "pwsh -NoProfile -Command `"if (Test-Path '$resultPath') { Get-Content -Raw '$resultPath' }`""
} until ($raw -or [DateTimeOffset]::UtcNow -ge $deadline)
if (-not $raw) { throw "No result from $SshAlias within ${TimeoutSeconds}s ($resultPath). Nothing is known about the entry; check the screen." }
$result = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
$result.request = [ordered]@{ messageId = $checked.MessageId; stationId = $checked.StationId; expectedSublots = $checked.ExpectedSublots }
$json = $result | ConvertTo-Json -Depth 5
if ($EvidencePath) { $json | Set-Content -LiteralPath $EvidencePath -Encoding utf8NoBOM }
$json
if (-not $result.submitted) { exit 2 }
