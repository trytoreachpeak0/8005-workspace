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

function Get-V2MovingVehicle {
    <#
        8005-workspace#68. Of the vehicles of -Rows (journey rows not Completed), those that may be under way, one line each:
        the vehicle, its journeys, and why. A vehicle -VehicleMotion has no entry for -- or all of them, when it is $null
        because the staged control-server predates #68 -- is not judged, and may be under way. Pure.
    #>
    param([AllowEmptyCollection()][object[]] $Rows, [AllowNull()][object[]] $VehicleMotion)
    foreach ($key in @($Rows | ForEach-Object { [string] $_['VehicleKey'] } | Sort-Object -Unique -CaseSensitive)) {
        $mine = @($Rows | Where-Object { [string] $_['VehicleKey'] -ceq $key })
        $journeys = @($mine | ForEach-Object { "$($_['JourneyId']) ($($_['Stage']))" }) -join ', '
        $agvId = @($mine | ForEach-Object { [string] $_['AgvId'] } | Sort-Object -Unique -CaseSensitive) -join ', '
        $entry = @($VehicleMotion | Where-Object { $_ -is [System.Collections.IDictionary] -and [string] $_['VehicleKey'] -ceq $key })
        if ($null -eq $VehicleMotion -or $entry.Count -ne 1) {
            "vehicle $agvId / $key with $journeys`: not judged (RIoT was not read for it; a control-server checkout from before 8005-workspace#68 cannot)"
        } elseif (@($entry[0]['Reasons']).Count -gt 0) {
            "vehicle $agvId / $key with $journeys`: $(@($entry[0]['Reasons']) -join '; ')"
        }
    }
}

