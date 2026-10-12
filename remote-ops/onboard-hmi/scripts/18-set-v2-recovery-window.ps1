#Requires -Version 7
<#
.SYNOPSIS
    Opens or closes the recovery window on agv02 / agv03 against the v2 parallel
    instance ('8005 AGV ControlServer V2' on factory01). The v2 counterpart of
    14-set-recovery-window.ps1, which stays the MVP line's (agv01 + the MVP
    service). Runs on the control host.

.DESCRIPTION
    What "the recovery window" is, read from the code (8005-workspace#25):

    * Vehicle: wireToGate.recoveryResumeEnabled (the maintenance switch) and the
      machine variable CONTROL_SERVER_RECOVERY_PROOF. Every recovery-administrator
      entry on the onboard screen -- 「确认清桩」, 「充电后返回服务」, the recovery
      vectors -- needs both (CanUseRecoveryOperator(requireProof: true)), plus an
      operator id. In Production the client refuses to start when the switch is
      on and the variable is missing (SQCD.Agv.Infrastructure/Configuration.cs).
    * Server: the v2 instance checks the proof a vehicle sends in
      ExceptionRecoverySessionRequested against the variable named by
      Recovery:AuthenticationProofEnvironmentVariable, which no v2 deployment
      sets, so it is the fallback CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF.
      FixedTimeEquals over UTF-8 bytes: the two ends must hold the same value.
      CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL is a different secret (the Host
      endpoints' bearer) and is not touched here.
    * 「确认清桩」 does not send the proof; the server judges the operator id
      against the R-11/R-13 roster, and accepts the request only with
      fieldOperatorRoles.onboardClearanceEntryDeclared = true. Those two belong
      to the v2 instance definition, not to this script.

    One proof serves both vehicles (the server has one variable). It lives in
    the control host's DPAPI store with the list of vehicles whose window is
    open. -Revert closes one vehicle; the server entry and the store go only
    when the last open vehicle closes.

    The proof never touches a disk outside the DPAPI store: it reaches each
    machine on ssh's standard input, not inside the staged script, and nothing
    prints it. Output names variables only.

    Restarting the V2 service is needed only when its entry changes. Before
    that the server is checked, and the run refuses with nothing changed when:
      * the service is not Running or Stopped, or is the MVP service;
      * RIoT dispatch may be open: RiotCreateDispatch.enabled is true in the
        installed appsettings.Production.json, the file is unreadable, it was
        written after the running process started (so the file is not what the
        process does), or a RiotCreateDispatch__* entry sits in the service
        Environment;
      * a vehicle holds an established connection to the onboard port. A
        restart drops it into recovery and stops the supervision of whatever
        journey it carries. The server exposes no journey list, and a journey
        can only progress with its vehicle connected, so a connection is the
        signal. -AllowConnectedVehicles turns this one refusal into a warning,
        for a field run whose people have accepted that the other vehicle
        reconnects into recovery.

    Shut is the factory setting, and no deployment script opens it. The other
    way round is the trap: 06-deploy-onboard-hmi.ps1 renders the switch back to
    false while the machine variable stays, and a first install (or uninstall
    and reinstall) of the V2 service rebuilds its Environment without the
    server entry. Re-run this script after either, inside a window.

    It starts nothing. The vehicle's client must be stopped and is left stopped.

.PARAMETER SshAlias
    agv02 or agv03. Required; there is no default, and agv01 is refused by the
    parameter validation.

.PARAMETER Revert
    Close the window on this vehicle.

.PARAMETER AllowConnectedVehicles
    Restart the V2 service even while a vehicle is connected to it, with a
    warning. Without it such a run refuses before changing anything.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-set-v2-recovery-window.ps1 -SshAlias agv03 -WhatIf

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/18-set-v2-recovery-window.ps1 -SshAlias agv03 -Revert
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('agv02', 'agv03')]
    [string] $SshAlias,

    [switch] $Revert,

    [switch] $AllowConnectedVehicles,

    [string] $ServerSshAlias = 'factory01',

    [ValidateScript({
            if ($_.Trim() -ieq '8005 AGV ControlServer') { throw "'$_' is the MVP service; this script only changes the v2 parallel instance." }
            $true
        })]
    [string] $ServiceName = '8005 AGV ControlServer V2',

    [ValidateScript({
            if ($_.TrimEnd('\') -ieq 'C:\Program Files\8005 AGV\ControlServer') { throw "'$_' is the MVP install root." }
            $true
        })]
    [string] $ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer.V2',

    [ValidateRange(1, 65535)]
    [int] $OnboardPort = 58105,

    [string] $ServerOpsRoot = 'D:\zhengyushao\control-server-v2-ops',

    [string] $SitePath,

    # The same scratch directory 06-deploy-onboard-hmi.ps1 stages into.
    [string] $StagingRoot = 'C:\temp\agv\onboard-staging',

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\w2g-v2-recovery-window.xml')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

$vehicleVariable = 'CONTROL_SERVER_RECOVERY_PROOF'
$serverVariable = 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF'

if (-not $SitePath) {
    $SitePath = Join-Path (Split-Path -Parent $PSScriptRoot) "config\site-$SshAlias.json"
}
if (-not (Test-Path -LiteralPath $SitePath -PathType Leaf)) { throw "No site file at $SitePath. Nothing was changed." }
$installRoot = (Get-Content -Raw -LiteralPath $SitePath | ConvertFrom-Json).install.root
if ([string]::IsNullOrWhiteSpace($installRoot)) { throw "$SitePath has no install.root. Nothing was changed." }

# Runs a staged script on a machine. The script carries no secret; the proof, when
# given, goes on standard input and the script reads it with [Console]::In.
function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)][string] $Alias,
        [Parameter(Mandatory)][string] $Body,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $RemoteDirectory,
        [string] $StandardInput
    )
    $local = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-$(Get-Random).ps1"
    Set-Content -LiteralPath $local -Value $Body -Encoding utf8NoBOM -WhatIf:$false
    try {
        $remote = "$RemoteDirectory\$Name.ps1"
        & ssh $Alias "pwsh -NoLogo -NoProfile -Command `"New-Item -ItemType Directory -Force -Path '$RemoteDirectory' | Out-Null`""
        if ($LASTEXITCODE -ne 0) { throw "ssh $Alias failed preparing $RemoteDirectory (exit $LASTEXITCODE)" }
        & scp -q $local "${Alias}:$(& $toPosix $remote)"
        if ($LASTEXITCODE -ne 0) { throw "scp to $Alias failed (exit $LASTEXITCODE)" }
        $command = "pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File '$remote'"
        $output = if ($PSBoundParameters.ContainsKey('StandardInput')) {
            $StandardInput | & ssh $Alias $command 2>&1
        } else {
            & ssh $Alias $command 2>&1
        }
        $exit = $LASTEXITCODE
        $output | ForEach-Object { Write-Host "  $_" }
        & ssh $Alias "pwsh -NoLogo -NoProfile -Command `"Remove-Item -LiteralPath '$remote' -Force -ErrorAction SilentlyContinue`"" | Out-Null
        if ($exit -ne 0) { throw "$Name failed on $Alias (exit $exit). See the lines above." }
        return @($output | ForEach-Object { "$_" })
    } finally {
        Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# --------------------------------------------------------------- remote bodies ---

# Shared opening of every remote body: read the proof from standard input when the
# mode needs one. 64 lowercase hex characters, as generated below; anything else is
# refused before a change, so a broken pipe can never write an empty proof.
$readProof = @'
$proof = [Console]::In.ReadLine()
if ($null -eq $proof -or $proof -notmatch '^[0-9a-f]{64}$') { throw 'PROOF_NOT_RECEIVED: no well-formed proof on standard input. Nothing was changed.' }
'@

function New-VehicleBody {
    param([bool] $Open)
    $enabled = $Open.ToString().ToLowerInvariant()
    return @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$(if ($Open) { $readProof } else { '' })
`$settingsPath = '$installRoot\appsettings.json'
if (-not (Test-Path -LiteralPath `$settingsPath)) {
    throw "No onboard installation at $installRoot -- deploy it first with 06-deploy-onboard-hmi.ps1. Nothing was changed."
}
# The client reads the file and the variable at start; changing either under a
# running client takes effect at a restart nobody asked for.
if (@(Get-Process -Name 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'SQCD.Agv.Wpf is running on the vehicle. Close it before changing the recovery window. Nothing was changed.'
}

`$settings = Get-Content -Raw -LiteralPath `$settingsPath | ConvertFrom-Json
`$settings.wireToGate.recoveryResumeEnabled = [bool]::Parse('$enabled')
`$settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath `$settingsPath -Encoding utf8NoBOM
`$readBack = (Get-Content -Raw -LiteralPath `$settingsPath | ConvertFrom-Json).wireToGate.recoveryResumeEnabled
"recoveryResumeEnabled: `$readBack"
if ([string] `$readBack -ne '$(if ($Open) { 'True' } else { 'False' })') { throw "recoveryResumeEnabled read back as `$readBack." }

if (`$$Open) {
    [Environment]::SetEnvironmentVariable('$vehicleVariable', `$proof, 'Machine')
    "$vehicleVariable set (machine scope, value not shown)"
} else {
    # [NullString]::Value, not `$null: `$null reaches a .NET string parameter as ""
    # and writes an empty REG_SZ instead of deleting (agv01, 2026-09-10).
    [Environment]::SetEnvironmentVariable('$vehicleVariable', [NullString]::Value, 'Machine')
    "$vehicleVariable removed"
}
"@
}

# Mode: 'check' reads only; 'set' and 'remove' change the entry and restart the
# service, after the same checks. Every refusal throws before a change.
function New-ServerBody {
    param([ValidateSet('check', 'set', 'remove')][string] $Mode, [bool] $AllowConnected)
    $needsProof = $Mode -ne 'remove'
    return @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$(if ($needsProof) { $readProof } else { '' })
`$serviceName = '$ServiceName'
if (`$serviceName.Trim() -ieq '8005 AGV ControlServer') { throw 'Refusing the MVP service. Nothing was changed.' }
`$key = "SYSTEM\CurrentControlSet\Services\`$serviceName"
`$registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(`$key, `$false)
if (`$null -eq `$registryKey) { throw "SERVICE_MISSING: no service '`$serviceName'. Nothing was changed." }
try { [string[]] `$environment = @(`$registryKey.GetValue('Environment', [string[]] @())) } finally { `$registryKey.Close() }
`$environment = @(`$environment | Where-Object { `$_ })
`$current = @(`$environment | Where-Object { `$_.StartsWith('$serverVariable=', [StringComparison]::OrdinalIgnoreCase) })
`$entry = if (`$current.Count -eq 0) { 'absent' } elseif ($(if ($needsProof) { "`$current.Count -eq 1 -and `$current[0].Substring($($serverVariable.Length + 1)) -ceq `$proof" } else { '$false' })) { 'same' } else { 'different' }
"ENTRY=`$entry"

`$wanted = '$Mode'
if (`$wanted -eq 'check') { `$wanted = 'set' }
if ((`$wanted -eq 'set' -and `$entry -eq 'same') -or (`$wanted -eq 'remove' -and `$entry -eq 'absent')) {
    'NO_CHANGE: the service already holds what this window needs; no restart.'
    return
}

# ---- before a restart: the service, the dispatch gate, the connected vehicles ----
`$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='`$serviceName'"
if (`$service.State -notin @('Running', 'Stopped')) { throw "SERVICE_NOT_SETTLED: '`$serviceName' is `$(`$service.State). Nothing was changed." }
`$configurationPath = '$ServerInstallRoot\appsettings.Production.json'
if (-not (Test-Path -LiteralPath `$configurationPath -PathType Leaf)) { throw "INSTALLED_CONFIGURATION_MISSING: `$configurationPath. Nothing was changed." }
try { `$configuration = [IO.File]::ReadAllText(`$configurationPath) | ConvertFrom-Json -AsHashtable -Depth 12 } catch { `$configuration = `$null }
if (`$configuration -isnot [System.Collections.IDictionary]) { throw "INSTALLED_CONFIGURATION_UNREADABLE: `$configurationPath. Nothing was changed." }
`$dispatch = `$configuration['RiotCreateDispatch']
if (`$dispatch -isnot [System.Collections.IDictionary] -or `$dispatch['enabled'] -isnot [bool]) { throw 'DISPATCH_GATE_UNKNOWN: RiotCreateDispatch.enabled is not a boolean in the installed configuration. Nothing was changed.' }
if (`$dispatch['enabled']) { throw 'DISPATCH_GATE_OPEN: RiotCreateDispatch.enabled is true. Close the gate (20-set-control-server-parallel-dispatch-gate.ps1) before a window restarts the service. Nothing was changed.' }
if (@(`$environment | Where-Object { `$_ -like 'RiotCreateDispatch__*' }).Count -gt 0) { throw 'DISPATCH_GATE_OVERRIDDEN: a RiotCreateDispatch__* entry in the service Environment overrides the file. Nothing was changed.' }
if (`$service.State -eq 'Running') {
    `$started = (Get-Process -Id `$service.ProcessId -ErrorAction SilentlyContinue)?.StartTime
    if (`$null -eq `$started) { throw 'SERVICE_START_TIME_UNKNOWN. Nothing was changed.' }
    if ([IO.File]::GetLastWriteTimeUtc(`$configurationPath) -gt `$started.ToUniversalTime()) {
        throw 'CONFIGURATION_CHANGED_SINCE_START: the file was written after the process started, so it does not say what the process does. Nothing was changed.'
    }
}
`$connected = @(Get-NetTCPConnection -LocalPort $OnboardPort -State Established -ErrorAction SilentlyContinue)
"CONNECTED_VEHICLES=`$(`$connected.Count)"
if (`$connected.Count -gt 0) {
    `$from = (@(`$connected | ForEach-Object { `$_.RemoteAddress } | Sort-Object -Unique) -join ', ')
    if (`$$AllowConnected) {
        "WARNING: CONNECTED_VEHICLES (`$from): the restart drops them into recovery and stops the supervision of their journeys."
    } else {
        throw "CONNECTED_VEHICLES: `$(`$connected.Count) connection(s) on port $OnboardPort from `$from. A restart drops them into recovery. Stop their clients, or pass -AllowConnectedVehicles once the field has accepted it. Nothing was changed."
    }
}
if ('$Mode' -eq 'check') { 'CHECK_PASSED'; return }

# ---- the change ----
`$writable = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(`$key, `$true)
try {
    # Every other entry stays, in its order: the MES secret, the onboard and
    # fault-recovery credentials live in this same value.
    `$kept = @(`$environment | Where-Object { -not `$_.StartsWith('$serverVariable=', [StringComparison]::OrdinalIgnoreCase) })
    [string[]] `$next = if ('$Mode' -eq 'set') { @(`$kept) + "$serverVariable=`$proof" } else { @(`$kept) }
    `$writable.SetValue('Environment', `$next, [Microsoft.Win32.RegistryValueKind]::MultiString)
    "service environment now carries: `$(@(`$next | ForEach-Object { (`$_ -split '=', 2)[0] }) -join ', ')"
} finally {
    `$writable.Close()
}
if (`$service.State -eq 'Running') {
    Restart-Service -Name `$serviceName -Force
    "service `$serviceName is `$((Get-Service -Name `$serviceName).Status)"
} else {
    "service `$serviceName is Stopped and left stopped; it reads the entry when it starts"
}
"@
}

