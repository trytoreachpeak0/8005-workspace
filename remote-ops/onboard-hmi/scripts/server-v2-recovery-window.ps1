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
    The order is Invoke-V2RecoveryWindowServer's. The MVP service is fingerprinted before and after
    a change.
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
$null = Assert-ParallelInstanceDefinition -Definition $definition -AllowRiotCreateDispatch -AllowRiotForeignOrderCancel -ForStopDirection
$layout = Get-ParallelInstanceLayout -Definition $definition
$serviceName = $layout.ServiceName
$onboardPort = [int] $definition['onboardPort']
$configurationPath = "$($layout.InstallRoot)\appsettings.Production.json"
$registryPath = "SYSTEM\CurrentControlSet\Services\$serviceName"

$readConfiguration = { (Test-Path -LiteralPath $configurationPath -PathType Leaf) ? [IO.File]::ReadAllText($configurationPath) : $null }

$actions = @{
    ReadEnvironment = { Read-V2RegistryMultiString -Root ([Microsoft.Win32.Registry]::LocalMachine) -Path $registryPath }
    WriteEnvironment = { param([string[]] $Value) Write-V2RegistryMultiString -Root ([Microsoft.Win32.Registry]::LocalMachine) -Path $registryPath -Value $Value }
    MergeEntry = { param([string[]] $Environment, [string] $Name, [string] $Value) Set-ParallelServiceEnvironmentEntry -Environment $Environment -Name $Name -Value $Value }
    ServiceStatus = { $s = Get-Service -Name $serviceName -ErrorAction SilentlyContinue; $s ? [string] $s.Status : $null }
    PreInstallRefusal = {
        $text = & $readConfiguration
        Get-ParallelPreInstallRefusal -ServiceExists ([bool] (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) `
            -ServiceStatus ([string] (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)?.Status) `
            -ServiceName $serviceName -ConfigurationPath $configurationPath -ConfigurationText $text `
            -ConfigurationWriteTimeUtc ($null -ne $text ? [IO.File]::GetLastWriteTimeUtc($configurationPath) : $null) `
            -ProcessStartTimeUtc (Get-ParallelServiceProcessStartTimeUtc -ServiceName $serviceName)
    }
    JourneyState = {
        try {
            $configuration = ConvertFrom-Json -InputObject (& $readConfiguration) -AsHashtable -Depth 12
            $databasePath = Resolve-ParallelInstanceDatabasePath -Configuration $configuration -DataRoot $layout.DataRoot -ConfigurationPath $configurationPath
        } catch {
            return @{ Error = "the database path cannot be resolved from $configurationPath ($($_.Exception.Message))" }
        }
        Get-ParallelJourneyDispatchState -DatabasePath $databasePath -AssemblyDirectory $layout.InstallRoot
    }
    # All connections, then filtered: a filtered Get-NetTCPConnection reports "none" as an error,
    # and swallowing errors would read "cannot tell" as "nobody connected".
    Connections = {
        @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.LocalPort -eq $onboardPort -and [string] $_.State -eq 'Established' } |
                ForEach-Object { [string] $_.RemoteAddress })
    }
    RestartService = { Restart-Service -Name $serviceName -Force }
}

Write-Output "Definition: $definitionPath ($($definition['instanceId'])); service '$serviceName'; onboard port $onboardPort"

if ($request['mode'] -in @('set', 'remove')) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'This script must run elevated. Nothing was changed.' }
    $mvpBefore = Get-MvpFingerprint
    try {
        Invoke-V2RecoveryWindowServer -Request $request -ServiceName $serviceName -OnboardPort $onboardPort -Actions $actions
    } finally {
        Assert-MvpUntouched -Before $mvpBefore -After (Get-MvpFingerprint)
        Write-Output 'MVP service fingerprint unchanged.'
    }
} else {
    Invoke-V2RecoveryWindowServer -Request $request -ServiceName $serviceName -OnboardPort $onboardPort -Actions $actions
}
