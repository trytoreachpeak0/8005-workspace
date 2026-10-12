#Requires -Version 7
<#
.SYNOPSIS
    Opens, closes or reports the recovery window on agv02 / agv03 against the v2 parallel instance
    on factory01. The v2 counterpart of 14-set-recovery-window.ps1, which stays the MVP line's
    (agv01 + the MVP service). Runs on the control host.

.DESCRIPTION
    What "the recovery window" is, read from the code (8005-workspace#25):

    * Vehicle: wireToGate.recoveryResumeEnabled (the maintenance switch) and the machine variable
      CONTROL_SERVER_RECOVERY_PROOF. Every recovery-administrator entry on the onboard screen --
      「确认清桩」, 「充电后返回服务」, the recovery vectors -- needs both, plus an operator id. In
      Production the client refuses to start when the switch is on and the variable is missing.
    * Server: the v2 instance checks the proof a vehicle sends in ExceptionRecoverySessionRequested
      against CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF (the fallback of
      Recovery:AuthenticationProofEnvironmentVariable, which no v2 deployment sets), byte for byte.
      CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL is a different secret and is not touched.
    * 「确认清桩」 does not send the proof; the server needs onboardClearanceEntryDeclared and the
      operator id in the R-11/R-13 roster. Those belong to the v2 instance definition.

    One proof serves both vehicles (the server has one variable). It lives in the control host's DPAPI
    store with the list of vehicles whose window is open. It travels on ssh's standard input inside a
    one-line JSON request; no staged file, command line or output carries it.

    Which server and which instance are not parameters: the server is factory01, and everything about
    the instance -- service name, install root, onboard port -- comes from the definition the installer
    recorded there (installed-instance.json), read by the server half with control-server's own
    modules, staged from -ControlServerRepository as 20-set-control-server-parallel-dispatch-gate.ps1
    stages them. Only opsRoot is read here, from the repository's instance definition, to know where.

    Order (each remote half is in V2RecoveryWindow.psm1):
      Open:  server check (read-only) -> vehicle (variable, read back, then switch) -> store records the
             vehicle -> server entry (checks again, write, read back, restart).
      Close: when it is the last open vehicle, server check (read-only) first -> vehicle (switch off,
             then variable) -> store drops the vehicle -> server entry removed -> store deleted.
             Another vehicle still open: the vehicle only; the server entry stays.
             Closing the last vehicle needs the V2 instance idle (the server restarts). When it is not --
             in production it usually is not -- the check refuses before the vehicle is touched and names
             -Revert -VehicleOnly, which closes the vehicle and leaves the entry, recorded as a residue.
    The server refuses before any change when: the dispatch gate is open or cannot be judged (the
    installer's pre-install refusal), a RiotCreateDispatch__* override is set, a journey is not
    Completed or the journeys cannot be read, a vehicle holds a connection to the onboard port (unless
    -AllowConnectedVehicles: a warning) or the connections cannot be read. Restarting is skipped when
    the entry already holds the proof.

    What can still be left behind: the server check and the server write are minutes apart, with the
    vehicle in between. A journey or a connection that appears in that gap makes the write refuse
    after the vehicle half is done (open: the vehicle open, the server without the entry; close: the
    vehicle closed, the server still holding it). The store records what was done, -Status shows both
    ends against it and prints a RESIDUE line computed here, and the same command again (or -Revert)
    finishes or undoes it. -Status copies the same staged files to both ends; it changes neither end's
    switch, variable or entry, nor the store.

    Shut is the factory setting, and no deployment script opens it. Re-run after re-deploying the
    onboard client (06 renders the switch back to false) or after a first install of the V2 service
    (its Environment is rebuilt).

    It starts nothing. The vehicle's client must be stopped and is left stopped. Start it with
    10-start-onboard-stack.ps1, not by a double click: the variable is written from the ssh session,
    and an Explorer that was already running does not see a machine variable written that way.

.PARAMETER SshAlias
    agv02 or agv03. Required; there is no default, and agv01 is refused by the parameter validation.

.PARAMETER ControlServerRepository
    A clean 8005-agv-control-server checkout or worktree. Its scripts/parallel/ParallelInstance.psm1 and
    ParallelHost.psm1 are staged on factory01 in <opsRoot>\recovery-window\<its HEAD commit>, beside the
    server half from this directory; its instance-factory01-v2.json gives opsRoot.

.PARAMETER Revert
    Close the window on this vehicle.

.PARAMETER Status
    Read only: the switch and the variable on this vehicle, the entry on the server, each compared
    with the store. Changes nothing.

.PARAMETER AllowConnectedVehicles
    Restart the V2 service even while a vehicle is connected to it, with a warning.

.PARAMETER VehicleOnly
    With -Revert only: close the window on the vehicle and leave the server entry, recorded in the store
    as a residue. For the end of a field window when the V2 instance is not idle (a vehicle connected, a
    journey not Completed): the server refuses to restart then, and a vehicle left open beyond its
    authorized window is the worse of the two -- an entry on the server that no vehicle holds is inert.
    Run -Revert without it later, when the instance is idle, to remove the entry.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-set-v2-recovery-window.ps1 -SshAlias agv03 -ControlServerRepository <checkout> -WhatIf

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-set-v2-recovery-window.ps1 -SshAlias agv03 -ControlServerRepository <checkout> -Status
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Change')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('agv02', 'agv03')]
    [string] $SshAlias,

    [Parameter(Mandatory = $true)]
    [string] $ControlServerRepository,

    [Parameter(ParameterSetName = 'Change')]
    [switch] $Revert,

    [Parameter(ParameterSetName = 'Status')]
    [switch] $Status,

    [Parameter(ParameterSetName = 'Change')]
    [switch] $AllowConnectedVehicles,

    [Parameter(ParameterSetName = 'Change')]
    [switch] $VehicleOnly,

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\w2g-v2-recovery-window.xml')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$SshAlias = $SshAlias.ToLowerInvariant()
if ($VehicleOnly -and -not $Revert) { throw '-VehicleOnly only closes (-Revert); opening needs both ends. Nothing was changed.' }
$serverAlias = 'factory01'
$vehicleStaging = 'C:\temp\agv\onboard-staging\v2-recovery-window'
$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

# ------------------------------------------------------ local facts, no network ---

$repoRoot = (Resolve-Path -LiteralPath $ControlServerRepository).Path
$parallelScripts = Join-Path $repoRoot 'scripts\parallel'
foreach ($name in 'ParallelInstance.psm1', 'ParallelHost.psm1', 'instance-factory01-v2.json') {
    if (-not (Test-Path -LiteralPath (Join-Path $parallelScripts $name) -PathType Leaf)) { throw "No scripts/parallel/$name in $repoRoot. Nothing was changed." }
}
$dirty = & git -C $repoRoot status --porcelain 2>&1
if ($LASTEXITCODE -ne 0) { throw "git status failed in $repoRoot (exit $LASTEXITCODE). Nothing was changed." }
if ($dirty) { throw "$repoRoot has uncommitted changes; the modules staged on the server would not be its HEAD. Nothing was changed." }
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw "Cannot read the HEAD commit of $repoRoot. Nothing was changed." }
Import-Module (Join-Path $parallelScripts 'ParallelInstance.psm1') -Force
$definition = Read-ParallelInstanceDefinition -Path (Join-Path $parallelScripts 'instance-factory01-v2.json')
$opsRoot = [string] $definition['opsRoot']
$opsProblem = Test-ParallelInstanceOwnedPath -Path $opsRoot
if ($opsProblem) { throw "opsRoot $opsProblem. Nothing was changed." }
$serverStaging = "$opsRoot\recovery-window\$commit"

$sitePath = Join-Path (Split-Path -Parent $PSScriptRoot) "config\site-$SshAlias.json"
$site = Get-Content -Raw -LiteralPath $sitePath -Encoding utf8 | ConvertFrom-Json
$installRoot = [string] $site.install.root
$onboardInstanceId = [string] $site.wireToGate.onboardInstanceId
if ([string]::IsNullOrWhiteSpace($installRoot) -or $onboardInstanceId -notmatch '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') {
    throw "$sitePath lacks install.root or a wireToGate.onboardInstanceId UUID. Nothing was changed."
}

function Read-Store {
    if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) { return $null }
    try {
        $stored = Import-Clixml -LiteralPath $SecretPath
        $proof = [System.Net.NetworkCredential]::new('', $stored['RecoveryProof']).Password
    } catch {
        throw ("STORE_UNREADABLE: $SecretPath cannot be decrypted by this account on this machine ($($_.Exception.Message)). " +
            'Nothing was changed. See USAGE.md, "v2 线的恢复窗口", for closing the window by hand.')
    }
    if ($proof -cnotmatch '^[0-9a-f]{64}$') { throw "STORE_UNREADABLE: $SecretPath holds no well-formed proof. Nothing was changed." }
    return @{ Proof = $proof; OpenVehicles = [string[]] @($stored['OpenVehicles'] | Where-Object { $_ }) }
}

