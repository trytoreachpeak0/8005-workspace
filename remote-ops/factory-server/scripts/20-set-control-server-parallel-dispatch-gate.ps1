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
      * reads the instance's own SQLite store, read-only, and RIoT, GET only (8005-workspace#68; with a checkout
        that has it): -State Closed refuses while a journey is not Completed on a vehicle that may be under way --
        RIoT does not show it standing still with no unfinished order, or it holds a fault (a vehicle parked on its
        charger no longer holds the gate); -State Open refuses while any journey has an order that was or may have
        been sent to RIoT, except a CONFIRMED one RIoT shows ended (SUCCESS, FAILED, CANCELED) -- journeys waiting
        for the gate are allowed, they are what opening it is for;
      * reads both once with the service running and once after stopping it; a refusal on the second read
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

.PARAMETER IoCheckRecord
    workspace#51. Required for -State Open when the installed definition is in the production phase of the cutover
    (productionCutover.phase "production", read over one read-only ssh before anything is copied): the record that
    remote-ops/onboard-hmi/scripts/20-check-production-io.ps1 wrote after reading every vehicle's ioModule back. It
    must be under six hours old, cover every vehicle of the installed fleet and say OK for each; otherwise the gate
    is not opened (IO_CHECK_RECORD_*). In the trial phase, outside a cutover, and for -State Closed it is not asked
    for: closing a gate is never held up.

