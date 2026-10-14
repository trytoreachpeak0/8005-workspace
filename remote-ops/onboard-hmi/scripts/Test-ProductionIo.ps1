#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for ProductionIo.psm1 and the scripts that use it (workspace#51): in the production phase of the
    cutover, no vehicle goes live on the slot simulator's IO.

.DESCRIPTION
    Nothing here reaches a vehicle or factory01. The server-side probe text runs in a fresh pwsh against scratch files;
    09-switch-io-module.ps1, 20-check-production-io.ps1 and the dispatch gate's refusal run against an ssh shim on PATH
    with aliases that resolve nowhere. 06-deploy-onboard-hmi.ps1's end-to-end cases are in Test-DeployOnboardHmi.ps1.

    What it pins:
      * the phase the server reports: production / trial / none (a parallel definition without productionCutover), the
        port of the installed instance checked against the vehicle's, and an absent, unreadable or foreign record
        refused rather than read as "not production";
      * in the production phase (and on the MVP pair) a loopback IO host, the simulator port or anything but the site
        file's module is refused with a readable code; the site file's module passes; trial and none let the
        simulator through;
      * the IO check record: required, fresh, covering every vehicle in the installed fleet, every result OK;
      * 09 -Simulator refused in the production phase before anything is written; allowed in trial;
      * 20-check-production-io.ps1 writes a record the gate accepts only when every car reads back its real module;
      * the dispatch gate refuses -State Open in the production phase without a valid record, and never asks for one
        to close.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/Test-ProductionIo.ps1
