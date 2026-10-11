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
$definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-VehicleSafetyCredential' }, $true)
Write-Result -Ok ($null -ne $definition) -Name 'Resolve-VehicleSafetyCredential is defined in 06-deploy-onboard-hmi.ps1' -Detail 'missing'
if ($null -eq $definition) {
    Write-Host ''
    Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Red
    exit 1
}
. ([scriptblock]::Create($definition.Extent.Text))

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

$r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $agv03Key; StoreKeys = $storeBoth }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.StoreKey -ceq "OnboardSafetyCredential:$agv03Key" -and $r.Value.Variable -ceq $safety) `
    -Name 'a separate projection variable takes this vehicle''s own credential, never another''s' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"

$r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $agv03Key; StoreKeys = @('OnboardCredential', "OnboardSafetyCredential:$agv02Key") }
Write-Result -Ok ($null -ne $r.Error -and $r.Error.Contains('VEHICLE_SAFETY_CREDENTIAL_MISSING') -and $r.Error.Contains($agv03Key) -and
    $r.Error.Contains('-NewVehicleSafetyCredential') -and $r.Error.Contains('-SharedSafetyCredential')) `
    -Name 'without its own credential the vehicle is refused (another vehicle''s in the store does not stand in)' -Detail "error: $($r.Error)"

$r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $agv03Key; StoreKeys = @('OnboardCredential'); SharedSafetyCredential = $true }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.StoreKey -ceq 'OnboardCredential' -and $r.Value.Variable -ceq $safety) `
    -Name '-SharedSafetyCredential (a single-car server) writes the shared credential into the projection variable' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"

$r = Invoke-Resolve @{ SafetyVariable = $safety; SessionVariable = $session; VehicleKey = $agv03Key; StoreKeys = $storeBoth; SharedSafetyCredential = $true }
Write-Result -Ok ($null -eq $r.Error -and $r.Value.StoreKey -ceq "OnboardSafetyCredential:$agv03Key") `
    -Name 'a vehicle credential in the store wins over -SharedSafetyCredential' -Detail "error: $($r.Error); got $($r.Value | ConvertTo-Json -Compress)"

# The place script: the machine variable and the probe both use the chosen credential and the rendered endpoint.
$text = Get-Content -Raw -LiteralPath $source
Write-Result -Ok ($text.Contains("[Environment]::SetEnvironmentVariable('`$(`$safetyChoice.Variable)', '`$(`$safetyCredential)', 'Machine')")) `
    -Name 'the vehicle''s projection variable is set from the chosen credential' -Detail 'SetEnvironmentVariable for the chosen variable not found'
Write-Result -Ok ($text.Contains("Invoke-WebRequest -Uri '`$(`$config.vehicleSafety.endpoint)'") -and $text.Contains("Authorization = 'Bearer `$(`$safetyCredential)'")) `
    -Name 'the probe asks the rendered endpoint (with ?vehicleKey=) with the chosen credential' -Detail 'probe line not found'

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
