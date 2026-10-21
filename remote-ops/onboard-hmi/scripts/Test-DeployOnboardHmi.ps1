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

    And which server the vehicle's credentials go to (workspace#32), through Assert-ControlServerPorts and
    Assert-RenderedServerTarget lifted the same way, the place script's read-back run for real, and the whole script:
      * one port alone, or neither, is refused before any ssh -- -OnboardPort 58105 alone sends nothing to 58007;
      * a port of the MVP pair beside a non-MVP one is refused before any ssh; agv02/agv03 never get the MVP pair;
      * a v2 template (own projection variable, ?vehicleKey=) on the MVP pair is refused before the vehicle is touched;
      * the projection endpoint renders on -HealthPort, and the vehicle reads that back before any credential is set;
      * the two v2 ports, and the MVP pair with the MVP template (agv01), render as before.

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
foreach ($name in @('Resolve-VehicleSafetyCredential', 'Assert-VehicleSafetyEndpointNamesVehicle', 'Test-SimulatorIoHost', 'Get-IoTargetKind', 'Resolve-OnboardIoTarget',
        'Assert-ControlServerPorts', 'Assert-RenderedServerTarget')) {
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

# ------------------------------------------------------------------------- workspace#32: which server, on which ports ---

Write-Host ''
Write-Host 'ControlServer ports (workspace#32)' -ForegroundColor Cyan
# control-server#564: which line a car is on comes from its site file. Here the lines of today's real site files, unless a
# case says otherwise (-Line); 'unset' stands for a site file without the field (the reader throws).
function Invoke-Ports([string[]] $Given, [int] $Onboard, [int] $Health, [string] $Alias = 'agv02', [string] $Line) {
    $resolved = $Line ? $Line : (($Alias.Trim().ToLowerInvariant() -ceq 'agv01') ? 'mvp' : 'v2')
    $reader = ($resolved -ceq 'unset') ? { throw 'VEHICLE_LINE_UNSET: test reader' } : [scriptblock]::Create("'$resolved'")
    try { return @{ Value = (Assert-ControlServerPorts -Given $Given -OnboardPort $Onboard -HealthPort $Health -SshAlias $Alias -LineReader $reader); Error = $null } }
    catch { return @{ Value = $null; Error = $_.Exception.Message } }
}
$both = @('OnboardPort', 'HealthPort')
foreach ($case in @(
        @{ Name = '-OnboardPort alone (the 2026-10-12 call)'; Given = @('OnboardPort'); Onboard = 58105; Health = 0; Missing = '-HealthPort' }
        @{ Name = '-HealthPort alone'; Given = @('HealthPort'); Onboard = 0; Health = 58107; Missing = '-OnboardPort' }
        @{ Name = 'neither port'; Given = @('SshAlias'); Onboard = 0; Health = 0; Missing = '-OnboardPort, -HealthPort' })) {
    $r = Invoke-Ports $case.Given $case.Onboard $case.Health
    Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('PORTS_REQUIRED:') -and $r.Error.Contains("(missing: $($case.Missing))") -and $r.Error.Contains('58107')) `
        -Name "$($case.Name) is refused, naming what is missing" -Detail "error: $($r.Error)"
}
foreach ($pair in @(@(58105, 58007), @(58005, 58107), @(58007, 58005), @(58005, 58005), @(58007, 58007), @(58105, 58005), @(58007, 58107))) {
    $r = Invoke-Ports $both $pair[0] $pair[1] 'agv01'
    Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('PORTS_MIXED_MVP:')) -Name "-OnboardPort $($pair[0]) -HealthPort $($pair[1]) mixes the MVP pair and is refused (even for agv01)" -Detail "error: $($r.Error)"
}
foreach ($alias in @('agv02', 'agv03', 'AGV02', ' agv03 ')) {
    $r = Invoke-Ports $both 58005 58007 $alias
    Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('MVP_PORTS_FOR_V2_VEHICLE:')) -Name "the MVP pair for '$alias' is refused" -Detail "error: $($r.Error)"
}
$r = Invoke-Ports $both 58005 58007 'agv01'
Write-Result -Ok ($null -eq $r.Error -and $r.Value -eq $true) -Name 'the MVP pair for agv01 passes and says so' -Detail "error: $($r.Error); value $($r.Value)"
foreach ($alias in @('agv02', 'agv03')) {
    $r = Invoke-Ports $both 58105 58107 $alias
    Write-Result -Ok ($null -eq $r.Error -and $r.Value -eq $false) -Name "the two v2 ports pass for $alias" -Detail "error: $($r.Error); value $($r.Value)"
}
# control-server#564: the pairing is the site file's controlServerLine. agv01 on the MVP line gets the MVP pair only; once the
# cutover changes its field to "v2" it gets the v2 ports only; a site file without the field is refused, but only after the
# port checks (a missing port is still PORTS_REQUIRED whatever the file says).
$r = Invoke-Ports $both 58105 58107 'agv01'
Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('V2_PORTS_FOR_MVP_VEHICLE:')) -Name 'the two v2 ports for agv01 on the MVP line are refused' -Detail "error: $($r.Error)"
$r = Invoke-Ports $both 58105 58107 'agv01' -Line 'v2'
Write-Result -Ok ($null -eq $r.Error -and $r.Value -eq $false) -Name 'the two v2 ports pass for agv01 once its site file says v2 (the cutover)' -Detail "error: $($r.Error); value $($r.Value)"
$r = Invoke-Ports $both 58005 58007 'agv01' -Line 'v2'
Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('MVP_PORTS_FOR_V2_VEHICLE:')) -Name 'the MVP pair for agv01 on the v2 line is refused (the half-done cutover)' -Detail "error: $($r.Error)"
$r = Invoke-Ports $both 58005 58007 'agv02' -Line 'mvp'
Write-Result -Ok ($null -eq $r.Error -and $r.Value -eq $true) -Name 'the MVP pair passes for any car whose site file says mvp (the alias decides nothing)' -Detail "error: $($r.Error); value $($r.Value)"
foreach ($pair in @(@(58105, 58107), @(58005, 58007))) {
    $r = Invoke-Ports $both $pair[0] $pair[1] 'agv01' -Line 'unset'
    Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('VEHICLE_LINE_UNSET:')) -Name "a site file without controlServerLine is refused ($($pair[0])/$($pair[1]))" -Detail "error: $($r.Error)"
}
$r = Invoke-Ports @('OnboardPort') 58105 0 'agv01' -Line 'unset'
Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('PORTS_REQUIRED:')) -Name 'a missing port is refused before the site file is read' -Detail "error: $($r.Error)"
$r = Invoke-Ports $both 58105 58107 'agv01' -Line 'MVP'
Write-Result -Ok ($null -ne $r.Error -and $r.Error.StartsWith('VEHICLE_LINE_UNSET:')) -Name 'a reader returning anything but mvp or v2 exactly is refused' -Detail "error: $($r.Error)"

function Invoke-Rendered([string] $Endpoint, [string] $SafetyVariable, [int] $Health, [bool] $Mvp) {
    try { Assert-RenderedServerTarget -Endpoint $Endpoint -SafetyVariable $SafetyVariable -SessionVariable $session -HealthPort $Health -IsMvpPair $Mvp; return $null }
    catch { return $_.Exception.Message }
}
$v2Endpoint = { param($p) "http://172.19.205.222:$p/api/onboard/v1/vehicle-safety?vehicleKey=$agv02Key" }
$mvpEndpoint = { param($p) "http://172.19.205.222:$p/api/onboard/v1/vehicle-safety" }
$e = Invoke-Rendered (& $v2Endpoint 58007) $safety 58007 $true
Write-Result -Ok ($null -ne $e -and $e.StartsWith('MVP_PORTS_FOR_V2_TEMPLATE:')) -Name 'a v2 template (own variable, ?vehicleKey=) on the MVP pair is refused' -Detail "error: $e"
$e = Invoke-Rendered (& $mvpEndpoint 58007) $safety 58007 $true
Write-Result -Ok ($null -ne $e -and $e.StartsWith('MVP_PORTS_FOR_V2_TEMPLATE:')) -Name 'a template with only its own projection variable on the MVP pair is refused' -Detail "error: $e"
$e = Invoke-Rendered (& $v2Endpoint 58007) $session 58007 $true
Write-Result -Ok ($null -ne $e -and $e.StartsWith('MVP_PORTS_FOR_V2_TEMPLATE:')) -Name 'a template with only ?vehicleKey= on the MVP pair is refused' -Detail "error: $e"
$e = Invoke-Rendered (& $v2Endpoint 58007) $safety 58107 $false
Write-Result -Ok ($null -ne $e -and $e.StartsWith('ENDPOINT_PORT_MISMATCH:') -and $e.Contains('58007') -and $e.Contains('58107')) -Name 'an endpoint rendered on another port than -HealthPort is refused' -Detail "error: $e"
$e = Invoke-Rendered (& $v2Endpoint 58107) $safety 58107 $false
Write-Result -Ok ($null -eq $e) -Name 'a v2 template on the v2 ports passes' -Detail "error: $e"
$e = Invoke-Rendered (& $mvpEndpoint 58007) $session 58007 $true
Write-Result -Ok ($null -eq $e) -Name 'the MVP template on the MVP pair (agv01) passes' -Detail "error: $e"

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
        function Invoke-ReadBack([string] $PlacedHost, [int] $PlacedPort, [int] $SafetyPort = 58107, [int] $HealthPort = 58107,
            [bool] $isMvpPair = $false, [int] $OnboardPort = 58105) {
            $ControlServerHost = '172.19.205.222'
            $ioTarget = [pscustomobject]@{ Host = '127.0.0.1'; Port = 1502 }
            @{ wireToGate = @{ host = $ControlServerHost; port = $OnboardPort }; ioModule = @{ host = $PlacedHost; port = $PlacedPort }
                vehicleSafety = @{ endpoint = "http://${ControlServerHost}:$SafetyPort/api/onboard/v1/vehicle-safety" } } |
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
        # workspace#32: the projection endpoint, read back on the vehicle before any credential is set.
        $rb = Invoke-ReadBack '127.0.0.1' 1502 -SafetyPort 58007 -HealthPort 58107
        Write-Result -Ok ($null -ne $rb.Error -and $rb.Error.Contains('Placed vehicleSafety.endpoint is on port 58007, expected 58107')) `
            -Name 'read-back throws when the placed projection endpoint is not on -HealthPort' -Detail "error: $($rb.Error); output: $($rb.Output)"
        $rb = Invoke-ReadBack '127.0.0.1' 1502 -SafetyPort 58007 -HealthPort 58007 -isMvpPair $false
        Write-Result -Ok ($null -ne $rb.Error -and $rb.Error.Contains('Placed vehicleSafety.endpoint is on the MVP''s port 58007')) `
            -Name 'read-back throws when a non-MVP deployment''s placed projection endpoint is on an MVP port' -Detail "error: $($rb.Error); output: $($rb.Output)"
        $rb = Invoke-ReadBack '127.0.0.1' 1502 -SafetyPort 58007 -HealthPort 58007 -isMvpPair $true -OnboardPort 58005
        Write-Result -Ok ($null -eq $rb.Error -and $rb.Output.Contains('vehicleSafety endpoint read back: http://172.19.205.222:58007/')) `
            -Name 'read-back passes the MVP pair''s endpoint for an MVP deployment' -Detail "error: $($rb.Error); output: $($rb.Output)"
        $rb = Invoke-ReadBack '127.0.0.1' 1502
        Write-Result -Ok ($null -eq $rb.Error -and $rb.Output.Contains('vehicleSafety endpoint read back: http://172.19.205.222:58107/')) `
            -Name 'read-back reports the v2 projection endpoint' -Detail "error: $($rb.Error); output: $($rb.Output)"
    } finally {
        Remove-Item -LiteralPath $readBackRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$readBackAt = $placeText.IndexOf('Placed vehicleSafety.endpoint is on port')
$firstCredential = $placeText.IndexOf('SetEnvironmentVariable(')
$probeAt = $placeText.IndexOf('Invoke-WebRequest')
Write-Result -Ok ($readBackAt -ge 0 -and $firstCredential -gt $readBackAt -and $probeAt -gt $readBackAt) `
    -Name 'the vehicle reads the projection endpoint back before any credential is set or sent (workspace#32)' -Detail "read-back $readBackAt, credential $firstCredential, probe $probeAt"
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
        install = @{ root = 'C:\8005\OnboardHmi' }; controlServerLine = 'v2' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sitePath
    # control-server#564: the same car on the MVP line, and a site file that does not say.
    $sitePathMvp = Join-Path $work 'site-fake-mvp.json'
    $siteMvp = Get-Content -Raw -LiteralPath $sitePath | ConvertFrom-Json -AsHashtable; $siteMvp['controlServerLine'] = 'mvp'
    $siteMvp | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sitePathMvp
    $sitePathUnset = Join-Path $work 'site-fake-unset.json'
    $siteUnset = Get-Content -Raw -LiteralPath $sitePath | ConvertFrom-Json -AsHashtable; $siteUnset.Remove('controlServerLine')
    $siteUnset | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $sitePathUnset
    # workspace#32: the same package with the v2 line's template -- its own projection variable, ?vehicleKey= endpoint.
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'pkg-v2/onboard-hmi') | Out-Null
    (Get-Content -Raw -LiteralPath (Join-Path $work 'pkg/onboard-hmi/appsettings.Production.template.json')).
        Replace('/vehicle-safety"', '/vehicle-safety?vehicleKey=REPLACE_WITH_EXPECTED_VEHICLE_KEY"').
        Replace('"expectedVehicleKey": "REPLACE_WITH_EXPECTED_VEHICLE_KEY", "credentialEnvironmentVariable": "CONTROL_SERVER_ONBOARD_CREDENTIAL"',
            '"expectedVehicleKey": "REPLACE_WITH_EXPECTED_VEHICLE_KEY", "credentialEnvironmentVariable": "CONTROL_SERVER_ONBOARD_SAFETY_CREDENTIAL"') |
        Set-Content -LiteralPath (Join-Path $work 'pkg-v2/onboard-hmi/appsettings.Production.template.json')
    Copy-Item -LiteralPath (Join-Path $work 'pkg/release-manifest.json') -Destination (Join-Path $work 'pkg-v2/release-manifest.json')
    $zipV2 = Join-Path $work 'package-v2.zip'
    Compress-Archive -Path (Join-Path $work 'pkg-v2/*') -DestinationPath $zipV2
    "$((Get-FileHash -LiteralPath $zipV2 -Algorithm SHA256).Hash.ToLowerInvariant())  package-v2.zip" | Set-Content -LiteralPath "$zipV2.sha256"
    $secretPath = Join-Path $work 'secrets.xml'
    @{ OnboardCredential = (ConvertTo-SecureString 'fake-onboard' -AsPlainText -Force); OperatorId = (ConvertTo-SecureString 'fake-operator' -AsPlainText -Force)
        "OnboardSafetyCredential:$agv02Key" = (ConvertTo-SecureString 'fake-agv02-safety' -AsPlainText -Force) } |
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
# workspace#51 review L2: ProductionIo.psm1 calls ssh with -o options before the alias; drop them first.
$plain = @($args | Where-Object { $_ -notin @('-o', 'BatchMode=yes', 'ConnectTimeout=15') })
$alias = [string] $plain[0]
$command = ($plain | Select-Object -Skip 1) -join ' '
# -WhatIf:$false: the deploy script runs under -WhatIf, and that preference reaches this script too.
Add-Content -LiteralPath $env:WS28_SSH_LOG -Value "$alias | $command" -WhatIf:$false
# workspace#51: the server alias answers 06's phase probe, run in a fresh pwsh against the fixture record.
if ($alias -ceq $env:WS51_SERVER_ALIAS) {
    if ($command -notmatch '-EncodedCommand (\S+)') { "shim: unexpected server command: $command"; exit 255 }
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
    $rewritten = $decoded.Replace('D:\zhengyushao\control-server-v2-ops\installed-instance.json', $env:WS51_SERVER_RECORD)
    if ($rewritten -ceq $decoded) { 'shim: the phase probe does not read the v2 installed-instance.json'; exit 255 }
    & pwsh -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rewritten))) 2>&1
    exit $LASTEXITCODE
}
if ($alias -cne $env:WS28_FAKE_ALIAS) { "shim: unexpected alias $alias"; exit 255 }
if ($command -match 'Get-Process SQCD\.Agv\.Wpf') { 'STOPPED'; exit 0 }
# workspace#32 review S1: the non -WhatIf run. The staging directory is local; the placement script the deploy script
# copied there is replaced by a fixture (never run for real: it sets machine-scope variables), and then the deploy
# script's own command line -- the part under test -- runs in a fresh pwsh, the way the vehicle's sshd runs it.
if ($command -match "^New-Item -ItemType Directory -Force -Path '[^']+' \| Out-Null; 'ready'$") { 'ready'; exit 0 }
if ($command -match '^pwsh -NoProfile -File "([^"]+place-onboard\.ps1)"') {
    $placePath = $Matches[1]
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $placePath) -WhatIf:$false | Out-Null
    $fixture = ($env:WS32_PLACE_MODE -ceq 'fail') ?
        "'placed: fixture'; throw 'Placed vehicleSafety.endpoint is on port 58007, expected 58107.'" :
        "'placed: fixture'; 'vehicle-safety 200: {}'"
    Set-Content -LiteralPath $placePath -Value $fixture -WhatIf:$false
    & pwsh -NoProfile -Command $command 2>&1
    $code = $LASTEXITCODE
    if (Test-Path -LiteralPath $placePath) { 'shim: the placement script was not removed' }
    exit $code
}
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
    # scp shim (workspace#32 review S1): log the copy and pretend it landed; nothing leaves this machine.
    @'
