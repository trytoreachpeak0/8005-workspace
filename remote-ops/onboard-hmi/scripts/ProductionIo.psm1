#Requires -Version 7
<#
    workspace#51. In the production phase of the cutover no vehicle goes live on the slot simulator's IO.

    Until this module, the only production guard on the onboard configuration refused loopback for wireToGate.host and
    vehicleSafety.endpoint. ioModule was not checked at all, and the product's own default is the simulator
    (127.0.0.1:1502). A vehicle that missed "switch IO back to the real module" (production-cutover-mode-plan.md step
    20) would still connect, handshake and reach Ready -- and every unlock would then open a simulated door.

    Which phase the server is in comes from the server: productionCutover.phase of the definition the v2 installer
    recorded in <opsRoot>\installed-instance.json on factory01 (every v2 definition shares that opsRoot). Not from a
    switch on the deploy call: a switch is exactly the thing that is forgotten. The phases:
        production  productionCutover.phase "production"
        trial       productionCutover.phase "trial" (real MES, simulated slots)
        none        an installed parallel definition without productionCutover (agv02/agv03 testing)
        mvp         the vehicle talks to the MVP service (58005/58007); it serves customers, so it counts as production
    A record that is absent, unreadable, of another instance (onboardPort) or of an unknown phase is refused, never
    taken for "not production".

    Used by 06-deploy-onboard-hmi.ps1, 09-switch-io-module.ps1, 20-check-production-io.ps1 and
    factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1. Self-test: Test-ProductionIo.ps1.
#>

Set-StrictMode -Version 3.0

$script:InstalledDefinitionPath = 'D:\zhengyushao\control-server-v2-ops\installed-instance.json'
$script:SimulatorPort = 1502
$script:RealModulePort = 502
$script:GuardedPhases = @('production', 'mvp')
$script:KnownPhases = @('production', 'trial', 'none', 'mvp')
# How old an IO check record the dispatch gate still accepts.
$script:IoCheckMaxAge = [TimeSpan]::FromHours(6)

function Get-DefaultInstalledDefinitionPath { return $script:InstalledDefinitionPath }

function Get-ServerPhaseProbeCommand {
    <#
        The read-only PowerShell the server runs: one line, SERVER_PHASE=ABSENT, SERVER_PHASE=UNREADABLE <why> or
        SERVER_PHASE=PRESENT <json of onboardPort, phase, fleet>. No double quote in it (it may travel through ssh). Pure.
    #>
    param([Parameter(Mandatory = $true)][string] $RecordPath)
    $quoted = $RecordPath.Replace("'", "''")
    return @(
        "`$p = '$quoted'"
        "if (-not (Test-Path -LiteralPath `$p -PathType Leaf)) { 'SERVER_PHASE=ABSENT'; exit 0 }"
        'try {'
        '    $d = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json -AsHashtable'
        "    `$cut = (`$d['productionCutover'] -is [System.Collections.IDictionary]) ? `$d['productionCutover'] : `$null"
        "    `$journey = (`$d['journeyRuntime'] -is [System.Collections.IDictionary]) ? `$d['journeyRuntime'] : @{}"
        "    `$fleet = @(@(`$journey['fleet']) | Where-Object { `$_ -is [System.Collections.IDictionary] } | ForEach-Object { [string] `$_['vehicleKey'] })"
        "    'SERVER_PHASE=PRESENT ' + (@{ onboardPort = `$d['onboardPort']; cutover = (`$null -ne `$cut); phase = (`$cut ? `$cut['phase'] : `$null); fleet = `$fleet } | ConvertTo-Json -Compress)"
        '} catch {'
        "    'SERVER_PHASE=UNREADABLE ' + `$_.Exception.Message"
        '}'
    ) -join "`n"
}

