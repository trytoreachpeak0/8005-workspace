#Requires -Version 7
<#
    The logic of the v2 recovery window (8005-workspace#25), for both ends, with every step that
    touches a machine injected. 18-set-v2-recovery-window.ps1 drives it from the control host;
    agv-v2-recovery-window.ps1 runs the vehicle half on agv02/agv03 and server-v2-recovery-window.ps1
    the server half on factory01, each wiring the real actions in. Test-SetV2RecoveryWindow.ps1 runs
    the same functions against a temporary install root and a temporary registry key.

    Nothing here imports anything: the vehicle has no control-server modules, and the server's checks
    that come from control-server (the installer's pre-install refusal, the journey reader, the
    Environment merge) are passed in as actions by the server entry script.

    No function here writes a secret value to any stream. Lines name variables and say present,
    absent, same or different.
#>

Set-StrictMode -Version 3.0

$script:VehicleVariable = 'CONTROL_SERVER_RECOVERY_PROOF'
$script:ServerVariable = 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF'
$script:MvpServiceName = '8005 AGV ControlServer'
$script:MachineEnvironmentPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:ServicesPath = 'SYSTEM\CurrentControlSet\Services'
$script:ClientProcessName = 'SQCD.Agv.Wpf'

function Get-V2RecoveryWindowNames {
    [CmdletBinding()]
    param()
    return [ordered]@{
        VehicleVariable = $script:VehicleVariable
        ServerVariable = $script:ServerVariable
        MvpServiceName = $script:MvpServiceName
    }
}

function Read-V2RecoveryWindowRequest {
    <#
        .SYNOPSIS
            The request the control host sent on standard input: one line of JSON. Refused before
            anything is read or changed when it is missing, not JSON, or carries a malformed proof.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { throw 'REQUEST_NOT_RECEIVED: nothing on standard input. Nothing was changed.' }
    try { $request = ConvertFrom-Json -InputObject $Line -AsHashtable -ErrorAction Stop } catch { $request = $null }
    if ($request -isnot [System.Collections.IDictionary]) { throw 'REQUEST_NOT_RECEIVED: standard input is not a JSON object. Nothing was changed.' }
    if ($request.Contains('proof') -and $null -ne $request['proof'] -and ([string] $request['proof']) -cnotmatch '^[0-9a-f]{64}$') {
        throw 'PROOF_MALFORMED: the proof on standard input is not 64 lowercase hex characters. Nothing was changed.'
    }
    return $request
}

function Get-V2ProofComparison {
    # 'absent', 'same' or 'different'; never the value.
    param([AllowNull()][string] $Actual, [AllowNull()][string] $Expected)
    if ([string]::IsNullOrEmpty($Actual)) { return 'absent' }
    if (-not [string]::IsNullOrEmpty($Expected) -and $Actual -ceq $Expected) { return 'same' }
    return 'different'
}

# ----------------------------------------------------------------- vehicle ---

function Invoke-V2RecoveryWindowVehicle {
    <#
        .SYNOPSIS
            The vehicle half: open, close or report the window on this vehicle. Returns the lines to print.

        .DESCRIPTION
            Request keys: state ('Open', 'Close', 'Status'), installRoot, onboardInstanceId (the site
            file's, to be equal to the installed configuration's), proof (Open; Status optionally).

            Order, so that no failure leaves the switch on without the variable (the client then refuses
            to start in Production, Configuration.cs):
              Open:  the variable first, read back equal to the proof; only then the switch, read back.
              Close: the switch off first, read back; only then the variable deleted, read back absent.
            Refused before any change: no installation, a configuration that is not this vehicle's
            (onboardInstanceId), a running client.

            Actions (scriptblocks): ClientRunning -> [bool]; GetMachineVariable(name) -> string or $null;
            SetMachineVariable(name, value) -- $null deletes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Request,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Actions
    )
    $state = [string] $Request['state']
    if ($state -cnotin @('Open', 'Close', 'Status')) { throw "REQUEST_STATE_UNKNOWN: '$state'. Nothing was changed." }
    $installRoot = [string] $Request['installRoot']
    $expectedInstance = [string] $Request['onboardInstanceId']
    $proof = $Request.Contains('proof') ? [string] $Request['proof'] : $null
    if ($state -ceq 'Open' -and [string]::IsNullOrEmpty($proof)) { throw 'PROOF_NOT_RECEIVED: opening needs the proof. Nothing was changed.' }

    $settingsPath = Join-Path $installRoot 'appsettings.json'
    if ([string]::IsNullOrWhiteSpace($installRoot) -or -not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw "NO_INSTALLATION: no $settingsPath -- deploy it first with 06-deploy-onboard-hmi.ps1. Nothing was changed."
    }
    $read = { Get-Content -Raw -LiteralPath $settingsPath -Encoding utf8 | ConvertFrom-Json }
    $settings = & $read
    $installedInstance = [string] $settings.wireToGate.onboardInstanceId
    if ([string]::IsNullOrWhiteSpace($expectedInstance) -or $installedInstance -cne $expectedInstance) {
        throw ("VEHICLE_IDENTITY_MISMATCH: wireToGate.onboardInstanceId in $settingsPath is '$installedInstance', the site file says " +
            "'$expectedInstance'. This is not the vehicle the alias names. Nothing was changed.")
    }
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($state -ceq 'Status') {
        $lines.Add("recoveryResumeEnabled=$([bool] $settings.wireToGate.recoveryResumeEnabled)")
        $lines.Add("$script:VehicleVariable=$(Get-V2ProofComparison (& $Actions.GetMachineVariable $script:VehicleVariable) $proof)")
        $lines.Add("clientRunning=$([bool] (& $Actions.ClientRunning))")
        return $lines.ToArray()
    }

    if (& $Actions.ClientRunning) {
        throw 'CLIENT_RUNNING: SQCD.Agv.Wpf is running on the vehicle. Close it before changing the recovery window. Nothing was changed.'
    }

    $setSwitch = {
        param([bool] $Enabled)
        $s = & $read
        $s.wireToGate.recoveryResumeEnabled = $Enabled
        $s | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $settingsPath -Encoding utf8NoBOM
        $back = (& $read).wireToGate.recoveryResumeEnabled
        if ($back -isnot [bool] -or $back -ne $Enabled) { throw "SWITCH_READBACK_FAILED: recoveryResumeEnabled read back as '$back', not $Enabled." }
        $lines.Add("recoveryResumeEnabled=$Enabled")
    }

    if ($state -ceq 'Open') {
        & $Actions.SetMachineVariable $script:VehicleVariable $proof
        $back = Get-V2ProofComparison (& $Actions.GetMachineVariable $script:VehicleVariable) $proof
        if ($back -cne 'same') {
            throw "VARIABLE_READBACK_FAILED: $script:VehicleVariable reads back $back after the write. The switch was not changed (still $([bool] $settings.wireToGate.recoveryResumeEnabled))."
        }
        $lines.Add("$script:VehicleVariable=set (machine scope, value not shown)")
        & $setSwitch $true
    } else {
        & $setSwitch $false
        & $Actions.SetMachineVariable $script:VehicleVariable $null
        $back = Get-V2ProofComparison (& $Actions.GetMachineVariable $script:VehicleVariable) $null
        if ($back -cne 'absent') { throw "VARIABLE_DELETE_FAILED: $script:VehicleVariable is still present. The switch is off, so the client starts without the entry." }
        $lines.Add("$script:VehicleVariable=removed")
    }
    return $lines.ToArray()
}

