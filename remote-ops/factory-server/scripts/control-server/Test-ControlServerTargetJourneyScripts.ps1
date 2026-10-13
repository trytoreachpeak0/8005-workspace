#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for the instance and vehicle checks of 12-reset-journey-state.ps1, Complete-ChargingRun.ps1,
    11-drive-journey.ps1 and 14-set-recovery-window.ps1 (workspace#38).

.DESCRIPTION
    Nothing here reaches factory01, the MVP, the v2 instance or a vehicle. Two layers:

      * ControlServerTarget.psm1 driven directly: the Database kind, the three-parameter set of 12 and
        Complete-ChargingRun and the two-parameter set of 11 (TARGET_PARTIAL, TARGET_MIXED_MVP), the vehicle pairing
        (TARGET_VEHICLE_INSTANCE_MISMATCH), and the read-back without -BaseUrl and with -RequireOwnDatabase
        (TARGET_DATABASE_NOT_OWN);
      * the three scripts end to end in a child pwsh, with ssh and scp shims first on PATH that answer by
        recognising the command, log every call with the database it names, and refuse any alias but two that
        resolve nowhere (a bypassed shim fails to resolve rather than reaching a machine). A refused parameter set
        makes no ssh or scp call; a refused read-back makes exactly that one call; the MVP with no instance
        parameter and a complete v2 set get through to ShouldProcess (-WhatIf) against their own database.

    Test-ControlServerTarget.ps1 covers the same module for Set-JourneyRuntime.ps1 and 13 (workspace#35).

.PARAMETER RemoteOpsRoot
    The remote-ops directory under test. Mutation runs point it at an edited copy.

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/control-server/Test-ControlServerTargetJourneyScripts.ps1
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
    param([AllowNull()] $Ok, [string] $Name, [string] $Detail)
    if ([bool]$Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$root = (Resolve-Path -LiteralPath $RemoteOpsRoot).Path
$modulePath = Join-Path $root 'factory-server\scripts\control-server\ControlServerTarget.psm1'
$resetPath = Join-Path $root 'onboard-hmi\scripts\12-reset-journey-state.ps1'
$chargePath = Join-Path $root 'factory-server\scripts\control-server\Complete-ChargingRun.ps1'
$drivePath = Join-Path $root 'onboard-hmi\scripts\11-drive-journey.ps1'
$windowPath = Join-Path $root 'onboard-hmi\scripts\14-set-recovery-window.ps1'
Import-Module $modulePath -Force

$mvp = [ordered]@{
    ServiceName       = '8005 AGV ControlServer'
    ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer'
    ServerDatabase    = 'C:\ProgramData\8005\ControlServer\data\controlserver.db'
}
$v2 = [ordered]@{
    ServiceName       = '8005 AGV ControlServer V2'
    ServerInstallRoot = 'C:\Program Files\8005 AGV\ControlServer.V2'
    ServerDatabase    = 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db'
}
$copyDatabase = 'D:\rehearsal\controlserver.db'

function Get-Code {
    param([scriptblock] $Action)
    try { $null = & $Action; return 'OK' }
    catch { $m = $_.Exception.Message; return ($m -match '^([A-Z_]+):') ? $Matches[1] : "OTHER: $m" }
}
# A call that should pass: a throw becomes a failed result instead of ending the self-test.
function Invoke-Expected {
    param([scriptblock] $Action)
    try { & $Action } catch { [pscustomobject]@{ IsMvp = $null; Explicit = $null; Judged = $null; DatabaseIsCopy = $null; Error = $_.Exception.Message } }
}

# ----------------------------------------------------------------------------------------------- parameter set ---

Write-Host ''
Write-Host 'Assert-ControlServerTargetParameters for 12 / Complete-ChargingRun (three) and 11 (two)' -ForegroundColor Cyan

foreach ($d in @(
        @{ Value = $mvp.ServerDatabase; Mvp = $true }
        @{ Value = 'c:/programdata/8005/controlserver/DATA/controlserver.db'; Mvp = $true }
        @{ Value = '%ProgramData%\8005\ControlServer\data\controlserver.db'; Mvp = $true }
        @{ Value = $v2.ServerDatabase; Mvp = $false }
        @{ Value = $copyDatabase; Mvp = $false })) {
    $got = Test-MvpTargetValue -Kind Database -Value $d.Value
    Write-Result -Ok ($got -eq $d.Mvp) -Name "Database kind: $($d.Value) is $($d.Mvp ? '' : 'not ')the MVP's" -Detail "$got"
}

$threeKinds = [ordered]@{ ServerDatabase = 'Database'; ServerInstallRoot = 'InstallRoot'; ServiceName = 'ServiceName' }
$three = @($threeKinds.Keys)
function Get-ThreeCode([string[]] $Bound, [System.Collections.IDictionary] $Over) {
    $values = [ordered]@{}; foreach ($n in $three) { $values[$n] = $mvp[$n] }
    foreach ($k in @($Over.Keys)) { $values[$k] = $Over[$k] }
    Get-Code { Assert-ControlServerTargetParameters -Bound $Bound -Values $values -Kinds $threeKinds }
}
foreach ($name in $three) {
    $code = Get-ThreeCode @($name) ([ordered]@{ $name = $v2[$name] })
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "12/charging: v2 -$name alone -> TARGET_PARTIAL" -Detail $code
    $code = Get-ThreeCode @($name) ([ordered]@{})
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "12/charging: -$name given explicitly with its MVP value alone -> TARGET_PARTIAL" -Detail $code
}
foreach ($pair in @(@('ServerDatabase', 'ServerInstallRoot'), @('ServerDatabase', 'ServiceName'), @('ServerInstallRoot', 'ServiceName'))) {
    $over = [ordered]@{}; foreach ($n in $pair) { $over[$n] = $v2[$n] }
    $code = Get-ThreeCode $pair $over
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "12/charging: v2 -$($pair -join ', -') without the third -> TARGET_PARTIAL" -Detail $code
}
foreach ($odd in $three) {
    $over = [ordered]@{}; foreach ($n in $three) { $over[$n] = ($n -eq $odd) ? $mvp[$n] : $v2[$n] }
    $code = Get-ThreeCode $three $over
    Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name "12/charging: all three, only -$odd the MVP's -> TARGET_MIXED_MVP" -Detail $code
    $over = [ordered]@{}; foreach ($n in $three) { $over[$n] = ($n -eq $odd) ? $v2[$n] : $mvp[$n] }
    $code = Get-ThreeCode $three $over
    Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name "12/charging: all three, only -$odd not the MVP's -> TARGET_MIXED_MVP" -Detail $code
}
$r = Invoke-Expected { Assert-ControlServerTargetParameters -Bound @('Force') -Values ([ordered]@{ ServerDatabase = $mvp.ServerDatabase; ServerInstallRoot = $mvp.ServerInstallRoot; ServiceName = $mvp.ServiceName }) -Kinds $threeKinds }
Write-Result -Ok ($r.IsMvp -and -not $r.Explicit) -Name '12/charging: no instance parameter -> the MVP, passes' -Detail ($r | ConvertTo-Json -Compress)
$r = Invoke-Expected { Assert-ControlServerTargetParameters -Bound $three -Values ([ordered]@{ ServerDatabase = $v2.ServerDatabase; ServerInstallRoot = $v2.ServerInstallRoot; ServiceName = $v2.ServiceName }) -Kinds $threeKinds }
Write-Result -Ok ($r.IsMvp -eq $false -and $r.Explicit) -Name '12/charging: all three v2 -> passes, not the MVP' -Detail ($r | ConvertTo-Json -Compress)

$twoKinds = [ordered]@{ ServerDatabase = 'Database'; ServerInstallRoot = 'InstallRoot' }
$two = @($twoKinds.Keys)
function Get-TwoCode([string[]] $Bound, [System.Collections.IDictionary] $Over) {
    $values = [ordered]@{}; foreach ($n in $two) { $values[$n] = $mvp[$n] }
    foreach ($k in @($Over.Keys)) { $values[$k] = $Over[$k] }
    Get-Code { Assert-ControlServerTargetParameters -Bound $Bound -Values $values -Kinds $twoKinds }
}
foreach ($name in $two) {
    $code = Get-TwoCode @($name) ([ordered]@{ $name = $v2[$name] })
    Write-Result -Ok ($code -eq 'TARGET_PARTIAL') -Name "11: v2 -$name alone -> TARGET_PARTIAL" -Detail $code
    $other = @($two | Where-Object { $_ -ne $name })[0]
    $code = Get-TwoCode $two ([ordered]@{ $name = $v2[$name]; $other = $mvp[$other] })
    Write-Result -Ok ($code -eq 'TARGET_MIXED_MVP') -Name "11: v2 -$name with the MVP -$other -> TARGET_MIXED_MVP" -Detail $code
}

# ---------------------------------------------------------------------------------------------------- vehicle ---

Write-Host ''
Write-Host 'Assert-ControlServerVehicleTarget' -ForegroundColor Cyan
foreach ($c in @(
        @{ Alias = 'agv02'; IsMvp = $true; Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
        @{ Alias = 'agv03'; IsMvp = $true; Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
        @{ Alias = ' AGV02 '; IsMvp = $true; Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
        @{ Alias = 'agv01'; IsMvp = $false; Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
        @{ Alias = 'agv01'; IsMvp = $true; Code = 'OK' }
        @{ Alias = 'agv02'; IsMvp = $false; Code = 'OK' }
        @{ Alias = 'agv03'; IsMvp = $false; Code = 'OK' })) {
    $code = Get-Code { Assert-ControlServerVehicleTarget -SshAlias $c.Alias -IsMvp $c.IsMvp }
    Write-Result -Ok ($code -eq $c.Code) -Name "vehicle '$($c.Alias)' with $($c.IsMvp ? 'the MVP' : 'a v2 instance') -> $($c.Code)" -Detail $code
}
$r = Invoke-Expected { Assert-ControlServerVehicleTarget -SshAlias 'ws38-vehicle.invalid' -IsMvp $true }
Write-Result -Ok ($r.Judged -eq $false) -Name 'an alias that is no car of the fleet is not judged' -Detail ($r | ConvertTo-Json -Compress)

# control-server#564 (D7): which side a car is on is its site file's controlServerLine, read by VehicleControlServerLine.psm1.
# The cases above use the real site files (agv01 "mvp", agv02/agv03 "v2"). Here a scratch config directory stands for the
# cutover: agv01's one field changed to "v2" moves it, and nothing else does.
Write-Host ''
Write-Host 'controlServerLine: the pairing comes from the site file (control-server#564)' -ForegroundColor Cyan
Import-Module (Join-Path $root 'onboard-hmi\scripts\VehicleControlServerLine.psm1') -Force
$lineConfig = Join-Path ([IO.Path]::GetTempPath()) "cs564-line-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $lineConfig | Out-Null
try {
    foreach ($alias in @('agv01', 'agv02', 'agv03')) {
        $real = Get-Content -LiteralPath (Join-Path $root "onboard-hmi\config\site-$alias.json") -Raw | ConvertFrom-Json -AsHashtable
        Write-Result -Ok ($real['controlServerLine'] -ceq (($alias -ceq 'agv01') ? 'mvp' : 'v2')) -Name "the real site-$alias.json says $(($alias -ceq 'agv01') ? 'mvp' : 'v2') (today, before the cutover)" -Detail "got '$($real['controlServerLine'])'"
        $real['controlServerLine'] = 'v2'
        $real | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $lineConfig "site-$alias.json") -Encoding utf8
    }
    foreach ($c in @(
            @{ Alias = 'agv01'; IsMvp = $true; Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
            @{ Alias = 'agv01'; IsMvp = $false; Code = 'OK' }
            @{ Alias = 'agv02'; IsMvp = $false; Code = 'OK' })) {
        $code = Get-Code { Assert-ControlServerVehicleTarget -SshAlias $c.Alias -IsMvp $c.IsMvp -ConfigDirectory $lineConfig }
        Write-Result -Ok ($code -eq $c.Code) -Name "after the cutover's site file change: '$($c.Alias)' with $($c.IsMvp ? 'the MVP' : 'a v2 instance') -> $($c.Code)" -Detail $code
    }
    foreach ($bad in @(
            @{ Name = 'without the field'; Edit = { param($h) $h.Remove('controlServerLine') } }
            @{ Name = 'saying "MVP" (not exactly lower case)'; Edit = { param($h) $h['controlServerLine'] = 'MVP' } }
            @{ Name = 'saying "v3"'; Edit = { param($h) $h['controlServerLine'] = 'v3' } }
            @{ Name = 'with the field as a JSON boolean'; Edit = { param($h) $h['controlServerLine'] = $true } })) {
        $h = Get-Content -LiteralPath (Join-Path $root 'onboard-hmi\config\site-agv01.json') -Raw | ConvertFrom-Json -AsHashtable
        $null = & $bad.Edit $h
        $h | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $lineConfig 'site-agv01.json') -Encoding utf8
        foreach ($isMvp in @($true, $false)) {
            $code = Get-Code { Assert-ControlServerVehicleTarget -SshAlias 'agv01' -IsMvp $isMvp -ConfigDirectory $lineConfig }
            Write-Result -Ok ($code -eq 'VEHICLE_LINE_UNSET') -Name "a site file $($bad.Name) is refused, not guessed ($($isMvp ? 'MVP' : 'v2') target)" -Detail $code
        }
    }
    Remove-Item -LiteralPath (Join-Path $lineConfig 'site-agv01.json')
    $code = Get-Code { Assert-ControlServerVehicleTarget -SshAlias 'agv01' -IsMvp $true -ConfigDirectory $lineConfig }
    Write-Result -Ok ($code -eq 'VEHICLE_LINE_UNSET') -Name 'a fleet car with no site file is refused, not guessed' -Detail $code
    Set-Content -LiteralPath (Join-Path $lineConfig 'site-agv01.json') -Value '{ not json' -Encoding utf8
    $code = Get-Code { Read-VehicleControlServerLine -SitePath (Join-Path $lineConfig 'site-agv01.json') }
    Write-Result -Ok ($code -eq 'VEHICLE_LINE_UNSET') -Name 'a site file that is not JSON is refused' -Detail $code
} finally {
    Remove-Item -LiteralPath $lineConfig -Recurse -Force -ErrorAction SilentlyContinue
}
# The other two readers of the field: 06 (Test-DeployOnboardHmi.ps1 covers its port rule) and 16, which must refuse a car
# that is not on the v2 line before it reads the v2 database or types anything.
$text16 = Get-Content -LiteralPath (Join-Path $root 'onboard-hmi\scripts\16-enter-sublot-uia.ps1') -Raw
$at16 = $text16.IndexOf('if ($vehicleLine -cne ''v2'') {')
Write-Result -Ok ($at16 -gt 0 -and $text16.Contains('$vehicleLine = Read-VehicleControlServerLine -SitePath (Get-VehicleSitePath -SshAlias $SshAlias)') -and
    $at16 -lt $text16.IndexOf('$ServerDatabase = Assert-V2Database $ServerDatabase') -and $text16.Contains('[ValidateSet(''agv01'', ''agv02'', ''agv03'')][string] $SshAlias')) `
    -Name '16-enter-sublot-uia.ps1 refuses a car not on the v2 line before it reads the v2 database' -Detail "at $at16"
$text18 = Get-Content -LiteralPath (Join-Path $root 'onboard-hmi\scripts\18-set-v2-recovery-window.ps1') -Raw
$at18 = $text18.IndexOf('if ($vehicleLine -cne ''v2'') {')
Write-Result -Ok ($at18 -gt 0 -and $text18.Contains('$vehicleLine = Read-VehicleControlServerLine -SitePath (Get-VehicleSitePath -SshAlias $SshAlias)') -and
    $at18 -lt $text18.IndexOf('$repoRoot = (Resolve-Path -LiteralPath $ControlServerRepository).Path') -and $text18.Contains('[ValidateSet(''agv01'', ''agv02'', ''agv03'')]')) `
    -Name '18-set-v2-recovery-window.ps1 refuses a car not on the v2 line before it reads anything (review M2)' -Detail "at $at18"
foreach ($file in @('factory-server\scripts\control-server\ControlServerTarget.psm1', 'onboard-hmi\scripts\06-deploy-onboard-hmi.ps1', 'onboard-hmi\scripts\16-enter-sublot-uia.ps1',
        'onboard-hmi\scripts\18-set-v2-recovery-window.ps1')) {
    $code = Get-Content -LiteralPath (Join-Path $root $file) -Raw
    $lists = [regex]::Matches($code, "MvpVehicleAliases|V2VehicleAliases|v2OnlyAliases|ValidateSet\('agv02', 'agv03'\)")
    Write-Result -Ok ($lists.Count -eq 0) -Name "$(Split-Path -Leaf $file) keeps no list of which car is on which line" -Detail (($lists | ForEach-Object Value) -join ' | ')
}

# ---------------------------------------------------------------------------------------------------- read-back ---

Write-Host ''
Write-Host 'Assert-ControlServerTargetReadback without -BaseUrl, with -RequireOwnDatabase' -ForegroundColor Cyan
function New-Readback([System.Collections.IDictionary] $Target, [System.Collections.IDictionary] $Over = @{}) {
    $rb = [ordered]@{
        serviceFound     = $true
        servicePathName  = "`"$($Target.ServerInstallRoot)\ControlServer.Host.exe`""
        configFound      = $true
        healthUrl        = $null
        connectionString = "Data Source=$($Target.ServerDatabase)"
        logPath          = $null
    }
    foreach ($k in @($Over.Keys)) { $rb[$k] = $Over[$k] }
    [pscustomobject]$rb
}
function Test-WriterReadback([System.Collections.IDictionary] $Target, $Readback, [string] $Database = $Target.ServerDatabase) {
    Get-Code { Assert-ControlServerTargetReadback -Readback $Readback -ServiceName $Target.ServiceName `
            -ConfigPath (Join-Path $Target.ServerInstallRoot 'appsettings.Production.json') -InstallRoot $Target.ServerInstallRoot -Database $Database -RequireOwnDatabase }
}
foreach ($t in @(@{ Name = 'MVP'; T = $mvp }, @{ Name = 'v2'; T = $v2 })) {
    $code = Test-WriterReadback $t.T (New-Readback $t.T)
    Write-Result -Ok ($code -eq 'OK') -Name "$($t.Name) read-back consistent, no Health.url, no -BaseUrl -> passes" -Detail $code
}
foreach ($c in @(
        @{ Name = 'v2 set, its service runs from the MVP directory'; T = $v2; Over = @{ servicePathName = "`"$($mvp.ServerInstallRoot)\ControlServer.Host.exe`"" }; Db = $v2.ServerDatabase; Code = 'TARGET_SERVICE_CONFIG_MISMATCH' }
        @{ Name = 'v2 set, no such service'; T = $v2; Over = @{ serviceFound = $false; servicePathName = '' }; Db = $v2.ServerDatabase; Code = 'TARGET_SERVICE_NOT_FOUND' }
        @{ Name = 'v2 set, no configuration'; T = $v2; Over = @{ configFound = $false }; Db = $v2.ServerDatabase; Code = 'TARGET_CONFIG_NOT_FOUND' }
        @{ Name = 'v2 set, no connection string'; T = $v2; Over = @{ connectionString = $null }; Db = $v2.ServerDatabase; Code = 'TARGET_DATABASE_UNKNOWN' }
        @{ Name = 'v2 instance with the MVP database'; T = $v2; Over = @{}; Db = $mvp.ServerDatabase; Code = 'TARGET_DATABASE_OTHER_INSTANCE' }
        @{ Name = 'MVP instance whose configuration names another database'; T = $mvp; Over = @{ connectionString = "Data Source=$($v2.ServerDatabase)" }; Db = $mvp.ServerDatabase; Code = 'TARGET_DATABASE_OTHER_INSTANCE' }
        @{ Name = 'v2 instance with a copy outside ProgramData\8005'; T = $v2; Over = @{}; Db = $copyDatabase; Code = 'TARGET_DATABASE_NOT_OWN' }
        @{ Name = 'MVP instance with a copy outside ProgramData\8005'; T = $mvp; Over = @{}; Db = $copyDatabase; Code = 'TARGET_DATABASE_NOT_OWN' })) {
    $code = Test-WriterReadback $c.T (New-Readback $c.T $c.Over) $c.Db
    Write-Result -Ok ($code -eq $c.Code) -Name "$($c.Name) -> $($c.Code)" -Detail $code
}
$facts = Invoke-Expected { Assert-ControlServerTargetReadback -Readback (New-Readback $mvp) -ServiceName $mvp.ServiceName -ConfigPath (Join-Path $mvp.ServerInstallRoot 'appsettings.Production.json') -InstallRoot $mvp.ServerInstallRoot -Database $copyDatabase }
Write-Result -Ok ($facts.DatabaseIsCopy -eq $true) -Name 'without -RequireOwnDatabase a copy is still allowed and flagged (13 unchanged)' -Detail ($facts | ConvertTo-Json -Compress)

# ------------------------------------------------------------------------------------- whole scripts, shims ---

Write-Host ''
Write-Host 'The three scripts end to end in a child pwsh, ssh and scp shims on PATH, aliases resolving nowhere' -ForegroundColor Cyan
$work = Join-Path ([IO.Path]::GetTempPath()) "ws38-target-selftest-$PID"
$shimDir = Join-Path $work 'shim'
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
$log = Join-Path $work 'calls.log'
$savedPath = $env:PATH
try {
    @'
#Requires -Version 7
# ssh shim for Test-ControlServerTargetJourneyScripts.ps1: recognises each remote command by its content, answers with
# a fixture, logs "alias | kind | database". Unrecognised commands and other aliases fail.
$plain = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $args.Count; $i++) { if ($args[$i] -ceq '-o') { $i++ } else { $plain.Add([string]$args[$i]) } }
$alias = $plain[0]
$joined = ($plain | Select-Object -Skip 1) -join ' '
$decoded = ''
if ($joined -match '-EncodedCommand (\S+)') { $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])) }
$kind = if ($decoded -match '# workspace#35 target read-back') { 'readback' }
    elseif ($decoded -match '@@W2G-CHARGING-RUN@@' -and $decoded -match '\$settle = \$True') { 'charging-write' }
    elseif ($decoded -match '@@W2G-CHARGING-RUN@@') { 'charging-survey' }
    elseif ($decoded -match 'SublotEntryRequested') { 'sublot-query' }
    elseif ($decoded -match 'OperationProgress') { 'progress-query' }
    elseif ($decoded -match 'New-Item -ItemType Directory') { 'mkdir' }
    elseif ($decoded -match 'bytes, last written') { 'journal' }
    elseif ($joined -match 'Remove-Item -LiteralPath') { 'cleanup' }
    elseif ($joined -match 'server-settle-journey' -and $joined -match ' -Settle ') { 'settle-write' }
    elseif ($joined -match 'server-settle-journey') { 'settle-survey' }
    else { 'other' }
$text = "$decoded $joined"
$db = if ($text -match "\`$database = '([^']*)'") { $Matches[1] } elseif ($text -match "-Database '([^']*)'") { $Matches[1] }
    elseif ($text -match 'Data Source=([^;'']*)') { $Matches[1] } else { '' }
Add-Content -LiteralPath $env:WS38_LOG -Value "$alias | $kind | $db" -WhatIf:$false
if ($alias -cnotin @('ws38-server.invalid', 'ws38-vehicle.invalid')) { "shim: unexpected alias $alias"; exit 255 }
if ($kind -eq $env:WS38_FAIL_KIND) { "shim: $kind fails on purpose"; exit 255 }
switch ($kind) {
    'readback' { $env:WS38_READBACK; exit 0 }
    'charging-survey' { '@@W2G-CHARGING-RUN@@{"status":"SURVEY","runs":[{"ChargingRunId":"run-ws38","AgvId":"agv02","Stage":"Charging","BlockReasonCode":"CHARGER_NOT_ENGAGED","TriggeredAtBatteryPercent":20,"ReleasedAtBatteryPercent":null,"ChargerStationId":"C1","ChargerStationRiotId":"9","UpperId":"U1","CreatedAt":"x","UpdatedAt":"x","IntentStatus":"Completed","IntentOrderId":"o1"}],"serviceStatus":"Running"}'; exit 0 }
    'sublot-query' { 'S-WS38'; exit 0 }
    'mkdir' { exit 0 }
    'settle-survey' { $env:WS38_SURVEY ? $env:WS38_SURVEY : '{"status":"SURVEY","journeys":[],"refusals":[],"unattributedOutbox":[]}'; exit 0 }
    'journal' { '(absent)'; exit 0 }
    'cleanup' { exit 0 }
    default { 'shim: unexpected command'; exit 255 }
}
'@ | Set-Content -LiteralPath (Join-Path $shimDir 'ssh.ps1')
    @'
#Requires -Version 7
# scp shim: logs, copies nothing.
Add-Content -LiteralPath $env:WS38_LOG -Value "$(($args | Where-Object { "$_" -match ':' -and "$_" -notmatch '^[A-Za-z]:\\' } | Select-Object -First 1) -replace ':.*$', '') | scp | " -WhatIf:$false
exit 0
'@ | Set-Content -LiteralPath (Join-Path $shimDir 'scp.ps1')
    $env:PATH = "$shimDir;$savedPath"
    $env:WS38_LOG = $log

    function Invoke-Whole {
        param([string] $Script, [string[]] $Arguments, $Readback, [string] $FailKind = '', [string] $Survey = '')
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        $env:WS38_SURVEY = $Survey
        $env:WS38_READBACK = ($Readback | ConvertTo-Json -Compress)
        $env:WS38_FAIL_KIND = $FailKind
        $out = (& pwsh -NoProfile -File $Script @Arguments *>&1 | Out-String)
        $exit = $LASTEXITCODE
        $calls = @((Test-Path -LiteralPath $log) ? (Get-Content -LiteralPath $log) : @())
        [pscustomobject]@{
            Output = $out; Exit = $exit; Calls = $calls
            Kinds = (@($calls | ForEach-Object { ($_ -split ' \| ')[1] }) -join ',')
            Dbs   = @($calls | ForEach-Object { ($_ -split ' \| ')[2] } | Where-Object { $_ })
            Aliases = @($calls | ForEach-Object { ($_ -split ' \| ')[0] } | Sort-Object -Unique)
        }
    }
    function Get-Args([System.Collections.IDictionary] $Source, [string[]] $Names) { $a = @(); foreach ($n in $Names) { $a += "-$n"; $a += $Source[$n] }; $a }
    function Write-Refused($Res, [string] $Code, [string] $Name) {
        Write-Result -Ok ($Res.Exit -ne 0 -and $Res.Output -match $Code -and $Res.Calls.Count -eq 0) -Name "$Name`: $Code, no ssh or scp" `
            -Detail "exit $($Res.Exit), calls [$($Res.Calls -join '; ')], $($Res.Output.Trim())"
    }
    function Write-ReadbackOnly($Res, [string] $Code, [string] $Name) {
        Write-Result -Ok ($Res.Exit -ne 0 -and $Res.Output -match $Code -and $Res.Kinds -eq 'readback') -Name "$Name`: $Code after the read-back alone" `
            -Detail "exit $($Res.Exit), calls [$($Res.Calls -join '; ')], $($Res.Output.Trim())"
    }
    $server = @('-ServerAlias', 'ws38-server.invalid')
    $vehicle = @('-SshAlias', 'ws38-vehicle.invalid')

    # -------------------------------------------------------------------------------------------------- 12 ---
    $base12 = $server + @('-Force', '-ReasonCode', 'CANCELLED_BY_OPERATOR')
    foreach ($c in @(
            @{ Name = 'v2 -ServerDatabase alone'; Args = (Get-Args $v2 @('ServerDatabase')) + $vehicle; Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -ServerDatabase and -ServerInstallRoot (the review''s case)'; Args = (Get-Args $v2 @('ServerDatabase', 'ServerInstallRoot')) + $vehicle; Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -ServiceName alone'; Args = (Get-Args $v2 @('ServiceName')) + $vehicle; Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 database and install root, MVP -ServiceName'; Args = (Get-Args $v2 @('ServerDatabase', 'ServerInstallRoot')) + (Get-Args $mvp @('ServiceName')) + $vehicle; Code = 'TARGET_MIXED_MVP' }
            @{ Name = 'v2 service and install root, MVP -ServerDatabase'; Args = (Get-Args $v2 @('ServiceName', 'ServerInstallRoot')) + (Get-Args $mvp @('ServerDatabase')) + $vehicle; Code = 'TARGET_MIXED_MVP' }
            @{ Name = '-SshAlias agv02 with the defaults (the MVP)'; Args = @('-SshAlias', 'agv02'); Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
            @{ Name = 'all three v2, -SshAlias defaulted to agv01'; Args = (Get-Args $v2 $three); Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' })) {
        Write-Refused (Invoke-Whole $resetPath ($base12 + $c.Args) (New-Readback $v2)) $c.Code "12 -Force, $($c.Name)"
    }
    $all12 = $base12 + (Get-Args $v2 $three) + $vehicle
    Write-ReadbackOnly (Invoke-Whole $resetPath $all12 (New-Readback $v2 @{ servicePathName = "`"$($mvp.ServerInstallRoot)\ControlServer.Host.exe`"" })) 'TARGET_SERVICE_CONFIG_MISMATCH' '12 -Force, v2 set whose service runs from the MVP directory'
    Write-ReadbackOnly (Invoke-Whole $resetPath $all12 (New-Readback $v2 @{ connectionString = "Data Source=$($mvp.ServerDatabase)" })) 'TARGET_DATABASE_OTHER_INSTANCE' '12 -Force, v2 set whose configuration names the MVP database'
    Write-ReadbackOnly (Invoke-Whole $resetPath ($base12 + (Get-Args $v2 @('ServiceName', 'ServerInstallRoot')) + @('-ServerDatabase', $copyDatabase) + $vehicle) (New-Readback $v2)) 'TARGET_DATABASE_NOT_OWN' '12 -Force, v2 set with a database copy'
    Write-ReadbackOnly (Invoke-Whole $resetPath ($base12 + $vehicle) (New-Readback $mvp @{ connectionString = "Data Source=$($v2.ServerDatabase)" })) 'TARGET_DATABASE_OTHER_INSTANCE' '12 -Force, defaults, but the MVP configuration names another database'

    $res = Invoke-Whole $resetPath ($server + $vehicle + @('-WhatIf')) (New-Readback $mvp)
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Kinds -eq 'readback,mkdir,scp,settle-survey,journal,cleanup' -and ($res.Dbs -join '|') -ceq $mvp.ServerDatabase -and $res.Output -match 'WhatIf: nothing was changed' -and $res.Output -match 'the production MVP service') `
        -Name '12 -WhatIf, no instance parameter: read-back first, then the survey of the MVP database' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    $res = Invoke-Whole $resetPath ($server + $vehicle + @('-WhatIf') + (Get-Args $v2 $three)) (New-Readback $v2)
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Kinds -eq 'readback,mkdir,scp,settle-survey,journal,cleanup' -and ($res.Dbs -join '|') -ceq $v2.ServerDatabase -and $res.Output -match 'not the MVP service') `
        -Name '12 -WhatIf, all three v2: read-back first, then the survey of the v2 database' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    # agv02 with a v2 set gets past every check: the server's mkdir fails on purpose so nothing reaches agv02.
    $res = Invoke-Whole $resetPath ($server + @('-SshAlias', 'agv02', '-WhatIf') + (Get-Args $v2 $three)) (New-Readback $v2) -FailKind 'mkdir'
    Write-Result -Ok ($res.Exit -ne 0 -and $res.Kinds -eq 'readback,mkdir' -and $res.Output -notmatch 'TARGET_' -and $res.Output -match 'fails on purpose') `
        -Name '12, -SshAlias agv02 with all three v2: past the checks (stopped at the server''s mkdir on purpose)' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"

    # Review M1: the survey covers the whole instance, the journal is one vehicle's. Every in-flight journey must be
    # the vehicle's own, by the key in its site file.
    $keyOwn = 'BROKERX-ws38-own'; $keyOther = 'BROKERX-ws38-other'
    $site = Join-Path $work 'site-ws38.json'
    @{ vehicleSafety = @{ expectedVehicleKey = $keyOwn } } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $site
    $journey = {
        param([string] $Id, [string] $Key)
        [ordered]@{ journeyId = $Id; stage = 'Blocked'; agvId = "car-of-$Key"; vehicleKey = $Key; updatedAt = 'x'; revisions = 'r'
            demands = @(); lease = $null; outbox = @(); riotLegs = @(); refusals = @(); cancelDemandIds = @(); suppressDemandIds = @(); settleDemandIds = @(); releaseLease = $false }
    }
    $survey = { param([object[]] $Journeys) @{ status = 'SURVEY'; journeys = @($Journeys); refusals = @(); unattributedOutbox = @() } | ConvertTo-Json -Depth 6 -Compress }
    $m1 = $all12 + @('-SiteConfigPath', $site)
    foreach ($c in @(
            @{ Name = 'one journey of another vehicle'; Survey = (& $survey @((& $journey 'J-OTHER' $keyOther))) }
            @{ Name = 'its own journey and one of another vehicle'; Survey = (& $survey @((& $journey 'J-OWN' $keyOwn), (& $journey 'J-OTHER' $keyOther))) })) {
        $res = Invoke-Whole $resetPath $m1 (New-Readback $v2) -Survey $c.Survey
        Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'J-OTHER belongs to vehicle BROKERX-ws38-other' -and $res.Output -match 'Refused before touching either end' -and $res.Kinds -eq 'readback,mkdir,scp,settle-survey,journal,cleanup') `
            -Name "12 -Force, v2 set, $($c.Name): refused after the survey, nothing settled, onboard stack untouched" -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    }
    $res = Invoke-Whole $resetPath ($all12 + @('-SiteConfigPath', (Join-Path $work 'no-such-site.json'))) (New-Readback $v2) -Survey (& $survey @((& $journey 'J-OWN' $keyOwn)))
    Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match 'no vehicleSafety.expectedVehicleKey' -and $res.Output -match 'Refused before touching either end' -and $res.Kinds -eq 'readback,mkdir,scp,settle-survey,journal,cleanup') `
        -Name '12 -Force, v2 set, a journey in flight and no site file: refused, nothing settled' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    $res = Invoke-Whole $resetPath ($server + $vehicle + @('-WhatIf', '-SiteConfigPath', $site) + (Get-Args $v2 $three)) (New-Readback $v2) -Survey (& $survey @((& $journey 'J-OWN' $keyOwn)))
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Output -match 'Journey J-OWN' -and $res.Output -match 'would write' -and $res.Output -notmatch 'REFUSED' -and $res.Output -notmatch 'a real run would refuse') `
        -Name '12 -WhatIf, v2 set, only its own journey in flight: not refused' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"

    # ------------------------------------------------------------------------------------ Complete-ChargingRun ---
    $baseCharge = $server + @('-Force', '-ChargingRunId', 'run-ws38')
    foreach ($c in @(
            @{ Name = 'v2 -ServerDatabase alone'; Args = (Get-Args $v2 @('ServerDatabase')); Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -ServerDatabase and -ServerInstallRoot'; Args = (Get-Args $v2 @('ServerDatabase', 'ServerInstallRoot')); Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -ServiceName alone'; Args = (Get-Args $v2 @('ServiceName')); Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 service and install root, MVP -ServerDatabase'; Args = (Get-Args $v2 @('ServiceName', 'ServerInstallRoot')) + (Get-Args $mvp @('ServerDatabase')); Code = 'TARGET_MIXED_MVP' })) {
        Write-Refused (Invoke-Whole $chargePath ($baseCharge + $c.Args) (New-Readback $v2)) $c.Code "Complete-ChargingRun -Force, $($c.Name)"
    }
    $allCharge = $baseCharge + (Get-Args $v2 $three)
    Write-ReadbackOnly (Invoke-Whole $chargePath $allCharge (New-Readback $v2 @{ servicePathName = "`"$($mvp.ServerInstallRoot)\ControlServer.Host.exe`"" })) 'TARGET_SERVICE_CONFIG_MISMATCH' 'Complete-ChargingRun -Force, v2 set whose service runs from the MVP directory'
    Write-ReadbackOnly (Invoke-Whole $chargePath $allCharge (New-Readback $v2 @{ connectionString = "Data Source=$($mvp.ServerDatabase)" })) 'TARGET_DATABASE_OTHER_INSTANCE' 'Complete-ChargingRun -Force, v2 set whose configuration names the MVP database'
    Write-ReadbackOnly (Invoke-Whole $chargePath ($baseCharge + (Get-Args $v2 @('ServiceName', 'ServerInstallRoot')) + @('-ServerDatabase', $copyDatabase)) (New-Readback $v2)) 'TARGET_DATABASE_NOT_OWN' 'Complete-ChargingRun -Force, v2 set with a database copy'

    $res = Invoke-Whole $chargePath ($server + @('-ChargingRunId', 'run-ws38', '-WhatIf')) (New-Readback $mvp)
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Kinds -eq 'readback,charging-survey' -and ($res.Dbs -join '|') -ceq $mvp.ServerDatabase -and $res.Output -match 'What if' -and $res.Output -match [regex]::Escape("ws38-server.invalid ($($mvp.ServerDatabase))")) `
        -Name 'Complete-ChargingRun -WhatIf, no instance parameter: read-back, survey and ShouldProcess on the MVP database' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    $res = Invoke-Whole $chargePath ($server + @('-ChargingRunId', 'run-ws38', '-WhatIf') + (Get-Args $v2 $three)) (New-Readback $v2)
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Kinds -eq 'readback,charging-survey' -and ($res.Dbs -join '|') -ceq $v2.ServerDatabase -and $res.Output -match [regex]::Escape("ws38-server.invalid ($($v2.ServerDatabase))")) `
        -Name 'Complete-ChargingRun -WhatIf, all three v2: read-back, survey and ShouldProcess on the v2 database' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"

    # ---------------------------------------------------------------------------------------------------- 11 ---
    foreach ($c in @(
            @{ Name = 'v2 -ServerDatabase alone'; Args = (Get-Args $v2 @('ServerDatabase')) + $vehicle; Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 -ServerInstallRoot alone'; Args = (Get-Args $v2 @('ServerInstallRoot')) + $vehicle; Code = 'TARGET_PARTIAL' }
            @{ Name = 'v2 database, MVP install root'; Args = (Get-Args $v2 @('ServerDatabase')) + (Get-Args $mvp @('ServerInstallRoot')) + $vehicle; Code = 'TARGET_MIXED_MVP' }
            @{ Name = '-SshAlias agv02 with the defaults (the MVP)'; Args = @('-SshAlias', 'agv02'); Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
            @{ Name = '-SshAlias agv03 with both MVP paths given'; Args = @('-SshAlias', 'agv03') + (Get-Args $mvp $two); Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
            @{ Name = 'both v2 paths, -SshAlias defaulted to agv01'; Args = (Get-Args $v2 $two); Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' })) {
        Write-Refused (Invoke-Whole $drivePath ($server + $c.Args) $null) $c.Code "11, $($c.Name)"
    }
    $res = Invoke-Whole $drivePath ($server + $vehicle + @('-WhatIf')) $null
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Kinds -eq 'sublot-query' -and ($res.Dbs -join '|') -ceq $mvp.ServerDatabase -and $res.Output -match 'S-WS38' -and $res.Output -match 'What if') `
        -Name '11 -WhatIf, no server path: reads the MVP database, as before' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    # Under -WhatIf nothing reaches the vehicle before ShouldProcess, so agv02 itself can be named.
    $res = Invoke-Whole $drivePath ($server + @('-SshAlias', 'agv02', '-WhatIf') + (Get-Args $v2 $two)) $null
    Write-Result -Ok ($res.Exit -eq 0 -and $res.Kinds -eq 'sublot-query' -and ($res.Dbs -join '|') -ceq $v2.ServerDatabase -and ($res.Aliases -join '|') -ceq 'ws38-server.invalid' -and $res.Output -match 'What if.*agv02') `
        -Name '11 -WhatIf, -SshAlias agv02 with both v2 paths: reads the v2 database, nothing reaches agv02' -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"

    # ---------------------------------------------------------------------------------------------------- 14 ---
    # Review S1: the MVP's recovery window only; the v2 cars have 18-set-v2-recovery-window.ps1.
    $base14 = @('-ServerSshAlias', 'ws38-server.invalid', '-SecretPath', (Join-Path $work 'recovery-window.xml'))
    foreach ($c in @(
            @{ Name = '-SshAlias agv02'; Args = @('-SshAlias', 'agv02'); Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
            @{ Name = '-SshAlias agv03 -Revert'; Args = @('-SshAlias', 'agv03', '-Revert'); Code = 'TARGET_VEHICLE_INSTANCE_MISMATCH' }
            @{ Name = 'the V2 -ServiceName'; Args = @('-SshAlias', 'ws38-vehicle.invalid', '-ServiceName', $v2.ServiceName); Code = 'TARGET_NOT_MVP' })) {
        $res = Invoke-Whole $windowPath ($base14 + $c.Args) $null
        Write-Result -Ok ($res.Exit -ne 0 -and $res.Output -match $c.Code -and $res.Output -match '18-set-v2-recovery-window' -and $res.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $work 'recovery-window.xml'))) `
            -Name "14, $($c.Name): $($c.Code), points at 18, no ssh or scp, no proof generated" -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    }
    foreach ($alias in @('agv01', 'ws38-vehicle.invalid')) {
        $res = Invoke-Whole $windowPath ($base14 + @('-SshAlias', $alias, '-WhatIf')) $null
        Write-Result -Ok ($res.Exit -eq 0 -and $res.Output -match 'WhatIf: stopping before either machine is touched' -and $res.Output -notmatch 'TARGET_' -and $res.Calls.Count -eq 0) `
            -Name "14 -WhatIf, -SshAlias $alias with the MVP service: past the check, stops at ShouldProcess" -Detail "exit $($res.Exit), calls [$($res.Calls -join '; ')], $($res.Output.Trim())"
    }
}
finally {
    $env:PATH = $savedPath
    Remove-Item Env:WS38_LOG, Env:WS38_READBACK, Env:WS38_FAIL_KIND, Env:WS38_SURVEY -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$colour = $script:Failed ? 'Red' : 'Green'
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $colour
exit ($script:Failed ? 1 : 0)
