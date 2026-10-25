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

function Test-V2JourneyAwaitsRecovery {
    <#
        .SYNOPSIS
            8005-workspace#58. Whether a journey row stands still on a slot operation whose result needs an
            exception recovery session -- the state the recovery window is opened for. Pure.

        .DESCRIPTION
            Read from control-server c0389b68: the engine blocks a journey with Block(), which sets Stage
            Blocked and the block reason (JourneyRuntimeEngine.cs:6128-6133), under
            LOAD_RESULT_REQUIRES_RECOVERY when the load operation is RecoveryRequired (:1629-1631, and on a
            restart :5755-5775) and UNLOAD_RESULT_REQUIRES_RECOVERY for the unload (:2055-2057). A session
            result that did not reconcile keeps it Blocked as <messageType>_NOT_RECONCILED with the demand
            still RecoveryRequired (OnboardRecoveryCoordinator.cs:2767; BlockedJourneyRelease.cs:157-158),
            and a new session may be opened on it. A session is accepted only for a demand whose journey is
            Blocked on that vehicle (OnboardRecoveryCoordinator.cs:2876-2879).

            Not these: the unreleasable *_NOT_RECONCILED_ON_ENDED_DEMAND / *_BEFORE_UPGRADE (no session can
            be opened for an ended demand, BlockedJourneyRelease.cs:162-177), and every other Blocked reason
            (a lost session, an area hold, ...): a window does not move those.
    #>
    param([AllowNull()][string] $Stage, [AllowNull()][string] $BlockReasonCode)
    if ($Stage -cne 'Blocked' -or [string]::IsNullOrEmpty($BlockReasonCode)) { return $false }
    return ($BlockReasonCode -cin @('LOAD_RESULT_REQUIRES_RECOVERY', 'UNLOAD_RESULT_REQUIRES_RECOVERY')) -or
        ($BlockReasonCode -cmatch '^[A-Za-z]+_NOT_RECONCILED$')
}

function Read-V2JourneyRuntimeRow {
    <#
        .SYNOPSIS
            8005-workspace#58. One JourneyRuntimes row by JourneyId, read-only, with the block reason that
            control-server's Get-ParallelJourneyDispatchState does not select. Never throws: @{ Found = $false },
            @{ Found = $true; JourneyId; Stage; BlockReasonCode; AgvId; VehicleKey } or @{ Error = '...' }.

        .DESCRIPTION
            Opened as Get-ParallelJourneyDispatchState opens it (control-server scripts/parallel/ParallelHost.psm1):
            Microsoft.Data.Sqlite from the installed service, Mode=ReadOnly, unpooled. That reader has run in the
            same process just before, so the assemblies are already loaded. The id is a parameter, never text in
            the statement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $DatabasePath,
        [Parameter(Mandatory = $true)][string] $AssemblyDirectory,
        [Parameter(Mandatory = $true)][string] $JourneyId
    )
    $connection = $null
    try {
        if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) { throw "there is no file at $DatabasePath" }
        foreach ($assembly in @('SQLitePCLRaw.core.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll', 'SQLitePCLRaw.batteries_v2.dll', 'Microsoft.Data.Sqlite.dll')) {
            $path = Join-Path $AssemblyDirectory $assembly
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$assembly is not in $AssemblyDirectory" }
            Add-Type -LiteralPath $path -ErrorAction SilentlyContinue
        }
        try { [SQLitePCL.Batteries_V2]::Init() } catch { }
        $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$DatabasePath;Mode=ReadOnly;Pooling=False")
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT JourneyId, Stage, BlockReasonCode, AgvId, VehicleKey FROM JourneyRuntimes WHERE JourneyId = $id'
        $null = $command.Parameters.AddWithValue('$id', $JourneyId)
        $reader = $command.ExecuteReader()
        try {
            if (-not $reader.Read()) { return @{ Found = $false } }
            $row = @{ Found = $true }
            for ($i = 0; $i -lt $reader.FieldCount; $i++) { $row[$reader.GetName($i)] = $reader.IsDBNull($i) ? $null : [string] $reader.GetValue($i) }
            return $row
        } finally { $reader.Dispose(); $command.Dispose() }
    } catch {
        return @{ Error = $_.Exception.Message }
    } finally {
        if ($connection) { $connection.Dispose() }
    }
}