function New-V2VehicleActions {
    <#
        .SYNOPSIS
            The actions the vehicle half runs with. agv-v2-recovery-window.ps1 calls this with no
            arguments; the defaults are what production uses, and the self-test reads them back
            (Description) and runs the same scriptblocks against a temporary key.

        .DESCRIPTION
            The machine variable is read and written in the registry key Windows keeps machine
            variables in (HKLM\...\Session Manager\Environment), where
            [Environment]::SetEnvironmentVariable(..., 'Machine') writes too. A delete is DeleteValue:
            it cannot leave the empty REG_SZ that a "" passed for $null left on agv01 on 2026-09-10.
            No WM_SETTINGCHANGE is broadcast; from an ssh session it would not reach the desktop
            anyway, which is why the client is started with 10-start-onboard-stack.ps1.
    #>
    [CmdletBinding()]
    param(
        [Microsoft.Win32.RegistryKey] $EnvironmentRoot = [Microsoft.Win32.Registry]::LocalMachine,
        [string] $EnvironmentPath = $script:MachineEnvironmentPath,
        [string] $ProcessName = $script:ClientProcessName
    )
    return @{
        Description = "variables $($EnvironmentRoot.Name)\$EnvironmentPath; client process $ProcessName"
        ClientRunning = { @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0 }.GetNewClosure()
        GetMachineVariable = {
            param([string] $Name)
            $key = $EnvironmentRoot.OpenSubKey($EnvironmentPath, $false)
            if ($null -eq $key) { throw "No registry key $($EnvironmentRoot.Name)\$EnvironmentPath." }
            try {
                $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                return ($null -eq $value) ? $null : [string] $value
            } finally { $key.Close() }
        }.GetNewClosure()
        SetMachineVariable = {
            param([string] $Name, [AllowNull()][string] $Value)
            $key = $EnvironmentRoot.OpenSubKey($EnvironmentPath, $true)
            if ($null -eq $key) { throw "Cannot open $($EnvironmentRoot.Name)\$EnvironmentPath for writing." }
            try {
                if ([string]::IsNullOrEmpty($Value)) { $key.DeleteValue($Name, $false) }
                else { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String) }
            } finally { $key.Close() }
        }.GetNewClosure()
    }
}