function ConvertFrom-ServerPhaseProbe {
    <#
        The probe's output to Phase ('production' | 'trial' | 'none') and FleetVehicleKeys. OnboardPort 0 skips the
        check that the installed instance is the one the vehicle talks to. Throws a readable refusal otherwise. Pure.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Output,
        [Parameter(Mandatory = $true)][int] $OnboardPort,
        [Parameter(Mandatory = $true)][string] $RecordPath,
        [Parameter(Mandatory = $true)][string] $SshAlias
    )
    $where = "$RecordPath on $SshAlias"
    $line = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_.StartsWith('SERVER_PHASE=', [StringComparison]::Ordinal) } | Select-Object -Last 1)
    if ($line.Count -eq 0) {
        throw ("SERVER_PHASE_UNREAD: no answer from $where ($(($Output | Select-Object -First 3) -join ' | ')). Whether the server is " +
            'in the production phase decides whether the simulator IO may be used; refusing rather than guessing.')
    }
    if ($line[0] -ceq 'SERVER_PHASE=ABSENT') {
        throw ("SERVER_PHASE_UNREAD: there is no $where -- no v2 instance has been installed through 19-deploy-control-server-parallel.ps1. " +
            'Install the server first; refusing rather than taking an unknown server for one outside production.')
    }
    if (-not $line[0].StartsWith('SERVER_PHASE=PRESENT ', [StringComparison]::Ordinal)) {
        throw "SERVER_PHASE_UNREAD: $where could not be read ($($line[0])). Refusing rather than guessing."
    }
    try { $state = $line[0].Substring('SERVER_PHASE=PRESENT '.Length) | ConvertFrom-Json -AsHashtable }
    catch { throw "SERVER_PHASE_UNREAD: the probe of $where answered something that is not JSON ($($line[0]))." }
    if ($OnboardPort -ne 0) {
        $installedPort = 0
        if (-not [int]::TryParse([string] $state['onboardPort'], [ref]$installedPort) -or $installedPort -ne $OnboardPort) {
            throw ("SERVER_INSTANCE_PORT_MISMATCH: the instance recorded in $where listens on onboard port '$($state['onboardPort'])', " +
                "but this vehicle is pointed at $OnboardPort. That record is not the server this vehicle uses, so its phase says nothing about it.")
        }
    }
    $phase = $state['cutover'] ? [string] $state['phase'] : 'none'
    if ($phase -cnotin @('production', 'trial', 'none')) {
        throw "SERVER_PHASE_INVALID: $where has productionCutover.phase '$($state['phase'])', which is neither 'trial' nor 'production'."
    }
    return [pscustomobject]@{ Phase = $phase; FleetVehicleKeys = @($state['fleet'] | Where-Object { $_ }) }
}

function Read-ServerCutoverPhase {
    <#
        One read-only ssh to the server. OnboardPort 58005 (the MVP service) never asks: that is 'mvp'.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $ServerSshAlias,
        [Parameter(Mandatory = $true)][int] $OnboardPort,
        [string] $RecordPath = $script:InstalledDefinitionPath
    )
    if ($OnboardPort -eq 58005) { return [pscustomobject]@{ Phase = 'mvp'; FleetVehicleKeys = @() } }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-ServerPhaseProbeCommand -RecordPath $RecordPath)))
    $output = @(& ssh $ServerSshAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "SERVER_PHASE_UNREAD: ssh $ServerSshAlias failed (exit $LASTEXITCODE): $(($output | Select-Object -First 3) -join ' | '). Refusing rather than guessing."
    }
    return ConvertFrom-ServerPhaseProbe -Output $output -OnboardPort $OnboardPort -RecordPath $RecordPath -SshAlias $ServerSshAlias
}

function Test-LoopbackIoHost {
    param([AllowNull()][AllowEmptyString()][string] $IoHost)
    if ([string]::IsNullOrWhiteSpace($IoHost)) { return $false }
    $trimmed = $IoHost.Trim()
    if ($trimmed -ieq 'localhost' -or $trimmed -ieq 'localhost.') { return $true }
    $address = [ipaddress]::Any
    return [ipaddress]::TryParse($trimmed, [ref]$address) -and [ipaddress]::IsLoopback($address)
}

function Get-ProductionIoRefusal {
    <#
        $null when the IO target may go live in this phase; otherwise the refusal, 'CODE: text'. Outside production
        (trial, none) everything passes. In production (and on the MVP pair) only the site file's module on port 502
        does. Pure.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Phase,
        [AllowNull()][AllowEmptyString()][string] $IoHost,
        [int] $IoPort,
        [Parameter(Mandatory = $true)][string] $SiteHost
    )
    if ($Phase -cnotin $script:KnownPhases) { throw "Unknown server phase '$Phase'." }
    if ($Phase -cnotin $script:GuardedPhases) { return $null }
    $found = '{0}:{1}' -f $IoHost, $IoPort
    $wanted = '{0}:{1}' -f $SiteHost.Trim(), $script:RealModulePort
    $why = ($Phase -ceq 'mvp') ? 'this vehicle talks to the MVP service, which serves production' :
        'the server is in the production phase of the cutover (productionCutover.phase "production")'
    $fix = "Switch the vehicle to its real module first (09-switch-io-module.ps1 -RealModule, authorised, someone on site), or deploy with -UseSiteIo."
    if (Test-LoopbackIoHost $IoHost) {
        return "PRODUCTION_IO_LOOPBACK: ioModule is $found -- loopback, the slot simulator on the vehicle -- and $why. Unlock commands would open simulated doors while the real ones stay shut. It must be the site file's module $wanted. $fix"
    }
    if ($IoPort -eq $script:SimulatorPort) {
        return "PRODUCTION_IO_SIMULATOR_PORT: ioModule is $found -- the simulator's port $($script:SimulatorPort) -- and $why. It must be the site file's module $wanted. $fix"
    }
    if ([string]::IsNullOrWhiteSpace($IoHost) -or $IoHost.Trim() -cne $SiteHost.Trim() -or $IoPort -ne $script:RealModulePort) {
        return "PRODUCTION_IO_NOT_SITE_MODULE: ioModule is $found, not the site file's module $wanted, and $why. $fix"
    }
    return $null
}

