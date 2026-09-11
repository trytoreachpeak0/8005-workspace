#Requires -Version 7
<#
.SYNOPSIS
    Opens the onboard client's automation face on a vehicle running in
    Production, and closes it again with -Revert. Runs on the control host and
    reaches only the vehicle.

.DESCRIPTION
    An unattended field window plays the operator through two loopback faces on
    the vehicle (8005-agv-control-server scripts/field/FieldOperator.psm1, Remote
    mode). One of them, the onboard client's automation face on 127.0.0.1:58007,
    ships shut: the production template renders automation.enabled false, and
    06-deploy-onboard-hmi.ps1 renders that template every time.

    Turning it on in Production takes two fields, not one.
    SQCD.Agv.Infrastructure/Configuration.cs (OnboardAutomationSettings.Validate)
    refuses to start the client when automation.enabled is true in Production
    and automation.productionReviewReference is empty or a template placeholder.
    That reference is where the decision permitting the face is recorded, so this
    script takes it as a mandatory parameter with no default: a default would be
    a permission anyone could copy by running the script.

    Three things this script refuses, each because it has already cost a run:

    1. A running client. The face lives inside SQCD.Agv.Wpf; a changed file
       takes effect only at a restart nobody asked for, and -Revert under a
       running client would report the face closed while it is still answering.
       Stop it first with 10-start-onboard-stack.ps1 -Stop.

    2. Drift. ConvertTo-Json truncates silently past its -Depth and rewrites
       dates it recognises, and this file decides whether the vehicle's client
       starts at all. So every leaf of the file is compared before and after,
       the only differences allowed are the two fields named above, and anything
       else restores the backup and fails.

    3. A face the client would refuse anyway. The other half of Validate --
       loopback listen address, a port distinct from wireToGate.port and
       ioModule.port, wireToGate.enabled -- is checked before anything is
       written, because a refusal there is a client that throws at startup.

    Like 14-set-recovery-window.ps1, this is deliberately NOT folded into the
    deployment scripts. Shut is the factory setting. The consequence is the other
    way round: re-running 06-deploy-onboard-hmi.ps1 during a window renders the
    face shut again, and the field driver's preflight then refuses the window.
    Re-run this script after any redeployment inside a window.

    The face cannot dispatch a vehicle. Moving it stays with
    Set-JourneyRuntime.ps1 -Dispatch and its per-window authorisation, and the
    recovery requests the face can send still need 14-set-recovery-window.ps1.

    This changes what a vehicle can be asked to do. It starts nothing: the
    client is left stopped.

.PARAMETER ReviewReference
    The URL of the record permitting the face on this vehicle. Written verbatim
    into automation.productionReviewReference. For agv01 that record is
    https://github.com/trytoreachpeak0/8005-agv-program/issues/44#issuecomment-5632670629
    -- it covers agv01 only; another vehicle needs its own.

.PARAMETER Revert
    Close the face: automation.enabled back to false and
    automation.productionReviewReference removed.

.EXAMPLE
    pwsh -NoProfile -File 15-set-automation-face.ps1 -ReviewReference 'https://github.com/trytoreachpeak0/8005-agv-program/issues/44#issuecomment-5632670629'

.EXAMPLE
    pwsh -NoProfile -File 15-set-automation-face.ps1 -Revert
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Open')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Open')]
    [string]$ReviewReference,

    [Parameter(Mandatory, ParameterSetName = 'Revert')]
    [switch]$Revert,

    [string]$SshAlias = 'agv01',

    [string]$InstallRoot = 'C:\8005\OnboardHmi',

    # The same scratch directory 06-deploy-onboard-hmi.ps1 stages into.
    [string]$StagingRoot = 'C:\temp\agv\onboard-staging'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# .Replace rather than -replace: the right-hand side of -replace is a regular
