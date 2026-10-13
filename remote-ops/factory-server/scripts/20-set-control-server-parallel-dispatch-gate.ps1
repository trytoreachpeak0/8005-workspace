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

    Where it goes on the server. Into its own directory per commit, <opsRoot>\dispatch-gate\<commit>: the
    gate script and the two modules it imports, nothing else. Not into <opsRoot> itself, where
    19-deploy-control-server-parallel.ps1 keeps the installer, the uninstaller and the same two modules as
    one unit -- an uninstaller from one revision running on modules from another would validate and clean
    up by rules it was not written to, and the deploy's secret-file clean-up uses the module there too
    (control-server#472 review S4). So this script never changes what 19 deployed, and 19 needs no part
    in it. The cost is one small directory per commit used; they are removed with opsRoot (-Uninstall
    -RemoveData). The checkout must be clean, so the directory name says what is in it.

    AUTHORIZATION. Running it for real changes a live service on the server that carries production:
    it stops and starts the V2 service. Run it only when the user has authorized it for that occasion
    -- in practice right before an authorized v2 upgrade or rollback. -WhatIf copies this commit's copy
    into <opsRoot>\dispatch-gate\<commit> and changes nothing else; it needs no authorization. On a server
    where the instance was never installed, that dry run leaves the directory dispatch-gate\<commit>
    behind, used by nothing (the server-side script then refuses for want of installed-instance.json);
    remove it by hand if it matters. It never touches the MVP service, its files or its database.

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
    script and both modules are copied from it into <opsRoot>\dispatch-gate\<its HEAD commit>, so what
    runs is that revision. A dirty checkout is refused.

.PARAMETER InstanceDefinitionPath
    Only its opsRoot is used, to find the server-side scripts; the server takes everything else from
    the definition it recorded at install. Default: the repository's scripts/parallel/instance-factory01-v2.json.

.PARAMETER WhatIf
    The dry run: stages this commit's copy in <opsRoot>\dispatch-gate\<commit> (the same staging a real
    run does), then runs it with -WhatIf, which prints what the journey check says now, and stops. It
    stops, starts and writes nothing of the instance. Staging is done even here on purpose: without it a
    dry run of a new commit would have nothing to run, and the step "dry run first" would show nothing.
    Staging only adds files under this commit's own directory -- nothing the service, its configuration,
    the MVP or 19-deploy-control-server-parallel.ps1 reads -- and staging the same commit again writes
    the same bytes. So it is not counted as a change for ShouldProcess; what -WhatIf withholds is the
    gate change and the restart.

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

function Get-CheckoutCutoverRefusal {
    <#
        control-server#564 review S5. A -ControlServerRepository from before control-server#564 has a module that refuses a
        production cutover definition by name (agv01, WIRE_TO_GATE) -- and the gate script asserts the installed definition
        in both directions, so closing the gate would be refused too. $null when the checkout knows the cutover or the
        installed definition is not one; otherwise the refusal, before anything is copied. Pure.
    #>
    param([bool] $ModuleKnowsCutover, [bool] $InstalledIsCutover, [string] $Repository)
    if ($ModuleKnowsCutover -or -not $InstalledIsCutover) { return $null }
    return ("CHECKOUT_PREDATES_CUTOVER: the installed definition on the server is a production cutover (control-server#564), " +
        "and $Repository is older than that ticket: its module would refuse that definition, closing the gate included. " +
        'Use a checkout that has control-server#564. Nothing was copied or changed.')
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
# Clean, so that the commit the server-side directory is named after is what was copied into it.
$dirty = & git -C $repoRoot status --porcelain 2>&1
if ($LASTEXITCODE -ne 0) { throw "git status failed in $repoRoot (exit $LASTEXITCODE): $dirty" }
if ($dirty) { throw "$repoRoot has uncommitted changes; commit or discard them first. Nothing was copied or changed.`n$($dirty -join "`n")" }
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw "Cannot read the HEAD commit of $repoRoot ('$commit')." }
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
# Review S5: an old checkout and a cutover instance. Only then is the server asked (read-only) what is installed.
if ($null -eq (Get-Command Test-ParallelProductionCutoverDefinition -ErrorAction SilentlyContinue)) {
    $installedRecord = "$opsRoot\installed-instance.json"
    $probe = Invoke-Ssh @("if (Test-Path -LiteralPath '$installedRecord') { (Get-Content -Raw -LiteralPath '$installedRecord').Contains('productionCutover') } else { 'False' }")
    $checkoutRefusal = Get-CheckoutCutoverRefusal -ModuleKnowsCutover $false -InstalledIsCutover (@($probe | ForEach-Object { "$_".Trim() }) -contains 'True') -Repository $repoRoot
    if ($checkoutRefusal) { throw $checkoutRefusal }
}
$gateRoot = "$opsRoot\dispatch-gate\$commit"
$remoteScript = "$gateRoot\$serverScript"
# The installed definition stays where the installer recorded it, beside 19's unit; the gate script is told where.
$switch = "-State $State -InstanceDefinitionPath `"$opsRoot\installed-instance.json`""

Write-Step "Target: $SshAlias  v2 parallel instance, server-side script $remoteScript (control-server $commit)"
Write-Step "Requested: RiotCreateDispatch.enabled=$($State -eq 'Open' ? 'true' : 'false') (the server resolves the V2 service and file from installed-instance.json)"

# Staged on both paths, the dry run included (see .PARAMETER WhatIf): only this commit's own directory is
# written, and nothing the instance, the MVP or 19's unit in opsRoot reads.
Invoke-Ssh @("New-Item -ItemType Directory -Force -Path '$gateRoot' | Out-Null")
foreach ($name in @('ParallelInstance.psm1', 'ParallelHost.psm1', $serverScript)) {
    & scp -q (Join-Path $parallelScripts $name) "${SshAlias}:$(& $toPosix "$gateRoot\$name")"
    if ($LASTEXITCODE -ne 0) { throw "scp of $name failed (exit $LASTEXITCODE). The gate was not changed." }
}
Write-Step "Server-side script and modules staged in $gateRoot (what 19 deployed in $opsRoot is untouched)"

if (-not $PSCmdlet.ShouldProcess($SshAlias, "Set the v2 parallel instance's RIoT dispatch gate $State and restart its service")) {
    # The server-side script's own -WhatIf branch reads only; Test-ParallelInstance.ps1 pins that it does.
    Invoke-Ssh @("pwsh -NoProfile -File `"$remoteScript`" $switch -WhatIf")
    return
}

Invoke-Ssh @("pwsh -NoProfile -File `"$remoteScript`" $switch -Confirm:`$false")
Write-Step "Done. The MVP service was not involved."