function Assert-ProductionIoTarget {
    param(
        [Parameter(Mandatory = $true)][string] $Phase,
        [AllowNull()][AllowEmptyString()][string] $IoHost,
        [int] $IoPort,
        [Parameter(Mandatory = $true)][string] $SiteHost
    )
    $refusal = Get-ProductionIoRefusal -Phase $Phase -IoHost $IoHost -IoPort $IoPort -SiteHost $SiteHost
    if ($refusal) { throw $refusal }
}

function Get-IoCheckRecordRefusal {
    <#
        $null when the record written by 20-check-production-io.ps1 lets the dispatch gate open: kind onboard-io-check,
        checked within the last six hours, every result OK, and every vehicle of the installed fleet among them.
        Otherwise the refusal. Pure.
    #>
    param(
        [AllowNull()] $Record,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $FleetVehicleKeys,
        [Parameter(Mandatory = $true)][DateTimeOffset] $Now
    )
    $run = 'Run remote-ops/onboard-hmi/scripts/20-check-production-io.ps1 -SshAlias <every car of this stage> -RecordPath <file> and pass that file as -IoCheckRecord.'
    if ($null -eq $Record) {
        return "IO_CHECK_RECORD_REQUIRED: the server is in the production phase, and the gate opens only after every vehicle of its fleet has been read back on its real IO module. $run"
    }
    if ($Record -isnot [System.Collections.IDictionary] -or [string] $Record['kind'] -cne 'onboard-io-check' -or $Record['results'] -isnot [System.Collections.IEnumerable]) {
        return "IO_CHECK_RECORD_UNREADABLE: the file given is not a record of 20-check-production-io.ps1. $run"
    }
    $at = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string] $Record['checkedAt'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$at)) {
        return "IO_CHECK_RECORD_UNREADABLE: checkedAt '$($Record['checkedAt'])' is not a time. $run"
    }
    $age = $Now - $at
    if ($age -gt $script:IoCheckMaxAge -or $age -lt [TimeSpan]::FromMinutes(-5)) {
        return "IO_CHECK_RECORD_STALE: the record was written at $($at.ToString('o')), not within the last $($script:IoCheckMaxAge.TotalHours) hours. $run"
    }
    $results = @($Record['results'] | Where-Object { $_ -is [System.Collections.IDictionary] })
    $bad = @($results | Where-Object { $_['ok'] -ne $true })
    if ($bad.Count -gt 0) {
        return "IO_CHECK_RECORD_FAILED: not on the real module: $(($bad | ForEach-Object { "$($_['alias']) $($_['host']):$($_['port'])" }) -join ', '). $run"
    }
    $checked = @($results | ForEach-Object { [string] $_['vehicleKey'] })
    $missing = @($FleetVehicleKeys | Where-Object { $checked -cnotcontains $_ })
    if ($FleetVehicleKeys.Count -eq 0 -or $results.Count -eq 0 -or $missing.Count -gt 0) {
        return "IO_CHECK_RECORD_INCOMPLETE: the installed fleet has vehicle(s) the record does not cover: $(($missing.Count -gt 0) ? ($missing -join ', ') : '(empty fleet or empty record)'). $run"
    }
    return $null
}

Export-ModuleMember -Function Get-DefaultInstalledDefinitionPath, Get-ServerPhaseProbeCommand, ConvertFrom-ServerPhaseProbe,
    Read-ServerCutoverPhase, Test-LoopbackIoHost, Get-ProductionIoRefusal, Assert-ProductionIoTarget, Get-IoCheckRecordRefusal