# expression, where a lone backslash is an error rather than a backslash.
$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RemoteDirectory
    )
    $local = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-$(Get-Random).ps1"
    Set-Content -LiteralPath $local -Value $Body -Encoding utf8NoBOM -WhatIf:$false
    try {
        $remote = "$RemoteDirectory\$Name.ps1"
        & ssh $Alias "pwsh -NoLogo -NoProfile -Command `"New-Item -ItemType Directory -Force -Path '$RemoteDirectory' | Out-Null`""
        if ($LASTEXITCODE -ne 0) { throw "ssh $Alias failed preparing $RemoteDirectory (exit $LASTEXITCODE)" }
        & scp -q $local "${Alias}:$(& $toPosix $remote)"
        if ($LASTEXITCODE -ne 0) { throw "scp to $Alias failed (exit $LASTEXITCODE)" }
        $output = & ssh $Alias "pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File '$remote'" 2>&1
        $exit = $LASTEXITCODE
        $output | ForEach-Object { Write-Host "  $_" }
        & ssh $Alias "pwsh -NoLogo -NoProfile -Command `"Remove-Item -LiteralPath '$remote' -Force`"" | Out-Null
        if ($exit -ne 0) { throw "$Name failed on $Alias (exit $exit)" }
    } finally {
        Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# ----------------------------------------------------------------- reference ---

if (-not $Revert) {
    $uri = $null
    if (-not [Uri]::TryCreate($ReviewReference.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw "-ReviewReference must be an absolute https URL naming the record that permits the face; got '$ReviewReference'."
    }
    # Mirrors OnboardSettings.IsPlaceholderValue. Failing here costs nothing;
    # failing in the client costs a start that throws on the vehicle.
    foreach ($marker in 'REPLACE', 'EXAMPLE', 'CHANGEME', 'YOUR_', 'YOUR-', 'TODO') {
        if ($ReviewReference.Contains($marker, [StringComparison]::OrdinalIgnoreCase)) {
            throw "-ReviewReference contains '$marker', which the client treats as a template placeholder and refuses."
        }
    }
    $ReviewReference = $ReviewReference.Trim()
}

$action = $Revert ? 'Close' : 'Open'
if (-not $PSCmdlet.ShouldProcess($SshAlias, "$action the onboard automation face")) {
    Write-Step 'WhatIf: stopping before the vehicle is touched.'
    Write-Step ("Would set automation.enabled to {0} in $InstallRoot\appsettings.json" -f (-not $Revert).ToString().ToLowerInvariant())
    Write-Step ($Revert ? 'Would remove automation.productionReviewReference' : "Would set automation.productionReviewReference to $ReviewReference")
    return
}

# ------------------------------------------------------------------- vehicle ---

# The request travels as base64 JSON rather than being spliced into the script
# text: a URL fragment, a quote or a dollar sign in it must not become code.
$request = @{
    installRoot     = $InstallRoot
    enable          = -not $Revert
    reviewReference = $Revert ? $null : $ReviewReference
} | ConvertTo-Json -Compress
$requestBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))

$vehicleBody = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@REQUEST@@')) | ConvertFrom-Json -AsHashtable
$enable = [bool]$request['enable']
$reference = $request['reviewReference']

$settingsPath = Join-Path $request['installRoot'] 'appsettings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    throw "No onboard installation at $($request['installRoot']) -- deploy it first with 06-deploy-onboard-hmi.ps1."
}

# The face lives inside the client. Editing its file under a running client
# changes nothing until a restart nobody asked for -- and a -Revert would report
# the face closed while it is still answering.
if (@(Get-Process -Name 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'SQCD.Agv.Wpf is running on the vehicle. Stop it first (10-start-onboard-stack.ps1 -Stop).'
}

# -DateKind String: without it ConvertFrom-Json turns date-shaped strings into
# DateTime and ConvertTo-Json writes them back in another format.
function Read-Settings([string]$Path) {
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -DateKind String -Depth 64)
}

# Ordinal, and every comparison below is -cne: [ordered]@{} keys and -ne on
# strings are both case-insensitive, and a drift in casing is still a drift.
function New-LeafMap {
    return [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
}

# The comparison reads the file with System.Text.Json, not ConvertFrom-Json: a
# check that parses the same way the edit does cannot see what that parse
# changes -- a date rewritten as the same instant in another offset reads back
# as an equal DateTime. Strings compare by decoded value, everything else by its
# JSON text.
function Get-FileLeaves([string]$File) {
    $into = New-LeafMap
    $document = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($File))
    try {
        Add-Leaves -Element $document.RootElement -Path '' -Into $into
    } finally {
        $document.Dispose()
    }
    return $into
}

function Add-Leaves {
    param([System.Text.Json.JsonElement]$Element, [string]$Path, [System.Collections.IDictionary]$Into)
    switch ($Element.ValueKind) {
        'Object' {
            $count = 0
            foreach ($property in $Element.EnumerateObject()) {
                $count++
                Add-Leaves -Element $property.Value -Path ($Path ? "$Path.$($property.Name)" : $property.Name) -Into $Into
            }
            if ($count -eq 0) { $Into[$Path] = '{}' }
        }
        'Array' {
            $index = 0
            foreach ($item in $Element.EnumerateArray()) {
                Add-Leaves -Element $item -Path "$Path[$index]" -Into $Into
                $index++
            }
            if ($index -eq 0) { $Into[$Path] = '[]' }
        }
        'String' { $Into[$Path] = 'string:' + $Element.GetString() }
        default { $Into[$Path] = $Element.GetRawText() }
    }
}

$settings = Read-Settings $settingsPath
$automation = $settings['automation']
if ($automation -isnot [System.Collections.IDictionary] -or -not $automation.Contains('enabled')) {
    throw 'appsettings.json carries no automation.enabled. This package predates the automation face.'
}

