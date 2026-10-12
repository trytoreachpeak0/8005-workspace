#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for 06-deploy-onboard-hmi.ps1's choice of vehicle-safety credential (control-server#600).

.DESCRIPTION
    Lifts Resolve-VehicleSafetyCredential out of the deploy script by its AST -- the script itself is never run,
    nothing reaches a vehicle, and no secret store is read -- and drives it with the shapes a rendered template and a
    store can take.

    What it pins:
      * a template whose projection reads the session's own variable (the MVP onboard, agv01) keeps the shared
        credential, as before;
      * a template with a separate projection variable takes this vehicle's own credential from the store;
      * without one, it is refused -- unless -SharedSafetyCredential says the server is a single-car one, which accepts
        only the shared credential;
      * another vehicle's credential is never chosen;
      * the deploy script parses, and its probe and its machine variable use what this function chose.

    And the IO target (workspace#28), first through Resolve-OnboardIoTarget lifted the same way, then by running the
    whole deploy script with -WhatIf against an ssh shim on PATH, a fake package, site file and secret store, and an
    alias that resolves nowhere (so a bypassed shim fails to resolve rather than reaching a vehicle):
      * a vehicle on the simulator is never switched to the real module without -UseSiteIo: refused, naming both
        switches; -KeepCurrentIo keeps 127.0.0.1:1502; -UseSiteIo takes the site module, says it needs the user's
        authorisation, and warns;
      * a vehicle on the real module (agv01) and a first deployment render the site value without a switch, as before;
      * -KeepCurrentIo on a first deployment, or on an installed configuration it cannot read, is refused;
      * an installed configuration it cannot read counts as maybe-simulator; the two switches exclude each other;
      * every case prints the summary line; the place script reads ioModule back on the vehicle.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/Test-DeployOnboardHmi.ps1
#>
[CmdletBinding()]
param(
    # Mutation runs point this at an edited copy; normally the sibling script.
    [string] $DeployScript = (Join-Path $PSScriptRoot '06-deploy-onboard-hmi.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$source = (Resolve-Path -LiteralPath $DeployScript).Path
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
Write-Result -Ok (@($errors).Count -eq 0) -Name '06-deploy-onboard-hmi.ps1 parses' -Detail (@($errors) -join ' | ')
foreach ($name in @('Resolve-VehicleSafetyCredential', 'Assert-VehicleSafetyEndpointNamesVehicle', 'Test-SimulatorIoHost', 'Get-IoTargetKind', 'Resolve-OnboardIoTarget')) {
    $definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Write-Result -Ok ($null -ne $definition) -Name "$name is defined in 06-deploy-onboard-hmi.ps1" -Detail 'missing'
    if ($null -eq $definition) {
        Write-Host ''
        Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Red
        exit 1
    }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$agv02Key = 'BROKERX-f38975561adf46ccb1d2f23833c7d0e4'
$agv03Key = 'BROKERX-7daca4ee91da498d8026c68b7b941127'
$session = 'CONTROL_SERVER_ONBOARD_CREDENTIAL'
$safety = 'CONTROL_SERVER_ONBOARD_SAFETY_CREDENTIAL'
$storeBoth = @('OnboardCredential', 'OperatorId', "OnboardSafetyCredential:$agv02Key", "OnboardSafetyCredential:$agv03Key")

function Invoke-Resolve([hashtable] $Arguments) {
    try { return @{ Value = (Resolve-VehicleSafetyCredential @Arguments); Error = $null } }
    catch { return @{ Value = $null; Error = $_.Exception.Message } }
}

Write-Host 'Vehicle-safety credential choice (control-server#600)' -ForegroundColor Cyan
$r = Invoke-Resolve @{ SafetyVariable = $session; SessionVariable = $session; VehicleKey = $agv02Key; StoreKeys = $storeBoth }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.StoreKey -ceq 'OnboardCredential' -and $r.Value.Variable -ceq $session) `
    -Name 'a template sharing the session variable (the MVP onboard) keeps the shared credential' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"

foreach ($own in @($agv02Key, $agv03Key)) {
    $r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $own; StoreKeys = $storeBoth }
    Write-Result -Ok ($null -eq $r.Error -and $r.Value.StoreKey -ceq "OnboardSafetyCredential:$own" -and $r.Value.Variable -ceq $safety) `
        -Name "a separate projection variable takes this vehicle's own credential, never another's ($own)" -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"
}

$r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $agv03Key; StoreKeys = @('OnboardCredential', "OnboardSafetyCredential:$agv02Key") }
Write-Result -Ok ($null -ne $r.Error -and $r.Error.Contains('VEHICLE_SAFETY_CREDENTIAL_MISSING') -and $r.Error.Contains($agv03Key) -and
    $r.Error.Contains('-NewVehicleSafetyCredential') -and $r.Error.Contains('-SharedSafetyCredential')) `
    -Name 'without its own credential the vehicle is refused (another vehicle''s in the store does not stand in)' -Detail "error: $($r.Error)"

$r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $agv03Key; StoreKeys = @('OnboardCredential'); SharedSafetyCredential = $true }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.StoreKey -ceq 'OnboardCredential' -and $r.Value.Variable -ceq $safety) `
    -Name '-SharedSafetyCredential (a single-car server) writes the shared credential into the projection variable' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"

# Review S2: the explicit switch wins. Credentials generated for a two-car instance must not be written for a vehicle being
# deployed against a single-car one, which would answer them 401.
$r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $agv03Key; StoreKeys = $storeBoth; SharedSafetyCredential = $true }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.StoreKey -ceq 'OnboardCredential' -and $r.Value.Variable -ceq $safety -and $r.Value.Reason.Contains('ignored')) `
    -Name '-SharedSafetyCredential wins over a vehicle credential in the store, and says it ignored it' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"

# Review L3: the endpoint's vehicleKey, when it names one, must be the vehicle's own.
function Invoke-EndpointCheck([string] $Endpoint, [string] $Key) {
    try { Assert-VehicleSafetyEndpointNamesVehicle -Endpoint $Endpoint -VehicleKey $Key; return $null } catch { return $_.Exception.Message }
}
$e = Invoke-EndpointCheck "http://172.19.205.222:58107/api/onboard/v1/vehicle-safety?vehicleKey=$agv02Key" $agv03Key
Write-Result -Ok ($null -ne $e -and $e.Contains($agv02Key) -and $e.Contains($agv03Key)) -Name 'an endpoint naming another vehicle is refused' -Detail "error: $e"
$e = Invoke-EndpointCheck "http://172.19.205.222:58107/api/onboard/v1/vehicle-safety?vehicleKey=$agv03Key" $agv03Key
Write-Result -Ok ($null -eq $e) -Name 'an endpoint naming this vehicle passes' -Detail "error: $e"
$e = Invoke-EndpointCheck 'http://172.19.205.222:58007/api/onboard/v1/vehicle-safety' $agv03Key
Write-Result -Ok ($null -eq $e) -Name 'an endpoint naming no vehicle (the MVP template) passes' -Detail "error: $e"

# The place script: the machine variable and the probe both use the chosen credential and the rendered endpoint.
$text = Get-Content -Raw -LiteralPath $source
Write-Result -Ok ($text.Contains("[Environment]::SetEnvironmentVariable('`$(`$safetyChoice.Variable)', '`$(`$safetyCredential)', 'Machine')")) `
    -Name 'the vehicle''s projection variable is set from the chosen credential' -Detail 'SetEnvironmentVariable for the chosen variable not found'
Write-Result -Ok ($text.Contains("Invoke-WebRequest -Uri '`$(`$config.vehicleSafety.endpoint)'") -and $text.Contains("Authorization = 'Bearer `$(`$safetyCredential)'")) `
    -Name 'the probe asks the rendered endpoint (with ?vehicleKey=) with the chosen credential' -Detail 'probe line not found'
# Review S3: PS7's Invoke-WebRequest throws on 401/403, which printed UNREACHABLE and sent people to deploy the server.
Write-Result -Ok ($text.Contains('-SkipHttpErrorCheck') -and $text -match '(?m)^\s*"vehicle-safety `\$\(`\$safety\.StatusCode\)') `
    -Name 'the probe reports the real HTTP status (401/403 are not UNREACHABLE)' -Detail 'SkipHttpErrorCheck or status line not found'
# Review L6: the chosen credential's plain text is cleared on the way out, like the others.
$finally = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $true) |
        Where-Object { $_.Finally.Extent.Text.Contains('$plain.Clear()') -or $_.Finally.Extent.Text.Contains('Remove-Item -LiteralPath $localStage') })
Write-Result -Ok ($finally.Count -ge 1 -and @($finally | Where-Object { $_.Finally.Extent.Text.Contains('$safetyCredential = $null') }).Count -ge 1) `
    -Name 'the finally clears the chosen credential' -Detail "finally blocks: $($finally.Count)"

# ------------------------------------------------------------------------------------------- workspace#28: IO target ---

Write-Host ''
Write-Host 'IO target choice (workspace#28)' -ForegroundColor Cyan

$realSite = '192.168.71.150'
foreach ($h in @('127.0.0.1', '127.0.0.2', '::1', 'localhost', ' LOCALHOST ')) {
    Write-Result -Ok ((Get-IoTargetKind $h $realSite) -ceq 'simulator') -Name "'$h' is the simulator" -Detail "got $(Get-IoTargetKind $h $realSite)"
}
foreach ($h in @($realSite, " $realSite ")) {
    Write-Result -Ok ((Get-IoTargetKind $h $realSite) -ceq 'real') -Name "'$h' is the site's real module" -Detail "got $(Get-IoTargetKind $h $realSite)"
}
# Review S3: the spellings the review found falling to "real module" under the old loopback-or-real split.
foreach ($h in @('localhost.', '127.0.0.1:1502', 'DESKTOP-94OA6CK', '192.168.71.50', '', $null)) {
    Write-Result -Ok ((Get-IoTargetKind $h $realSite) -ceq 'unknown') -Name "'$h' is unknown IO, neither simulator nor the site's module" -Detail "got $(Get-IoTargetKind $h $realSite)"
}

function Invoke-Io([hashtable] $Arguments) {
    $all = @{ SiteHost = $realSite; TemplatePort = 502 }
    foreach ($key in $Arguments.Keys) { $all[$key] = $Arguments[$key] }
    try { return @{ Value = (Resolve-OnboardIoTarget @all); Error = $null } }
    catch { return @{ Value = $null; Error = $_.Exception.Message } }
}

# Every installed state against no switch, -KeepCurrentIo and -UseSiteIo. An expectation is either an error code, or
# the rendered host:port plus whether the switch-to-real-IO warning appears.
$sim = @{ State = 'present'; Host = '127.0.0.1'; Port = 1502 }
$real = @{ State = 'present'; Host = $realSite; Port = 502 }
$absent = @{ State = 'absent' }
$unreadable = @{ State = 'unreadable'; Error = 'Conversion from JSON failed' }
$previousSim = @{ State = 'previous-only'; PreviousHost = '127.0.0.1'; PreviousPort = 1502 }
$previousBroken = @{ State = 'previous-only'; Error = 'Conversion from JSON failed' }
$site = "${realSite}:502"
$matrix = @(
    @{ Name = 'simulator';                     Installed = $sim;            None = 'IO_SIMULATOR_TO_REAL_REFUSED'; Keep = '127.0.0.1:1502';      Use = "$site warn" }
    @{ Name = 'real module (agv01)';           Installed = $real;           None = "$site";                        Keep = "$site";               Use = "$site" }
    @{ Name = 'first deployment';              Installed = $absent;         None = "$site";                        Keep = 'IO_KEEP_NO_INSTALLED_CONFIG'; Use = "$site" }
    @{ Name = 'unreadable';                    Installed = $unreadable;     None = 'IO_SIMULATOR_TO_REAL_REFUSED'; Keep = 'IO_KEEP_UNREADABLE';  Use = "$site warn" }
    @{ Name = 'no host';                       Installed = @{ State = 'present'; Host = ''; Port = 1502 }; None = 'IO_SIMULATOR_TO_REAL_REFUSED'; Keep = 'IO_KEEP_UNREADABLE'; Use = "$site warn" }
    @{ Name = 'port 0';                        Installed = @{ State = 'present'; Host = '127.0.0.1'; Port = 0 }; None = 'IO_SIMULATOR_TO_REAL_REFUSED'; Keep = 'IO_KEEP_UNREADABLE'; Use = "$site warn" }
    @{ Name = 'placeholder host';              Installed = @{ State = 'present'; Host = 'REPLACE_IO_MODULE_IP'; Port = 502 }; None = 'IO_SIMULATOR_TO_REAL_REFUSED'; Keep = 'IO_KEEP_UNREADABLE'; Use = "$site warn" }
    @{ Name = 'unknown localhost.';            Installed = @{ State = 'present'; Host = 'localhost.'; Port = 1502 }; None = 'IO_UNKNOWN_TO_REAL_REFUSED'; Keep = 'localhost.:1502'; Use = "$site warn" }
    @{ Name = 'unknown 127.0.0.1:1502 as host'; Installed = @{ State = 'present'; Host = '127.0.0.1:1502'; Port = 1502 }; None = 'IO_UNKNOWN_TO_REAL_REFUSED'; Keep = '127.0.0.1:1502:1502'; Use = "$site warn" }
    @{ Name = 'unknown machine name';          Installed = @{ State = 'present'; Host = 'DESKTOP-94OA6CK'; Port = 1502 }; None = 'IO_UNKNOWN_TO_REAL_REFUSED'; Keep = 'DESKTOP-94OA6CK:1502'; Use = "$site warn" }
    @{ Name = 'unknown other module';          Installed = @{ State = 'present'; Host = '192.168.71.50'; Port = 502 }; None = 'IO_UNKNOWN_TO_REAL_REFUSED'; Keep = '192.168.71.50:502'; Use = "$site warn" }
    @{ Name = 'only .previous (simulator)';    Installed = $previousSim;    None = 'IO_PREVIOUS_INSTALL_ONLY';     Keep = 'IO_PREVIOUS_INSTALL_ONLY'; Use = "$site warn" }
    @{ Name = 'only .previous (unreadable)';   Installed = $previousBroken; None = 'IO_PREVIOUS_INSTALL_ONLY';     Keep = 'IO_PREVIOUS_INSTALL_ONLY'; Use = "$site warn" }
)
foreach ($row in $matrix) {
    foreach ($mode in @('None', 'Keep', 'Use')) {
        $arguments = @{ Installed = $row.Installed }
        if ($mode -eq 'Keep') { $arguments.KeepCurrentIo = $true }
        if ($mode -eq 'Use') { $arguments.UseSiteIo = $true }
        $expect = $row[$mode]
        $r = Invoke-Io $arguments
        $got = $r.Error ? $r.Error : ('{0}:{1}{2}' -f $r.Value.Host, $r.Value.Port, ($r.Value.Warning ? ' warn' : ''))
        $ok = ($expect -like 'IO_*') ?
            ($null -ne $r.Error -and $r.Error.StartsWith("${expect}:")) :
            ($null -eq $r.Error -and $got -ceq $expect -and $r.Value.Port -is [int] -and $r.Value.Line.StartsWith('IO target: '))
        if ($ok -and $expect -like 'IO_*_REFUSED') {
            $ok = $r.Error.Contains('-KeepCurrentIo') -and $r.Error.Contains('-UseSiteIo')
        }
        if ($ok -and $mode -eq 'Use' -and $expect -notlike 'IO_*') {
            $ok = $r.Value.Line.Contains('REAL IO') -and $r.Value.Line.Contains('authorisation') -and $r.Value.Line.Contains('on site')
        }
        if ($ok -and $mode -eq 'None' -and $expect -notlike 'IO_*') {
            $ok = -not $r.Value.Line.Contains('-UseSiteIo')
        }
        $switchName = @{ None = 'no switch'; Keep = '-KeepCurrentIo'; Use = '-UseSiteIo' }[$mode]
        Write-Result -Ok $ok -Name "$($row.Name) + ${switchName}: $expect" -Detail "got: $got; line: $($r.Value ? $r.Value.Line : '')"
    }
}

$r = Invoke-Io @{ Installed = @{ State = 'present'; Host = '127.0.0.1'; Port = '1502' }; KeepCurrentIo = $true }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.Port -eq 1502 -and $r.Value.Port -is [int]) -Name 'an installed port read as text is kept as the number' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"
$r = Invoke-Io @{ Installed = $sim; SiteHost = '127.0.0.1'; TemplatePort = 1502 }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.Host -ceq '127.0.0.1' -and $null -eq $r.Value.Warning) -Name 'a site file that itself names the simulator is not a switch to real IO' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"
$r = Invoke-Io @{ Installed = $sim; KeepCurrentIo = $true; UseSiteIo = $true }
Write-Result -Ok ($null -ne $r.Error -and $r.Error.Contains('IO_OPTIONS_EXCLUSIVE')) -Name '-KeepCurrentIo and -UseSiteIo together are refused' -Detail "error: $($r.Error)"
$r = Invoke-Io @{ Installed = $sim; UseSiteIo = $true }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.Warning.Contains('simulator 127.0.0.1:1502') -and $r.Value.Warning.Contains("REAL MODULE ${realSite}:502")) `
    -Name 'the switch-to-real-IO warning names both ends' -Detail "got $($r.Value.Warning)"

# Review L2: the read-back in the place script, run for real. The snippet from "$placed = Get-Content" to the
# "ioModule read back" line is taken out of the here-string, expanded the way the deploy script expands it, and run
# against an install root on this machine.
Write-Host ''
Write-Host 'The place script''s read-back and the hand-off summary (workspace#28 review L2)' -ForegroundColor Cyan
$placeAssignment = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$place' }, $true)
$placeText = $placeAssignment ? $placeAssignment.Right.Extent.Text : ''
$from = $placeText.IndexOf('`$placed = Get-Content')
$lastLine = $placeText.IndexOf('"ioModule read back:')
Write-Result -Ok ($from -ge 0 -and $lastLine -gt $from) -Name 'the place script reads the placed configuration and reports ioModule' -Detail "from $from, last $lastLine"
if ($from -ge 0 -and $lastLine -gt $from) {
    $snippet = $placeText.Substring($from, $placeText.IndexOf("`n", $lastLine) - $from)
    $readBackRoot = Join-Path ([IO.Path]::GetTempPath()) "ws28-readback-$PID"
    New-Item -ItemType Directory -Force -Path $readBackRoot | Out-Null
    try {
        function Invoke-ReadBack([string] $PlacedHost, [int] $PlacedPort) {
            $ControlServerHost = '172.19.205.222'; $OnboardPort = 58105
            $ioTarget = [pscustomobject]@{ Host = '127.0.0.1'; Port = 1502 }
            @{ wireToGate = @{ host = $ControlServerHost; port = $OnboardPort }; ioModule = @{ host = $PlacedHost; port = $PlacedPort } } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $readBackRoot 'appsettings.json')
            $code = "`$root = '$readBackRoot'`n" + $ExecutionContext.InvokeCommand.ExpandString($snippet)
            try { return @{ Output = (& ([scriptblock]::Create($code)) | Out-String); Error = $null } }
            catch { return @{ Output = $null; Error = $_.Exception.Message } }
        }
        $rb = Invoke-ReadBack '127.0.0.1' 1502
        Write-Result -Ok ($null -eq $rb.Error -and $rb.Output.Contains('ioModule read back: 127.0.0.1:1502')) `
            -Name 'read-back passes when the placed ioModule is the chosen target' -Detail "error: $($rb.Error); output: $($rb.Output)"
        foreach ($wrong in @(@($realSite, 502), @('127.0.0.1', 502))) {
            $rb = Invoke-ReadBack $wrong[0] $wrong[1]
            Write-Result -Ok ($null -ne $rb.Error -and $rb.Error.Contains("Placed ioModule is $($wrong[0]):$($wrong[1]), expected 127.0.0.1:1502")) `
                -Name "read-back throws when the placed ioModule is $($wrong[0]):$($wrong[1])" -Detail "error: $($rb.Error); output: $($rb.Output)"
        }
    } finally {
        Remove-Item -LiteralPath $readBackRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$text = Get-Content -Raw -LiteralPath $source
Write-Result -Ok ($text -match "Write-Step 'Staged\. NOT started[^\r\n]*\r?\n\s*Write-Step \`$ioTarget\.Line\r?\n\s*if \(\`$ioTarget\.Warning\) \{ Write-Warning \`$ioTarget\.Warning \}") `
    -Name 'the hand-off repeats the IO summary line and the warning after "Staged. NOT started"' -Detail 'hand-off lines not found'

# The whole script, -WhatIf, against an ssh shim. The alias resolves nowhere, so if the shim were bypassed the real ssh
# would fail to resolve the host rather than reach a vehicle; the shim log proves it was the shim that answered.
# Review S1: the shim runs the deploy script's own IO probe, with its install root pointed at a fixture directory, so a
# probe that misreads the vehicle fails here rather than passing on a canned answer.
Write-Host ''
Write-Host 'The deploy script end to end, -WhatIf, ssh shim running the real probe (workspace#28)' -ForegroundColor Cyan
$work = Join-Path ([IO.Path]::GetTempPath()) "ws28-deploy-selftest-$PID"
$fakeAlias = 'ws28-offline-fake'
$commit = 'a' * 39 + 'b'
$savedPath = $env:PATH
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'pkg/onboard-hmi'), (Join-Path $work 'shim') | Out-Null
    @"
{
  "agvId": "AGV-8005-01",
  "onboardInstanceId": "OBU-8005-01",
  "wireToGate": { "enabled": true, "host": "REPLACE_CONTROL_SERVER_IP", "port": 58005, "onboardInstanceId": "REPLACE_WITH_STABLE_UUID",
                  "onboardBuildCommit": "$commit", "credentialEnvironmentVariable": "CONTROL_SERVER_ONBOARD_CREDENTIAL" },
  "vehicleSafety": { "enabled": true, "endpoint": "http://REPLACE_CONTROL_SERVER_HOST/api/onboard/v1/vehicle-safety",
                     "expectedVehicleKey": "REPLACE_WITH_EXPECTED_VEHICLE_KEY", "credentialEnvironmentVariable": "CONTROL_SERVER_ONBOARD_CREDENTIAL" },
  "ruleGateway": { "host": "REPLACE_RULE_SERVER_IP" },
  "ioModule": { "host": "REPLACE_IO_MODULE_IP", "port": 502, "unitId": 255, "doStartAddress": 100, "diStartAddress": 200, "channelCount": 16 }
}
"@ | Set-Content -LiteralPath (Join-Path $work 'pkg/onboard-hmi/appsettings.Production.template.json')
    @{ components = @{ onboardHmi = @{ commit = $commit }; controlServer = @{ commit = 'c' * 40 } } } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $work 'pkg/release-manifest.json')
    $zip = Join-Path $work 'package.zip'
    Compress-Archive -Path (Join-Path $work 'pkg/*') -DestinationPath $zip
    "$((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant())  package.zip" | Set-Content -LiteralPath "$zip.sha256"
    $sitePath = Join-Path $work 'site-fake.json'
    @{ agvId = 'TEST-CAR-WS28'; onboardInstanceId = 'OBU-TEST-WS28'; wireToGate = @{ onboardInstanceId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301' }
        vehicleSafety = @{ expectedVehicleKey = $agv02Key }; ruleGateway = @{ host = '127.0.0.1' }; ioModule = @{ host = $realSite }
        install = @{ root = 'C:\8005\OnboardHmi' } } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sitePath
    $secretPath = Join-Path $work 'secrets.xml'
    @{ OnboardCredential = (ConvertTo-SecureString 'fake-onboard' -AsPlainText -Force); OperatorId = (ConvertTo-SecureString 'fake-operator' -AsPlainText -Force) } |
        Export-Clixml -LiteralPath $secretPath

    # One fixture vehicle per installed state: <state>/OnboardHmi is what the probe reads as the install root.
    function New-InstalledConfig([string] $Directory, [string] $Content) {
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
        Set-Content -LiteralPath (Join-Path $Directory 'appsettings.json') -Value $Content
    }
    $io = { param($h, $p) @{ wireToGate = @{ host = '172.19.205.222'; port = 58105 }; ioModule = @{ host = $h; port = $p; unitId = 255 } } | ConvertTo-Json -Depth 4 }
    $vehicles = Join-Path $work 'vehicles'
    New-InstalledConfig (Join-Path $vehicles 'simulator/OnboardHmi') (& $io '127.0.0.1' 1502)
    New-InstalledConfig (Join-Path $vehicles 'real/OnboardHmi') (& $io $realSite 502)
    New-InstalledConfig (Join-Path $vehicles 'unknown/OnboardHmi') (& $io 'localhost.' 1502)
    New-InstalledConfig (Join-Path $vehicles 'unreadable/OnboardHmi') '{ "ioModule": { "host": '
    New-InstalledConfig (Join-Path $vehicles 'nohost/OnboardHmi') '{ "ioModule": { "port": 1502 } }'
    New-InstalledConfig (Join-Path $vehicles 'previous-only/OnboardHmi.previous') (& $io '127.0.0.1' 1502)
    New-Item -ItemType Directory -Force -Path (Join-Path $vehicles 'absent') | Out-Null

    $sshLog = Join-Path $work 'ssh-calls.log'
    @'
#Requires -Version 7
# ssh shim for Test-DeployOnboardHmi.ps1. Answers the deploy script's two read-only probes; anything else fails.
# The IO probe is the deploy script's own, decoded, with its install root pointed at a fixture and run in a fresh pwsh.
$alias = [string] $args[0]
$command = ($args | Select-Object -Skip 1) -join ' '
# -WhatIf:$false: the deploy script runs under -WhatIf, and that preference reaches this script too.
Add-Content -LiteralPath $env:WS28_SSH_LOG -Value "$alias | $command" -WhatIf:$false
if ($alias -cne $env:WS28_FAKE_ALIAS) { "shim: unexpected alias $alias"; exit 255 }
if ($command -match 'Get-Process SQCD\.Agv\.Wpf') { 'STOPPED'; exit 0 }
if ($command -match '-EncodedCommand (\S+)') {
    if ($env:WS28_IO_STATE -ceq 'garbage') { 'no state line at all'; exit 0 }
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
    $rootLine = "`$root = 'C:\8005\OnboardHmi'"
    if (([regex]::Matches($decoded, [regex]::Escape($rootLine))).Count -ne 1) { "shim: the IO probe does not set `$root from the install root once"; exit 255 }
    $fixture = Join-Path $env:WS28_VEHICLES "$env:WS28_IO_STATE\OnboardHmi"
    $rewritten = $decoded.Replace($rootLine, "`$root = '$fixture'")
    & pwsh -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rewritten))) 2>&1
    exit $LASTEXITCODE
}
"shim: unhandled command: $command"
exit 255
'@ | Set-Content -LiteralPath (Join-Path $work 'shim/ssh.ps1')

    $env:PATH = (Join-Path $work 'shim') + [IO.Path]::PathSeparator + $env:PATH
    $env:WS28_SSH_LOG = $sshLog
    $env:WS28_FAKE_ALIAS = $fakeAlias
    $env:WS28_VEHICLES = $vehicles
    function Invoke-Deploy([string] $IoState, [string[]] $Switches) {
        $env:WS28_IO_STATE = $IoState
        if (Test-Path -LiteralPath $sshLog) { Remove-Item -LiteralPath $sshLog }
        $output = & pwsh -NoProfile -File $source -PackagePath $zip -SshAlias $fakeAlias -SitePath $sitePath -SecretPath $secretPath `
            -OnboardPort 58105 -WhatIf @Switches *>&1 | Out-String
        $code = $LASTEXITCODE
        # Strip colour codes, and rejoin error messages the console view wrapped at its width (newline, spaces, "| ").
        $output = ($output -replace '\x1b\[[0-9;]*m', '') -replace '\r?\n {2,}\| ?', ' '
        $calls = @((Test-Path -LiteralPath $sshLog) ? (Get-Content -LiteralPath $sshLog) : @())
        $rendered = $null
        $marker = $output.IndexOf('WhatIf: stopping before the vehicle is touched.')
        if ($marker -ge 0) {
            $start = $output.IndexOf('{', $marker); $end = $output.LastIndexOf('}')
            if ($start -ge 0 -and $end -gt $start) { $rendered = $output.Substring($start, $end - $start + 1) | ConvertFrom-Json }
        }
        $warning = @($output -split '\r?\n' | Where-Object { $_ -match '^WARNING: .*switches the vehicle''s IO' })
        return [pscustomobject]@{ Code = $code; Output = $output; Calls = $calls; Config = $rendered; Warned = $warning.Count -gt 0 }
    }
    function Get-Io($d) { return ($null -eq $d.Config) ? '(none rendered)' : ('{0}:{1}' -f $d.Config.ioModule.host, $d.Config.ioModule.port) }
    function Test-Refused($d, [string] $Code) { return $d.Code -ne 0 -and $d.Output.Contains("${Code}:") -and $null -eq $d.Config }

    $d = Invoke-Deploy 'simulator' @()
    Write-Result -Ok ((Test-Refused $d 'IO_SIMULATOR_TO_REAL_REFUSED') -and $d.Calls.Count -eq 2 -and $d.Output.Contains('Installed IO on ws28-offline-fake: present 127.0.0.1:1502')) `
        -Name 'E2E simulator -> site, no switch: the probe reads 127.0.0.1:1502, refused, nothing rendered (2 ssh calls, both the shim)' -Detail "exit $($d.Code), io $(Get-Io $d), calls $($d.Calls.Count)`n$($d.Output)"
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo')
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq '127.0.0.1:1502' -and $d.Config.ioModule.unitId -eq 255 -and $d.Config.ioModule.doStartAddress -eq 100 -and
        $d.Output.Contains('IO target: simulator 127.0.0.1:1502, kept from the installed configuration') -and -not $d.Warned) `
        -Name 'E2E simulator + -KeepCurrentIo: renders 127.0.0.1:1502, other ioModule keys from the template, summary line, no warning' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'simulator' @('-UseSiteIo')
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq "${realSite}:502" -and $d.Output.Contains("IO target: REAL MODULE ${realSite}:502, from the site file") -and
        $d.Output.Contains('this connects the vehicle to REAL IO') -and $d.Warned) `
        -Name 'E2E simulator + -UseSiteIo: renders the real module, summary line says real IO needs authorisation, warns' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'real' @()
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq "${realSite}:502" -and $d.Output.Contains("IO target: REAL MODULE ${realSite}:502, from the site file; before: REAL MODULE ${realSite}:502") -and -not $d.Warned) `
        -Name 'E2E real module -> site, no switch: renders the site module as before, summary line, no warning' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'absent' @()
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq "${realSite}:502" -and $d.Output.Contains('first deployment') -and -not $d.Warned) `
        -Name 'E2E first deployment, no switch: renders the site module as before' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'absent' @('-KeepCurrentIo')
    Write-Result -Ok (Test-Refused $d 'IO_KEEP_NO_INSTALLED_CONFIG') -Name 'E2E first deployment + -KeepCurrentIo: refused, nothing rendered' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'unreadable' @()
    Write-Result -Ok ((Test-Refused $d 'IO_SIMULATOR_TO_REAL_REFUSED') -and $d.Output.Contains('Installed IO on ws28-offline-fake: unreadable')) `
        -Name 'E2E an installed configuration that does not parse: the probe says unreadable, refused' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'nohost' @('-KeepCurrentIo')
    Write-Result -Ok (Test-Refused $d 'IO_KEEP_UNREADABLE') -Name 'E2E an installed ioModule without host + -KeepCurrentIo: refused' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'unknown' @()
    Write-Result -Ok (Test-Refused $d 'IO_UNKNOWN_TO_REAL_REFUSED') -Name 'E2E unknown IO (localhost.) -> site, no switch: refused' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'unknown' @('-KeepCurrentIo')
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq 'localhost.:1502' -and $d.Output.Contains('IO target: UNKNOWN IO localhost.:1502, kept')) `
        -Name 'E2E unknown IO + -KeepCurrentIo: kept as it is' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'previous-only' @()
    Write-Result -Ok ((Test-Refused $d 'IO_PREVIOUS_INSTALL_ONLY') -and $d.Output.Contains('simulator 127.0.0.1:1502')) `
        -Name 'E2E no install root but a .previous on the simulator: refused, not taken as a first deployment' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'garbage' @()
    Write-Result -Ok ((Test-Refused $d 'IO_SIMULATOR_TO_REAL_REFUSED') -and $d.Output.Contains('no IO-STATE line')) `
        -Name 'E2E a probe that answers nothing usable: refused, not taken as a first deployment' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo', '-UseSiteIo')
    Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains('IO_OPTIONS_EXCLUSIVE') -and $d.Calls.Count -eq 0) `
        -Name 'E2E both switches: refused before any ssh' -Detail "exit $($d.Code), calls $($d.Calls.Count)`n$($d.Output)"
} finally {
    $env:PATH = $savedPath
    Remove-Item Env:WS28_SSH_LOG, Env:WS28_FAKE_ALIAS, Env:WS28_IO_STATE, Env:WS28_VEHICLES -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
