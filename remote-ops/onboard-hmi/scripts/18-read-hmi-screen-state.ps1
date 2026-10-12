#Requires -Version 7
<#
.SYNOPSIS
    Read-only reader for the onboard HMI's screen-state snapshot (hmi-state.json and its daily timeline),
    with a -CrossCheck mode that holds the snapshot against a UI Automation reading of the same screen.
    onboard-hmi#316 (T3 of docs/W2G_HMI_OBSERVABILITY_RESEARCH.md in 8005-agv-onboard-hmi).

.DESCRIPTION
    Runs on the control host. The onboard client (SQCD.Agv.Wpf, onboard-hmi#315 and later, with
    screenState.enabled true in its configuration) writes, next to its technical log:

      hmi-state.json               what the screen shows and lets the operator press, rewritten on every
                                   change and at least every heartbeat (5 s by default), moved into place
                                   in one step
      hmi-state-yyyyMMdd.ndjson    one line per content change

    Read mode reads the current file (and with -TimelineLines the tail of the newest timeline) over SSH
    and judges it. Read-only: the one script it sends to the vehicle opens files with FileAccess.Read
    and FileShare ReadWrite|Delete (the writer replaces the file while we hold it), lists the timeline
    files and lists SQCD.Agv.Wpf processes. It registers no task, starts and stops no process, writes
    nothing on the vehicle; -SelfTest scans the generated script for that (see Test-ReadOnlyScript).
    The bytes come back base64-encoded, never through the console code page (hmi#292).

    Outcomes (exit code in brackets), all judged on the vehicle's own clock:

      ACTIVE [0]        status ACTIVE, writtenAt within -StaleAfterSeconds, the writing process alive
      DISABLED [2]      status DISABLED: the snapshot stopped itself after an exception (entry, reason)
      STALE [3]         status ACTIVE, the writing process alive, but writtenAt older than
                        -StaleAfterSeconds (or that far in the future): the dispatcher is not running
                        the heartbeat, i.e. the screen is not responding
      EXITED [4]        status ACTIVE but the process named in the file (processId, started no later
                        than processStartedAt) is gone. The writer writes no end marker on exit
                        (onboard-hmi#315, residual risk L2), so the process id is what tells
                        "exited" from "hung"
      ABSENT [5]        no hmi-state.json: snapshot switched off, an HMI without it, wrong directory
      UNREADABLE [6]    the file is there but is not a document this reader knows
      TOOL_FAILURE [1]  SSH failed, or the vehicle's answer could not be decoded

    -CrossCheck reads the snapshot, takes one UIA reading of the HMI window, waits -SettleMilliseconds
    and reads the snapshot again. Only when both reads are ACTIVE with the same processStartId and the
    same contentRevision (nothing changed around the UIA reading) does it compare: the banner's state
    text, each button's and input box's visibility and enabledness, whether each input box is empty,
    the modal dialogs, and the raw codes of the status cells (UIA ItemStatus). It writes a difference
    table. Remote mode takes the UIA reading with 17-capture-hmi-screen.ps1 (which does register a
    one-shot task on the vehicle, its own documented contract); -Local runs the same vehicle half,
    agv-capture-hmi-screen.ps1, directly in this desktop session, with no SSH and no task.

      MATCH [0]           compared, no difference
      MISMATCH [10]       compared, at least one difference: the snapshot is not to be trusted
                          (research section 6, item 1) until it is explained
      MOVING [11]         the screen changed around the UIA reading (revision or process differs, or
                          the UIA reading saw another process): no conclusion
      CAPTURE_FAILED [12] the UIA reading did not produce a complete tree
      or the first read's outcome when that was not ACTIVE

    agv02 and agv03 only. agv01 is production; reading it needs the user first (Ask first,
    category 2). There is no default vehicle.

    What it does not compare, on purpose: the guidance line and the operator notice (an expiring notice
    lags the screen by design, onboard-hmi#313 review L5), the countdown text, the journey plan and
    worklist rows, the slot cards, the KeyBinding's CanExecute (UIA has no reading of it).

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-read-hmi-screen-state.ps1 -SshAlias agv02 -TimelineLines 20

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-read-hmi-screen-state.ps1 -SshAlias agv02 -CrossCheck -EvidenceDirectory evidence/field/<dir>

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-read-hmi-screen-state.ps1 -Local -Directory <L2 evidence>/onboard-app -CrossCheck -EvidenceDirectory <dir>

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-read-hmi-screen-state.ps1 -SelfTest
#>
[CmdletBinding(DefaultParameterSetName = 'Remote')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Remote')]
    [ValidateSet('agv02', 'agv03', ErrorMessage = "'{0}' is refused. Only the spare vehicles agv02 and agv03; agv01 is production and needs the user first (Ask first, category 2).")]
    [string] $SshAlias,
    # Where the vehicle's HMI writes: the technical log directory of the HT account (docs/USAGE.md).
    [Parameter(ParameterSetName = 'Remote')][string] $VehicleDirectory = 'C:\Users\HT\AppData\Local\SQCD\8005AGV\logs',
    [Parameter(Mandatory, ParameterSetName = 'Local')][switch] $Local,
    [Parameter(ParameterSetName = 'Local')][string] $Directory = (Join-Path $env:LOCALAPPDATA 'SQCD\8005AGV\logs'),
    [Parameter(ParameterSetName = 'Remote')][Parameter(ParameterSetName = 'Local')][switch] $CrossCheck,
    [Parameter(ParameterSetName = 'Remote')][Parameter(ParameterSetName = 'Local')][string] $EvidenceDirectory,
    # Three heartbeats at the shipped 5000 ms (research T3 acceptance). Raise it with heartbeatIntervalMs.
    [Parameter(ParameterSetName = 'Remote')][Parameter(ParameterSetName = 'Local')][int] $StaleAfterSeconds = 15,
    [Parameter(ParameterSetName = 'Remote')][Parameter(ParameterSetName = 'Local')][int] $TimelineLines = 0,
    # Three flush intervals at the shipped 500 ms: a change seen by UIA is in the file by then.
    [Parameter(ParameterSetName = 'Remote')][Parameter(ParameterSetName = 'Local')][int] $SettleMilliseconds = 1500,
    [Parameter(ParameterSetName = 'Remote')][Parameter(ParameterSetName = 'Local')][int] $CaptureTimeoutSeconds = 90,
    # Off-vehicle tests only.
    [Parameter(DontShow, ParameterSetName = 'Remote')][string] $SshExecutable = 'ssh',
    [Parameter(DontShow, ParameterSetName = 'Remote')][Parameter(DontShow, ParameterSetName = 'Local')][string] $ProcessName = 'SQCD.Agv.Wpf',
    [Parameter(DontShow, ParameterSetName = 'Remote')][Parameter(DontShow, ParameterSetName = 'Local')][string] $CaptureScript,
    [Parameter(Mandatory, ParameterSetName = 'SelfTest')][switch] $SelfTest
)

$ErrorActionPreference = 'Stop'
$captureScript17 = Join-Path $PSScriptRoot '17-capture-hmi-screen.ps1'
$vehicleCaptureScript = Join-Path $PSScriptRoot 'agv-capture-hmi-screen.ps1'
$currentFileName = 'hmi-state.json'
$knownSchemaVersion = 1
# A process that started more than this after the writer's processStartedAt is a reused id, not the writer.
$processStartToleranceSeconds = 5

$exitCodes = [ordered]@{
    ACTIVE = 0; TOOL_FAILURE = 1; DISABLED = 2; STALE = 3; EXITED = 4; ABSENT = 5; UNREADABLE = 6
    MATCH = 0; MISMATCH = 10; MOVING = 11; CAPTURE_FAILED = 12
}

<#
    The one script sent to the vehicle (or run locally). Reads only; prints one base64 line holding JSON.
    Test-ReadOnlyScript holds it to that.
#>
function New-ReadScript {
    param([string] $Directory, [int] $TimelineLines, [string] $ProcessName)
    $dir = $Directory -replace "'", "''"
    $name = $ProcessName -replace "'", "''"
    return @"
`$ErrorActionPreference = 'Stop'
# Delete sharing too: the writer moves a new file over this one while we may hold it open.
`$share = [System.IO.FileShare]'ReadWrite, Delete'
function Read-Shared([string] `$Path, [long] `$Tail) {
    `$stream = [System.IO.File]::Open(`$Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, `$share)
    try {
        `$start = if (`$Tail -gt 0 -and `$stream.Length -gt `$Tail) { `$stream.Length - `$Tail } else { 0 }
        `$null = `$stream.Seek(`$start, [System.IO.SeekOrigin]::Begin)
        `$buffer = [System.IO.MemoryStream]::new()
        `$stream.CopyTo(`$buffer)
        return [ordered]@{ length = `$stream.Length; offset = `$start; base64 = [Convert]::ToBase64String(`$buffer.ToArray()) }
    } finally {
        `$stream.Dispose()
    }
}
`$result = [ordered]@{
    now = [DateTimeOffset]::Now.ToString('o')
    directory = '$dir'
    directoryExists = (Test-Path -LiteralPath '$dir' -PathType Container)
    current = `$null
    currentError = `$null
    timeline = `$null
    timelineError = `$null
    processes = @()
}
`$path = Join-Path '$dir' '$currentFileName'
if (Test-Path -LiteralPath `$path -PathType Leaf) {
    try { `$result.current = Read-Shared `$path 0 } catch { `$result.currentError = `$_.Exception.Message }
}
if ($TimelineLines -gt 0 -and `$result.directoryExists) {
    try {
        `$newest = Get-ChildItem -LiteralPath '$dir' -Filter 'hmi-state-*.ndjson' -File | Where-Object Name -Match '^hmi-state-\d{8}\.ndjson$' | Sort-Object Name | Select-Object -Last 1
        if (`$newest) { `$tail = Read-Shared `$newest.FullName 1048576; `$tail.name = `$newest.Name; `$result.timeline = `$tail }
    } catch { `$result.timelineError = `$_.Exception.Message }
}
`$result.processes = @(Get-Process -Name '$name' -ErrorAction SilentlyContinue | ForEach-Object {
    `$started = try { `$_.StartTime.ToString('o') } catch { `$null }
    [ordered]@{ id = `$_.Id; sessionId = `$_.SessionId; startTime = `$started }
})
[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((`$result | ConvertTo-Json -Compress -Depth 5)))
"@
}

<#
    What the generated read script may call. An allowlist over the syntax tree, not a blacklist of names:
    a command or a .NET method not listed here fails the self-test. It sees direct calls; a name built at
    run time (& (`$a + `$b)) shows up as a command it cannot name and fails too.
#>
$readScriptCommands = 'Test-Path', 'Join-Path', 'Get-ChildItem', 'Where-Object', 'Sort-Object', 'Select-Object',
    'Get-Process', 'ForEach-Object', 'ConvertTo-Json', 'Read-Shared'
$readScriptMethods = 'Open', 'Seek', 'new', 'CopyTo', 'ToArray', 'ToBase64String', 'Dispose', 'ToString', 'GetBytes'

function Test-ReadOnlyScript {
    param([string] $Text)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref] $null, [ref] $errors)
    if ($errors.Count) { throw "does not parse: $($errors[0].Message)" }
    $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $unnamed = @($commands | Where-Object { -not $_.GetCommandName() })
    if ($unnamed.Count) { throw "a command with no literal name: $($unnamed[0].Extent.Text)" }
    $extraCommands = @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -notin $readScriptCommands } | Sort-Object -Unique)
    if ($extraCommands.Count) { throw "commands outside the read allowlist: $($extraCommands -join ', ')" }
    $members = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
    $extraMethods = @($members | ForEach-Object { $_.Member.Extent.Text } | Where-Object { $_ -notin $readScriptMethods } | Sort-Object -Unique)
    if ($extraMethods.Count) { throw ".NET methods outside the read allowlist: $($extraMethods -join ', ')" }
    $opens = @($members | Where-Object { $_.Member.Extent.Text -eq 'Open' })
    foreach ($open in $opens) {
        $arguments = @($open.Arguments | ForEach-Object { $_.Extent.Text })
        if ($open.Expression.Extent.Text -ne '[System.IO.File]' -or $arguments.Count -ne 4 -or
            $arguments[1] -ne '[System.IO.FileMode]::Open' -or $arguments[2] -ne '[System.IO.FileAccess]::Read' -or $arguments[3] -ne '$share') {
            throw "an Open that is not File.Open(path, Open, Read, `$share): $($open.Extent.Text)"
        }
    }
    if ($opens.Count -ne 1) { throw "expected one File.Open, found $($opens.Count)" }
    if ($Text -notmatch [regex]::Escape("`$share = [System.IO.FileShare]'ReadWrite, Delete'")) { throw 'the share mode is not ReadWrite, Delete' }
}

<# Runs the read script on the vehicle (or locally) and returns the decoded answer. #>
function Invoke-StateRead {
    $text = New-ReadScript -Directory ($Local ? $Directory : $VehicleDirectory) -TimelineLines $TimelineLines -ProcessName $ProcessName
    # An explicit exit 0, as in 17-capture-hmi-screen.ps1's Invoke-Vehicle.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$text`nexit 0"))
    $raw = if ($Local) {
        & pwsh -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
    } else {
        & $SshExecutable -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -NonInteractive -EncodedCommand $encoded" 2>&1
    }
    $exit = $LASTEXITCODE
    $lines = @($raw | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($exit -ne 0) { throw "reading $($Local ? $Directory : "${SshAlias}:$VehicleDirectory") failed (exit $exit): $(($lines | Select-Object -Last 5) -join ' | ')" }
    $last = $lines | Select-Object -Last 1
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($last)) | ConvertFrom-Json -DateKind String
    } catch {
        throw "the answer was not the expected base64 JSON line: $(($lines | Select-Object -Last 3) -join ' | ')"
    }
}

function ConvertFrom-Base64Utf8 {
    param([string] $Base64)
    # Strict: a byte sequence that is not UTF-8 is an unreadable file, not a file with replacement characters.
    return [System.Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($Base64))
}

function ConvertTo-Instant {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    return [DateTimeOffset]::Parse("$Value", [System.Globalization.CultureInfo]::InvariantCulture)
}

<#
    The outcome of one read. Pure, so -SelfTest covers every branch. Order matters: a file that is not a
    document cannot say anything else; DISABLED is what the writer said last whatever happened after;
    a process that is gone cannot be "hung", so EXITED outranks STALE.
#>
function Get-SnapshotVerdict {
    param([object] $Read, [int] $StaleAfterSeconds)
    $verdict = [ordered]@{
        outcome = $null; detail = $null; vehicleNow = $Read.now; ageSeconds = $null
        processStartId = $null; contentRevision = $null; processId = $null; writerAlive = $null
        hmiProcesses = @($Read.processes); document = $null
    }
    function Done([string] $Outcome, [string] $Detail) { $verdict.outcome = $Outcome; $verdict.detail = $Detail; return $verdict }

    if ($Read.currentError) { return Done 'UNREADABLE' "opening $currentFileName failed: $($Read.currentError)" }
    if (-not $Read.current) {
        $running = @($Read.processes | ForEach-Object { $_.id })
        $why = if (-not $Read.directoryExists) { "the directory $($Read.directory) does not exist" } else { "no $currentFileName in $($Read.directory)" }
        $hint = if ($running.Count) { "; the HMI is running (pid $($running -join ', ')), so the snapshot is probably switched off (screenState.enabled) or written elsewhere (screenState.directory)" } else { '; no HMI process is running' }
        return Done 'ABSENT' "$why$hint"
    }
    try {
        $document = ConvertFrom-Base64Utf8 $Read.current.base64 | ConvertFrom-Json -DateKind String
    } catch {
        return Done 'UNREADABLE' "$currentFileName ($($Read.current.length) bytes) is not UTF-8 JSON: $($_.Exception.Message)"
    }
    if ($document -isnot [System.Management.Automation.PSCustomObject]) { return Done 'UNREADABLE' "$currentFileName is not a JSON object" }
    if ($document.schemaVersion -ne $knownSchemaVersion) { return Done 'UNREADABLE' "schemaVersion '$($document.schemaVersion)'; this reader knows $knownSchemaVersion" }
    $missing = @('status', 'contentRevision', 'writtenAt', 'processStartId', 'processId', 'processStartedAt' | Where-Object { $null -eq $document.$_ })
    if ($missing.Count) { return Done 'UNREADABLE' "missing field(s): $($missing -join ', ')" }
    try {
        $now = ConvertTo-Instant $Read.now
        $writtenAt = ConvertTo-Instant $document.writtenAt
        $processStartedAt = ConvertTo-Instant $document.processStartedAt
    } catch {
        return Done 'UNREADABLE' "a time field does not parse: $($_.Exception.Message)"
    }
    $verdict.document = $document
    $verdict.processStartId = $document.processStartId
    $verdict.contentRevision = $document.contentRevision
    $verdict.processId = $document.processId
    $verdict.ageSeconds = [Math]::Round(($now - $writtenAt).TotalSeconds, 1)

    if ($document.status -eq 'DISABLED') {
        return Done 'DISABLED' "the snapshot stopped itself at $($document.disabledAt) in $($document.disabledEntry): $($document.disabledReason)"
    }
    if ($document.status -ne 'ACTIVE') { return Done 'UNREADABLE' "unknown status '$($document.status)'" }
    if ($null -eq $document.state) { return Done 'UNREADABLE' 'status ACTIVE without a state' }

    $writer = @($Read.processes | Where-Object { $_.id -eq $document.processId }) | Select-Object -First 1
    $reused = $false
    if ($writer -and $writer.startTime) {
        # The writer starts after the process, so the process start can only be earlier; much later is a new process.
        $reused = (ConvertTo-Instant $writer.startTime) -gt $processStartedAt.AddSeconds($processStartToleranceSeconds)
    }
    $verdict.writerAlive = [bool] $writer -and -not $reused
    if (-not $verdict.writerAlive) {
        $why = if ($reused) { "process id $($document.processId) now belongs to a $ProcessName started $($writer.startTime), after the writer's start $($document.processStartedAt)" } else { "no $ProcessName with process id $($document.processId) is running" }
        return Done 'EXITED' "$why. The writer leaves no end marker on exit (onboard-hmi#315 L2), so the file still says ACTIVE; last written $($document.writtenAt)."
    }
    if ($verdict.ageSeconds -gt $StaleAfterSeconds) {
        return Done 'STALE' "writtenAt $($document.writtenAt) is $($verdict.ageSeconds) s old (limit $StaleAfterSeconds s) while process $($document.processId) is running: the dispatcher is not running the heartbeat"
    }
    if ($verdict.ageSeconds -lt -$StaleAfterSeconds) {
        return Done 'STALE' "writtenAt $($document.writtenAt) is $(-$verdict.ageSeconds) s ahead of the vehicle clock $($Read.now): the clock moved back, the age cannot be judged"
    }
    return Done 'ACTIVE' "written $($verdict.ageSeconds) s ago by process $($document.processId)"
}

<# Every node of a UIA tree record, depth-first, in tree order. #>
function Get-UiaNodes {
    param($Node)
    if (-not $Node) { return }
    $Node
    foreach ($child in @($Node.children)) { Get-UiaNodes $child }
}

<# The HMI's main window record: the visible non-dialog window with the largest tree. #>
function Get-UiaMainWindow {
    param($Uia)
    return @($Uia.hmiWindows | Where-Object { $_.uia -and $_.visible -and $_.className -ne '#32770' }) |
        Sort-Object { @(Get-UiaNodes $_.uia).Count } -Descending | Select-Object -First 1
}

<#
    Holds one snapshot against one UIA reading. Pure. Returns one row per compared field; a row with
    match = $false is a difference. Input box contents never enter a row: only whether the box is empty.
    "Visible" on the UIA side is "in the control view": WPF leaves a Collapsed element out of the tree.
#>
function Compare-ScreenState {
    param($State, $Uia)
    $rows = [System.Collections.Generic.List[object]]::new()
    function Row([string] $Category, [string] $Key, [string] $Field, $Snapshot, $UiaValue) {
        $rows.Add([ordered]@{ category = $Category; key = $Key; field = $Field; snapshot = $Snapshot; uia = $UiaValue; match = ("$Snapshot" -ceq "$UiaValue") })
    }

    $main = Get-UiaMainWindow $Uia
    $nodes = @(if ($main) { Get-UiaNodes $main.uia })
    $buttons = @($nodes | Where-Object { $_.controlType -eq 'Button' })

    # Banner: the state text has no AutomationId; it is the first Text after the manual-submit button
    # (MainWindow.xaml: scan box, 手动提交, then the banner's StateText).
    $anchorName = (@($State.buttons | Where-Object { $_.key -eq 'ManualSubmitCommand' }) | Select-Object -First 1).content ?? '手动提交'
    $bannerNode = $null
    $afterAnchor = $false
    foreach ($node in $nodes) {
        if ($afterAnchor -and $node.controlType -eq 'Text') { $bannerNode = $node; break }
        if (-not $afterAnchor -and $node.controlType -eq 'Button' -and $node.name -ceq $anchorName) { $afterAnchor = $true }
    }
    Row 'banner' 'StateText' 'text' $State.banner.stateText ($bannerNode ? $bannerNode.name : "<no Text after the '$anchorName' button>")

    $optionContainer = @($nodes | Where-Object { $_.automationId -eq 'UnableToChargeOptions' }) | Select-Object -First 1
    $optionButtons = @(if ($optionContainer) { Get-UiaNodes $optionContainer | Where-Object { $_.controlType -eq 'Button' } })
    foreach ($button in @($State.buttons)) {
        if ($null -ne $button.options) {
            # The template button: one UIA button per option, found under its ItemsControl or by AutomationId.
            $ids = @($button.options | ForEach-Object { $_.automationId })
            $seen = @(@($optionButtons) + @($buttons | Where-Object { $_.automationId -in $ids }) | Sort-Object automationId -Unique)
            $expected = $button.visible ? $ids : @()
            Row 'button' $button.key 'options' (($expected | Sort-Object) -join ',') ((@($seen | ForEach-Object { $_.automationId }) | Sort-Object) -join ',')
            if ($button.visible -and $seen.Count) {
                Row 'button' $button.key 'enabled' $button.enabled (@($seen | Where-Object { -not $_.isEnabled }).Count -eq 0)
            }
            continue
        }
        $matched = if ($button.automationId) {
            @($buttons | Where-Object { $_.automationId -ceq $button.automationId })
        } else {
            @($buttons | Where-Object { -not $_.automationId -and $_.name -ceq $button.content })
        }
        if ($matched.Count -gt 1) {
            Row 'button' $button.key 'unique' 'one element' "$($matched.Count) elements named '$($button.content)'"
            continue
        }
        Row 'button' $button.key 'visible' $button.visible ($matched.Count -eq 1)
        if ($button.visible -and $matched.Count -eq 1) { Row 'button' $button.key 'enabled' $button.enabled ([bool] $matched[0].isEnabled) }
    }

    $edits = @($nodes | Where-Object { $_.controlType -eq 'Edit' })
    foreach ($box in @($State.inputs)) {
        $matched = @($edits | Where-Object { $_.automationId -ceq $box.key })
        if ($matched.Count -gt 1) { Row 'input' $box.key 'unique' 'one element' "$($matched.Count) elements"; continue }
        Row 'input' $box.key 'visible' $box.visible ($matched.Count -eq 1)
        if ($box.visible -and $matched.Count -eq 1) {
            Row 'input' $box.key 'enabled' $box.enabled ([bool] $matched[0].isEnabled)
            $hasText = if ($matched[0].PSObject.Properties['value']) { -not [string]::IsNullOrEmpty($matched[0].value) } else { '<no value pattern>' }
            Row 'input' $box.key 'hasText' $box.hasText $hasText
        }
    }

    $dialogs = @($Uia.hmiWindows | Where-Object { $_.className -eq '#32770' -and $_.visible })
    Row 'modal' 'dialogs' 'depth' $State.modals.depth $dialogs.Count
    Row 'modal' 'dialogs' 'titles' ((@($State.modals.open | ForEach-Object { $_.title }) | Sort-Object) -join ' | ') ((@($dialogs | ForEach-Object { $_.title }) | Sort-Object) -join ' | ')

    foreach ($code in @($State.rawCodes)) {
        $matched = @($nodes | Where-Object { $_.automationId -ceq $code.automationId })
        if ($matched.Count -gt 1) { Row 'rawCode' $code.automationId 'unique' 'one element' "$($matched.Count) elements"; continue }
        Row 'rawCode' $code.automationId 'visible' $code.visible ($matched.Count -eq 1)
        if ($code.visible -and $matched.Count -eq 1) { Row 'rawCode' $code.automationId 'value' $code.value ($matched[0].itemStatus ?? '') }
    }
    return $rows.ToArray()
}

<# Whether a UIA reading is complete enough that "not in the tree" means "not visible". #>
function Get-UiaCompleteness {
    param($Uia)
    if (-not $Uia) { return 'no UIA result' }
    if ($Uia.uiaTruncated) { return "the UIA walk hit its node cap ($($Uia.uiaNodeCount) nodes)" }
    $main = Get-UiaMainWindow $Uia
    if (-not $main) { return 'no visible HMI main window with a UIA tree' }
    $cut = @(Get-UiaNodes $main.uia | Where-Object { $_.PSObject.Properties['truncated'] })
    if ($cut.Count) { return "the UIA walk was cut short ($(@($cut | ForEach-Object truncated | Sort-Object -Unique) -join ', '))" }
    return $null
}

<#
    The cross-check's outcome. Pure. Compares only when nothing moved around the UIA reading: same process,
    same content revision before and after, and UIA read that very process.
#>
function Get-CrossCheckVerdict {
    param($Before, $After, [string] $CaptureOutcome, $Uia, [object[]] $Rows)
    if ($Before.outcome -ne 'ACTIVE') { return [ordered]@{ outcome = $Before.outcome; detail = "first read: $($Before.detail)" } }
    if ($CaptureOutcome -notin 'CAPTURED', 'DESKTOP_LOCKED') { return [ordered]@{ outcome = 'CAPTURE_FAILED'; detail = "the UIA reading ended $CaptureOutcome" } }
    $incomplete = Get-UiaCompleteness $Uia
    if ($incomplete) { return [ordered]@{ outcome = 'CAPTURE_FAILED'; detail = $incomplete } }
    if ($After.outcome -ne 'ACTIVE') { return [ordered]@{ outcome = 'MOVING'; detail = "second read: $($After.outcome) ($($After.detail))" } }
    if ($Before.processStartId -ne $After.processStartId) { return [ordered]@{ outcome = 'MOVING'; detail = 'the HMI restarted around the UIA reading' } }
    if ($Before.contentRevision -ne $After.contentRevision) { return [ordered]@{ outcome = 'MOVING'; detail = "contentRevision moved from $($Before.contentRevision) to $($After.contentRevision) around the UIA reading" } }
    $uiaPids = @($Uia.hmi.processes | ForEach-Object { $_.id })
    if ($Before.processId -notin $uiaPids) { return [ordered]@{ outcome = 'MOVING'; detail = "UIA read process(es) $($uiaPids -join ', '), the snapshot is from $($Before.processId)" } }
    $differences = @($Rows | Where-Object { -not $_.match })
    if ($differences.Count) { return [ordered]@{ outcome = 'MISMATCH'; detail = "$($differences.Count) of $(@($Rows).Count) compared field(s) differ" } }
    return [ordered]@{ outcome = 'MATCH'; detail = "$(@($Rows).Count) compared field(s), no difference" }
}

<#
    17's own outcome rule, lifted out of its syntax tree (17 has no dot-source exit that skips its
    mandatory parameters), so the local UIA reading is judged by the same rule as the remote one.
#>
function Import-CaptureOutcomeRule {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($captureScript17, [ref] $null, [ref] $null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CaptureOutcome' }, $true)
    if (-not $fn) { throw "no Get-CaptureOutcome in $captureScript17" }
    return $fn.Extent.Text
}

function Format-Summary {
    param($Verdict)
    $doc = $Verdict.document
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("  file: status $($doc.status ?? '-'), contentRevision $($Verdict.contentRevision ?? '-'), writtenAt $($doc.writtenAt ?? '-') (age $($Verdict.ageSeconds ?? '-') s on the vehicle clock), process $($Verdict.processId ?? '-'), program $($doc.programVersion ?? '-')")
    $state = $doc.state
    if (-not $state) { return $lines }
    $banner = $state.banner
    $lines.Add("  banner: $($banner.stateText) (from $($banner.source)$(if ($banner.hasError) { ', error' } elseif ($banner.hasWarning) { ', warning' }))")
    if ($state.operatorNotice) { $lines.Add("  operator notice until $($state.operatorNotice.until): $($state.operatorNotice.text)") }
    if ($state.modals.depth) { $lines.Add("  modal dialog(s) open: $(@($state.modals.open | ForEach-Object { $_.title }) -join ' > ')") }
    $visibleButtons = @($state.buttons | Where-Object visible | ForEach-Object {
            $label = $_.content ?? (@($_.options | ForEach-Object label) -join '/')
            "$label[$($_.enabled ? '可按' : '不可按')]"
        })
    $lines.Add("  buttons shown: $(if ($visibleButtons.Count) { $visibleButtons -join ' ' } else { '(none)' })")
    $inputs = @($state.inputs | Where-Object visible | ForEach-Object { "$($_.key)[$($_.enabled ? 'enabled' : 'disabled'), $($_.hasText ? 'has text' : 'empty')]" })
    if ($inputs.Count) { $lines.Add("  input boxes shown: $($inputs -join ' ')") }
    $codes = @($state.rawCodes | Where-Object { $_.visible -and $_.value } | ForEach-Object { "$($_.automationId)=$($_.value)" })
    if ($codes.Count) { $lines.Add("  raw codes: $($codes -join ' ')") }
    if ($state.stationDepartureCountdown.visible) { $lines.Add("  departure countdown: $($state.stationDepartureCountdown.tier), deadline $($state.stationDepartureCountdown.deadlineAt)") }
    return $lines
}

function Format-Timeline {
    param($Read, [int] $Count)
    if ($Read.timelineError) { return @("  timeline: reading failed: $($Read.timelineError)") }
    if (-not $Read.timeline) { return @('  timeline: no hmi-state-yyyyMMdd.ndjson') }
    $text = ConvertFrom-Base64Utf8 $Read.timeline.base64
    $lines = @($text -split "`r?`n" | Where-Object { $_ })
    # A tail that starts mid-file starts mid-line.
    if ($Read.timeline.offset -gt 0 -and $lines.Count) { $lines = @($lines | Select-Object -Skip 1) }
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("  timeline $($Read.timeline.name) ($($Read.timeline.length) bytes), last $([Math]::Min($Count, $lines.Count)):")
    foreach ($line in @($lines | Select-Object -Last $Count)) {
        try {
            $entry = $line | ConvertFrom-Json -DateKind String
            $out.Add("    $($entry.writtenAt)  rev $($entry.contentRevision)  $($entry.status)  $($entry.state.banner.stateText) ($($entry.state.banner.source))")
        } catch { $out.Add('    (a line that is not JSON)') }
    }
    return $out
}

function Invoke-SelfTest {
    $failures = [System.Collections.Generic.List[string]]::new()
    function Check([string] $Name, [scriptblock] $Body) {
        try { & $Body; "PASS $Name" } catch { $failures.Add($Name); "FAIL $Name -- $($_.Exception.Message)" }
    }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) "hmi316-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        . (Join-Path $PSScriptRoot '18-read-hmi-screen-state.selftest.ps1')
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    "SELFTEST $(if ($failures.Count -eq 0) { 'PASS' } else { "FAIL ($($failures -join '; '))" }) ($($failures.Count) failed)"
    if ($failures.Count -ne 0) { exit 1 }
}

# Dot-sourced by an off-vehicle test: define the functions and stop.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($PSCmdlet.ParameterSetName -eq 'SelfTest') { Invoke-SelfTest; return }

if ($CrossCheck -and -not $EvidenceDirectory) { throw '-CrossCheck needs -EvidenceDirectory.' }
if ($EvidenceDirectory) {
    New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
    $EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
}
# Named by the control host's clock: the vehicles' clocks have been months off before (fleet.md).
$name = '{0}-{1}' -f ($Local ? 'local' : $SshAlias), (Get-Date -Format 'yyyyMMdd\THHmmss')
$record = [ordered]@{
    tool = '18-read-hmi-screen-state'; mode = $CrossCheck ? 'crosscheck' : 'read'; target = $Local ? "local:$Directory" : "${SshAlias}:$VehicleDirectory"
    name = $name; startedAt = [DateTimeOffset]::Now.ToString('o'); staleAfterSeconds = $StaleAfterSeconds
    outcome = $null; detail = $null; error = $null
}

function Save-Document([string] $Suffix, $Read) {
    if (-not $EvidenceDirectory -or -not $Read.current) { return }
    # The decoded file as it was on the vehicle; it holds no input text or credential (content boundary, research 4.1).
    $path = Join-Path $EvidenceDirectory "$name-$Suffix.json"
    [System.IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($Read.current.base64))
}

function Write-Verdict([string] $Label, $Verdict) {
    $colour = $Verdict.outcome -eq 'ACTIVE' ? 'Green' : 'Yellow'
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Label $($Verdict.outcome): $($Verdict.detail)" -ForegroundColor $colour
    Format-Summary $Verdict | ForEach-Object { Write-Host $_ }
}

function Select-VerdictRecord($Verdict) {
    $copy = [ordered]@{}
    foreach ($key in $Verdict.Keys) { if ($key -ne 'document') { $copy[$key] = $Verdict[$key] } }
    return $copy
}

try {
    $first = Invoke-StateRead
    $before = Get-SnapshotVerdict -Read $first -StaleAfterSeconds $StaleAfterSeconds
    Save-Document ($CrossCheck ? 'state-before' : 'state') $first
    Write-Verdict ($CrossCheck ? 'first read' : 'read') $before
    if ($TimelineLines -gt 0) { Format-Timeline $first $TimelineLines | ForEach-Object { Write-Host $_ } }
    $record.read = Select-VerdictRecord $before
    $record.outcome = $before.outcome
    $record.detail = $before.detail

    if ($CrossCheck -and $before.outcome -eq 'ACTIVE') {
        $captureStarted = Get-Date
        $captureOutcome = $null
        $uia = $null
        if ($Local) {
            $stamp = "$name-uia"
            $script = $CaptureScript ? $CaptureScript : $vehicleCaptureScript
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] UIA reading of process $($before.processId) in this session ($script)"
            & pwsh -NoProfile -NonInteractive -File $script -OutputDirectory $EvidenceDirectory -Stamp $stamp -ProcessName $ProcessName -ProcessId $before.processId 2>&1 | ForEach-Object { Write-Host "  $_" }
            $uiaFile = Join-Path $EvidenceDirectory "$stamp-uia.json"
            if (Test-Path -LiteralPath $uiaFile) {
                $uia = Get-Content -LiteralPath $uiaFile -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
                . ([scriptblock]::Create((Import-CaptureOutcomeRule)))
                # Same session, nothing launched: the preflight's three refusals do not apply.
                $captureOutcome = Get-CaptureOutcome ([pscustomobject]@{ consoleSessionId = 1; wshDisabled = $false; otherDesktopTools = @() }) $uia $false
            } else {
                $captureOutcome = 'TOOL_FAILURE'
            }
        } else {
            $script = $CaptureScript ? $CaptureScript : $captureScript17
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] UIA reading through $script"
            & pwsh -NoProfile -NonInteractive -File $script -SshAlias $SshAlias -EvidenceDirectory $EvidenceDirectory -TimeoutSeconds $CaptureTimeoutSeconds 2>&1 | ForEach-Object { Write-Host "  $_" }
            $runFile = @(Get-ChildItem -LiteralPath $EvidenceDirectory -Filter "$SshAlias-*-run.json" -File | Where-Object LastWriteTime -ge $captureStarted.AddSeconds(-1) | Sort-Object LastWriteTime) | Select-Object -Last 1
            if ($runFile) {
                $run = Get-Content -LiteralPath $runFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
                $captureOutcome = $run.outcome
                $uiaFile = Join-Path $EvidenceDirectory "$($run.name)-uia.json"
                if (Test-Path -LiteralPath $uiaFile) { $uia = Get-Content -LiteralPath $uiaFile -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String }
            } else {
                $captureOutcome = 'TOOL_FAILURE'
            }
        }
        $record.capture = [ordered]@{ outcome = $captureOutcome; uiaFile = $uiaFile; seconds = [Math]::Round(((Get-Date) - $captureStarted).TotalSeconds, 1) }

        Start-Sleep -Milliseconds $SettleMilliseconds
        $second = Invoke-StateRead
        $after = Get-SnapshotVerdict -Read $second -StaleAfterSeconds $StaleAfterSeconds
        Save-Document 'state-after' $second
        Write-Verdict 'second read' $after
        $record.secondRead = Select-VerdictRecord $after

        $rows = @(if ($before.document.state -and $uia) { Compare-ScreenState $before.document.state $uia })
        $verdict = Get-CrossCheckVerdict -Before $before -After $after -CaptureOutcome $captureOutcome -Uia $uia -Rows $rows
        $record.outcome = $verdict.outcome
        $record.detail = $verdict.detail
        $record.rows = $rows
        if ($verdict.outcome -in 'MATCH', 'MISMATCH') {
            $differences = @($rows | Where-Object { -not $_.match })
            Write-Host "  compared $($rows.Count) field(s): banner, buttons, input boxes, modal dialogs, raw codes"
            if ($differences.Count) {
                Write-Host '  differences (category | key | field | snapshot | UIA):' -ForegroundColor Yellow
                foreach ($d in $differences) { Write-Host "    $($d.category) | $($d.key) | $($d.field) | $($d.snapshot) | $($d.uia)" -ForegroundColor Yellow }
            }
        }
    }
} catch {
    $record.error = $_.Exception.Message
    $record.outcome = 'TOOL_FAILURE'
    $record.detail = $_.Exception.Message
}

$record.finishedAt = [DateTimeOffset]::Now.ToString('o')
if ($EvidenceDirectory) {
    $recordFile = Join-Path $EvidenceDirectory "$name-$($CrossCheck ? 'crosscheck' : 'read').json"
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordFile -Encoding utf8NoBOM
}
$colour = $record.outcome -in 'ACTIVE', 'MATCH' ? 'Green' : 'Yellow'
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($record.outcome): $($record.detail)" -ForegroundColor $colour
if ($EvidenceDirectory) { Write-Host "  $recordFile" }
# ?? 1: a missing key must never exit 0 (exit $null does). -SelfTest checks every outcome has a key.
exit ($exitCodes[$record.outcome] ?? 1)