#>
[CmdletBinding()]
param(
    # Mutation runs point these at edited copies; normally the siblings.
    [string] $ModulePath = (Join-Path $PSScriptRoot 'ProductionIo.psm1'),
    [string] $SwitchScript = (Join-Path $PSScriptRoot '09-switch-io-module.ps1'),
    [string] $CheckScript = (Join-Path $PSScriptRoot '20-check-production-io.ps1'),
    [string] $GateScript = (Join-Path $PSScriptRoot '../../factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}
function Finish {
    Write-Host ''
    Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
    exit ($script:Failed -eq 0 ? 0 : 1)
}

if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
    Write-Result -Ok $false -Name 'ProductionIo.psm1 exists' -Detail "missing: $ModulePath"
    Finish
}
Import-Module $ModulePath -Force

$site = '192.168.71.150'
$agv01Key = 'BROKERX-0c20ff0600d644869a6a80c186065d85'
$agv02Key = 'BROKERX-f38975561adf46ccb1d2f23833c7d0e4'
$agv03Key = 'BROKERX-7daca4ee91da498d8026c68b7b941127'
$work = Join-Path ([IO.Path]::GetTempPath()) "ws51-production-io-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null

function New-InstalledRecord([string] $Name, [AllowNull()][string] $Phase, [int] $OnboardPort = 58105, [string[]] $Fleet = @($agv02Key)) {
    $definition = [ordered]@{ instanceId = 'factory01-v2-parallel'; onboardPort = $OnboardPort
        journeyRuntime = @{ fleet = @($Fleet | ForEach-Object { @{ agvId = 'x'; vehicleKey = $_ } }) } }
    if ($null -ne $Phase) { $definition['productionCutover'] = @{ approvalRecord = 'test'; phase = $Phase } }
    $path = Join-Path $work "$Name.json"
    $definition | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
    return $path
}
function Invoke-Probe([string] $RecordPath, [int] $OnboardPort = 58105) {
    $command = Get-ServerPhaseProbeCommand -RecordPath $RecordPath
    $output = @(& pwsh -NoProfile -Command $command 2>&1 | ForEach-Object { "$_" })
    try { return @{ Value = (ConvertFrom-ServerPhaseProbe -Output $output -OnboardPort $OnboardPort -RecordPath $RecordPath -SshAlias 'factory01'); Error = $null; Raw = $output } }
    catch { return @{ Value = $null; Error = $_.Exception.Message; Raw = $output } }
}

try {
    Write-Host 'The phase the server reports (probe text run against scratch files)' -ForegroundColor Cyan
    $command = Get-ServerPhaseProbeCommand -RecordPath 'D:\x\installed-instance.json'
    Write-Result -Ok (-not $command.Contains('"')) -Name 'the probe command carries no double quote (it travels through ssh)' -Detail $command

    $p = Invoke-Probe (New-InstalledRecord 'production' 'production' -Fleet @($agv02Key, $agv01Key))
    Write-Result -Ok ($null -eq $p.Error -and $p.Value.Phase -ceq 'production' -and (@($p.Value.FleetVehicleKeys) -join ',') -ceq "$agv02Key,$agv01Key") `
        -Name 'a production cutover record reads as production, with its fleet' -Detail "error: $($p.Error); raw: $($p.Raw -join ' | ')"
    $p = Invoke-Probe (New-InstalledRecord 'trial' 'trial')
    Write-Result -Ok ($null -eq $p.Error -and $p.Value.Phase -ceq 'trial') -Name 'a trial cutover record reads as trial' -Detail "error: $($p.Error); raw: $($p.Raw -join ' | ')"
    $p = Invoke-Probe (New-InstalledRecord 'parallel' $null)
    Write-Result -Ok ($null -eq $p.Error -and $p.Value.Phase -ceq 'none') -Name 'a parallel definition without productionCutover reads as none' -Detail "error: $($p.Error); raw: $($p.Raw -join ' | ')"
    $p = Invoke-Probe (Join-Path $work 'no-such-record.json')
    Write-Result -Ok ($null -ne $p.Error -and $p.Error.StartsWith('SERVER_PHASE_UNREAD:')) -Name 'no installed record is refused (SERVER_PHASE_UNREAD), not read as "not production"' -Detail "error: $($p.Error)"
    $bad = Join-Path $work 'unreadable.json'; Set-Content -LiteralPath $bad -Value '{ "productionCutover": '
    $p = Invoke-Probe $bad
    Write-Result -Ok ($null -ne $p.Error -and $p.Error.StartsWith('SERVER_PHASE_UNREAD:')) -Name 'an unreadable record is refused (SERVER_PHASE_UNREAD)' -Detail "error: $($p.Error)"
    $p = Invoke-Probe (New-InstalledRecord 'odd' 'pilot')
    Write-Result -Ok ($null -ne $p.Error -and $p.Error.StartsWith('SERVER_PHASE_INVALID:')) -Name 'a phase that is neither trial nor production is refused (SERVER_PHASE_INVALID)' -Detail "error: $($p.Error)"
    $p = Invoke-Probe (New-InstalledRecord 'otherport' 'trial' -OnboardPort 58205) -OnboardPort 58105
    Write-Result -Ok ($null -ne $p.Error -and $p.Error.StartsWith('SERVER_INSTANCE_PORT_MISMATCH:')) `
        -Name 'an installed instance on another port is refused (SERVER_INSTANCE_PORT_MISMATCH): it is not the server this vehicle uses' -Detail "error: $($p.Error)"
    $p = Invoke-Probe (New-InstalledRecord 'anyport' 'production' -OnboardPort 58205) -OnboardPort 0
    Write-Result -Ok ($null -eq $p.Error -and $p.Value.Phase -ceq 'production') -Name 'OnboardPort 0 skips the port check (the dispatch gate)' -Detail "error: $($p.Error)"
    try { $null = ConvertFrom-ServerPhaseProbe -Output @('ssh: connect to host factory01 port 22: timed out') -OnboardPort 58105 -RecordPath 'x' -SshAlias 'factory01'; $e = $null } catch { $e = $_.Exception.Message }
    Write-Result -Ok ($null -ne $e -and $e.StartsWith('SERVER_PHASE_UNREAD:')) -Name 'output without a SERVER_PHASE line is refused (SERVER_PHASE_UNREAD)' -Detail "error: $e"

    Write-Host ''
    Write-Host 'The IO target by phase' -ForegroundColor Cyan
    $refuse = { param($phase, $h, $port) Get-ProductionIoRefusal -Phase $phase -IoHost $h -IoPort $port -SiteHost $site }
    $r = & $refuse 'production' '127.0.0.1' 1502
    Write-Result -Ok ("$r".StartsWith('PRODUCTION_IO_LOOPBACK:') -and "$r".Contains('127.0.0.1:1502') -and "$r".Contains("${site}:502")) `
        -Name 'production: the simulator 127.0.0.1:1502 is refused (PRODUCTION_IO_LOOPBACK), naming what was found and what is wanted' -Detail "refusal: $r"
    foreach ($loop in @('localhost', '::1', '127.0.0.2')) {
        $r = & $refuse 'production' $loop 502
        Write-Result -Ok ("$r".StartsWith('PRODUCTION_IO_LOOPBACK:')) -Name "production: loopback '$loop' on port 502 is refused" -Detail "refusal: $r"
    }
    $r = & $refuse 'production' $site 1502
    Write-Result -Ok ("$r".StartsWith('PRODUCTION_IO_SIMULATOR_PORT:')) -Name 'production: the simulator port 1502 on the site host is refused (PRODUCTION_IO_SIMULATOR_PORT)' -Detail "refusal: $r"
    $r = & $refuse 'production' '192.168.71.50' 502
    Write-Result -Ok ("$r".StartsWith('PRODUCTION_IO_NOT_SITE_MODULE:')) -Name 'production: another module than the site file''s is refused (PRODUCTION_IO_NOT_SITE_MODULE)' -Detail "refusal: $r"
    $r = & $refuse 'production' '' 502
    Write-Result -Ok ("$r".StartsWith('PRODUCTION_IO_NOT_SITE_MODULE:')) -Name 'production: an empty IO host is refused' -Detail "refusal: $r"
    $r = & $refuse 'production' $site 502
    Write-Result -Ok ($null -eq $r) -Name 'production: the site file''s real module passes' -Detail "refusal: $r"
    $r = & $refuse 'production' " $site " 502
    Write-Result -Ok ($null -eq $r) -Name 'production: the site module with surrounding spaces passes' -Detail "refusal: $r"
    $r = & $refuse 'mvp' '127.0.0.1' 1502
    Write-Result -Ok ("$r".StartsWith('PRODUCTION_IO_LOOPBACK:')) -Name 'the MVP pair counts as production: the simulator is refused' -Detail "refusal: $r"
    $r = & $refuse 'trial' '127.0.0.1' 1502
    Write-Result -Ok ($null -eq $r) -Name 'trial: the simulator passes' -Detail "refusal: $r"
    $r = & $refuse 'none' '127.0.0.1' 1502
    Write-Result -Ok ($null -eq $r) -Name 'none (parallel, no cutover): the simulator passes' -Detail "refusal: $r"
    try { Assert-ProductionIoTarget -Phase 'production' -IoHost '127.0.0.1' -IoPort 1502 -SiteHost $site; $e = $null } catch { $e = $_.Exception.Message }
    Write-Result -Ok ($null -ne $e -and $e.StartsWith('PRODUCTION_IO_LOOPBACK:')) -Name 'Assert-ProductionIoTarget throws the refusal' -Detail "error: $e"
    try { Get-ProductionIoRefusal -Phase 'pilot' -IoHost $site -IoPort 502 -SiteHost $site; $e = $null } catch { $e = $_.Exception.Message }
    Write-Result -Ok ($null -ne $e) -Name 'an unknown phase is not taken for "not production"' -Detail "error: $e"

    Write-Host ''
    Write-Host 'The IO check record the dispatch gate asks for' -ForegroundColor Cyan
    $now = [DateTimeOffset]::new(2026, 10, 14, 14, 0, 0, [TimeSpan]::FromHours(8))
    $ok = { param($alias, $key) @{ alias = $alias; vehicleKey = $key; siteHost = $site; host = $site; port = 502; ok = $true; refusal = $null } }
    $record = { param($results, $at = $now.AddMinutes(-20)) @{ kind = 'onboard-io-check'; checkedAt = $at.ToString('o'); results = @($results) } }
    $check = { param($rec, [string[]] $fleet = @($agv02Key)) Get-IoCheckRecordRefusal -Record $rec -FleetVehicleKeys $fleet -Now $now }
    $r = & $check $null
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_REQUIRED:') -and "$r".Contains('20-check-production-io.ps1')) -Name 'no record: refused (IO_CHECK_RECORD_REQUIRED), naming the check script' -Detail "refusal: $r"
    $r = & $check (& $record @((& $ok 'agv02' $agv02Key)))
    Write-Result -Ok ($null -eq $r) -Name 'a fresh record with the fleet''s car OK passes' -Detail "refusal: $r"
    $r = & $check (& $record @((& $ok 'agv02' $agv02Key)) $now.AddHours(-7))
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_STALE:')) -Name 'a record older than six hours is refused (IO_CHECK_RECORD_STALE)' -Detail "refusal: $r"
    $r = & $check (& $record @((& $ok 'agv02' $agv02Key)) $now.AddHours(1))
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_STALE:')) -Name 'a record dated in the future is refused' -Detail "refusal: $r"
    $r = & $check (& $record @((& $ok 'agv02' $agv02Key))) @($agv02Key, $agv01Key)
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_INCOMPLETE:') -and "$r".Contains($agv01Key)) -Name 'a fleet car missing from the record is refused (IO_CHECK_RECORD_INCOMPLETE), naming it' -Detail "refusal: $r"
    $failed = & $ok 'agv02' $agv02Key; $failed['ok'] = $false; $failed['host'] = '127.0.0.1'; $failed['port'] = 1502; $failed['refusal'] = 'PRODUCTION_IO_LOOPBACK: x'
    $r = & $check (& $record @($failed))
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_FAILED:') -and "$r".Contains('agv02')) -Name 'a record with a car not OK is refused (IO_CHECK_RECORD_FAILED)' -Detail "refusal: $r"
    $r = & $check (& $record @((& $ok 'agv02' $agv02Key), $failed))
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_FAILED:')) -Name 'a failed car outside the fleet still refuses the record' -Detail "refusal: $r"
    $r = & $check @{ kind = 'something-else'; checkedAt = $now.ToString('o'); results = @() }
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_UNREADABLE:')) -Name 'a record of another kind is refused (IO_CHECK_RECORD_UNREADABLE)' -Detail "refusal: $r"
    $r = & $check (& $record @()) @()
    Write-Result -Ok ("$r".StartsWith('IO_CHECK_RECORD_INCOMPLETE:')) -Name 'an empty fleet and an empty record is refused, not vacuously OK' -Detail "refusal: $r"

    # ---------------------------------------------------------------- ssh shim for the scripts ---
    $shim = Join-Path $work 'shim'
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    $sshLog = Join-Path $work 'ssh.log'
    @'
#Requires -Version 7
# ssh shim for Test-ProductionIo.ps1. The server alias answers the phase probe against a fixture record; a vehicle alias
# answers the IO reads from a fixture configuration. Anything else fails. Every call is logged.
$alias = [string] $args[0]
$rest = @($args | Select-Object -Skip 1 | Where-Object { $_ -notin @('-o', 'BatchMode=yes', 'ConnectTimeout=15') })
$command = $rest -join ' '
Add-Content -LiteralPath $env:WS51_SSH_LOG -Value "$alias | $command" -WhatIf:$false
if ($alias -ceq $env:WS51_SERVER_ALIAS) {
    $text = ($command -match '-EncodedCommand (\S+)') ? [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) : $command
    $rewritten = $text.Replace('D:\zhengyushao\control-server-v2-ops\installed-instance.json', $env:WS51_SERVER_RECORD)
    if ($rewritten -ceq $text) { 'shim: the server command does not read the v2 installed-instance.json'; exit 255 }
    & pwsh -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rewritten))) 2>&1
    exit $LASTEXITCODE
}
$fixture = [Environment]::GetEnvironmentVariable('WS51_VEHICLE_' + $alias.Replace('-', '_'))
if (-not $fixture) { "shim: unexpected alias $alias"; exit 255 }
if ($command -match '-EncodedCommand (\S+)') {
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
    if ($decoded -match 'Set-Content') { 'shim: a write reached the vehicle'; exit 254 }
    $rewritten = $decoded.Replace('C:\8005\OnboardHmi\appsettings.json', $fixture)
    & pwsh -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rewritten))) 2>&1
    exit $LASTEXITCODE
}
"shim: unhandled command: $command"
exit 255
'@ | Set-Content -LiteralPath (Join-Path $shim 'ssh.ps1')
    @'
#Requires -Version 7
Add-Content -LiteralPath $env:WS51_SSH_LOG -Value "scp | $($args -join ' ')" -WhatIf:$false
exit 0
'@ | Set-Content -LiteralPath (Join-Path $shim 'scp.ps1')
    $savedPath = $env:PATH
    $env:PATH = $shim + [IO.Path]::PathSeparator + $env:PATH
    $env:WS51_SSH_LOG = $sshLog
    $env:WS51_SERVER_ALIAS = 'ws51-server-fake'

    function New-VehicleConfig([string] $Alias, [string] $IoHost, [int] $IoPort, [int] $ServerPort = 58105) {
        $path = Join-Path $work "vehicle-$Alias.json"
        @{ wireToGate = @{ host = '172.19.205.222'; port = $ServerPort }; ioModule = @{ host = $IoHost; port = $IoPort; unitId = 255 } } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path
        [Environment]::SetEnvironmentVariable('WS51_VEHICLE_' + $Alias.Replace('-', '_'), $path)
        return $path
    }
    function New-Site([string] $Alias, [string] $Key) {
        $path = Join-Path $work "site-$Alias.json"
        @{ controlServerLine = 'v2'; vehicleSafety = @{ expectedVehicleKey = $Key }; ioModule = @{ host = $site } } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $path
        return $path
    }
    function Invoke-Script([string] $Path, [string[]] $Arguments) {
        if (Test-Path -LiteralPath $sshLog) { Remove-Item -LiteralPath $sshLog }
        $output = & pwsh -NoProfile -File $Path @Arguments *>&1 | Out-String
        $code = $LASTEXITCODE
        $output = ($output -replace '\x1b\[[0-9;]*m', '') -replace '\r?\n {2,}\| ?', ' '
        $calls = @((Test-Path -LiteralPath $sshLog) ? (Get-Content -LiteralPath $sshLog) : @())
        return [pscustomobject]@{ Code = $code; Output = $output; Calls = $calls }
    }

    Write-Host ''
    Write-Host '09-switch-io-module.ps1 -Simulator by phase (ssh shim)' -ForegroundColor Cyan
    $car = 'ws51-car-a'
    $siteA = New-Site $car $agv02Key
    $null = New-VehicleConfig $car $site 502
    $env:WS51_SERVER_RECORD = New-InstalledRecord 'switch-production' 'production'
    $d = Invoke-Script $SwitchScript @('-Simulator', '-SshAlias', $car, '-SitePath', $siteA, '-ServerSshAlias', 'ws51-server-fake', '-WhatIf')
    Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains('PRODUCTION_IO_LOOPBACK:') -and -not $d.Output.Contains('Not changed.')) `
        -Name '09 -Simulator in the production phase is refused (PRODUCTION_IO_LOOPBACK) before the change is even offered' -Detail "exit $($d.Code)`n$($d.Output)"
    Write-Result -Ok (@($d.Calls | Where-Object { $_ -like 'ws51-server-fake |*' }).Count -ge 1) -Name '09 asked the server for its phase' -Detail ($d.Calls -join "`n")
    $env:WS51_SERVER_RECORD = New-InstalledRecord 'switch-trial' 'trial'
    $d = Invoke-Script $SwitchScript @('-Simulator', '-SshAlias', $car, '-SitePath', $siteA, '-ServerSshAlias', 'ws51-server-fake', '-WhatIf')
    Write-Result -Ok ($d.Code -eq 0 -and $d.Output.Contains('Not changed.') -and -not $d.Output.Contains('PRODUCTION_IO')) `
        -Name '09 -Simulator in the trial phase is let through (to the -WhatIf stop)' -Detail "exit $($d.Code)`n$($d.Output)"
    $null = New-VehicleConfig $car $site 502 -ServerPort 58005
    $d = Invoke-Script $SwitchScript @('-Simulator', '-SshAlias', $car, '-SitePath', $siteA, '-ServerSshAlias', 'ws51-server-fake', '-WhatIf')
    Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains('PRODUCTION_IO_LOOPBACK:') -and @($d.Calls | Where-Object { $_ -like 'ws51-server-fake |*' }).Count -eq 0) `
        -Name '09 -Simulator on a vehicle that talks to the MVP (58005) is refused without asking the v2 server' -Detail "exit $($d.Code)`n$($d.Output)`n$($d.Calls -join "`n")"
    $null = New-VehicleConfig $car '127.0.0.1' 1502
    $env:WS51_SERVER_RECORD = New-InstalledRecord 'switch-production-2' 'production'
    $d = Invoke-Script $SwitchScript @('-RealModule', '-SshAlias', $car, '-SitePath', $siteA, '-ServerSshAlias', 'ws51-server-fake', '-WhatIf')
    Write-Result -Ok ($d.Code -eq 0 -and $d.Output.Contains('Not changed.') -and -not $d.Output.Contains('PRODUCTION_IO')) `
        -Name '09 -RealModule in the production phase is let through (to the -WhatIf stop)' -Detail "exit $($d.Code)`n$($d.Output)"

    Write-Host ''
    Write-Host '20-check-production-io.ps1 (ssh shim, read-only)' -ForegroundColor Cyan
    $b = 'ws51-car-b'; $c = 'ws51-car-c'
    $siteB = New-Site $b $agv01Key; $siteC = New-Site $c $agv03Key
    $null = New-VehicleConfig $car $site 502
    $null = New-VehicleConfig $b $site 502
    $null = New-VehicleConfig $c '127.0.0.1' 1502
    $siteDir = Join-Path $work 'sites'; New-Item -ItemType Directory -Force -Path $siteDir | Out-Null
    Copy-Item $siteA (Join-Path $siteDir "site-$car.json"); Copy-Item $siteB (Join-Path $siteDir "site-$b.json"); Copy-Item $siteC (Join-Path $siteDir "site-$c.json")
    $recordOk = Join-Path $work 'io-check-ok.json'
    $d = Invoke-Script $CheckScript @('-SshAlias', "$car,$b", '-SiteDirectory', $siteDir, '-RecordPath', $recordOk)
    $rec = (Test-Path -LiteralPath $recordOk) ? (Get-Content -Raw -LiteralPath $recordOk | ConvertFrom-Json -AsHashtable) : $null
    Write-Result -Ok ($d.Code -eq 0 -and $null -ne $rec -and @($rec['results']).Count -eq 2 -and @($rec['results'] | Where-Object { -not $_['ok'] }).Count -eq 0 -and
        $null -eq (Get-IoCheckRecordRefusal -Record $rec -FleetVehicleKeys @($agv02Key, $agv01Key) -Now ([DateTimeOffset]::Now))) `
        -Name 'two cars on their real module: exit 0, a record the gate accepts for that fleet' -Detail "exit $($d.Code)`n$($d.Output)"
    Write-Result -Ok (-not ($d.Calls -match 'Set-Content|Copy-Item')) -Name 'the check sends nothing that writes to a vehicle' -Detail ($d.Calls -join "`n")
    $recordBad = Join-Path $work 'io-check-bad.json'
    $d = Invoke-Script $CheckScript @('-SshAlias', "$car,$c", '-SiteDirectory', $siteDir, '-RecordPath', $recordBad)
    $rec = (Test-Path -LiteralPath $recordBad) ? (Get-Content -Raw -LiteralPath $recordBad | ConvertFrom-Json -AsHashtable) : $null
    Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains("IO_CHECK $c REFUSED PRODUCTION_IO_LOOPBACK") -and $null -ne $rec -and
        "$(Get-IoCheckRecordRefusal -Record $rec -FleetVehicleKeys @($agv02Key) -Now ([DateTimeOffset]::Now))".StartsWith('IO_CHECK_RECORD_FAILED:')) `
        -Name 'one car still on the simulator: non-zero exit, a readable line, and a record the gate refuses' -Detail "exit $($d.Code)`n$($d.Output)"

    Write-Host ''
    Write-Host 'The dispatch gate: -State Open in the production phase needs the IO check record (ssh shim)' -ForegroundColor Cyan
    $repo = Join-Path $work 'cs-repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'scripts/parallel') | Out-Null
    # A stand-in control-server checkout: enough for the gate script to read opsRoot and pass its checkout checks.
    @'