function Get-V2RecoveryJourneyRefusal {
    <#
        .SYNOPSIS
            8005-workspace#58. With a named recovery journey, the journey check before a restart: $null when
            the only journey not Completed is that journey, on that vehicle, awaiting recovery; otherwise the
            refusal text. Without one, the unchanged JOURNEYS_IN_PROGRESS rule. Pure but for -ReadRow.

        .DESCRIPTION
            -Open is the rows Get-ParallelJourneyDispatchState returned (not Completed). -RecoveryJourney is the
            request's recoveryJourney (journeyId, agvId, vehicleKey) or $null. -ReadRow(journeyId) returns
            Read-V2JourneyRuntimeRow's answer. No journey open passes either way: the instance is idle, which is
            what a -Revert sees once the session has settled the journey.
    #>
    param(
        [AllowEmptyCollection()][object[]] $Open,
        [AllowNull()][System.Collections.IDictionary] $RecoveryJourney,
        [scriptblock] $ReadRow,
        # STUB (8005-workspace#68 test commit): accepted, not used yet.
        [string] $Target = 'set',
        [AllowNull()][object[]] $VehicleMotion
    )
    $open = @($Open)
    if ($open.Count -eq 0) { return $null }
    $named = @($open | ForEach-Object { "$($_['JourneyId']) ($($_['Stage']))" }) -join ', '
    if ($null -eq $RecoveryJourney) {
        return ("JOURNEYS_IN_PROGRESS: $($open.Count) journey(s) not Completed: $named. A restart stops their supervision; " +
            'finish or settle them first. Nothing was changed.')
    }
    $id = [string] $RecoveryJourney['journeyId']
    $others = @($open | Where-Object { [string] $_['JourneyId'] -cne $id })
    if ($others.Count -gt 0) {
        $otherNamed = @($others | ForEach-Object { "$($_['JourneyId']) ($($_['Stage']))" }) -join ', '
        return ("RECOVERY_JOURNEY_NOT_ALONE: the recovery journey is $id, and $($others.Count) other journey(s) are not Completed: " +
            "$otherNamed. A restart stops their supervision; finish or settle them first. Nothing was changed.")
    }
    $row = & $ReadRow $id
    if ($row -isnot [System.Collections.IDictionary] -or $row.Contains('Error')) {
        $why = ($row -is [System.Collections.IDictionary]) ? [string] $row['Error'] : 'no answer'
        return "JOURNEY_STATE_UNREADABLE: the recovery journey $id cannot be read ($why). Nothing was changed."
    }
    if (-not $row['Found']) { return "JOURNEY_STATE_UNREADABLE: the recovery journey $id was listed but its row is gone. Nothing was changed." }
    if ([string] $row['AgvId'] -cne [string] $RecoveryJourney['agvId'] -or [string] $row['VehicleKey'] -cne [string] $RecoveryJourney['vehicleKey']) {
        return ("RECOVERY_JOURNEY_VEHICLE_MISMATCH: journey $id is on agvId '$($row['AgvId'])' / vehicleKey '$($row['VehicleKey'])', " +
            "not the target vehicle's '$($RecoveryJourney['agvId'])' / '$($RecoveryJourney['vehicleKey'])'. Nothing was changed.")
    }
    if (-not (Test-V2JourneyAwaitsRecovery -Stage ([string] $row['Stage']) -BlockReasonCode ([string] $row['BlockReasonCode']))) {
        return ("RECOVERY_JOURNEY_NOT_AWAITING_RECOVERY: journey $id is $($row['Stage']) / $($row['BlockReasonCode'] ?? '(no block reason)'), " +
            'not Blocked on a slot operation result that needs recovery. A restart stops its supervision. Nothing was changed.')
    }
    return $null
}