.PARAMETER RecoveryJourneyId
    8005-workspace#61, with -RecoveryVehicleAlias and -State Closed only. The whole JourneyId
    (journey:<demandId>|g<generation>, quoted for the '|') of each journey a vehicle stuck on a slot operation result is
    recovered from; several, comma-separated, each paired by position with -RecoveryVehicleAlias. Without it, closing is
    refused while such a journey's vehicle may be under way (until 8005-workspace#68: while any journey is not
    Completed, which such a journey is not) -- while 18's recovery window, 19 and the task-type station activation all
    need the gate closed first. With it, closing lets each named journey through while
    it is on its vehicle, Blocked on a slot operation result that needs recovery (LOAD_RESULT_REQUIRES_RECOVERY,
    UNLOAD_RESULT_REQUIRES_RECOVERY, <messageType>_NOT_RECONCILED), and its vehicle holds no fault (a restart would drop
    the stop proof of a fault that stands; wait until it clears -- the held order resumed -- or for control-server#771).
    Opening after it: see remote-ops/factory-server/docs/wire-to-gate-parallel-cd.md section 10. The server-side half judges (Get-ParallelDispatchGateRefusal -RecoveryJourney in the control-server checkout).
    Every other journey is judged as without it, and so is every other check. Opening is not widened: control-server#771
    takes the journey to Completed, after which the ordinary -State Open sees it no more. Needs a checkout that has it
    (CHECKOUT_PREDATES_RECOVERY_JOURNEY otherwise, before anything is copied).

.PARAMETER RecoveryVehicleAlias
    With -RecoveryJourneyId, one per journey, in the same order: the vehicle that journey must be on (agv01, agv02, agv03). Its agvId and
    vehicleSafety.expectedVehicleKey are read from remote-ops/onboard-hmi/config/site-<alias>.json and must equal the
    journey row's AgvId and VehicleKey.

.PARAMETER WhatIf
    The dry run: stages this commit's copy in <opsRoot>\dispatch-gate\<commit> (the same staging a real
    run does), then runs it with -WhatIf, which prints what the journey check says now, and stops. It
    stops, starts and writes nothing of the instance. Staging is done even here on purpose: without it a
    dry run of a new commit would have nothing to run, and the step "dry run first" would show nothing.
    Staging only adds files under this commit's own directory -- nothing the service, its configuration,
    the MVP or 19-deploy-control-server-parallel.ps1 reads -- and staging the same commit again writes
    the same bytes. So it is not counted as a change for ShouldProcess; what -WhatIf withholds is the
    gate change and the restart. workspace#51: in the production phase -State Open -WhatIf asks for
    -IoCheckRecord too -- the check runs before staging, read-only, so the dry run shows the refusal the
    real run would meet.

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1 -State Closed -ControlServerRepository <checkout> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Exactly as spelled (8005-workspace#61): 'closed' used to pass here, skip the IO check below and reach the server as an opening.
    [Parameter(Mandatory = $true)][ValidateSet('Closed', 'Open', IgnoreCase = $false)][string] $State,

    [Parameter(Mandatory = $true)][string] $ControlServerRepository,

    [string] $InstanceDefinitionPath,

    [string] $SshAlias = 'factory01',

    [string] $IoCheckRecord,

    # The whole JourneyId as the server stores it (control-server MultiDemandJourneyPorts.cs). Checked, and split on commas,
    # in Get-RecoveryJourneyTarget: under pwsh -File, "a,b" arrives as one string, not as an array.
    [string[]] $RecoveryJourneyId,

    [string[]] $RecoveryVehicleAlias
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

function Get-InstalledCutoverProbeCommand {
    <#
        The read-only PowerShell the server runs to say whether its installed definition is a production cutover: 'True' or
        'False' on one line. No double quote in it (it travels through ssh): the key's quotes are [char]34. Pure; Test-DeployControlServerParallel.ps1 runs the text it returns against scratch files.
    #>
    param([Parameter(Mandatory = $true)][string] $RecordPath)
    $quoted = $RecordPath.Replace("'", "''")
    return "if (Test-Path -LiteralPath '$quoted') { (Get-Content -Raw -LiteralPath '$quoted').Contains([string][char]34 + 'productionCutover' + [char]34) } else { 'False' }"
}

function Get-RecoveryJourneyTarget {
    <#
        8005-workspace#61. The journeys the server-side half is to judge on their own, as @{ journeyId; agvId; vehicleKey;
        alias } entries written to the pipeline one by one (collect them with @(...)), none without -RecoveryJourneyId. agvId and vehicleKey come from each
        vehicle's site file, the same two identities the server records on the journey row. Throws before anything is
        copied. Pure but for reading the site files.
    #>
    param([string[]] $JourneyId, [string[]] $VehicleAlias, [string] $SiteDirectory, [string] $State)
    # pwsh -File passes "a,b" as one string; a call from pwsh passes an array. Both end up as one list here.
    $ids = @($JourneyId | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $aliases = @($VehicleAlias | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ids.Count -eq 0 -and $aliases.Count -eq 0) { return }
    $badId = @($ids | Where-Object { $_ -cnotmatch '^[A-Za-z0-9:._|-]{1,200}$' })
    $badAlias = @($aliases | Where-Object { $_ -cnotin @('agv01', 'agv02', 'agv03') })
    if ($badId.Count -gt 0 -or $badAlias.Count -gt 0) {
        throw ("-RecoveryJourneyId takes whole journey ids ([A-Za-z0-9:._|-], at most 200) and -RecoveryVehicleAlias agv01, agv02 or agv03: " +
            "refused $(@($badId + $badAlias) -join ', '). Nothing was copied or changed.")
    }
    # -State binds only as 'Closed' or 'Open', exactly (review L1).
    if ($State -cne 'Closed') {
        throw '-RecoveryJourneyId is for -State Closed only; opening is not widened (control-server#771 takes the journey to Completed). Nothing was copied or changed.'
    }
    if ($ids.Count -ne $aliases.Count) {
        throw ("-RecoveryJourneyId and -RecoveryVehicleAlias go together, one vehicle per journey in the same order: $($ids.Count) journey(s), " +
            "$($aliases.Count) vehicle(s). Nothing was copied or changed.")
    }
    if (@($ids | Sort-Object -Unique -CaseSensitive).Count -ne $ids.Count) { throw '-RecoveryJourneyId names a journey twice. Nothing was copied or changed.' }
    $targets = for ($i = 0; $i -lt $ids.Count; $i++) {
        $sitePath = Join-Path $SiteDirectory "site-$($aliases[$i]).json"
        try { $site = Get-Content -Raw -LiteralPath $sitePath | ConvertFrom-Json -AsHashtable }
        catch { throw "$sitePath cannot be read ($($_.Exception.Message)). Nothing was copied or changed." }
        $agvId = [string] $site['agvId']
        $safety = $site['vehicleSafety']
        $vehicleKey = $safety -is [System.Collections.IDictionary] ? [string] $safety['expectedVehicleKey'] : ''
        if ([string]::IsNullOrWhiteSpace($agvId) -or [string]::IsNullOrWhiteSpace($vehicleKey)) {
            throw "$sitePath lacks agvId or vehicleSafety.expectedVehicleKey, which the recovery journey is matched against. Nothing was copied or changed."
        }
        @{ journeyId = $ids[$i]; agvId = $agvId; vehicleKey = $vehicleKey; alias = $aliases[$i] }
    }
    return $targets
}

# The cutover contract this script was written for (control-server#564 review round 2, L3): a checkout must carry at least
# this version of Get-ParallelCutoverContractVersion to act on an installed cutover. Revision 1 of #677 already had
# Test-ParallelProductionCutoverDefinition, but not the MVP checks.
$script:RequiredCutoverContract = 2

function Invoke-Ssh {
    param([string[]] $Arguments)
    $output = & ssh $SshAlias @Arguments 2>&1
    $output | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed (exit $LASTEXITCODE)" }
    return $output
}

$recoveryTarget = @(Get-RecoveryJourneyTarget -JourneyId $RecoveryJourneyId -VehicleAlias $RecoveryVehicleAlias `
    -SiteDirectory (Join-Path $PSScriptRoot '../../onboard-hmi/config') -State $State)
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
# 8005-workspace#61: an older checkout's server-side script has no -RecoveryJourney and would refuse the argument.
if ($recoveryTarget.Count -gt 0 -and -not (Get-Command ConvertTo-ParallelRecoveryJourneyArgument -ErrorAction SilentlyContinue)) {
    throw ("CHECKOUT_PREDATES_RECOVERY_JOURNEY: $repoRoot has no ConvertTo-ParallelRecoveryJourneyArgument, so its server-side " +
        'script does not know -RecoveryJourney (8005-workspace#61). Use a checkout that has it. Nothing was copied or changed.')
}

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
# Review round 2, L3: "old" is judged by the cutover contract version, not by a function revision 1 of #677 already had.
$contract = (Get-Command Get-ParallelCutoverContractVersion -ErrorAction SilentlyContinue) ? (Get-ParallelCutoverContractVersion) : 0
if ($contract -lt $script:RequiredCutoverContract) {
    $probe = Invoke-Ssh @(Get-InstalledCutoverProbeCommand -RecordPath "$opsRoot\installed-instance.json")
    $checkoutRefusal = Get-CheckoutCutoverRefusal -ModuleKnowsCutover $false -InstalledIsCutover (@($probe | ForEach-Object { "$_".Trim() }) -contains 'True') -Repository $repoRoot
    if ($checkoutRefusal) { throw $checkoutRefusal }
}
# workspace#51. No gate opens in the production phase until every vehicle of the installed fleet has been read back on
# its real IO module. Read-only, before anything is copied; closing is never held up.
if ($State -eq 'Open') {
    Import-Module (Join-Path $PSScriptRoot '../../onboard-hmi/scripts/ProductionIo.psm1') -Force
    $installedPhase = Read-ServerCutoverPhase -ServerSshAlias $SshAlias -OnboardPort 0 -RecordPath "$opsRoot\installed-instance.json"
    Write-Step "Installed phase: $($installedPhase.Phase); fleet: $(@($installedPhase.FleetVehicleKeys) -join ', ')"
    if ($installedPhase.Phase -ceq 'production') {
        $record = $null
        if ($IoCheckRecord) {
            try { $record = Get-Content -Raw -LiteralPath $IoCheckRecord | ConvertFrom-Json -AsHashtable }
            catch { $record = @{ kind = "unreadable: $($_.Exception.Message)" } }
        }
        $ioRefusal = Get-IoCheckRecordRefusal -Record $record -FleetVehicleKeys @($installedPhase.FleetVehicleKeys) -Now ([DateTimeOffset]::Now)
        if ($ioRefusal) { throw "$ioRefusal The gate was not changed and nothing was copied." }
        Write-Step "IO check record ${IoCheckRecord}: every vehicle of the installed fleet is on its real module (checked $($record['checkedAt']))"
    }
}

$gateRoot = "$opsRoot\dispatch-gate\$commit"
$remoteScript = "$gateRoot\$serverScript"
# The installed definition stays where the installer recorded it, beside 19's unit; the gate script is told where.
$switch = "-State $State -InstanceDefinitionPath `"$opsRoot\installed-instance.json`""
if ($recoveryTarget.Count -gt 0) {
    # Base64: the id carries '|' and the agvId is Chinese, and neither may be re-quoted or re-encoded through ssh.
    $switch += ' -RecoveryJourney ' + (ConvertTo-ParallelRecoveryJourneyArgument -Journeys $recoveryTarget)
}

Write-Step "Target: $SshAlias  v2 parallel instance, server-side script $remoteScript (control-server $commit)"
Write-Step "Requested: RiotCreateDispatch.enabled=$($State -eq 'Open' ? 'true' : 'false') (the server resolves the V2 service and file from installed-instance.json)"
foreach ($target in $recoveryTarget) {
    Write-Step "Recovery journey: $($target.journeyId) on $($target.alias) ($($target.agvId) / $($target.vehicleKey)) -- judged on its own by the server-side half"
}

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