function Read-ParallelInstanceDefinition { param([string] $Path) return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable) }
function Test-ParallelInstanceOwnedPath { param([string] $Path) return $null }
function Get-ParallelCutoverContractVersion { return 2 }
Export-ModuleMember -Function *
'@ | Set-Content -LiteralPath (Join-Path $repo 'scripts/parallel/ParallelInstance.psm1')
    '' | Set-Content -LiteralPath (Join-Path $repo 'scripts/parallel/ParallelHost.psm1')
    '' | Set-Content -LiteralPath (Join-Path $repo 'scripts/parallel/Set-ParallelDispatchGateLocal.ps1')
    @{ opsRoot = 'D:\zhengyushao\control-server-v2-ops' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'scripts/parallel/instance-factory01-v2.json')
    & git -C $repo init -q 2>&1 | Out-Null
    & git -C $repo -c user.email=t@t -c user.name=t add -A 2>&1 | Out-Null
    & git -C $repo -c user.email=t@t -c user.name=t commit -q -m fixture 2>&1 | Out-Null
    $gateArgs = { param($state, [string[]] $extra = @()) @('-State', $state, '-ControlServerRepository', $repo, '-SshAlias', 'ws51-server-fake', '-WhatIf') + $extra }

    $env:WS51_SERVER_RECORD = New-InstalledRecord 'gate-production' 'production' -Fleet @($agv02Key, $agv01Key)
    $d = Invoke-Script $GateScript (& $gateArgs 'Open')
    Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains('IO_CHECK_RECORD_REQUIRED:') -and @($d.Calls | Where-Object { $_ -like 'scp |*' }).Count -eq 0) `
        -Name 'production, Open, no record: refused (IO_CHECK_RECORD_REQUIRED) before anything is copied' -Detail "exit $($d.Code)`n$($d.Output)"
    $d = Invoke-Script $GateScript (& $gateArgs 'Open' @('-IoCheckRecord', $recordBad))
    Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains('IO_CHECK_RECORD_FAILED:')) -Name 'production, Open, a record with a car on the simulator: refused' -Detail "exit $($d.Code)`n$($d.Output)"
    $d = Invoke-Script $GateScript (& $gateArgs 'Open' @('-IoCheckRecord', $recordOk))
    Write-Result -Ok (-not $d.Output.Contains('IO_CHECK_RECORD') -and $d.Output.Contains('IO check record')) `
        -Name 'production, Open, a valid record for the installed fleet: the IO check passes' -Detail "exit $($d.Code)`n$($d.Output)"
    $d = Invoke-Script $GateScript (& $gateArgs 'Closed')
    Write-Result -Ok (-not $d.Output.Contains('IO_CHECK_RECORD')) -Name 'production, Closed: no record asked for' -Detail "exit $($d.Code)`n$($d.Output)"
    $env:WS51_SERVER_RECORD = New-InstalledRecord 'gate-trial' 'trial'
    $d = Invoke-Script $GateScript (& $gateArgs 'Open')
    Write-Result -Ok (-not $d.Output.Contains('IO_CHECK_RECORD')) -Name 'trial, Open, no record: not asked for' -Detail "exit $($d.Code)`n$($d.Output)"
} finally {
    if ($null -ne (Get-Variable -Name savedPath -ValueOnly -ErrorAction SilentlyContinue)) { $env:PATH = $savedPath }
    Get-ChildItem Env: | Where-Object { $_.Name -like 'WS51_*' } | ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Finish