function Get-V2RecoveryJourneyRefusal {
    <#
        .SYNOPSIS
            The journey check before a restart of the V2 service, by vehicle (8005-workspace#68): $null when no journey that
            is not Completed rides on a vehicle that may be under way; otherwise the refusal text. Pure but for -ReadRow.

        .DESCRIPTION
            A restart stops the fault supervision of every vehicle, so it waits while one may be moving under this
            instance. Until 8005-workspace#68 any journey not Completed counted, and a vehicle parked on its charger -- its
            charging journey stays AwaitingPickupArrival until the battery reads full -- held a planned restart for hours.
            Now each such journey is judged by its vehicle: -VehicleMotion is control-server's Get-ParallelGateVehicleMotion
            answer for them (RIoT read now shows it standing still with no unfinished order, and it holds no fault), or
            $null when the staged control-server cannot tell, and then every journey refuses as before.

            -Target says which way the window goes:
              * 'set' (opening). With -RecoveryJourney (8005-workspace#58), that journey -- when it is among the open ones --
                passes on its own rule: on that vehicle, awaiting recovery (-ReadRow(journeyId), Read-V2JourneyRuntimeRow's
                answer); its vehicle is not asked. Every other journey is judged by its vehicle (RECOVERY_JOURNEY_NOT_ALONE).
                Without it, every journey by its vehicle (JOURNEYS_IN_PROGRESS).
              * 'remove' (closing). The window itself is taken away, whatever the named journey has become (8005-workspace#68,
                the field's instance 1 of 2026-10-21: after a fault cargo handoff the journey went on to two more pickup stops
                and -Revert was refused, leaving the server entry behind). -RecoveryJourney and -ReadRow are not consulted.
                What still refuses is the one case where the close itself is unsafe: a journey on a vehicle that may be under
                way, the named one included, because the restart would stop its supervision (JOURNEYS_IN_PROGRESS).
            No journey open passes either way.
    #>
    param(
        [AllowEmptyCollection()][object[]] $Open,
        [AllowNull()][System.Collections.IDictionary] $RecoveryJourney,
        [scriptblock] $ReadRow,
        [ValidateSet('set', 'remove')][string] $Target = 'set',
        [AllowNull()][object[]] $VehicleMotion
    )
    $open = @($Open)
    if ($open.Count -eq 0) { return $null }
    $restart = ($Target -ceq 'remove') ? 'Closing the window restarts the service' : 'Opening the window restarts the service'
    if ($null -eq $RecoveryJourney -or $Target -ceq 'remove') {
        $moving = @(Get-V2MovingVehicle -Rows $open -VehicleMotion $VehicleMotion)
        if ($moving.Count -eq 0) { return $null }
        return ("JOURNEYS_IN_PROGRESS: $($moving.Count) vehicle(s) with a journey not Completed may be under way: $($moving -join ' | '). " +
            "$restart, which stops their supervision; wait until they stand still (RIoT: MODE_AUTO, MT_FINISHED, speed 0, no " +
            'unfinished order) or their journeys finish.' + $(if ($Target -ceq 'remove') { ' Which journey the window was opened for, and its state, do not matter for closing it.' } else { '' }) +
            ' Nothing was changed.')
    }
    $id = [string] $RecoveryJourney['journeyId']
    $others = @($open | Where-Object { [string] $_['JourneyId'] -cne $id })
    $moving = @(Get-V2MovingVehicle -Rows $others -VehicleMotion $VehicleMotion)
    if ($moving.Count -gt 0) {
        return ("RECOVERY_JOURNEY_NOT_ALONE: the recovery journey is $id, and $($moving.Count) vehicle(s) with another journey not " +
            "Completed may be under way: $($moving -join ' | '). $restart, which stops their supervision; wait until they stand " +
            'still or their journeys finish. Nothing was changed.')
    }
    # The named journey not among the open ones (finished, or mistyped) waives nothing, and everything open stands still.
    if ($others.Count -eq $open.Count) { return $null }
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
                 allowConnectedVehicles (then a warning); no journey that is not Completed on a vehicle
                 that may be under way (the instance's SQLite store, read-only, and RIoT, GET only;
                 8005-workspace#68 -- before, any journey not Completed refused). Unreadable connections or
                 journeys refuse. With recoveryJourney (8005-workspace#58), opening lets that journey through
                 on its own rule -- on that vehicle, awaiting recovery -- and closing takes the window away
                 whatever that journey has become (Get-V2RecoveryJourneyRefusal); every other check above is
                 the same.
                 'check' stops here: CHECK_PASSED.
              5. Write the Environment with every other entry kept in its order, read it back; on a
                 mismatch the original is written back and the run fails.
              6. A Running service is stopped, the journeys and RIoT are read again (8005-workspace#68), and
                 it is started and required Running again. Refused on that second read, the original
                 Environment is written back and the service started on it (AFTER_STOP). A Stopped one is
                 left stopped.

            Actions: built by New-V2ServerActions. RegistryPath (the key it writes, checked against
            ServiceName and the MVP); scriptblocks ReadEnvironment -> string[]; WriteEnvironment([string[]]);
            MergeEntry(environment, name, value) -> string[]; ServiceStatus -> string or $null;
            PreInstallRefusal -> string or $null; JourneyState -> hashtable (Journeys and, with a
            control-server from 8005-workspace#68 on, VehicleMotion; or Error); JourneyRow(journeyId) ->
            Read-V2JourneyRuntimeRow's answer (only with recoveryJourney, when opening);
            Connections -> string[] of remote addresses (throws when it cannot read); StopService; StartService.
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
    # The journeys not Completed and, by vehicle, whether one may be under way (8005-workspace#68); read again after the stop.
    $journeyCheck = {
        $journeys = & $Actions.JourneyState
        if ($journeys -isnot [System.Collections.IDictionary] -or $journeys.Contains('Error')) {
            $why = ($journeys -is [System.Collections.IDictionary]) ? [string] $journeys['Error'] : 'no answer'
            return @{ Open = @(); Refusal = "JOURNEY_STATE_UNREADABLE: $why. Nothing was changed." }
        }
        $open = @($journeys['Journeys'])
        $motion = $journeys.Contains('VehicleMotion') ? @($journeys['VehicleMotion']) : $null
        return @{ Open = $open; Refusal = (Get-V2RecoveryJourneyRefusal -Open $open -RecoveryJourney $recoveryJourney -ReadRow $Actions.JourneyRow -Target $target -VehicleMotion $motion) }
    }
    $checked = & $journeyCheck
    if ($checked.Refusal) { throw $checked.Refusal }
    if ($checked.Open.Count -gt 0) {
        $lines.Add("OPEN_JOURNEYS=$($checked.Open.Count), every one on a vehicle RIoT shows standing still$(($recoveryJourney -and ($target -ceq 'set')) ? ' or the recovery journey' : '').")
    }
    if ($recoveryJourney -and $checked.Open.Count -gt 0) {
        $lines.Add($target -ceq 'set' ?
            "RECOVERY_JOURNEY=$($recoveryJourney['journeyId']) awaits recovery on $($recoveryJourney['agvId']). A restart stops its supervision until the vehicle reconnects." :
            "RECOVERY_JOURNEY=$($recoveryJourney['journeyId']) named; closing the window does not depend on its state (8005-workspace#68).")
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

    # ---- 6. the restart: stop, read again, start (8005-workspace#68) ----
    # The read after the stop counts, as for the dispatch gate (control-server ParallelHost.psm1, Invoke-ParallelDispatchGateChange
    # step 5): a vehicle somebody drives off by hand in RIoT between the first read and the restart is caught here. Refused, the
    # Environment is written back as it was and the service started again on it.
    $status = & $Actions.ServiceStatus
    if ($status -ceq 'Running') {
        & $Actions.StopService
        $again = & $journeyCheck
        if ($again.Refusal) {
            & $Actions.WriteEnvironment $environment
            $restored = ([string[]] @(& $Actions.ReadEnvironment) -join "`n") -ceq ($environment -join "`n")
            & $Actions.StartService
            throw ('AFTER_STOP ' + $again.Refusal.Replace(' Nothing was changed.', '') + " The service was stopped for this second read; the Environment was " +
                $(if ($restored) { 'written back as it was' } else { 'NOT read back as it was -- check it' }) + " and '$ServiceName' started again ($(& $Actions.ServiceStatus)).")
        }
        & $Actions.StartService
        $now = & $Actions.ServiceStatus
        if ($now -cne 'Running') { throw "SERVICE_NOT_RUNNING_AFTER_RESTART: '$ServiceName' is $now. The Environment was written." }
        $lines.Add("service '$ServiceName' stopped, the journeys and RIoT read again, started, Running")
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
            root, a temporary install and data root, a loopback port, a recorded stop and start, and a fake
            RIoT GET.

        .DESCRIPTION
            The control-server functions it calls (Get-ParallelPreInstallRefusal,
            Get-ParallelServiceProcessStartTimeUtc, Resolve-ParallelInstanceDatabasePath,
            Get-ParallelJourneyDispatchState, Set-ParallelServiceEnvironmentEntry, Get-MvpFingerprint,
            Assert-MvpUntouched; from 8005-workspace#68 Resolve-ParallelRiotGateConnection, Read-ParallelRiotGateFacts and
            Get-ParallelGateVehicleMotion, used when present) must be imported by the caller: ParallelInstance.psm1 and
            ParallelHost.psm1, staged beside this module.

            JourneyState reads RIoT as the installed service does: the RIoT section of appsettings.json under
            appsettings.Production.json, the key from this service's registry Environment (else the machine scope), GET only.

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
        # 8005-workspace#68: the restart in two halves, so the journeys and RIoT are read again in between.
        [scriptblock] $StopService,
        [scriptblock] $StartService,
        # 8005-workspace#68, for the self-test: replaces the RIoT GET (Read-ParallelRiotGateFacts -Get); $null in production.
        [scriptblock] $RiotGet
    )
    if ($ServiceName.Trim().TrimEnd('\') -ieq $script:MvpServiceName) { throw 'MVP_SERVICE_REFUSED: no actions are built for the MVP service. Nothing was changed.' }
    $registryPath = "$ServicesPath\$ServiceName"
    $configurationPath = "$InstallRoot\appsettings.Production.json"
    $baseConfigurationPath = "$InstallRoot\appsettings.json"
    $readConfiguration = { (Test-Path -LiteralPath $configurationPath -PathType Leaf) ? [IO.File]::ReadAllText($configurationPath) : $null }.GetNewClosure()
    $stop = $StopService ?? { Stop-Service -Name $ServiceName -Force }.GetNewClosure()
    $start = $StartService ?? { Start-Service -Name $ServiceName }.GetNewClosure()
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
            $state = Get-ParallelJourneyDispatchState -DatabasePath $databasePath -AssemblyDirectory $InstallRoot
            # 8005-workspace#68: each vehicle with a journey not Completed asked of RIoT, with control-server's own functions.
            # A staged control-server from before #68 has none of them: no VehicleMotion then, and every journey refuses as before.
            if (@(Get-Command Read-ParallelRiotGateFacts, Resolve-ParallelRiotGateConnection, Get-ParallelGateVehicleMotion -ErrorAction SilentlyContinue).Count -ne 3) {
                return $state
            }
            $base = $null
            try { if (Test-Path -LiteralPath $baseConfigurationPath -PathType Leaf) { $base = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($baseConfigurationPath)) -AsHashtable -Depth 12 } } catch { $base = $null }
            $serviceEnvironment = try { [string[]] @(Read-V2RegistryMultiString -Root $RegistryRoot -Path $registryPath) } catch { [string[]] @() }
            $connection = Resolve-ParallelRiotGateConnection -BaseConfiguration $base -Configuration $configuration -ServiceEnvironment $serviceEnvironment `
                -MachineVariable { param([string] $Name) [Environment]::GetEnvironmentVariable($Name, 'Machine') }
            $state = Read-ParallelRiotGateFacts -State $state -Direction Close -Connection $connection -Get $RiotGet
            if ($state -is [System.Collections.IDictionary] -and -not $state.Contains('Error')) {
                $state['VehicleMotion'] = @(Get-ParallelGateVehicleMotion -State $state -Journeys @($state['Journeys']))
            }
            $state
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
        StopService = $stop
        StartService = $start
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