#Requires -Version 7
Add-Content -LiteralPath $env:WS28_SSH_LOG -Value "scp | $($args -join ' ')" -WhatIf:$false
if (($args -join ' ') -notmatch [regex]::Escape("$($env:WS28_FAKE_ALIAS):")) { 'shim: unexpected scp target'; exit 255 }
exit 0
'@ | Set-Content -LiteralPath (Join-Path $work 'shim/scp.ps1')

    $env:PATH = (Join-Path $work 'shim') + [IO.Path]::PathSeparator + $env:PATH
    $env:WS28_SSH_LOG = $sshLog
    $env:WS28_FAKE_ALIAS = $fakeAlias
    $env:WS28_VEHICLES = $vehicles
    # workspace#51: the server whose phase 06 reads. Trial unless a case says otherwise, so the cases above it are unchanged.
    $serverAlias = 'ws51-server-fake'
    $env:WS51_SERVER_ALIAS = $serverAlias
    function New-ServerRecord([string] $Name, [AllowNull()][string] $Phase, [int] $OnboardPort = 58105) {
        $record = [ordered]@{ instanceId = 'factory01-v2-parallel'; onboardPort = $OnboardPort; journeyRuntime = @{ fleet = @(@{ vehicleKey = $agv02Key }) } }
        if (-not [string]::IsNullOrEmpty($Phase)) { $record['productionCutover'] = @{ approvalRecord = 'test'; phase = $Phase } }
        $path = Join-Path $work "server-$Name.json"
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
        return $path
    }
    $serverTrial = New-ServerRecord 'trial' 'trial'
    $serverProduction = New-ServerRecord 'production' 'production'
    $env:WS51_SERVER_RECORD = $serverTrial
    function Invoke-Deploy([string] $IoState, [string[]] $Switches, [string[]] $Ports = @('-OnboardPort', '58105', '-HealthPort', '58107'),
        [string] $Package = $zip, [string] $Site = $sitePath, [string] $Server = $serverTrial) {
        $env:WS28_IO_STATE = $IoState
        $env:WS51_SERVER_RECORD = $Server
        if (Test-Path -LiteralPath $sshLog) { Remove-Item -LiteralPath $sshLog }
        $output = & pwsh -NoProfile -File $source -PackagePath $Package -SshAlias $fakeAlias -SitePath $Site -SecretPath $secretPath `
            -ServerSshAlias $serverAlias -WhatIf @Ports @Switches *>&1 | Out-String
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
    Write-Result -Ok ((Test-Refused $d 'IO_SIMULATOR_TO_REAL_REFUSED') -and @($d.Calls | Where-Object { $_ -like "$fakeAlias |*" }).Count -eq 2 -and $d.Output.Contains('Installed IO on ws28-offline-fake: present 127.0.0.1:1502')) `
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

    # workspace#51. In the production phase of the cutover the rendered IO must be the site file's module: a vehicle
    # kept on the simulator is refused before anything reaches it. Trial keeps the simulator, as before.
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo') -Server $serverProduction
    Write-Result -Ok ((Test-Refused $d 'PRODUCTION_IO_LOOPBACK') -and $d.Output.Contains('127.0.0.1:1502') -and $d.Output.Contains("${realSite}:502") -and
        $d.Output.Contains('Server phase: production')) `
        -Name 'E2E production phase + simulator + -KeepCurrentIo: refused (PRODUCTION_IO_LOOPBACK), nothing rendered' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    Write-Result -Ok (@($d.Calls | Where-Object { $_ -like "$serverAlias |*" }).Count -eq 1) -Name 'E2E production phase: 06 read the phase from the server once' -Detail ($d.Calls -join "`n")
    $d = Invoke-Deploy 'unknown' @('-KeepCurrentIo') -Server $serverProduction
    Write-Result -Ok (Test-Refused $d 'PRODUCTION_IO_LOOPBACK') -Name 'E2E production phase + unknown IO (localhost.) kept: refused (PRODUCTION_IO_LOOPBACK: localhost. is loopback)' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'real' @() -Server $serverProduction
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq "${realSite}:502" -and $d.Output.Contains('Server phase: production')) `
        -Name 'E2E production phase + real module: renders the site module' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'simulator' @('-UseSiteIo') -Server $serverProduction
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq "${realSite}:502") `
        -Name 'E2E production phase + simulator + -UseSiteIo: renders the site module (the authorised switch to real IO)' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo')
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq '127.0.0.1:1502' -and $d.Output.Contains('Server phase: trial')) `
        -Name 'E2E trial phase + simulator + -KeepCurrentIo: renders 127.0.0.1:1502 as before' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo') -Server (New-ServerRecord 'parallel' $null)
    Write-Result -Ok ($d.Code -eq 0 -and (Get-Io $d) -ceq '127.0.0.1:1502' -and $d.Output.Contains('Server phase: none')) `
        -Name 'E2E a parallel instance without productionCutover + simulator: renders 127.0.0.1:1502 as before' -Detail "exit $($d.Code), io $(Get-Io $d)`n$($d.Output)"
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo') -Server (Join-Path $work 'no-server-record.json')
    Write-Result -Ok ((Test-Refused $d 'SERVER_PHASE_UNREAD') -and @($d.Calls | Where-Object { $_ -like "$fakeAlias |*" }).Count -eq 0) `
        -Name 'E2E no installed record on the server: refused (SERVER_PHASE_UNREAD) before the vehicle is asked anything' -Detail "exit $($d.Code)`n$($d.Output)`n$($d.Calls -join "`n")"
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo') -Server (New-ServerRecord 'otherport' 'trial' -OnboardPort 58205)
    Write-Result -Ok (Test-Refused $d 'SERVER_INSTANCE_PORT_MISMATCH') -Name 'E2E the installed instance is on another port: refused (SERVER_INSTANCE_PORT_MISMATCH)' -Detail "exit $($d.Code)`n$($d.Output)"
    $d = Invoke-Deploy 'real' @() -Ports @('-OnboardPort', '58005', '-HealthPort', '58007') -Package $zip -Site $sitePathMvp -Server (Join-Path $work 'no-server-record.json')
    Write-Result -Ok ($d.Code -eq 0 -and @($d.Calls | Where-Object { $_ -like "$serverAlias |*" }).Count -eq 0 -and $d.Output.Contains('Server phase: mvp')) `
        -Name 'E2E the MVP pair: counted as production without asking the v2 server; the real module renders' -Detail "exit $($d.Code)`n$($d.Output)`n$($d.Calls -join "`n")"
    $d = Invoke-Deploy 'simulator' @('-KeepCurrentIo') -Ports @('-OnboardPort', '58005', '-HealthPort', '58007') -Package $zip -Site $sitePathMvp
    Write-Result -Ok (Test-Refused $d 'PRODUCTION_IO_LOOPBACK') -Name 'E2E the MVP pair + simulator kept: refused (PRODUCTION_IO_LOOPBACK)' -Detail "exit $($d.Code)`n$($d.Output)"

    # workspace#32. A refusal on the ports happens before any ssh, so nothing -- no probe, no credential -- goes anywhere.
    function Get-Endpoint($d) { return ($null -eq $d.Config) ? '(none rendered)' : [string] $d.Config.vehicleSafety.endpoint }
    foreach ($case in @(
            @{ Name = '-OnboardPort 58105 alone (the 2026-10-12 call)'; Ports = @('-OnboardPort', '58105'); Code = 'PORTS_REQUIRED' }
            @{ Name = '-HealthPort 58107 alone'; Ports = @('-HealthPort', '58107'); Code = 'PORTS_REQUIRED' }
            @{ Name = 'no port at all'; Ports = @(); Code = 'PORTS_REQUIRED' }
            @{ Name = '-OnboardPort 58105 -HealthPort 58007'; Ports = @('-OnboardPort', '58105', '-HealthPort', '58007'); Code = 'PORTS_MIXED_MVP' }
            @{ Name = '-OnboardPort 58005 -HealthPort 58107'; Ports = @('-OnboardPort', '58005', '-HealthPort', '58107'); Code = 'PORTS_MIXED_MVP' })) {
        foreach ($package in @($zip, $zipV2)) {
            $d = Invoke-Deploy 'real' @() -Ports $case.Ports -Package $package
            Write-Result -Ok ((Test-Refused $d $case.Code) -and $d.Calls.Count -eq 0 -and -not $d.Output.Contains('58007/api')) `
                -Name "E2E $($case.Name), $(Split-Path -Leaf $package): $($case.Code), refused before any ssh" -Detail "exit $($d.Code), calls $($d.Calls.Count)`n$($d.Output)"
        }
    }
    $d = Invoke-Deploy 'real' @() -Ports @('-OnboardPort', '58005', '-HealthPort', '58007') -Package $zipV2 -Site $sitePathMvp
    Write-Result -Ok ((Test-Refused $d 'MVP_PORTS_FOR_V2_TEMPLATE') -and -not $d.Output.Contains('WhatIf: stopping')) `
        -Name 'E2E v2 template on the MVP pair: refused before the configuration is rendered' -Detail "exit $($d.Code), calls $($d.Calls.Count)`n$($d.Output)"
    $d = Invoke-Deploy 'real' @() -Ports @('-OnboardPort', '58105', '-HealthPort', '58107') -Package $zipV2
    Write-Result -Ok ($d.Code -eq 0 -and $d.Config.wireToGate.port -eq 58105 -and
        (Get-Endpoint $d) -ceq "http://172.19.205.222:58107/api/onboard/v1/vehicle-safety?vehicleKey=$agv02Key" -and
        $d.Config.vehicleSafety.credentialEnvironmentVariable -ceq $safety -and $d.Output.Contains('ControlServer ports: NDJSON 58105, HTTP 58107 (not the MVP service)')) `
        -Name 'E2E v2 template on the two v2 ports: renders 58105 and the 58107 endpoint naming the vehicle' -Detail "exit $($d.Code), endpoint $(Get-Endpoint $d)`n$($d.Output)"
    $d = Invoke-Deploy 'real' @() -Ports @('-OnboardPort', '58005', '-HealthPort', '58007') -Package $zip -Site $sitePathMvp
    Write-Result -Ok ($d.Code -eq 0 -and $d.Config.wireToGate.port -eq 58005 -and (Get-Endpoint $d) -ceq 'http://172.19.205.222:58007/api/onboard/v1/vehicle-safety' -and
        $d.Output.Contains('(the MVP service)')) `
        -Name 'E2E MVP template on the MVP pair (agv01 as before): renders 58005 and the 58007 endpoint' -Detail "exit $($d.Code), endpoint $(Get-Endpoint $d)`n$($d.Output)"
    # control-server#564: the car's line is its site file's controlServerLine; a mismatch or a file that does not say is refused
    # before any ssh, so no probe and no credential goes to the wrong server.
    $d = Invoke-Deploy 'real' @() -Ports @('-OnboardPort', '58105', '-HealthPort', '58107') -Package $zipV2 -Site $sitePathMvp
    Write-Result -Ok ((Test-Refused $d 'V2_PORTS_FOR_MVP_VEHICLE') -and $d.Calls.Count -eq 0) `
        -Name 'E2E v2 ports for a car whose site file says mvp: refused before any ssh' -Detail "exit $($d.Code), calls $($d.Calls.Count)`n$($d.Output)"
    $d = Invoke-Deploy 'real' @() -Ports @('-OnboardPort', '58005', '-HealthPort', '58007') -Package $zip
    Write-Result -Ok ((Test-Refused $d 'MVP_PORTS_FOR_V2_VEHICLE') -and $d.Calls.Count -eq 0) `
        -Name 'E2E the MVP pair for a car whose site file says v2: refused before any ssh' -Detail "exit $($d.Code), calls $($d.Calls.Count)`n$($d.Output)"
    foreach ($ports in @(@('-OnboardPort', '58105', '-HealthPort', '58107'), @('-OnboardPort', '58005', '-HealthPort', '58007'))) {
        $d = Invoke-Deploy 'real' @() -Ports $ports -Package $zip -Site $sitePathUnset
        Write-Result -Ok ((Test-Refused $d 'VEHICLE_LINE_UNSET') -and $d.Calls.Count -eq 0) `
            -Name "E2E a site file without controlServerLine ($($ports[1])/$($ports[3])): refused before any ssh" -Detail "exit $($d.Code), calls $($d.Calls.Count)`n$($d.Output)"
    }

    # workspace#32 review S1: past the -WhatIf gate. A placement that throws on the vehicle (a read-back mismatch) must
    # fail the deployment, not print the "Staged" hand-off. Covers ws#28's IO read-back too: same call.
    function Invoke-Place([string] $Mode) {
        $env:WS32_PLACE_MODE = $Mode
        $env:WS28_IO_STATE = 'real'
        if (Test-Path -LiteralPath $sshLog) { Remove-Item -LiteralPath $sshLog }
        $env:WS51_SERVER_RECORD = $serverTrial
        $output = & pwsh -NoProfile -File $source -PackagePath $zipV2 -SshAlias $fakeAlias -SitePath $sitePath -SecretPath $secretPath `
            -ServerSshAlias $serverAlias -OnboardPort 58105 -HealthPort 58107 -StagingRoot (Join-Path $work "staging-$Mode") *>&1 | Out-String
        $code = $LASTEXITCODE
        $output = ($output -replace '\x1b\[[0-9;]*m', '') -replace '\r?\n {2,}\| ?', ' '
        $calls = @((Test-Path -LiteralPath $sshLog) ? (Get-Content -LiteralPath $sshLog) : @())
        return [pscustomobject]@{ Code = $code; Output = $output; Calls = $calls }
    }
    $p = Invoke-Place 'fail'
    Write-Result -Ok ($p.Code -ne 0 -and -not $p.Output.Contains('Staged') -and $p.Output.Contains('Placed vehicleSafety.endpoint is on port 58007') -and
        @($p.Calls | Where-Object { $_ -match 'place-onboard\.ps1' }).Count -ge 2 -and -not $p.Output.Contains('was not removed')) `
        -Name 'E2E a placement that throws on the vehicle: 06 exits non-zero, no "Staged", the placement script is still removed' -Detail "exit $($p.Code)`n$($p.Output)"
    $p = Invoke-Place 'ok'
    Write-Result -Ok ($p.Code -eq 0 -and $p.Output.Contains('Staged. NOT started') -and $p.Output.Contains('vehicle-safety 200') -and -not $p.Output.Contains('was not removed')) `
        -Name 'E2E a placement that succeeds: 06 exits 0 and hands off with "Staged"' -Detail "exit $($p.Code)`n$($p.Output)"
} finally {
    $env:PATH = $savedPath
    Remove-Item Env:WS28_SSH_LOG, Env:WS28_FAKE_ALIAS, Env:WS28_IO_STATE, Env:WS28_VEHICLES, Env:WS32_PLACE_MODE, Env:WS51_SERVER_ALIAS, Env:WS51_SERVER_RECORD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# control-server#797: -RecoveryResume turns the recovery entry on with this vehicle's own proof, never on the MVP pair, never
# without a proof in the store; without the switch nothing about recovery changes.
Write-Host ''
Write-Host 'Recovery entry (-RecoveryResume, control-server#797)' -ForegroundColor Cyan
$deployAst = [System.Management.Automation.Language.Parser]::ParseFile($DeployScript, [ref]$null, [ref]$null)
$recoveryDefinition = $deployAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-VehicleRecoveryProof' }, $true)
Write-Result -Ok ($null -ne $recoveryDefinition) -Name 'Resolve-VehicleRecoveryProof is defined in 06-deploy-onboard-hmi.ps1' -Detail 'missing'
if ($null -ne $recoveryDefinition) {
    . ([scriptblock]::Create($recoveryDefinition.Extent.Text))
    $recoveryKey = 'BROKERX-f38975561adf46ccb1d2f23833c7d0e4'
    function Invoke-RecoveryChoice([hashtable] $Arguments) {
        try { return @{ Value = (Resolve-VehicleRecoveryProof @Arguments); Error = $null } } catch { return @{ Value = $null; Error = $_.Exception.Message } }
    }
    $own = Invoke-RecoveryChoice @{ ProofVariable = 'CONTROL_SERVER_RECOVERY_PROOF'; VehicleKey = $recoveryKey
        StoreKeys = @('OnboardCredential', "RecoveryProof:$recoveryKey", 'RecoveryProof:BROKERX-other'); IsMvpPair = $false }
    Write-Result -Ok ($null -eq $own.Error -and $own.Value.StoreKey -ceq "RecoveryProof:$recoveryKey" -and $own.Value.Variable -ceq 'CONTROL_SERVER_RECOVERY_PROOF') `
        -Name 'this vehicle''s own proof, into the variable the template names' -Detail "error: $($own.Error); got $($own.Value.StoreKey) -> $($own.Value.Variable)"
    foreach ($case in @(
            @{ Name = 'a vehicle without a proof in the store is refused, not given another vehicle''s'; Says = 'VEHICLE_RECOVERY_PROOF_MISSING'
                Arguments = @{ ProofVariable = 'CONTROL_SERVER_RECOVERY_PROOF'; VehicleKey = $recoveryKey; StoreKeys = @('OnboardCredential', 'RecoveryProof:BROKERX-other'); IsMvpPair = $false } }
            @{ Name = 'the MVP pair is refused: the MVP service checks no grant'; Says = 'RECOVERY_RESUME_ON_MVP'
                Arguments = @{ ProofVariable = 'CONTROL_SERVER_RECOVERY_PROOF'; VehicleKey = $recoveryKey; StoreKeys = @("RecoveryProof:$recoveryKey"); IsMvpPair = $true } }
            @{ Name = 'a template without a proof variable is refused'; Says = 'recoveryAuthenticationProofEnvironmentVariable'
                Arguments = @{ ProofVariable = ''; VehicleKey = $recoveryKey; StoreKeys = @("RecoveryProof:$recoveryKey"); IsMvpPair = $false } })) {
        $r = Invoke-RecoveryChoice $case.Arguments
        Write-Result -Ok ($null -ne $r.Error -and $r.Error.Contains($case.Says)) -Name "recovery entry: $($case.Name)" -Detail "error: $($r.Error)"
    }
}
$deployText = Get-Content -Raw -LiteralPath $DeployScript
Write-Result -Ok ($deployText.Contains('if ($recoveryChoice) { "[Environment]::SetEnvironmentVariable(''$($recoveryChoice.Variable)''') -and
        $deployText.Contains('$config.wireToGate.recoveryResumeEnabled = $true') -and
        @([regex]::Matches($deployText, '\$config\.wireToGate\.recoveryResumeEnabled = ')).Count -eq 1 -and
        $deployText.Contains('Placed wireToGate.recoveryResumeEnabled is')) `
    -Name 'recovery entry: the switch is set only under -RecoveryResume, the proof variable only with a choice, and both are read back on the vehicle' -Detail 'pattern not found'

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