function Invoke-V2RecoveryWindowServer {
    <#
        .SYNOPSIS
            The server half: report, check, set or remove CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF in
            the V2 service's Environment, restarting the service only when the entry changes. Returns
            the lines to print.

        .DESCRIPTION
            Request keys: mode ('status', 'check', 'set', 'remove'), target ('set' or 'remove', for
            'check'), proof ('set'; 'check' and 'status' optionally), allowConnectedVehicles,
            recoveryJourney (optional, 8005-workspace#58: journeyId, agvId, vehicleKey).

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
                 With recoveryJourney (8005-workspace#58), and only then, the one journey not Completed may
                 be that journey, on that vehicle, awaiting recovery (Get-V2RecoveryJourneyRefusal); every
                 other check above is the same.
                 'check' stops here: CHECK_PASSED.
              5. Write the Environment with every other entry kept in its order, read it back; on a
                 mismatch the original is written back and the run fails.
              6. Restart a Running service and require it Running again. A Stopped one is left stopped.

            Actions: built by New-V2ServerActions. RegistryPath (the key it writes, checked against
            ServiceName and the MVP); scriptblocks ReadEnvironment -> string[]; WriteEnvironment([string[]]);
            MergeEntry(environment, name, value) -> string[]; ServiceStatus -> string or $null;
            PreInstallRefusal -> string or $null; JourneyState -> hashtable (Journeys, or Error);
            JourneyRow(journeyId) -> Read-V2JourneyRuntimeRow's answer (only with recoveryJourney);
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
    $recoveryJourney = $null
    if ($Request.Contains('recoveryJourney') -and $null -ne $Request['recoveryJourney']) {
        $recoveryJourney = $Request['recoveryJourney']
        if ($recoveryJourney -isnot [System.Collections.IDictionary] -or
            @('journeyId', 'agvId', 'vehicleKey' | Where-Object { [string]::IsNullOrWhiteSpace([string] $recoveryJourney[$_]) }).Count -gt 0) {
            throw 'REQUEST_RECOVERY_JOURNEY_MALFORMED: recoveryJourney needs journeyId, agvId and vehicleKey. Nothing was changed.'
        }
    }

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
    $journeyRefusal = Get-V2RecoveryJourneyRefusal -Open $open -RecoveryJourney $recoveryJourney -ReadRow $Actions.JourneyRow
    if ($journeyRefusal) { throw $journeyRefusal }
    if ($recoveryJourney -and $open.Count -gt 0) {
        $lines.Add("RECOVERY_JOURNEY=$($recoveryJourney['journeyId']) awaits recovery on $($recoveryJourney['agvId']); no other journey open. A restart stops its supervision until the vehicle reconnects.")
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
        [scriptblock] $RestartService,
        # STUB (8005-workspace#68 test commit): accepted, not used yet; a restart runs the two in order.
        [scriptblock] $RiotGet,
        [scriptblock] $StopService,
        [scriptblock] $StartService
    )
    if (-not $RestartService -and $StopService -and $StartService) { $RestartService = { & $StopService; & $StartService }.GetNewClosure() }
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
        JourneyRow = {
            param([string] $JourneyId)
            try {
                $configuration = ConvertFrom-Json -InputObject (& $readConfiguration) -AsHashtable -Depth 12
                $databasePath = Resolve-ParallelInstanceDatabasePath -Configuration $configuration -DataRoot $DataRoot -ConfigurationPath $configurationPath
            } catch {
                return @{ Error = "the database path cannot be resolved from $configurationPath ($($_.Exception.Message))" }
            }
            Read-V2JourneyRuntimeRow -DatabasePath $databasePath -AssemblyDirectory $InstallRoot -JourneyId $JourneyId
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
    Invoke-V2RecoveryWindowServer, New-V2ServerActions, Invoke-V2RecoveryWindowServerRun,
    Test-V2JourneyAwaitsRecovery, Read-V2JourneyRuntimeRow, Get-V2RecoveryJourneyRefusal
