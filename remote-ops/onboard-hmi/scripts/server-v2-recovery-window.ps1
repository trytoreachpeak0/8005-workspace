#Requires -Version 7
<#
.SYNOPSIS
    The server half of 18-set-v2-recovery-window.ps1. Runs ON factory01 from
    <opsRoot>\recovery-window\<control-server commit>, staged beside V2RecoveryWindow.psm1 and the
    control-server modules ParallelInstance.psm1 and ParallelHost.psm1; never run by hand.

.DESCRIPTION
    Takes no parameters: the request (mode, target, proof, allowConnectedVehicles) arrives as one line
    of JSON on standard input. Which instance comes from the definition the installer recorded,
    <opsRoot>\installed-instance.json -- two directories above this script -- asserted as
    20-set-control-server-parallel-dispatch-gate.ps1's server half asserts it, so the MVP's service,
    paths and ports are refused, and the service name, install root and onboard port come from there
    rather than from anybody's parameters.

    The checks before a restart are control-server's own: Get-ParallelPreInstallRefusal (configuration,
    service state, process start time, dispatch gate) and Get-ParallelJourneyDispatchState (journeys
    not Completed, the SQLite store read-only); the Environment merge is Set-ParallelServiceEnvironmentEntry.
    The actions are New-V2ServerActions', the order Invoke-V2RecoveryWindowServer's, the elevation
    check and the MVP fingerprint Invoke-V2RecoveryWindowServerRun's.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'ParallelInstance.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ParallelHost.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'V2RecoveryWindow.psm1') -Force

$request = Read-V2RecoveryWindowRequest -Line ([Console]::In.ReadLine())

$definitionPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'installed-instance.json'
if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
    throw "No installed definition at ${definitionPath}: the v2 instance was never installed through 19-deploy. Nothing was changed."
}
$definition = Read-ParallelInstanceDefinition -Path $definitionPath
# control-server#564: an installed production cutover definition carries its record, which got there only through an
# install with -ProductionCutover; the switch is taken from it (Get-V2InstalledCutoverArgument).
$cutoverArgument = Get-V2InstalledCutoverArgument -Definition $definition `
    -ModuleKnowsCutover ($null -ne (Get-Command Test-ParallelProductionCutoverDefinition -ErrorAction SilentlyContinue))
$null = Assert-ParallelInstanceDefinition -Definition $definition -AllowRiotCreateDispatch -AllowRiotForeignOrderCancel -ForStopDirection @cutoverArgument
$layout = Get-ParallelInstanceLayout -Definition $definition
$onboardPort = [int] $definition['onboardPort']
# Only these four, all from the installed definition: the registry root, the services path and the restart
# are New-V2ServerActions' defaults, the production wiring. Test-SetV2RecoveryWindow.ps1 pins that this
# call passes nothing else.
$actions = New-V2ServerActions -ServiceName $layout.ServiceName -InstallRoot $layout.InstallRoot -DataRoot $layout.DataRoot -OnboardPort $onboardPort

Write-Output "Definition: $definitionPath ($($definition['instanceId'])); $($actions.Description)"
Invoke-V2RecoveryWindowServerRun -Request $request -ServiceName $layout.ServiceName -OnboardPort $onboardPort -Actions $actions