if ($enable) {
    # The rest of OnboardAutomationSettings.Validate. Each of these is a client
    # that throws at startup, so none of them is worth writing the file for.
    $wireToGate = $settings['wireToGate']
    $ioModule = $settings['ioModule']
    if ($wireToGate -isnot [System.Collections.IDictionary] -or $ioModule -isnot [System.Collections.IDictionary]) {
        throw 'appsettings.json carries no wireToGate or ioModule section; this is not a rendered production configuration.'
    }
    $listen = [string]($automation['listenAddress'] ?? '127.0.0.1')
    $port = [int]($automation['port'] ?? 58007)
    $wireToGatePort = [int]($wireToGate['port'] ?? 58005)
    $ioModulePort = [int]($ioModule['port'] ?? 1502)
    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($listen, [ref]$address) -or -not [System.Net.IPAddress]::IsLoopback($address)) {
        throw "automation.listenAddress is '$listen'. The client only opens the face on loopback."
    }
    if ($port -lt 1 -or $port -gt 65535 -or $port -eq $wireToGatePort -or $port -eq $ioModulePort) {
        throw "automation.port $port collides with wireToGate.port $wireToGatePort or ioModule.port $ioModulePort, or is out of range."
    }
    if (-not [bool]$wireToGate['enabled']) {
        throw 'wireToGate.enabled is false. The client only opens the face with WIRE_TO_GATE on.'
    }
}

$before = Get-FileLeaves $settingsPath

# What the two fields must read afterwards. $null means absent.
$expected = New-LeafMap
$expected['automation.enabled'] = $enable ? 'true' : 'false'
$expected['automation.productionReviewReference'] = $enable ? "string:$reference" : $null

# The binder matches keys case-insensitively, so a key that differs from one of
# the two only by casing is the same setting: it has to be gone afterwards.
function Get-Expectation([string]$Path) {
    foreach ($key in $expected.Keys) {
        if ($key -ceq $Path) { return @{ Governed = $true; Value = $expected[$key] } }
        if ($key -ieq $Path) { return @{ Governed = $true; Value = $null } }
    }
    return @{ Governed = $false; Value = $null }
}

$alreadyThere = @(@($before.Keys) + @($expected.Keys) | Select-Object -Unique | Where-Object {
    $expectation = Get-Expectation $_
    $expectation.Governed -and $before[$_] -cne $expectation.Value
}).Count -eq 0
if ($alreadyThere) {
    "already $($enable ? 'open' : 'closed'); nothing written"
} else {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path (Split-Path -Parent $request['installRoot']) "appsettings-backup-automation-face-$($enable ? 'open' : 'close')-$stamp.json"
    Copy-Item -LiteralPath $settingsPath -Destination $backupPath
    "backup: $backupPath"

    $automation['enabled'] = $enable
    # Any casing the binder would also accept, so a -Revert cannot leave one behind.
    foreach ($key in @($automation.Keys | Where-Object { $_ -ieq 'productionReviewReference' })) { $automation.Remove($key) }
    if ($enable) { $automation['productionReviewReference'] = $reference }

    $settings | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $settingsPath -Encoding utf8NoBOM
}

# Read the file back rather than trusting the write, and compare every leaf.
$after = Get-FileLeaves $settingsPath

$problems = [System.Collections.Generic.List[string]]::new()
foreach ($path in @(@($before.Keys) + @($after.Keys) | Select-Object -Unique)) {
    $was = $before.Contains($path) ? $before[$path] : $null
    $now = $after.Contains($path) ? $after[$path] : $null
    $expectation = Get-Expectation $path
    if ($expectation.Governed) {
        if ($now -cne $expectation.Value) { $problems.Add("$path is $($now ?? '(absent)'), expected $($expectation.Value ?? '(absent)')") }
        "${path}: $($was ?? '(absent)') -> $($now ?? '(absent)')"
    } elseif ($was -cne $now) {
        $problems.Add("$path drifted: $($was ?? '(absent)') -> $($now ?? '(absent)')")
    }
}
"other leaves compared: $(@($before.Keys | Where-Object { -not (Get-Expectation $_).Governed }).Count), unchanged"

if ($problems.Count -gt 0) {
    if (-not $alreadyThere) {
        Copy-Item -LiteralPath $backupPath -Destination $settingsPath -Force
        "restored $settingsPath from $backupPath"
    }
    $problems | ForEach-Object { "DRIFT: $_" }
    exit 1
}
'@
$vehicleBody = $vehicleBody.Replace('@@REQUEST@@', $requestBase64)

Write-Step "$action the automation face on $SshAlias"
Invoke-RemoteScript -Alias $SshAlias -Body $vehicleBody -Name 'set-automation-face' -RemoteDirectory $StagingRoot

# --------------------------------------------------------------------- after ---

if ($Revert) {
    Write-Step 'Automation face closed. The client is still stopped.'
} else {
    Write-Step 'Automation face open. The client is still stopped -- starting it is yours (10-start-onboard-stack.ps1).'
    Write-Host ''
    Write-Host '  Close it again when the window ends:' -ForegroundColor DarkGray
    Write-Host '    pwsh -NoProfile -File 15-set-automation-face.ps1 -Revert' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Re-deploying the onboard client renders the face shut again.' -ForegroundColor DarkGray
    Write-Host '  Re-run this script if you do.' -ForegroundColor DarkGray
}
