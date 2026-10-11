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

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/Test-DeployOnboardHmi.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$source = Join-Path $PSScriptRoot '06-deploy-onboard-hmi.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
Write-Result -Ok (@($errors).Count -eq 0) -Name '06-deploy-onboard-hmi.ps1 parses' -Detail (@($errors) -join ' | ')
foreach ($name in @('Resolve-VehicleSafetyCredential', 'Assert-VehicleSafetyEndpointNamesVehicle')) {
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

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
