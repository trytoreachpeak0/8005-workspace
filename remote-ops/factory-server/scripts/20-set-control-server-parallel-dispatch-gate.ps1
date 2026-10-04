#Requires -Version 7
<#
.SYNOPSIS
    Closes or opens the RIoT dispatch gate of the v2 parallel ControlServer instance on factory01,
    and restarts its service. Runs on the control host.

.DESCRIPTION
    control-server#472. An upgrade or rollback of the parallel instance is refused while its installed
    RiotCreateDispatch.enabled is true (UPGRADE_REFUSED_DISPATCH_OPEN, control-server#454), and the only
    way to close the gate was to log on to factory01, edit
    C:\Program Files\8005 AGV\ControlServer.V2\appsettings.Production.json by hand and restart
    '8005 AGV ControlServer V2'. This script replaces that: it copies the server-side half from the
    control-server repository and runs it over ssh.

    AUTHORIZATION. Running it for real changes a live service on the server that carries production:
    it stops and starts the V2 service. Run it only when the user has authorized it for that occasion
    -- in practice right before an authorized v2 upgrade or rollback. -WhatIf is read-only and needs no
    authorization. It never touches the MVP service, its files or its database.

    What the server-side half (the control-server repository's scripts/parallel/Set-ParallelDispatchGateLocal.ps1,
    logic in ParallelHost.psm1's Invoke-ParallelDispatchGateChange) does, and refuses:
      * takes the service name and every path from the definition the installer recorded
        (installed-instance.json), asserted as for an install: the MVP's service, paths or ports are refused;
      * reads the instance's own SQLite store, read-only: -State Closed refuses while any journey is not
        Completed; -State Open refuses while any journey has an order that was or may have been sent to
        RIoT (journeys waiting for the gate are allowed -- they are what opening it is for);
      * reads it once with the service running and once after stopping it; a refusal on the second read
        starts the service again on the unchanged file and says so;
      * writes the flag with the section found ignoring case, reads the flag back and checks that every
        other value -- the Chinese agvId above all -- reads back unchanged; on a failed write the original
        bytes are put back;
      * starts the service and requires a process that started after the file was written (UTC);
      * fingerprints the MVP service before and after.
    Every refusal names the file and the service and says what was and was not changed.

    See remote-ops/factory-server/docs/wire-to-gate-parallel-cd.md, section 10.

.PARAMETER State
    Closed (RiotCreateDispatch.enabled false) or Open (true).

.PARAMETER ControlServerRepository
    A clean 8005-agv-control-server checkout or worktree that has control-server#472. The server-side
    script and both modules are copied from it, so what runs is that revision.

.PARAMETER InstanceDefinitionPath
    Only its opsRoot is used, to find the server-side scripts; the server takes everything else from
    the definition it recorded at install. Default: the repository's scripts/parallel/instance-factory01-v2.json.

.PARAMETER WhatIf
    Read-only: copies nothing, runs the server-side script with -WhatIf if it is already there (it prints
    what the journey check says now) and stops.

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1 -State Closed -ControlServerRepository <checkout> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Closed', 'Open')][string] $State,

    [Parameter(Mandatory = $true)][string] $ControlServerRepository,

    [string] $InstanceDefinitionPath,

    [string] $SshAlias = 'factory01'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Invoke-Ssh {
    param([string[]] $Arguments)
    $output = & ssh $SshAlias @Arguments 2>&1
    $output | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed (exit $LASTEXITCODE)" }
    return $output
}

$repoRoot = (Resolve-Path -LiteralPath $ControlServerRepository).Path
$parallelScripts = Join-Path $repoRoot 'scripts\parallel'
$serverScript = 'Set-ParallelDispatchGateLocal.ps1'
if (-not (Test-Path -LiteralPath (Join-Path $parallelScripts $serverScript) -PathType Leaf)) {
    throw "No scripts/parallel/$serverScript in $repoRoot. -ControlServerRepository is older than control-server#472; use a checkout that has it."
}
Import-Module (Join-Path $parallelScripts 'ParallelInstance.psm1') -Force

if (-not $InstanceDefinitionPath) {
    $InstanceDefinitionPath = Join-Path $parallelScripts 'instance-factory01-v2.json'
}
$definition = Read-ParallelInstanceDefinition -Path $InstanceDefinitionPath
# As for -Uninstall in 19-deploy-control-server-parallel.ps1: only opsRoot is used here, held to the
# allowlist; the server asserts the definition it recorded at install.
$opsRoot = [string] $definition['opsRoot']
$opsProblem = Test-ParallelInstanceOwnedPath -Path $opsRoot
if ($opsProblem) { throw "opsRoot in $InstanceDefinitionPath $opsProblem. Nothing was changed." }
$remoteScript = "$opsRoot\$serverScript"
$switch = "-State $State"

Write-Step "Target: $SshAlias  v2 parallel instance, server-side script $remoteScript"
Write-Step "Requested: RiotCreateDispatch.enabled=$($State -eq 'Open' ? 'true' : 'false') (the server resolves the V2 service and file from installed-instance.json)"

if (-not $PSCmdlet.ShouldProcess($SshAlias, "Set the v2 parallel instance's RIoT dispatch gate $State and restart its service")) {
    # Nothing is copied on this path: a dry run must not replace the server's scripts.
    $present = & ssh $SshAlias "pwsh -NoProfile -Command `"Test-Path -LiteralPath '$remoteScript' -PathType Leaf`"" 2>&1
    if ("$present".Trim() -eq 'True') {
        Invoke-Ssh @("pwsh -NoProfile -File `"$remoteScript`" $switch -WhatIf")
    } else {
        Write-Step "WhatIf: no $remoteScript on $SshAlias yet; a real run copies it from $parallelScripts first."
    }
    return
}

foreach ($name in @('ParallelInstance.psm1', 'ParallelHost.psm1', $serverScript)) {
    & scp -q (Join-Path $parallelScripts $name) "${SshAlias}:$(& $toPosix "$opsRoot\$name")"
    if ($LASTEXITCODE -ne 0) { throw "scp of $name failed (exit $LASTEXITCODE). The gate was not changed." }
}
Write-Step "Server-side script and modules staged in $opsRoot"

Invoke-Ssh @("pwsh -NoProfile -File `"$remoteScript`" $switch -Confirm:`$false")
Write-Step "Done. The MVP service was not involved."