# ------------------------------------------------------------------ server ---

function Read-V2RegistryMultiString {
    # The REG_MULTI_SZ value under Root\Path, empty when the value is absent. Throws when the key is missing.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Microsoft.Win32.RegistryKey] $Root, [Parameter(Mandatory = $true)][string] $Path, [string] $Name = 'Environment')
    $key = $Root.OpenSubKey($Path, $false)
    if ($null -eq $key) { throw "SERVICE_MISSING: no registry key $($Root.Name)\$Path. Nothing was changed." }
    try { return [string[]] @(@($key.GetValue($Name, [string[]] @())) | Where-Object { $_ }) } finally { $key.Close() }
}

function Write-V2RegistryMultiString {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Microsoft.Win32.RegistryKey] $Root, [Parameter(Mandatory = $true)][string] $Path,
        [AllowEmptyCollection()][string[]] $Value, [string] $Name = 'Environment')
    $key = $Root.OpenSubKey($Path, $true)
    if ($null -eq $key) { throw "Cannot open $($Root.Name)\$Path for writing." }
    try { $key.SetValue($Name, [string[]] @($Value), [Microsoft.Win32.RegistryValueKind]::MultiString) } finally { $key.Close() }
}

function Get-V2EntryNames([string[]] $Environment) {
    return (@($Environment | ForEach-Object { ($_ -split '=', 2)[0] }) -join ', ')
}