# ----------------------------------------------------------------------- store ---

function Read-Store {
    if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) { return $null }
    $stored = Import-Clixml -LiteralPath $SecretPath
    return @{
        Proof = [System.Net.NetworkCredential]::new('', $stored['RecoveryProof']).Password
        OpenVehicles = [string[]] @($stored['OpenVehicles'] | Where-Object { $_ })
    }
}

function Write-Store {
    param([string] $Proof, [string[]] $OpenVehicles)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SecretPath) -WhatIf:$false | Out-Null
    @{
        RecoveryProof = (ConvertTo-SecureString $Proof -AsPlainText -Force)
        OpenVehicles = [string[]] @($OpenVehicles | Sort-Object -Unique)
    } | Export-Clixml -LiteralPath $SecretPath -WhatIf:$false
}

$store = Read-Store
$others = @($store ? @($store.OpenVehicles | Where-Object { $_ -ne $SshAlias }) : @())

# ------------------------------------------------------------------------ plan ---

$serverMode = if (-not $Revert) { 'set' } elseif ($others.Count -eq 0) { 'remove' } else { 'keep' }
$action = $Revert ? 'Close' : 'Open'
Write-Step "$action the v2 recovery window on $SshAlias (vehicle install root $installRoot)"
$recorded = $store ? (@($store.OpenVehicles) -join ', ') : $null
Write-Step ("Open vehicles recorded in the store: {0}" -f ($null -eq $store ? '(no store)' : ($recorded ? $recorded : '(none)')))
Write-Step ("Vehicle: wireToGate.recoveryResumeEnabled -> {0}; {1} {2}" -f (-not $Revert).ToString().ToLowerInvariant(), $vehicleVariable, ($Revert ? 'removed' : 'set'))
Write-Step ("Server {0}, service '{1}': {2}" -f $ServerSshAlias, $ServiceName, $(switch ($serverMode) {
            'set' { "$serverVariable set to the stored proof if it differs (restart after the checks)" }
            'remove' { "$serverVariable removed if present (restart after the checks)" }
            'keep' { "$serverVariable kept: still open on $($others -join ', ')" }
        }))
