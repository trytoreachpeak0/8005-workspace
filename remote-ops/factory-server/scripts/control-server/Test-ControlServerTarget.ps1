#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for the instance-target checks of Set-JourneyRuntime.ps1 and 13-close-gates-when-idle.ps1
    (workspace#35).

.DESCRIPTION
    Nothing here reaches factory01, the MVP, the v2 instance or a vehicle. Three layers:

      * ControlServerTarget.psm1 imported and driven directly: which parameter sets are refused (TARGET_PARTIAL,
        TARGET_MIXED_MVP) and which read-backs are (TARGET_SERVICE_*, TARGET_CONFIG_*, TARGET_HEALTH_*,
        TARGET_BASE_URL_*, TARGET_DATABASE_*);
      * the read-back script the module sends to the server, run for real on this machine against a fixture
        configuration directory (read-only: it reads one service's metadata and two JSON files);
      * both scripts end to end in a child pwsh, with an ssh shim first on PATH that answers by recognising the
        decoded command and logs every call, and an alias that resolves nowhere (a bypassed shim fails to resolve
        rather than reaching a server). Refusals of the parameter set must make no ssh call at all; refusals of
        the read-back must make exactly that one call; the MVP with no instance parameters and a complete v2 set
        must get through to ShouldProcess (-WhatIf).

.PARAMETER RemoteOpsRoot
    The remote-ops directory under test. Mutation runs point it at an edited copy.

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/control-server/Test-ControlServerTarget.ps1
#>
[CmdletBinding()]
param(
    [string] $RemoteOpsRoot = (Join-Path $PSScriptRoot '..\..\..')
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

$root = (Resolve-Path -LiteralPath $RemoteOpsRoot).Path
$modulePath = Join-Path $root 'factory-server\scripts\control-server\ControlServerTarget.psm1'
$sjrPath = Join-Path $root 'factory-server\scripts\control-server\Set-JourneyRuntime.ps1'
$closePath = Join-Path $root 'onboard-hmi\scripts\13-close-gates-when-idle.ps1'
Import-Module $modulePath -Force

$mvp = [ordered]@{
    ServiceName = '8005 AGV ControlServer'
    InstallRoot = 'C:\Program Files\8005 AGV\ControlServer'
    ConfigPath  = 'C:\Program Files\8005 AGV\ControlServer\appsettings.Production.json'
    BaseUrl     = 'http://172.19.205.222:58007'
    Database    = 'C:\ProgramData\8005\ControlServer\data\controlserver.db'
}
$v2 = [ordered]@{
    ServiceName = '8005 AGV ControlServer V2'
    InstallRoot = 'C:\Program Files\8005 AGV\ControlServer.V2'
    ConfigPath  = 'C:\Program Files\8005 AGV\ControlServer.V2\appsettings.Production.json'
    BaseUrl     = 'http://172.19.205.222:58107'
    Database    = 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db'
}

function Get-Code {
    param([scriptblock] $Action)
    try { $null = & $Action; return 'OK' }
    catch { $m = $_.Exception.Message; return ($m -match '^([A-Z_]+):') ? $Matches[1] : "OTHER: $m" }
}

# ----------------------------------------------------------------------------------------------- parameter set ---

Write-Host ''
Write-Host 'Assert-ControlServerTargetParameters (no I/O)' -ForegroundColor Cyan

$sjrKinds = [ordered]@{ ServiceName = 'ServiceName'; ConfigPath = 'ConfigPath'; BaseUrl = 'BaseUrl' }
function Test-SjrSet {
    param([string[]] $Bound, [System.Collections.IDictionary] $Over)
    $values = [ordered]@{ ServiceName = $mvp.ServiceName; ConfigPath = $mvp.ConfigPath; BaseUrl = $mvp.BaseUrl }
    foreach ($k in @($Over.Keys)) { $values[$k] = $Over[$k] }
    Get-Code { Assert-ControlServerTargetParameters -Bound $Bound -Values $values -Kinds $sjrKinds }
}

$r = Assert-ControlServerTargetParameters -Bound @('Off', 'Force') -Values ([ordered]@{ ServiceName = $mvp.ServiceName; ConfigPath = $mvp.ConfigPath; BaseUrl = $mvp.BaseUrl }) -Kinds $sjrKinds
Write-Result -Ok ($r.IsMvp -and -not $r.Explicit) -Name 'Set-JourneyRuntime: no instance parameter -> the MVP, passes' -Detail ($r | ConvertTo-Json -Compress)
foreach ($name in @('ServiceName', 'ConfigPath', 'BaseUrl')) {
    $code = Test-SjrSet -Bound @($name) -Over ([ordered]@{ $name = $v2[$name] })
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "Set-JourneyRuntime: v2 -$name alone -> TARGET_PARTIAL" -Detail $code
}
foreach ($pair in @(@('ServiceName', 'ConfigPath'), @('ServiceName', 'BaseUrl'), @('ConfigPath', 'BaseUrl'))) {
    $over = [ordered]@{}; foreach ($n in $pair) { $over[$n] = $v2[$n] }
    $code = Test-SjrSet -Bound $pair -Over $over
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "Set-JourneyRuntime: v2 -$($pair -join ', -') without the third -> TARGET_PARTIAL" -Detail $code
}
foreach ($name in @('ServiceName', 'ConfigPath', 'BaseUrl')) {
    $code = Test-SjrSet -Bound @($name) -Over ([ordered]@{})
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "Set-JourneyRuntime: -$name given explicitly with its MVP value alone -> TARGET_PARTIAL" -Detail $code
}
$all = @('ServiceName', 'ConfigPath', 'BaseUrl')
foreach ($mvpOne in $all) {
    $over = [ordered]@{}; foreach ($n in $all) { $over[$n] = ($n -eq $mvpOne) ? $mvp[$n] : $v2[$n] }
    $code = Test-SjrSet -Bound $all -Over $over
    Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name "Set-JourneyRuntime: all three given, only -$mvpOne the MVP's -> TARGET_MIXED_MVP" -Detail $code
    $over = [ordered]@{}; foreach ($n in $all) { $over[$n] = ($n -eq $mvpOne) ? $v2[$n] : $mvp[$n] }
    $code = Test-SjrSet -Bound $all -Over $over
    Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name "Set-JourneyRuntime: all three given, only -$mvpOne not the MVP's -> TARGET_MIXED_MVP" -Detail $code
}
$code = Test-SjrSet -Bound $all -Over ([ordered]@{ ServiceName = ' 8005 agv controlserver '; ConfigPath = 'c:/program files/8005 agv/controlserver/appsettings.Production.json'; BaseUrl = $v2.BaseUrl })
Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name 'Set-JourneyRuntime: MVP name and path in other case and slashes are still the MVP -> TARGET_MIXED_MVP' -Detail $code
$code = Test-SjrSet -Bound $all -Over ([ordered]@{ ServiceName = $v2.ServiceName; ConfigPath = $v2.ConfigPath; BaseUrl = 'http://localhost:58007' })
Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name 'Set-JourneyRuntime: -BaseUrl on port 58007 of another host is still the MVP -> TARGET_MIXED_MVP' -Detail $code
$r = Assert-ControlServerTargetParameters -Bound $all -Values ([ordered]@{ ServiceName = $v2.ServiceName; ConfigPath = $v2.ConfigPath; BaseUrl = $v2.BaseUrl }) -Kinds $sjrKinds
Write-Result -Ok (-not $r.IsMvp -and $r.Explicit) -Name 'Set-JourneyRuntime: all three v2 -> passes, not the MVP' -Detail ($r | ConvertTo-Json -Compress)
$r = Assert-ControlServerTargetParameters -Bound $all -Values ([ordered]@{ ServiceName = $mvp.ServiceName; ConfigPath = $mvp.ConfigPath; BaseUrl = $mvp.BaseUrl }) -Kinds $sjrKinds
Write-Result -Ok ($r.IsMvp -and $r.Explicit) -Name 'Set-JourneyRuntime: all three MVP values given explicitly -> passes, the MVP' -Detail ($r | ConvertTo-Json -Compress)

$closeNames = [ordered]@{ ServerDatabase = 'Database'; ServerInstallRoot = 'InstallRoot'; ServerConfigPath = 'ConfigPath'; ServiceName = 'ServiceName'; BaseUrl = 'BaseUrl' }
$closeKinds = [ordered]@{ ServerInstallRoot = 'InstallRoot'; ServerConfigPath = 'ConfigPath'; ServiceName = 'ServiceName'; BaseUrl = 'BaseUrl' }
function Get-CloseValues([System.Collections.IDictionary] $Source, [System.Collections.IDictionary] $Over) {
    $values = [ordered]@{}
    foreach ($n in @($closeNames.Keys)) { $values[$n] = $Source[$closeNames[$n]] }
    foreach ($k in @($Over.Keys)) { $values[$k] = $Over[$k] }
    $values
}
foreach ($name in @($closeNames.Keys)) {
    $code = Get-Code { Assert-ControlServerTargetParameters -Bound @($name) -Values (Get-CloseValues $mvp ([ordered]@{ $name = $v2[$closeNames[$name]] })) -Kinds $closeKinds }
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "13: v2 -$name alone -> TARGET_PARTIAL" -Detail $code
}
$code = Get-Code { Assert-ControlServerTargetParameters -Bound @('ServerDatabase') -Values (Get-CloseValues $mvp ([ordered]@{ ServerDatabase = 'D:\rehearsal\controlserver.db' })) -Kinds $closeKinds }
Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name '13: a rehearsal copy as -ServerDatabase alone -> TARGET_PARTIAL (all five now)' -Detail $code
$allClose = @($closeNames.Keys)
foreach ($mvpOne in @($closeKinds.Keys)) {
    $over = [ordered]@{}; foreach ($n in $allClose) { $over[$n] = ($n -eq $mvpOne) ? $mvp[$closeNames[$n]] : $v2[$closeNames[$n]] }
    $code = Get-Code { Assert-ControlServerTargetParameters -Bound $allClose -Values $over -Kinds $closeKinds }
    Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name "13: all five given, only -$mvpOne the MVP's -> TARGET_MIXED_MVP" -Detail $code
}
$r = Assert-ControlServerTargetParameters -Bound @('Force') -Values (Get-CloseValues $mvp ([ordered]@{})) -Kinds $closeKinds
Write-Result -Ok $r.IsMvp -Name '13: no instance parameter -> the MVP, passes' -Detail ($r | ConvertTo-Json -Compress)
$r = Assert-ControlServerTargetParameters -Bound $allClose -Values (Get-CloseValues $v2 ([ordered]@{})) -Kinds $closeKinds
Write-Result -Ok (-not $r.IsMvp) -Name '13: all five v2 -> passes' -Detail ($r | ConvertTo-Json -Compress)
$r = Assert-ControlServerTargetParameters -Bound $allClose -Values (Get-CloseValues $mvp ([ordered]@{ ServerDatabase = 'D:\rehearsal\controlserver.db' })) -Kinds $closeKinds
Write-Result -Ok $r.IsMvp -Name '13: all five, MVP with a rehearsal copy -> passes the parameter check (the database is the read-back''s)' -Detail ($r | ConvertTo-Json -Compress)

# ---------------------------------------------------------------------------------------------------- read-back ---

Write-Host ''
Write-Host 'Assert-ControlServerTargetReadback' -ForegroundColor Cyan

function New-Readback([System.Collections.IDictionary] $Target, [System.Collections.IDictionary] $Over) {
    $rb = [ordered]@{
        serviceFound     = $true
        servicePathName  = "`"$($Target.InstallRoot)\ControlServer.Host.exe`""
        configFound      = $true
        healthUrl        = ($Target.BaseUrl -replace '^http://[^:]+', 'http://172.19.205.222')
        connectionString = "Data Source=$($Target.Database)"
        logPath          = ($Target.Database -replace '\\data\\controlserver\.db$', '\logs\controlserver-.ndjson')
    }
    foreach ($k in @($Over.Keys)) { $rb[$k] = $Over[$k] }
    [pscustomobject]$rb
}
function Test-Readback([System.Collections.IDictionary] $Target, $Readback, [System.Collections.IDictionary] $Extra = @{}) {
    Get-Code { Assert-ControlServerTargetReadback -Readback $Readback -ServiceName $Target.ServiceName -ConfigPath $Target.ConfigPath -BaseUrl $Target.BaseUrl @Extra }
}
$closeExtraFor = { param($t) @{ InstallRoot = $t.InstallRoot; Database = $t.Database } }

foreach ($t in @(@{ Name = 'MVP'; T = $mvp }, @{ Name = 'v2'; T = $v2 })) {
    $code = Test-Readback $t.T (New-Readback $t.T @{})
    Write-Result -Ok ($code -eq 'OK') -Name "$($t.Name) read-back consistent -> passes (Set-JourneyRuntime)" -Detail $code
    $code = Test-Readback $t.T (New-Readback $t.T @{}) (& $closeExtraFor $t.T)
    Write-Result -Ok ($code -eq 'OK') -Name "$($t.Name) read-back consistent -> passes (13, with install root and database)" -Detail $code
}
$facts = Assert-ControlServerTargetReadback -Readback (New-Readback $v2 @{}) -ServiceName $v2.ServiceName -ConfigPath $v2.ConfigPath -BaseUrl $v2.BaseUrl
Write-Result -Ok ($facts.LogDirectory -eq 'C:\ProgramData\8005\ControlServer.V2\logs' -and $facts.LogFilter -eq 'controlserver-*.ndjson') `
    -Name 'v2 read-back names its own log directory and file pattern' -Detail ($facts | ConvertTo-Json -Compress)
$facts = Assert-ControlServerTargetReadback -Readback (New-Readback $v2 @{ logPath = $null }) -ServiceName $v2.ServiceName -ConfigPath $v2.ConfigPath -BaseUrl $v2.BaseUrl
Write-Result -Ok ($null -eq $facts.LogDirectory) -Name 'a configuration naming no log file gives no log directory' -Detail ($facts | ConvertTo-Json -Compress)

$cases = @(
    @{ Name = 'the v2 service is not on the server'; T = $v2; Over = @{ serviceFound = $false; servicePathName = '' }; Code = 'TARGET_SERVICE_NOT_FOUND' }
    @{ Name = 'the v2 configuration is not on the server'; T = $v2; Over = @{ configFound = $false }; Code = 'TARGET_CONFIG_NOT_FOUND' }
    @{ Name = 'v2 parameters, but that service runs from the MVP directory'; T = $v2; Over = @{ servicePathName = "`"$($mvp.InstallRoot)\ControlServer.Host.exe`"" }; Code = 'TARGET_SERVICE_CONFIG_MISMATCH' }
    @{ Name = 'MVP parameters, but the MVP-named service runs from the V2 directory'; T = $mvp; Over = @{ servicePathName = "$($v2.InstallRoot)\ControlServer.Host.exe --contentRoot x" }; Code = 'TARGET_SERVICE_CONFIG_MISMATCH' }
    @{ Name = 'Health.url missing'; T = $v2; Over = @{ healthUrl = $null }; Code = 'TARGET_HEALTH_URL_UNKNOWN' }
    @{ Name = 'Health.url unparseable'; T = $v2; Over = @{ healthUrl = 'not a url' }; Code = 'TARGET_HEALTH_URL_UNKNOWN' }
    @{ Name = 'v2 configuration binds health on 58007, -BaseUrl 58107'; T = $v2; Over = @{ healthUrl = 'http://172.19.205.222:58007' }; Code = 'TARGET_BASE_URL_MISMATCH' }
)
foreach ($c in $cases) {
    $code = Test-Readback $c.T (New-Readback $c.T $c.Over)
    Write-Result -Ok ($code -eq $c.Code) -Name "$($c.Name) -> $($c.Code)" -Detail $code
}
$code = Test-Readback $v2 (New-Readback $v2 @{}) @{ InstallRoot = $mvp.InstallRoot; Database = $v2.Database }
Write-Result -Ok ($code -eq 'TARGET_SERVICE_CONFIG_MISMATCH') -Name '13: -ServerInstallRoot not the directory the service runs from -> TARGET_SERVICE_CONFIG_MISMATCH' -Detail $code
$code = Test-Readback $v2 (New-Readback $v2 @{ connectionString = $null }) (& $closeExtraFor $v2)
Write-Result -Ok ($code -eq 'TARGET_DATABASE_UNKNOWN') -Name '13: no readable connection string -> TARGET_DATABASE_UNKNOWN' -Detail $code
$code = Test-Readback $v2 (New-Readback $v2 @{}) @{ InstallRoot = $v2.InstallRoot; Database = $mvp.Database }
Write-Result -Ok ($code -eq 'TARGET_DATABASE_OTHER_INSTANCE') -Name '13: v2 instance with the MVP database -> TARGET_DATABASE_OTHER_INSTANCE' -Detail $code
$code = Test-Readback $mvp (New-Readback $mvp @{}) @{ InstallRoot = $mvp.InstallRoot; Database = $v2.Database }
Write-Result -Ok ($code -eq 'TARGET_DATABASE_OTHER_INSTANCE') -Name '13: MVP instance with the v2 database -> TARGET_DATABASE_OTHER_INSTANCE' -Detail $code
$facts = Assert-ControlServerTargetReadback -Readback (New-Readback $mvp @{}) -ServiceName $mvp.ServiceName -ConfigPath $mvp.ConfigPath -BaseUrl $mvp.BaseUrl -InstallRoot $mvp.InstallRoot -Database 'D:\rehearsal\controlserver.db'
Write-Result -Ok $facts.DatabaseIsCopy -Name '13: a database outside C:\ProgramData\8005\ is a rehearsal copy, allowed and flagged' -Detail ($facts | ConvertTo-Json -Compress)
$facts = Assert-ControlServerTargetReadback -Readback (New-Readback $mvp @{ connectionString = 'Data Source=c:/programdata/8005/controlserver/data/CONTROLSERVER.db;Mode=ReadWriteCreate' }) -ServiceName $mvp.ServiceName -ConfigPath $mvp.ConfigPath -BaseUrl $mvp.BaseUrl -InstallRoot $mvp.InstallRoot -Database $mvp.Database
Write-Result -Ok (-not $facts.DatabaseIsCopy) -Name '13: the own database in other case, slashes and extra keywords is the own' -Detail ($facts | ConvertTo-Json -Compress)

$src = Resolve-ControlServerLogSource -Facts ([pscustomobject]@{ LogDirectory = 'C:\ProgramData\8005\ControlServer.V2\logs'; LogFilter = 'cs-*.ndjson' }) -IsMvp $false
Write-Result -Ok ($src.Directory -eq 'C:\ProgramData\8005\ControlServer.V2\logs' -and $src.Filter -eq 'cs-*.ndjson') -Name 'log tail: the directory and pattern the configuration names' -Detail ($src | ConvertTo-Json -Compress)
$src = Resolve-ControlServerLogSource -Facts ([pscustomobject]@{ LogDirectory = $null; LogFilter = $null }) -IsMvp $false
Write-Result -Ok ($null -eq $src) -Name 'log tail: another instance whose configuration names no log file is not tailed (never the MVP log)' -Detail ($src | ConvertTo-Json -Compress)
$src = Resolve-ControlServerLogSource -Facts ([pscustomobject]@{ LogDirectory = $null; LogFilter = $null }) -IsMvp $true
Write-Result -Ok ($src.Directory -eq 'C:\ProgramData\8005\ControlServer\logs' -and $src.Filter -eq 'controlserver-*.ndjson') -Name 'log tail: the MVP falls back to its fixed directory, as before' -Detail ($src | ConvertTo-Json -Compress)

foreach ($p in @(
        @{ In = '"C:\Program Files\8005 AGV\ControlServer.V2\ControlServer.Host.exe" --urls x'; Out = 'C:\Program Files\8005 AGV\ControlServer.V2' }
        @{ In = 'C:\Program Files\8005 AGV\ControlServer\ControlServer.Host.exe'; Out = 'C:\Program Files\8005 AGV\ControlServer' }
        @{ In = 'C:\svc\a.exe -x'; Out = 'C:\svc' })) {
    $got = Get-ServiceExecutableDirectory $p.In
    Write-Result -Ok ($got -eq $p.Out) -Name "service PathName $($p.In) -> $($p.Out)" -Detail $got
}

# ------------------------------------------------------------------------------ the read-back script, for real ---

Write-Host ''
Write-Host 'The read-back script, run on this machine against a fixture directory (read-only)' -ForegroundColor Cyan
$work = Join-Path ([IO.Path]::GetTempPath()) "ws35-target-selftest-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$savedPath = $env:PATH
try {
    $fixture = Join-Path $work 'install'
    New-Item -ItemType Directory -Force -Path $fixture | Out-Null
    @{ Health = @{ url = 'http://172.19.205.222:58107' }; ConnectionStrings = @{ ControlServer = "Data Source=$($v2.Database)" }; JourneyRuntime = @{ enabled = $false } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture 'appsettings.Production.json')
    @{ Serilog = @{ WriteTo = @(@{ Name = 'Console' }, @{ Name = 'File'; Args = @{ path = 'C:\ProgramData\8005\ControlServer.V2\logs\controlserver-.ndjson' } }) } } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixture 'appsettings.json')
    $cfg = Join-Path $fixture 'appsettings.Production.json'
    $run = {
        param($service, $config)
        $text = Get-ControlServerTargetReadbackScript -ServiceName $service -ConfigPath $config
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text))
        (& pwsh -NoProfile -EncodedCommand $encoded | Out-String).Trim() | ConvertFrom-Json
    }
    $rb = & $run "ws35 no such service 'quoted'" $cfg
    Write-Result -Ok (-not $rb.serviceFound -and $rb.configFound -and $rb.healthUrl -eq 'http://172.19.205.222:58107' -and
        $rb.connectionString -eq "Data Source=$($v2.Database)" -and $rb.logPath -like '*ControlServer.V2\logs\controlserver-.ndjson') `
        -Name 'reads Health.url and the connection string from the Production file, the log path from the base file; absent service not found' -Detail ($rb | ConvertTo-Json -Compress)
    $rb = & $run 'Winmgmt' (Join-Path $work 'absent\appsettings.Production.json')
    Write-Result -Ok ($rb.serviceFound -and $rb.servicePathName -match '\.exe' -and -not $rb.configFound -and $null -eq $rb.healthUrl) `
        -Name 'an existing service (Winmgmt) is found with its PathName; a missing configuration is reported, not thrown' -Detail ($rb | ConvertTo-Json -Compress)

    # ------------------------------------------------------------------------------------- whole scripts, shim ---

    Write-Host ''
    Write-Host 'Both scripts end to end in a child pwsh, ssh shim on PATH, alias resolving nowhere' -ForegroundColor Cyan
    $shimDir = Join-Path $work 'shim'
    New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
    $sshLog = Join-Path $work 'ssh-calls.log'
    @'
#Requires -Version 7
# ssh shim for Test-ControlServerTarget.ps1: recognises each remote script by its content, answers with a fixture,
# logs the kind of call. Anything it does not recognise fails.
$plain = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -ceq '-o') { $i++ } else { $plain.Add([string]$args[$i]) } }
$alias = $plain[0]
$joined = ($plain | Select-Object -Skip 1) -join ' '
$decoded = ''
if ($joined -match '-EncodedCommand (\S+)') { $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) }
$kind = if ($decoded -match '# workspace#35 target read-back') { 'readback' }
    elseif ($decoded -match 'chargeTrigger\s+=') { 'survey' }
    elseif ($decoded -match 'AcceptedDemands') { 'state' }
    else { 'other' }
Add-Content -LiteralPath $env:WS35_SSH_LOG -Value "$alias | $kind" -WhatIf:$false
if ($alias -cne 'ws35-nowhere.invalid') { "shim: unexpected alias $alias"; exit 255 }
switch ($kind) {
    'readback' { $env:WS35_READBACK; exit 0 }
    'survey' { '{"runtime":true,"dispatch":false,"chargeTrigger":null,"chargeResume":null,"autoCharging":true,"baseTrigger":30,"baseResume":80,"minimumBattery":20,"service":"Running"}'; exit 0 }
    'state' { '{"accepted":[],"intentDemands":[],"intentLegs":[],"journeys":[],"newest":[],"runtime":true,"dispatch":false,"service":"Running"}'; exit 0 }
    default { 'shim: unexpected command'; exit 255 }
}
'@ | Set-Content -LiteralPath (Join-Path $shimDir 'ssh.ps1')
    $env:PATH = "$shimDir;$savedPath"
    $env:WS35_SSH_LOG = $sshLog

    function Invoke-Whole {
        param([string] $Script, [string[]] $Arguments, $Readback)
        Remove-Item -LiteralPath $sshLog -Force -ErrorAction SilentlyContinue
        $env:WS35_READBACK = ($Readback | ConvertTo-Json -Compress)
        $out = (& pwsh -NoProfile -File $Script @Arguments *>&1 | Out-String)
        $exit = $LASTEXITCODE
        $calls = @((Test-Path -LiteralPath $sshLog) ? (Get-Content -LiteralPath $sshLog) : @())
        [pscustomobject]@{ Output = $out; Exit = $exit; Calls = $calls; Kinds = @($calls | ForEach-Object { ($_ -split ' \| ')[1] }) }
    }
    $common = @('-ServerAlias', 'ws35-nowhere.invalid', '-MesIngestSecretPath', (Join-Path $work 'no-such-secrets.xml'))
    $sjrArgs = { param($t, [string[]] $names) $a = @(); foreach ($n in $names) { $a += "-$n"; $a += $t[$n] }; $a }

    # Set-JourneyRuntime: refused before any ssh.
    foreach ($case in @(
            @{ Name = 'v2 -ServiceName alone'; Args = (& $sjrArgs $v2 @('ServiceName')); Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -ConfigPath alone'; Args = (& $sjrArgs $v2 @('ConfigPath')); Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -BaseUrl alone'; Args = (& $sjrArgs $v2 @('BaseUrl')); Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -ServiceName and -BaseUrl'; Args = (& $sjrArgs $v2 @('ServiceName', 'BaseUrl')); Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 service and URL, MVP configuration'; Args = ((& $sjrArgs $v2 @('ServiceName', 'BaseUrl')) + (& $sjrArgs $mvp @('ConfigPath'))); Code = 'TARGET_MIXED_MVP' })) {
        $res = Invoke-Whole $sjrPath (@('-Off', '-Force') + $common + $case.Args) (New-Readback $v2 @{})
        Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match $case.Code -and $res.Calls.Count -eq 0) `
            -Name "Set-JourneyRuntime -Off -Force, $($case.Name): $($case.Code), no ssh" -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    }
    # Refused on the read-back: one call, and nothing after it.
    $res = Invoke-Whole $sjrPath (@('-Off', '-Force') + $common + (& $sjrArgs $v2 @('ServiceName', 'ConfigPath', 'BaseUrl'))) (New-Readback $v2 @{ servicePathName = "`"$($mvp.InstallRoot)\ControlServer.Host.exe`"" })
    Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'TARGET_SERVICE_CONFIG_MISMATCH' -and ($res.Kinds -join ',') -eq 'readback') `
        -Name 'Set-JourneyRuntime -Off -Force, v2 set whose service runs from the MVP directory: refused after the read-back alone' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    $res = Invoke-Whole $sjrPath (@('-Off', '-Force') + $common + (& $sjrArgs $v2 @('ServiceName', 'ConfigPath', 'BaseUrl'))) (New-Readback $v2 @{ healthUrl = 'http://172.19.205.222:58007' })
    Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'TARGET_BASE_URL_MISMATCH' -and ($res.Kinds -join ',') -eq 'readback') `
        -Name 'Set-JourneyRuntime -Off -Force, v2 set whose configuration binds health on 58007: refused after the read-back alone' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    # Through to ShouldProcess.
    $res = Invoke-Whole $sjrPath (@('-Off', '-WhatIf') + $common) (New-Readback $mvp @{})
    Write-Result -Ok ($res.Exit -eq 0 -and ($res.Kinds -join ',') -eq 'readback,survey' -and $res.Output -match [regex]::Escape("ws35-nowhere.invalid ($($mvp.ConfigPath))") -and $res.Output -match 'the production MVP service') `
        -Name 'Set-JourneyRuntime -Off -WhatIf, no instance parameter: read-back, survey, ShouldProcess on the MVP configuration' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    $res = Invoke-Whole $sjrPath (@('-Off', '-WhatIf') + $common + (& $sjrArgs $v2 @('ServiceName', 'ConfigPath', 'BaseUrl'))) (New-Readback $v2 @{})
    Write-Result -Ok ($res.Exit -eq 0 -and ($res.Kinds -join ',') -eq 'readback,survey' -and $res.Output -match [regex]::Escape("ws35-nowhere.invalid ($($v2.ConfigPath))") -and $res.Output -match 'not the MVP service') `
        -Name 'Set-JourneyRuntime -Off -WhatIf, all three v2: read-back, survey, ShouldProcess on the v2 configuration' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    $res = Invoke-Whole $sjrPath (@('-Dispatch', '-WhatIf') + $common + (& $sjrArgs $v2 @('ServiceName', 'ConfigPath', 'BaseUrl'))) (New-Readback $v2 @{})
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Output -match 'not read: the target is not the MVP service' -and $res.Output -notmatch 'Could not read the MesIngest catalog') `
        -Name 'Set-JourneyRuntime -Dispatch -WhatIf, v2 without -MesIngestUrl: the production catalog is not read' -Detail $res.Output.Trim()
    $res = Invoke-Whole $sjrPath (@('-Dispatch', '-WhatIf') + $common) (New-Readback $mvp @{})
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Output -match 'Could not read the MesIngest catalog' -and $res.Output -notmatch 'not read: the target') `
        -Name 'Set-JourneyRuntime -Dispatch -WhatIf, MVP: tries the catalog as before (fails here on the absent secret file)' -Detail $res.Output.Trim()

    # 13: refused before any ssh.
    $closeArgs = { param($t, [string[]] $names) $a = @(); foreach ($n in $names) { $a += "-$n"; $a += $t[$closeNames[$n]] }; $a }
    $closeCommon = @('-ServerAlias', 'ws35-nowhere.invalid', '-Force')
    foreach ($name in $allClose) {
        $res = Invoke-Whole $closePath ($closeCommon + (& $closeArgs $v2 @($name))) (New-Readback $v2 @{})
        Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'TARGET_PARTIAL' -and $res.Calls.Count -eq 0) `
            -Name "13 -Force, v2 -$name alone: TARGET_PARTIAL, no ssh" -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    }
    $res = Invoke-Whole $closePath ($closeCommon + (& $closeArgs $v2 @('ServerDatabase', 'ServerInstallRoot', 'ServerConfigPath', 'ServiceName')) + (& $closeArgs $mvp @('BaseUrl'))) (New-Readback $v2 @{})
    Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'TARGET_MIXED_MVP' -and $res.Calls.Count -eq 0) `
        -Name '13 -Force, v2 set with the MVP -BaseUrl: TARGET_MIXED_MVP, no ssh' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    # Refused on the read-back.
    $res = Invoke-Whole $closePath ($closeCommon + (& $closeArgs $v2 $allClose)) (New-Readback $v2 @{ servicePathName = "`"$($mvp.InstallRoot)\ControlServer.Host.exe`"" })
    Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'TARGET_SERVICE_CONFIG_MISMATCH' -and ($res.Kinds -join ',') -eq 'readback') `
        -Name '13 -Force, v2 set whose service runs from the MVP directory: refused after the read-back alone' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    $res = Invoke-Whole $closePath ($closeCommon + (& $closeArgs $v2 @('ServerInstallRoot', 'ServerConfigPath', 'ServiceName', 'BaseUrl')) + (& $closeArgs $mvp @('ServerDatabase'))) (New-Readback $v2 @{})
    Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'TARGET_DATABASE_OTHER_INSTANCE' -and ($res.Kinds -join ',') -eq 'readback') `
        -Name '13 -Force, v2 set with the MVP database: refused after the read-back alone' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    # Through to ShouldProcess.
    $res = Invoke-Whole $closePath @('-ServerAlias', 'ws35-nowhere.invalid', '-WhatIf') (New-Readback $mvp @{})
    Write-Result -Ok ($res.Exit -eq 0 -and ($res.Kinds -join ',') -eq 'readback,state' -and $res.Output -match 'What if' -and $res.Output -match 'the production MVP service') `
        -Name '13 -WhatIf, no instance parameter: read-back, survey, ShouldProcess' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    $res = Invoke-Whole $closePath (@('-ServerAlias', 'ws35-nowhere.invalid', '-WhatIf') + (& $closeArgs $v2 $allClose)) (New-Readback $v2 @{})
    Write-Result -Ok ($res.Exit -eq 0 -and ($res.Kinds -join ',') -eq 'readback,state' -and $res.Output -match 'What if' -and $res.Output -match 'not the MVP service') `
        -Name '13 -WhatIf, all five v2: read-back, survey, ShouldProcess' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
    $res = Invoke-Whole $closePath (@('-ServerAlias', 'ws35-nowhere.invalid', '-WhatIf') + (& $closeArgs $mvp @('ServerInstallRoot', 'ServerConfigPath', 'ServiceName', 'BaseUrl')) + @('-ServerDatabase', 'D:\rehearsal\controlserver.db')) (New-Readback $mvp @{})
    Write-Result -Ok ($res.Exit -eq 0 -and ($res.Kinds -join ',') -eq 'readback,state' -and $res.Output -match 'is a copy') `
        -Name '13 -WhatIf, MVP rehearsal with all five and a copy outside ProgramData\8005: passes, says it is a copy' -Detail "exit $($res.Exit), calls [$($res.Kinds -join ',')], $($res.Output.Trim())"
}
finally {
    $env:PATH = $savedPath
    Remove-Item Env:WS35_SSH_LOG, Env:WS35_READBACK -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------------------------------- source ---

Write-Host ''
Write-Host 'Source' -ForegroundColor Cyan
$closeText = Get-Content -Raw -LiteralPath $closePath
Write-Result -Ok ($closeText -match '& \$gateScript -Off -Force -ServerAlias \$ServerAlias -ServiceName \$ServiceName -ConfigPath \$ServerConfigPath -BaseUrl \$BaseUrl') `
    -Name '13 hands Set-JourneyRuntime.ps1 all three of its instance parameters' -Detail 'call line changed'

Write-Host ''
$colour = $script:Failed ? 'Red' : 'Green'
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $colour
exit ($script:Failed ? 1 : 0)