function Write-Store {
    param([string] $Proof, [string[]] $OpenVehicles)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SecretPath) -WhatIf:$false | Out-Null
    @{
        RecoveryProof = (ConvertTo-SecureString $Proof -AsPlainText -Force)
        OpenVehicles = [string[]] @($OpenVehicles | Where-Object { $_ } | Sort-Object -Unique)
    } | Export-Clixml -LiteralPath $SecretPath -WhatIf:$false
}

$store = Read-Store
$others = @($store ? @($store.OpenVehicles | Where-Object { $_ -ne $SshAlias }) : @())
$last = $others.Count -eq 0
# Closing the last open vehicle removes the server entry too, unless -VehicleOnly leaves it for later.
$serverClose = $Revert -and $last -and -not $VehicleOnly

# -------------------------------------------------------------------- remote ---

function Invoke-Remote {
    param([Parameter(Mandatory)][string] $Alias, [Parameter(Mandatory)][string] $Script, [Parameter(Mandatory)][hashtable] $Request)
    $line = $Request | ConvertTo-Json -Compress
    $output = $line | & ssh $Alias "pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$Script'" 2>&1
    $exit = $LASTEXITCODE
    $output | ForEach-Object { Write-Host "  $_" }
    if ($exit -ne 0) { throw "$(Split-Path -Leaf $Script) refused or failed on $Alias (exit $exit). See the lines above." }
    return @($output | ForEach-Object { "$_" })
}