function Invoke-V2RecoveryWindowServer {
    <#
        .SYNOPSIS
            The server half: report, check, set or remove CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF in
            the V2 service's Environment, restarting the service only when the entry changes. Returns
            the lines to print.

        .DESCRIPTION
            Request keys: mode ('status', 'check', 'set', 'remove'), target ('set' or 'remove', for
            'check'), proof ('set'; 'check' and 'status' optionally), allowConnectedVehicles.

            In order; nothing changes before step 5, and every refusal throws:
              1. The MVP service is refused by name.
              2. The entry now: absent, same (as the proof) or different. 'status' stops here.
              3. Already what the target needs: NO_CHANGE, no restart.
              4. Before a restart: the installer's own pre-install refusal (configuration present and
                 readable, service Running or Stopped, a Running process newer than the file, the
                 dispatch gate closed -- Get-ParallelPreInstallRefusal); no RiotCreateDispatch__*
                 override in the Environment; no established connection on the onboard port, unless
                 allowConnectedVehicles (then a warning); no journey that is not Completed (the
                 instance's SQLite store, read-only; no switch). Unreadable connections or journeys refuse.
                 'check' stops here: CHECK_PASSED.
              5. Write the Environment with every other entry kept in its order, read it back; on a
                 mismatch the original is written back and the run fails.
              6. Restart a Running service and require it Running again. A Stopped one is left stopped.

            Actions: built by New-V2ServerActions. RegistryPath (the key it writes, checked against
            ServiceName and the MVP); scriptblocks ReadEnvironment -> string[]; WriteEnvironment([string[]]);
            MergeEntry(environment, name, value) -> string[]; ServiceStatus -> string or $null;
            PreInstallRefusal -> string or $null; JourneyState -> hashtable (Journeys, or Error);
            Connections -> string[] of remote addresses (throws when it cannot read); RestartService.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Request,
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][int] $OnboardPort,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Actions
    )
    $mode = [string] $Request['mode']
    if ($mode -cnotin @('status', 'check', 'set', 'remove')) { throw "REQUEST_MODE_UNKNOWN: '$mode'. Nothing was changed." }
    $target = $mode -ceq 'check' ? [string] $Request['target'] : $mode
    if ($mode -ne 'status' -and $target -cnotin @('set', 'remove')) { throw "REQUEST_TARGET_UNKNOWN: '$target'. Nothing was changed." }
    $proof = $Request.Contains('proof') ? [string] $Request['proof'] : $null
    if ($target -ceq 'set' -and [string]::IsNullOrEmpty($proof)) { throw 'PROOF_NOT_RECEIVED: setting the entry needs the proof. Nothing was changed.' }
    $allowConnected = [bool] $Request['allowConnectedVehicles']

    if ($ServiceName.Trim().TrimEnd('\') -ieq $script:MvpServiceName) { throw 'MVP_SERVICE_REFUSED: this script never changes the MVP service. Nothing was changed.' }
    # The key the actions write is checked too, not only the name passed here: a path pointing at the
    # MVP's key would rewrite its Environment silently, and the MVP fingerprint does not compare it.
    $registryLeaf = ([string] $Actions['RegistryPath']).TrimEnd('\').Split('\')[-1]
    if ($registryLeaf -ieq $script:MvpServiceName -or $registryLeaf -cne $ServiceName) {
        throw "REGISTRY_PATH_REFUSED: the actions write '$($Actions['RegistryPath'])', which is not the key of '$ServiceName'. Nothing was changed."
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $environment = [string[]] @(& $Actions.ReadEnvironment)
    $prefix = "$script:ServerVariable="
    $current = @($environment | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $entry = $current.Count -eq 0 ? 'absent' : ($current.Count -eq 1 ? (Get-V2ProofComparison $current[0].Substring($prefix.Length) $proof) : 'different')
    $lines.Add("ENTRY=$entry")
    if ($mode -ceq 'status') {
        $lines.Add("SERVICE=$((& $Actions.ServiceStatus) ?? 'absent')")
        return $lines.ToArray()
    }

    if (($target -ceq 'set' -and $entry -ceq 'same') -or ($target -ceq 'remove' -and $entry -ceq 'absent')) {
        $lines.Add('NO_CHANGE: the service already holds what this needs; no write, no restart.')
        if ($mode -ceq 'check') { $lines.Add('CHECK_PASSED') }
        return $lines.ToArray()
    }

    # ---- 4. before a restart ----
    $refusal = & $Actions.PreInstallRefusal
    if ($refusal) { throw "PRE_RESTART_REFUSED: $refusal" }
    $overrides = @($environment | Where-Object { $_ -like 'RiotCreateDispatch__*' })
    if ($overrides.Count -gt 0) {
        throw "DISPATCH_GATE_OVERRIDDEN: $(Get-V2EntryNames $overrides) in the service Environment override the file. Nothing was changed."
    }
    try { $connections = @(& $Actions.Connections) } catch {
        throw "CONNECTIONS_UNREADABLE: the connections on port $OnboardPort could not be read ($($_.Exception.Message)). Nothing was changed."
    }
    $lines.Add("CONNECTED_VEHICLES=$($connections.Count)")
    if ($connections.Count -gt 0) {
        $from = (@($connections | Sort-Object -Unique) -join ', ')
        if (-not $allowConnected) {
            throw ("CONNECTED_VEHICLES: $($connections.Count) connection(s) on port $OnboardPort from $from. A restart drops them into " +
                'recovery. Stop their clients, or pass -AllowConnectedVehicles once the field has accepted it. Nothing was changed.')
        }
        $lines.Add("WARNING: CONNECTED_VEHICLES ($from): the restart drops them into recovery.")
    }
    $journeys = & $Actions.JourneyState
    if ($journeys -isnot [System.Collections.IDictionary] -or $journeys.Contains('Error')) {
        $why = ($journeys -is [System.Collections.IDictionary]) ? [string] $journeys['Error'] : 'no answer'
        throw "JOURNEY_STATE_UNREADABLE: $why. Nothing was changed."
    }
    $open = @($journeys['Journeys'])
    if ($open.Count -gt 0) {
        $named = @($open | ForEach-Object { "$($_['JourneyId']) ($($_['Stage']))" }) -join ', '
        throw ("JOURNEYS_IN_PROGRESS: $($open.Count) journey(s) not Completed: $named. A restart stops their supervision; " +
            'finish or settle them first. Nothing was changed.')
    }
    if ($mode -ceq 'check') { $lines.Add('CHECK_PASSED'); return $lines.ToArray() }

    # ---- 5. the write ----
    $kept = [string[]] @($environment | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $next = ($target -ceq 'set') ? [string[]] @(& $Actions.MergeEntry $environment $script:ServerVariable $proof) : $kept
    $expectedKept = $kept -join "`n"
    & $Actions.WriteEnvironment $next
    $after = [string[]] @(& $Actions.ReadEnvironment)
    $afterKept = @($after | Where-Object { -not $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }) -join "`n"
    $afterEntry = @($after | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $entryOk = ($target -ceq 'set') ? ($afterEntry.Count -eq 1 -and $afterEntry[0].Substring($prefix.Length) -ceq $proof) : ($afterEntry.Count -eq 0)
    if ($afterKept -cne $expectedKept -or -not $entryOk) {
        & $Actions.WriteEnvironment $environment
        throw 'ENVIRONMENT_READBACK_FAILED: the Environment did not read back as written; the original was written back. The service was not restarted.'
    }
    $lines.Add("service environment now carries: $(Get-V2EntryNames $after)")

    # ---- 6. the restart ----
    $status = & $Actions.ServiceStatus
    if ($status -ceq 'Running') {
        & $Actions.RestartService
        $now = & $Actions.ServiceStatus
        if ($now -cne 'Running') { throw "SERVICE_NOT_RUNNING_AFTER_RESTART: '$ServiceName' is $now. The Environment was written." }
        $lines.Add("service '$ServiceName' restarted, Running")
    } else {
        $lines.Add("service '$ServiceName' is $status and left so; it reads the entry when it starts")
    }
    return $lines.ToArray()
}

function New-V2ServerActions {
    <#
        .SYNOPSIS
            The actions the server half runs with. server-v2-recovery-window.ps1 passes only the four
            values it read from installed-instance.json; everything else is a default here, which is
            what production uses. The self-test calls this same function with a temporary registry
            root, a temporary install and data root, a loopback port and a recorded restart.

        .DESCRIPTION
            The control-server functions it calls (Get-ParallelPreInstallRefusal,
            Get-ParallelServiceProcessStartTimeUtc, Resolve-ParallelInstanceDatabasePath,
            Get-ParallelJourneyDispatchState, Set-ParallelServiceEnvironmentEntry, Get-MvpFingerprint,
            Assert-MvpUntouched) must be imported by the caller: ParallelInstance.psm1 and ParallelHost.psm1,
            staged beside this module.

            Connections: every TCP connection, then filtered here -- a filtered Get-NetTCPConnection
            reports "none" as an error, and swallowing errors would read "cannot tell" as "nobody".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $DataRoot,
        [Parameter(Mandatory = $true)][int] $OnboardPort,
        [Microsoft.Win32.RegistryKey] $RegistryRoot = [Microsoft.Win32.Registry]::LocalMachine,
        [string] $ServicesPath = $script:ServicesPath,
        [scriptblock] $RestartService
    )
    if ($ServiceName.Trim().TrimEnd('\') -ieq $script:MvpServiceName) { throw 'MVP_SERVICE_REFUSED: no actions are built for the MVP service. Nothing was changed.' }
    $registryPath = "$ServicesPath\$ServiceName"
    $configurationPath = "$InstallRoot\appsettings.Production.json"
    $readConfiguration = { (Test-Path -LiteralPath $configurationPath -PathType Leaf) ? [IO.File]::ReadAllText($configurationPath) : $null }.GetNewClosure()
    $restart = $RestartService ?? { Restart-Service -Name $ServiceName -Force }.GetNewClosure()
    return @{
        Description = "registry $($RegistryRoot.Name)\$registryPath; configuration $configurationPath; onboard port $OnboardPort"
        RegistryPath = $registryPath
        ReadEnvironment = { Read-V2RegistryMultiString -Root $RegistryRoot -Path $registryPath }.GetNewClosure()
        WriteEnvironment = { param([string[]] $Value) Write-V2RegistryMultiString -Root $RegistryRoot -Path $registryPath -Value $Value }.GetNewClosure()
        MergeEntry = { param([string[]] $Environment, [string] $Name, [string] $Value) Set-ParallelServiceEnvironmentEntry -Environment $Environment -Name $Name -Value $Value }
        ServiceStatus = { $s = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue; $s ? [string] $s.Status : $null }.GetNewClosure()
        PreInstallRefusal = {
            $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            $text = & $readConfiguration
            Get-ParallelPreInstallRefusal -ServiceExists ($null -ne $service) -ServiceStatus ($service ? [string] $service.Status : $null) `
                -ServiceName $ServiceName -ConfigurationPath $configurationPath -ConfigurationText $text `
                -ConfigurationWriteTimeUtc ($null -ne $text ? [IO.File]::GetLastWriteTimeUtc($configurationPath) : $null) `
                -ProcessStartTimeUtc (Get-ParallelServiceProcessStartTimeUtc -ServiceName $ServiceName)
        }.GetNewClosure()
        Connections = {
            @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.LocalPort -eq $OnboardPort -and [string] $_.State -eq 'Established' } |
                    ForEach-Object { [string] $_.RemoteAddress })
        }.GetNewClosure()
        JourneyState = {
            try {
                $configuration = ConvertFrom-Json -InputObject (& $readConfiguration) -AsHashtable -Depth 12
                $databasePath = Resolve-ParallelInstanceDatabasePath -Configuration $configuration -DataRoot $DataRoot -ConfigurationPath $configurationPath
            } catch {
                return @{ Error = "the database path cannot be resolved from $configurationPath ($($_.Exception.Message))" }
            }
            Get-ParallelJourneyDispatchState -DatabasePath $databasePath -AssemblyDirectory $InstallRoot
        }.GetNewClosure()
        RestartService = $restart
        IsElevated = { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        MvpFingerprint = { Get-MvpFingerprint }
        AssertMvpUntouched = { param($Before, $After) Assert-MvpUntouched -Before $Before -After $After }
    }
}

function Invoke-V2RecoveryWindowServerRun {
    <#
        .SYNOPSIS
            What server-v2-recovery-window.ps1 runs: Invoke-V2RecoveryWindowServer, and for 'set' and
            'remove' first an elevation check, and the MVP service fingerprinted before and compared after.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Request,
        [Parameter(Mandatory = $true)][string] $ServiceName,
        [Parameter(Mandatory = $true)][int] $OnboardPort,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Actions
    )
    if ([string] $Request['mode'] -cnotin @('set', 'remove')) {
        return Invoke-V2RecoveryWindowServer -Request $Request -ServiceName $ServiceName -OnboardPort $OnboardPort -Actions $Actions
    }
    if (-not (& $Actions.IsElevated)) { throw 'NOT_ELEVATED: this must run elevated. Nothing was changed.' }
    $before = & $Actions.MvpFingerprint
    $lines = $null
    try {
        $lines = Invoke-V2RecoveryWindowServer -Request $Request -ServiceName $ServiceName -OnboardPort $OnboardPort -Actions $Actions
    } finally {
        & $Actions.AssertMvpUntouched $before (& $Actions.MvpFingerprint)
    }
    return @($lines) + 'MVP service fingerprint unchanged.'
}

function Get-V2InstalledCutoverArgument {
    <#
        control-server#564. The -ProductionCutover argument for asserting the installed definition, as a splat: present
        when the definition carries productionCutover -- it got there only through an install that carried the switch --
        absent otherwise. -ModuleKnowsCutover says whether the staged ParallelInstance.psm1 carries cutover contract 2 or
        later (Get-ParallelCutoverContractVersion; review round 2, L3: revision 1 of #677 had the switch but not the MVP
        checks); a cutover
        definition with a module from before control-server#564 is refused here with what to do, instead of by that
        module's whitelist naming agv01 (review S5). Pure.
    #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Definition, [Parameter(Mandatory = $true)][bool] $ModuleKnowsCutover)
    if (-not $Definition.Contains('productionCutover')) { return @{} }
    if (-not $ModuleKnowsCutover) {
        throw ('CHECKOUT_PREDATES_CUTOVER: the installed definition is a production cutover (control-server#564), and the ' +
            '-ControlServerRepository staged here is older than that ticket; its module would refuse the definition. Use a ' +
            'checkout that has control-server#564. Nothing was changed.')
    }
    return @{ ProductionCutover = $true }
}

Export-ModuleMember -Function Get-V2InstalledCutoverArgument, Get-V2RecoveryWindowNames, Read-V2RecoveryWindowRequest, Get-V2ProofComparison,
    Invoke-V2RecoveryWindowVehicle, New-V2VehicleActions, Read-V2RegistryMultiString, Write-V2RegistryMultiString,
    Invoke-V2RecoveryWindowServer, New-V2ServerActions, Invoke-V2RecoveryWindowServerRun