Write-Step ("Proof: {0}" -f $(if ($Revert) { 'not needed' } elseif ($store) { "reused from $SecretPath" } else { "to be generated and stored at $SecretPath" }))

if (-not $PSCmdlet.ShouldProcess("$SshAlias and $ServiceName on $ServerSshAlias", "$action the v2 recovery window")) {
    Write-Step 'WhatIf: stopping before any machine is reached or the store is written.'
    return
}

# ----------------------------------------------------------------------- proof ---

$proof = $null
if (-not $Revert) {
    if ($store) {
        $proof = $store.Proof
    } else {
        # 32 bytes, hex: it travels through a pipe, a registry MultiString and a JSON payload.
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $proof = [Convert]::ToHexString($bytes).ToLowerInvariant()
        Write-Store -Proof $proof -OpenVehicles @()
        $store = Read-Store
        Write-Step "Generated a new proof and stored it at $SecretPath"
    }
}

# ----------------------------------------------------------------------- apply ---

# Open: the server is checked first (read-only), so a refusal there leaves the
# vehicle untouched; then the vehicle; then the server entry. Close: the vehicle
# first, so its client cannot start on a proof the server no longer holds.
if (-not $Revert) {
    Write-Step "Server check on $ServerSshAlias"
    Invoke-RemoteScript -Alias $ServerSshAlias -Body (New-ServerBody -Mode 'check' -AllowConnected $AllowConnectedVehicles.IsPresent) `
        -Name 'v2-recovery-window-server-check' -RemoteDirectory "$ServerOpsRoot\recovery-window" -StandardInput $proof | Out-Null
}

Write-Step "Vehicle half on $SshAlias"
$vehicleArguments = @{ Alias = $SshAlias; Body = (New-VehicleBody -Open (-not $Revert)); Name = 'v2-recovery-window-vehicle'; RemoteDirectory = $StagingRoot }
if (-not $Revert) { $vehicleArguments['StandardInput'] = $proof }
Invoke-RemoteScript @vehicleArguments | Out-Null

if ($serverMode -ne 'keep') {
    Write-Step "Server half on $ServerSshAlias"
    $serverArguments = @{ Alias = $ServerSshAlias; Body = (New-ServerBody -Mode $serverMode -AllowConnected $AllowConnectedVehicles.IsPresent); Name = 'v2-recovery-window-server'; RemoteDirectory = "$ServerOpsRoot\recovery-window" }
    if ($serverMode -eq 'set') { $serverArguments['StandardInput'] = $proof }
    Invoke-RemoteScript @serverArguments | Out-Null
}

# ----------------------------------------------------------------------- after ---

if ($Revert) {
    if ($serverMode -eq 'remove') {
        Remove-Item -LiteralPath $SecretPath -Force -ErrorAction SilentlyContinue -WhatIf:$false
        Write-Step 'Recovery window closed on the last open vehicle. Server entry removed, stored proof deleted.'
    } else {
        $remaining = Read-Store
        Write-Store -Proof $remaining.Proof -OpenVehicles $others
        Write-Step "Recovery window closed on $SshAlias. Still open on $($others -join ', '); the server entry stays."
    }
} else {
    Write-Store -Proof $proof -OpenVehicles (@($store.OpenVehicles) + $SshAlias)
    Write-Step "Recovery window open on $SshAlias. The client is still stopped -- starting it is a field step."
    Write-Host ''
    Write-Host '  Close it when the window ends:' -ForegroundColor DarkGray
    Write-Host "    pwsh -File remote-ops/onboard-hmi/scripts/18-set-v2-recovery-window.ps1 -SshAlias $SshAlias -Revert" -ForegroundColor DarkGray
    Write-Host '  Re-run it after re-deploying the onboard client, or after a first install of the V2 service.' -ForegroundColor DarkGray
}