function Copy-Staged {
    param([string] $Alias, [string] $Directory, [string[]] $Files)
    & ssh $Alias "pwsh -NoLogo -NoProfile -NonInteractive -Command `"New-Item -ItemType Directory -Force -Path '$Directory' | Out-Null`""
    if ($LASTEXITCODE -ne 0) { throw "ssh $Alias failed preparing $Directory (exit $LASTEXITCODE). Nothing was changed." }
    foreach ($file in $Files) {
        & scp -q $file "${Alias}:$(& $toPosix "$Directory\$(Split-Path -Leaf $file)")"
        if ($LASTEXITCODE -ne 0) { throw "scp of $(Split-Path -Leaf $file) to $Alias failed (exit $LASTEXITCODE). Nothing was changed." }
    }
}

$module = Join-Path $PSScriptRoot 'V2RecoveryWindow.psm1'
$serverScript = "$serverStaging\server-v2-recovery-window.ps1"
$vehicleScript = "$vehicleStaging\agv-v2-recovery-window.ps1"
$vehicleRequest = { param([string] $State, [string] $Proof)
    $r = @{ state = $State; installRoot = $installRoot; onboardInstanceId = $onboardInstanceId }
    if ($Proof) { $r['proof'] = $Proof }
    $r
}
$serverRequest = { param([string] $Mode, [string] $Target, [string] $Proof)
    $r = @{ mode = $Mode; allowConnectedVehicles = $AllowConnectedVehicles.IsPresent }
    if ($Target) { $r['target'] = $Target }
    if ($Proof) { $r['proof'] = $Proof }
    $r
}

# ---------------------------------------------------------------------- plan ---

$action = $Status ? 'Report' : ($Revert ? 'Close' : 'Open')
$recorded = $store ? (@($store.OpenVehicles) -join ', ') : $null
Write-Step "$action the v2 recovery window on $SshAlias (site $(Split-Path -Leaf $sitePath), install root $installRoot)"
Write-Step "Server: $serverAlias, the instance recorded in $opsRoot\installed-instance.json; control-server modules from $commit"
Write-Step ("Store {0}: {1}" -f $SecretPath, ($null -eq $store ? '(none)' : "open on $($recorded ? $recorded : '(no vehicle)')"))
if (-not $Status) {
    Write-Step ("Vehicle: CONTROL_SERVER_RECOVERY_PROOF {0}; recoveryResumeEnabled {1}" -f
        ($Revert ? 'removed after the switch is off' : 'set and read back before the switch'), (-not $Revert).ToString().ToLowerInvariant())
    Write-Step ("Server: {0}" -f $(if (-not $Revert) { 'checked first; CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF set after the vehicle (no restart when it already holds the proof)' }
            elseif ($serverClose) { 'checked first; CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF removed after the vehicle (needs the V2 instance idle)' }
            elseif ($last) { 'untouched (-VehicleOnly): its CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF stays, recorded in the store as a residue' }
            else { "untouched: still open on $($others -join ', ')" }))
    Write-Step ("Proof: {0}" -f $(if ($Revert) { 'not needed' } elseif ($store) { 'reused from the store' } else { 'to be generated and stored' }))
}

if (-not $PSCmdlet.ShouldProcess("$SshAlias and the V2 service on $serverAlias", "$action the v2 recovery window")) {
    Write-Step 'WhatIf: stopping before any machine is reached or the store is written.'
    return
}

# ------------------------------------------------------------------- staging ---

# Staged files carry no secret: the request, proof included, goes on standard input. The server is
# staged only when this run needs it, the vehicle only once the server check has passed.
$stageServer = {
    Copy-Staged -Alias $serverAlias -Directory $serverStaging -Files @(
        (Join-Path $parallelScripts 'ParallelInstance.psm1'), (Join-Path $parallelScripts 'ParallelHost.psm1'),
        $module, (Join-Path $PSScriptRoot 'server-v2-recovery-window.ps1'))
}
$stageVehicle = { Copy-Staged -Alias $SshAlias -Directory $vehicleStaging -Files @($module, (Join-Path $PSScriptRoot 'agv-v2-recovery-window.ps1')) }

# -------------------------------------------------------------------- status ---

if ($Status) {
    $proof = $store ? $store.Proof : $null
    & $stageVehicle
    & $stageServer
    Write-Step "Vehicle $SshAlias"
    $vehicleLines = Invoke-Remote -Alias $SshAlias -Script $vehicleScript -Request (& $vehicleRequest 'Status' $proof)
    Write-Step "Server $serverAlias"
    $serverLines = Invoke-Remote -Alias $serverAlias -Script $serverScript -Request (& $serverRequest 'status' $null $proof)
    $read = { param([string[]] $Lines, [string] $Key) $m = @($Lines | Where-Object { $_ -match "^$([regex]::Escape($Key))=(\S+)" } | Select-Object -First 1); $m ? ($m[0] -split '=', 2)[1] : '(not reported)' }
    $switch = & $read $vehicleLines 'recoveryResumeEnabled'
    $variable = & $read $vehicleLines 'CONTROL_SERVER_RECOVERY_PROOF'
    $entry = & $read $serverLines 'ENTRY'
    $vehicleOpen = $null -ne $store -and @($store.OpenVehicles) -contains $SshAlias
    $serverHeld = $null -ne $store -and @($store.OpenVehicles).Count -gt 0
    $residues = [System.Collections.Generic.List[string]]::new()
    if ($vehicleOpen) {
        if ($switch -cne 'True' -or $variable -cne 'same') { $residues.Add("vehicle $SshAlias is recorded open but reads switch=$switch, variable=$variable -- run the open command again, or -Revert") }
    } else {
        if ($switch -cne 'False') { $residues.Add("vehicle $SshAlias is not recorded open but its switch reads $switch -- run -Revert") }
        if ($variable -cne 'absent') { $residues.Add("vehicle $SshAlias is not recorded open but CONTROL_SERVER_RECOVERY_PROOF reads $variable -- run -Revert (a close stopped after the switch, or an open stopped after the variable)") }
    }
    if ($serverHeld) {
        if ($entry -cne 'same') { $residues.Add("the server entry reads $entry while $(@($store.OpenVehicles) -join ', ') is recorded open -- run the open command again") }
    } elseif ($entry -cne 'absent') {
        $residues.Add("the server entry reads $entry while no vehicle is recorded open -- run -Revert on either vehicle when the V2 instance is idle")
    }
    Write-Step ("Store: {0}" -f ($null -eq $store ? '(none)' : "open on $($recorded ? $recorded : '(no vehicle)')"))
    Write-Host ("RESIDUE: {0}" -f ($residues.Count ? ($residues -join '; ') : 'none'))
    return
}

# --------------------------------------------------------------------- proof ---

$proof = $null
if (-not $Revert) {
    if ($store) {
        $proof = $store.Proof
    } else {
        # 32 bytes, hex: it travels through JSON, a registry MultiString and a protocol payload.
        $proof = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        Write-Store -Proof $proof -OpenVehicles @()
        $store = Read-Store
        Write-Step "Generated a new proof and stored it at $SecretPath"
    }
}

# --------------------------------------------------------------------- apply ---

if (-not $Revert) {
    & $stageServer
    Write-Step "Server check on $serverAlias (read-only)"
    Invoke-Remote -Alias $serverAlias -Script $serverScript -Request (& $serverRequest 'check' 'set' $proof) | Out-Null
    & $stageVehicle
    Write-Step "Vehicle half on $SshAlias"
    Invoke-Remote -Alias $SshAlias -Script $vehicleScript -Request (& $vehicleRequest 'Open' $proof) | Out-Null
    Write-Store -Proof $proof -OpenVehicles (@($store.OpenVehicles) + $SshAlias)
    Write-Step "Server half on $serverAlias"
    Invoke-Remote -Alias $serverAlias -Script $serverScript -Request (& $serverRequest 'set' $null $proof) | Out-Null
    Write-Step "Recovery window open on $SshAlias. The client is still stopped -- starting it is a field step."
    Write-Host ''
    Write-Host '  Start the client with 10-start-onboard-stack.ps1 (field authorization), not by a double click:' -ForegroundColor DarkGray
    Write-Host '  a client started from an Explorer that predates the variable does not see it and refuses to start.' -ForegroundColor DarkGray
    Write-Host '  Close the window when it ends:' -ForegroundColor DarkGray
    Write-Host "    pwsh -File remote-ops/onboard-hmi/scripts/18-set-v2-recovery-window.ps1 -SshAlias $SshAlias -ControlServerRepository <checkout> -Revert" -ForegroundColor DarkGray
    Write-Host '  Re-run the open after re-deploying the onboard client, or after a first install of the V2 service.' -ForegroundColor DarkGray
    return
}

if ($serverClose) {
    & $stageServer
    Write-Step "Server check on $serverAlias (read-only)"
    try {
        Invoke-Remote -Alias $serverAlias -Script $serverScript -Request (& $serverRequest 'check' 'remove' $null) | Out-Null
    } catch {
        throw ("$($_.Exception.Message) The vehicle was not touched. Removing the server entry needs the V2 instance idle; to close the " +
            "vehicle now and leave the entry for later, run: 18-set-v2-recovery-window.ps1 -SshAlias $SshAlias -ControlServerRepository <checkout> -Revert -VehicleOnly")
    }
}
& $stageVehicle
Write-Step "Vehicle half on $SshAlias"
Invoke-Remote -Alias $SshAlias -Script $vehicleScript -Request (& $vehicleRequest 'Close' $null) | Out-Null
if ($store) { Write-Store -Proof $store.Proof -OpenVehicles $others }
if (-not $last) {
    Write-Step "Recovery window closed on $SshAlias. Still open on $($others -join ', '); the server entry stays."
    return
}
if ($VehicleOnly) {
    Write-Step ("Recovery window closed on $SshAlias (-VehicleOnly). The server entry was left; " +
        $(if ($store) { 'the store keeps the proof with no vehicle open, which -Status reports as a residue.' } else { 'there is no store, so -Status will report the entry if it is there.' }) +
        ' Run -Revert without -VehicleOnly when the V2 instance is idle.')
    return
}
Write-Step "Server half on $serverAlias"
Invoke-Remote -Alias $serverAlias -Script $serverScript -Request (& $serverRequest 'remove' $null $null) | Out-Null
Remove-Item -LiteralPath $SecretPath -Force -ErrorAction SilentlyContinue -WhatIf:$false
Write-Step 'Recovery window closed on the last open vehicle. Server entry removed, stored proof deleted.'
