#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for 18-set-v2-recovery-window.ps1 and its two remote halves (8005-workspace#25).

.DESCRIPTION
    Nothing here reaches a vehicle or a server. The real secret store, the machine environment and the
    service registry are never read or written.

    Part 1 runs 18-set-v2-recovery-window.ps1 as an operator does (pwsh -File), with ssh and scp
    replaced by ssh.ps1 / scp.ps1 at the front of PATH, a throwaway store, and a throwaway git
    repository holding copies of control-server's scripts/parallel files. It pins which machines are
    reached, in which order, what the store records after every success and every refusal (the
    residues included), that the proof travels only on standard input, and that agv01, the MVP and
    the removed parameters are refused before any call.

    Part 2 runs the two remote halves' logic for real (V2RecoveryWindow.psm1): the vehicle half
    against a temporary install root with an in-memory machine environment, the server half against
    a temporary registry key under HKCU with control-server's own Get-ParallelPreInstallRefusal and
    Set-ParallelServiceEnvironmentEntry (imported from -ControlServerRepository). It pins the write
    order on the vehicle, that every refusal leaves the registry as it was and restarts nothing, that
    the restart comes after the write, that every other Environment entry survives in its order, and
    that no output carries the proof or any other entry's value.

    Part 3: neither deployment script names the recovery variables, so neither opens the window.

.PARAMETER ControlServerRepository
    An 8005-agv-control-server checkout. Read only: its scripts/parallel files are imported (Part 2)
    and copied into a throwaway repository (Part 1).

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/Test-SetV2RecoveryWindow.ps1 -ControlServerRepository <checkout>
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string] $ControlServerRepository)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$target = Join-Path $PSScriptRoot '18-set-v2-recovery-window.ps1'
$csParallel = Join-Path (Resolve-Path -LiteralPath $ControlServerRepository).Path 'scripts\parallel'
$work = Join-Path ([IO.Path]::GetTempPath()) "test-v2-recovery-window-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$fakeBin = Join-Path $work 'bin'
$staged = Join-Path $work 'staged'
$secret = Join-Path $work 'store\w2g-v2-recovery-window.xml'
$log = Join-Path $work 'ssh-log.jsonl'
$fakeRepo = Join-Path $work 'control-server'
$testKeyPath = "Software\8005-test-v2-recovery-window-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $fakeBin, $staged, (Join-Path $fakeRepo 'scripts\parallel') | Out-Null

try {
    foreach ($name in 'ParallelInstance.psm1', 'ParallelHost.psm1', 'instance-factory01-v2.json') {
        Copy-Item -LiteralPath (Join-Path $csParallel $name) -Destination (Join-Path $fakeRepo 'scripts\parallel')
    }
    & git -C $fakeRepo init -q 2>&1 | Out-Null
    & git -C $fakeRepo -c core.autocrlf=false add -A 2>&1 | Out-Null
    & git -C $fakeRepo -c user.name=test -c user.email=test@invalid commit -q -m fixture 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the throwaway control-server repository.' }

    # ================================================================ Part 1 ===

    # ssh.ps1 / scp.ps1 at the front of PATH: the script's `& ssh` finds them before ssh.exe. ssh logs
    # alias, command and what was piped in, and answers a remote run with the lines a passing run prints.
    # FAKE_SSH_FAIL_MATCH (regex) against "<alias>:<script>:<mode or state>" makes that run exit 1.
    Set-Content -LiteralPath (Join-Path $fakeBin 'ssh.ps1') -Encoding utf8NoBOM -Value @'
$stdin = @($input) -join "`n"
$command = $args[1..($args.Count - 1)] -join ' '
$key = ''
if ($command -match "-File '[^']*\\([\w-]+)\.ps1'") {
    $request = $stdin ? ($stdin | ConvertFrom-Json -AsHashtable) : @{}
    $key = "$($args[0]):$($Matches[1]):$($request['mode'] ?? $request['state'])"
}
[ordered]@{ alias = $args[0]; command = $command; stdin = $stdin; key = $key } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FAKE_SSH_LOG -Encoding utf8NoBOM
if ($key -and $env:FAKE_SSH_FAIL_MATCH -and $key -match $env:FAKE_SSH_FAIL_MATCH) { "REFUSED (fake): $key"; exit 1 }
if ($key -match ':check$') { 'ENTRY=absent'; 'CONNECTED_VEHICLES=0'; 'CHECK_PASSED' }
exit 0
'@
    Set-Content -LiteralPath (Join-Path $fakeBin 'scp.ps1') -Encoding utf8NoBOM -Value @'
$source = $args[-2]
Copy-Item -LiteralPath $source -Destination (Join-Path $env:FAKE_SCP_DIR ("{0:D3}-{1}" -f @(Get-ChildItem $env:FAKE_SCP_DIR).Count, (Split-Path -Leaf $source)))
[ordered]@{ alias = ($args[-1] -split ':')[0]; command = "scp $(Split-Path -Leaf $source)"; stdin = ''; key = '' } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FAKE_SSH_LOG -Encoding utf8NoBOM
exit 0
'@

    function Invoke-Target {
        param([string[]] $Arguments, [string] $FailMatch, [switch] $NoRepository)
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $staged | Remove-Item -Force
        $saved = @{ PATH = $env:PATH; FAKE_SSH_LOG = $env:FAKE_SSH_LOG; FAKE_SCP_DIR = $env:FAKE_SCP_DIR; FAKE_SSH_FAIL_MATCH = $env:FAKE_SSH_FAIL_MATCH }
        try {
            $env:PATH = "$fakeBin;$env:PATH"
            $env:FAKE_SSH_LOG = $log
            $env:FAKE_SCP_DIR = $staged
            $env:FAKE_SSH_FAIL_MATCH = $FailMatch
            $all = @($Arguments) + @('-SecretPath', $secret) + ($NoRepository ? @() : @('-ControlServerRepository', $fakeRepo))
            $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $target @all 2>&1 | ForEach-Object { "$_" }
            $exit = $LASTEXITCODE
        } finally {
            foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
        }
        $calls = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json } })
        $bodies = @(Get-ChildItem -LiteralPath $staged | Sort-Object Name | ForEach-Object { @{ Name = $_.Name; Text = [IO.File]::ReadAllText($_.FullName) } })
        return @{ Exit = $exit; Output = ($output -join "`n"); Calls = $calls; Bodies = $bodies; Runs = @($calls | Where-Object { $_.key } | ForEach-Object { $_.key }) }
    }

    function Get-Store {
        # A missing store reads as a value no assertion expects, so a check fails instead of the run crashing.
        if (-not (Test-Path -LiteralPath $secret)) { return @{ Proof = $null; Open = '(no store)' } }
        $s = Import-Clixml -LiteralPath $secret
        return @{ Proof = [Net.NetworkCredential]::new('', $s['RecoveryProof']).Password; Open = (@($s['OpenVehicles']) -join ',') }
    }

    function Assert-Runs($run, [string] $expected, [string] $label) {
        Write-Result -Ok (($run.Runs -join ' > ') -ceq $expected) -Name $label -Detail "runs: $($run.Runs -join ' > ')  (exit $($run.Exit))`n$($run.Output)"
    }

    function Assert-NoLeak($run, [string] $proof, [string] $label) {
        $leak = @()
        if ($run.Output.Contains($proof)) { $leak += 'script output' }
        if (@($run.Calls | Where-Object { $_.command.Contains($proof) }).Count) { $leak += 'a command line' }
        if (@($run.Bodies | Where-Object { $_.Text.Contains($proof) }).Count) { $leak += 'a staged file' }
        Write-Result -Ok ($leak.Count -eq 0) -Name "$label`: the proof is in no output, command line or staged file" -Detail ($leak -join ', ')
    }

    Write-Host 'Part 1: 18-set-v2-recovery-window.ps1 with fake ssh and scp'

    $errors = $null
    foreach ($file in '18-set-v2-recovery-window.ps1', 'V2RecoveryWindow.psm1', 'agv-v2-recovery-window.ps1', 'server-v2-recovery-window.ps1') {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$null, [ref]$errors)
        Write-Result -Ok (@($errors).Count -eq 0) -Name "$file parses" -Detail (@($errors) -join ' | ')
        if ($file -like '*-v2-recovery-window.ps1' -and $file -notlike '18-*') {
            # L1: the remote halves take nothing from a command line.
            Write-Result -Ok ($null -eq $ast.ParamBlock) -Name "$file has no parameters (its request comes on standard input)" -Detail 'has a param block'
        }
    }

    # ---- refused before any call ----
    $refusals = [ordered]@{
        'no -SshAlias'                     = @{ Arguments = @() }
        '-SshAlias agv01'                  = @{ Arguments = @('-SshAlias', 'agv01') }
        '-SshAlias agv01 -Revert'          = @{ Arguments = @('-SshAlias', 'agv01', '-Revert') }
        '-SshAlias agv01 -Status'          = @{ Arguments = @('-SshAlias', 'agv01', '-Status') }
        'no -ControlServerRepository'      = @{ Arguments = @('-SshAlias', 'agv03'); NoRepository = $true }
        '-ServerSshAlias (removed, S2)'    = @{ Arguments = @('-SshAlias', 'agv03', '-ServerSshAlias', 'agv01') }
        '-ServiceName (removed, S6)'       = @{ Arguments = @('-SshAlias', 'agv03', '-ServiceName', '8005 AGV ControlServer') }
        '-ServerInstallRoot (removed, S6)' = @{ Arguments = @('-SshAlias', 'agv03', '-ServerInstallRoot', 'C:\PROGRA~1\8005 AGV\ControlServer') }
        '-OnboardPort (removed, S6)'       = @{ Arguments = @('-SshAlias', 'agv03', '-OnboardPort', '1') }
        '-SitePath (removed)'              = @{ Arguments = @('-SshAlias', 'agv03', '-SitePath', 'x.json') }
        '-Status with -Revert'             = @{ Arguments = @('-SshAlias', 'agv03', '-Status', '-Revert') }
    }
    foreach ($case in $refusals.GetEnumerator()) {
        $run = Invoke-Target @($case.Value)
        Write-Result -Ok ($run.Exit -ne 0 -and $run.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $secret)) `
            -Name "$($case.Key) is refused before ssh or scp is called" -Detail "exit $($run.Exit), $($run.Calls.Count) call(s)"
    }
    Set-Content -LiteralPath (Join-Path $fakeRepo 'untracked.txt') -Value 'x'
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03')
    Write-Result -Ok ($run.Exit -ne 0 -and $run.Calls.Count -eq 0 -and $run.Output -match 'uncommitted') -Name 'a dirty -ControlServerRepository is refused before any call' -Detail $run.Output
    Remove-Item -LiteralPath (Join-Path $fakeRepo 'untracked.txt')

    # ---- WhatIf ----
    foreach ($arguments in @(@('-SshAlias', 'agv03', '-WhatIf'), @('-SshAlias', 'AGV02', '-Revert', '-WhatIf'), @('-SshAlias', 'agv02', '-Status', '-WhatIf'))) {
        $run = Invoke-Target -Arguments $arguments
        Write-Result -Ok ($run.Exit -eq 0 -and $run.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $secret) -and $run.Output -match 'WhatIf: stopping') `
            -Name "$($arguments -join ' '): no ssh, no scp, no store" -Detail "exit $($run.Exit), $($run.Calls.Count) call(s)`n$($run.Output)"
    }

    # ---- open, refused by the server check: the vehicle is not reached ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03') -FailMatch 'server-v2-recovery-window:check'
    Assert-Runs $run 'factory01:server-v2-recovery-window:check' 'open, server check refused: only the check ran'
    Write-Result -Ok ($run.Exit -ne 0 -and @($run.Calls | Where-Object { $_.alias -eq 'agv03' }).Count -eq 0) -Name '... and nothing reached agv03, not even staging' -Detail ''
    Write-Result -Ok ((Get-Store).Open -eq '') -Name '... and the store records no vehicle open' -Detail "open: $((Get-Store).Open)"
    Remove-Item -LiteralPath $secret -Force

    # ---- open agv03 ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03')
    $store = Get-Store
    $proof = $store.Proof
    Write-Result -Ok ($run.Exit -eq 0) -Name 'open agv03 succeeds against the fakes' -Detail $run.Output
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Open > factory01:server-v2-recovery-window:set' 'open agv03: server check, vehicle, server entry'
    Write-Result -Ok (@($run.Calls | Where-Object { $_.alias -notin @('agv03', 'factory01') }).Count -eq 0) -Name 'open agv03 reaches only agv03 and factory01' -Detail (@($run.Calls | ForEach-Object { $_.alias } | Sort-Object -Unique) -join ', ')
    Write-Result -Ok ($proof -cmatch '^[0-9a-f]{64}$' -and $store.Open -eq 'agv03') -Name 'open agv03: a 64-hex proof stored, agv03 recorded open' -Detail "open: $($store.Open)"
    $requests = @($run.Calls | Where-Object { $_.key } | ForEach-Object { $_.stdin | ConvertFrom-Json -AsHashtable })
    Write-Result -Ok (@($requests | Where-Object { $_['proof'] -ceq $proof }).Count -eq 3) -Name 'open agv03: each remote run gets the stored proof in its request on standard input' -Detail ''
    $vehicleRequest = $requests[1]
    $site = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\site-agv03.json') | ConvertFrom-Json
    Write-Result -Ok ($vehicleRequest['onboardInstanceId'] -ceq $site.wireToGate.onboardInstanceId -and $vehicleRequest['installRoot'] -ceq $site.install.root) `
        -Name "the vehicle request carries site-agv03.json's onboardInstanceId and install root" -Detail ($vehicleRequest | ConvertTo-Json -Compress).Replace($proof, '<proof>')
    Write-Result -Ok (@($run.Calls | Where-Object { -not $_.key -and $_.stdin }).Count -eq 0) -Name 'nothing but the remote runs is sent anything on standard input' -Detail ''
    Assert-NoLeak $run $proof 'open agv03'
    $stagedNames = @($run.Bodies | ForEach-Object { $_.Name -replace '^\d{3}-', '' }) -join ','
    Write-Result -Ok ($stagedNames -ceq 'ParallelInstance.psm1,ParallelHost.psm1,V2RecoveryWindow.psm1,server-v2-recovery-window.ps1,V2RecoveryWindow.psm1,agv-v2-recovery-window.ps1') `
        -Name 'open agv03 stages the server half with the control-server modules, then the vehicle half' -Detail $stagedNames
    $serverDir = @($run.Calls | Where-Object { $_.alias -eq 'factory01' -and $_.command -match 'New-Item' })[0].command
    $commit = (& git -C $fakeRepo rev-parse HEAD).Trim()
    Write-Result -Ok ($serverDir.Contains("D:\zhengyushao\control-server-v2-ops\recovery-window\$commit")) -Name 'the server half is staged in <opsRoot>\recovery-window\<commit>' -Detail $serverDir

    # ---- open agv02: the same proof ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv02')
    Write-Result -Ok ($run.Exit -eq 0 -and (Get-Store).Proof -ceq $proof -and (Get-Store).Open -eq 'agv02,agv03') -Name 'open agv02 reuses the proof; both recorded open' -Detail "open: $((Get-Store).Open)"
    Assert-NoLeak $run $proof 'open agv02'

    # ---- close agv03 while agv02 is open: the vehicle only ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Assert-Runs $run 'agv03:agv-v2-recovery-window:Close' 'close agv03 while agv02 is open: the vehicle only'
    Write-Result -Ok (@($run.Calls | Where-Object { $_.alias -eq 'factory01' }).Count -eq 0) -Name '... factory01 is not reached at all' -Detail ''
    Write-Result -Ok ((Get-Store).Proof -ceq $proof -and (Get-Store).Open -eq 'agv02') -Name '... the store keeps the proof with agv02 open' -Detail "open: $((Get-Store).Open)"
    Write-Result -Ok (@($run.Calls | Where-Object { $_.stdin -and $_.stdin.Contains($proof) }).Count -eq 0) -Name 'a close sends no proof anywhere' -Detail ''

    # ---- close the last vehicle, refused by the server check: the vehicle is not reached ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv02', '-Revert') -FailMatch 'server-v2-recovery-window:check'
    Assert-Runs $run 'factory01:server-v2-recovery-window:check' 'close the last vehicle, server check refused: only the check ran'
    Write-Result -Ok ($run.Exit -ne 0 -and @($run.Calls | Where-Object { $_.alias -eq 'agv02' }).Count -eq 0 -and (Get-Store).Open -eq 'agv02') `
        -Name '... agv02 untouched, still recorded open' -Detail "open: $((Get-Store).Open)"

    # ---- close the last vehicle, the server write refused after the vehicle (the residue) ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv02', '-Revert') -FailMatch 'server-v2-recovery-window:remove'
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv02:agv-v2-recovery-window:Close > factory01:server-v2-recovery-window:remove' 'close the last vehicle, server write refused: check, vehicle, write'
    Write-Result -Ok ($run.Exit -ne 0 -and (Get-Store).Proof -ceq $proof -and (Get-Store).Open -eq '') -Name '... residue recorded: no vehicle open, proof kept for the server entry' -Detail "open: $((Get-Store).Open)"
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv02', '-Status')
    Assert-Runs $run 'agv02:agv-v2-recovery-window:Status > factory01:server-v2-recovery-window:status' '-Status reads the vehicle, then the server'
    Write-Result -Ok ($run.Exit -eq 0 -and (Get-Store).Open -eq '' -and @($run.Calls | Where-Object { $_.key } | Where-Object { ($_.stdin | ConvertFrom-Json -AsHashtable)['proof'] -ceq $proof }).Count -eq 2) `
        -Name '-Status changes no store and compares both ends with the stored proof' -Detail ''
    Assert-NoLeak $run $proof '-Status'
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Close > factory01:server-v2-recovery-window:remove' 'the residue is finished by -Revert on either vehicle'
    Write-Result -Ok ($run.Exit -eq 0 -and -not (Test-Path -LiteralPath $secret)) -Name '... and the store is deleted' -Detail ''

    # ---- open, the server write refused after the vehicle (the residue) ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03') -FailMatch 'server-v2-recovery-window:set'
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Open > factory01:server-v2-recovery-window:set' 'open, server write refused: check, vehicle, write'
    Write-Result -Ok ($run.Exit -ne 0 -and (Get-Store).Open -eq 'agv03') -Name '... residue recorded: agv03 open, so -Revert will close it' -Detail "open: $((Get-Store).Open)"
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Close > factory01:server-v2-recovery-window:remove' '... and -Revert closes both ends'
    Write-Result -Ok (-not (Test-Path -LiteralPath $secret)) -Name '... and deletes the store' -Detail ''

    # ---- no store at all, -Revert: both ends closed ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Close > factory01:server-v2-recovery-window:remove' 'close with no store closes both ends'

    # ---- an unreadable store ----
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $secret) | Out-Null
    Set-Content -LiteralPath $secret -Value 'not a clixml file'
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Write-Result -Ok ($run.Exit -ne 0 -and $run.Calls.Count -eq 0 -and $run.Output -match 'STORE_UNREADABLE') -Name 'an unreadable store is refused before any call' -Detail $run.Output
    Remove-Item -LiteralPath $secret -Force

    # ================================================================ Part 2 ===

    Write-Host ''
    Write-Host 'Part 2: the remote halves, run for real against a temporary install root and registry key'

    Import-Module (Join-Path $csParallel 'ParallelInstance.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'V2RecoveryWindow.psm1') -Force
    $testProof = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $otherProof = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()

    function Invoke-Captured([scriptblock] $Block) {
        # Every stream, Write-Host included, as text; the error too.
        $text = ''; $failure = $null
        try { $text = (& $Block *>&1 | ForEach-Object { "$_" }) -join "`n" } catch { $failure = $_.Exception.Message }
        return @{ Text = $text; Error = $failure; All = "$text`n$failure" }
    }

    # ---------------------------------------------------------------- vehicle ---
    $installRoot = Join-Path $work 'OnboardHmi'
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    $settingsPath = Join-Path $installRoot 'appsettings.json'
    $instanceId = 'dce47db2-b531-4f27-9737-af60bec96beb'
    $pristine = [ordered]@{ agvId = 'test-car'; wireToGate = [ordered]@{ onboardInstanceId = $instanceId; recoveryResumeEnabled = $false; unableToChargeEntryEnabled = $true; port = 58105 } } | ConvertTo-Json -Depth 5
    $readSwitch = { (Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).wireToGate.recoveryResumeEnabled }

    function New-VehicleRig {
        param([bool] $Running = $false, [scriptblock] $SetHook, [scriptblock] $GetOverride)
        $rig = @{ Variables = @{}; Events = [System.Collections.Generic.List[string]]::new() }
        $rig.Actions = @{
            ClientRunning = { $Running }.GetNewClosure()
            GetMachineVariable = $GetOverride ?? { param($n) $rig.Variables[$n] }.GetNewClosure()
            SetMachineVariable = {
                param($n, $v)
                $rig.Events.Add("set $n $([string]::IsNullOrEmpty($v) ? 'delete' : 'value') with switch $(& $readSwitch)")
                if ($SetHook) { & $SetHook }
                if ([string]::IsNullOrEmpty($v)) { $rig.Variables.Remove($n) } else { $rig.Variables[$n] = $v }
            }.GetNewClosure()
        }
        return $rig
    }
    $request = { param($state, $proofValue, $instance = $instanceId)
        $r = @{ state = $state; installRoot = $installRoot; onboardInstanceId = $instance }
        if ($proofValue) { $r['proof'] = $proofValue }
        $r
    }

    Set-Content -LiteralPath $settingsPath -Value $pristine -Encoding utf8NoBOM
    $rig = New-VehicleRig
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($null -eq $r.Error -and (& $readSwitch) -eq $true -and $rig.Variables['CONTROL_SERVER_RECOVERY_PROOF'] -ceq $testProof) `
        -Name 'vehicle open: switch true and the variable holds the proof' -Detail $r.All
    Write-Result -Ok (($rig.Events -join ';') -ceq 'set CONTROL_SERVER_RECOVERY_PROOF value with switch False') -Name 'vehicle open (S1): the variable is written while the switch is still false' -Detail ($rig.Events -join ';')
    Write-Result -Ok (-not $r.All.Contains($testProof)) -Name 'vehicle open prints no proof' -Detail ''
    $after = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
    Write-Result -Ok ($after.agvId -ceq 'test-car' -and $after.wireToGate.unableToChargeEntryEnabled -eq $true -and $after.wireToGate.port -eq 58105 -and $after.wireToGate.onboardInstanceId -ceq $instanceId) `
        -Name 'vehicle open keeps every other setting' -Detail ($after | ConvertTo-Json -Compress)

    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Status' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($r.Text -match 'recoveryResumeEnabled=True' -and $r.Text -match 'CONTROL_SERVER_RECOVERY_PROOF=same' -and -not $r.All.Contains($testProof)) -Name 'vehicle status: True, same, no value printed' -Detail $r.All
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Status' $otherProof) -Actions $rig.Actions }
    Write-Result -Ok ($r.Text -match 'CONTROL_SERVER_RECOVERY_PROOF=different') -Name 'vehicle status against another proof: different' -Detail $r.All

    $rig.Events.Clear()
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Close' $null) -Actions $rig.Actions }
    Write-Result -Ok ($null -eq $r.Error -and (& $readSwitch) -eq $false -and -not $rig.Variables.ContainsKey('CONTROL_SERVER_RECOVERY_PROOF')) -Name 'vehicle close: switch false, variable gone' -Detail $r.All
    Write-Result -Ok (($rig.Events -join ';') -ceq 'set CONTROL_SERVER_RECOVERY_PROOF delete with switch False') -Name 'vehicle close (S1): the variable is deleted only after the switch is off' -Detail ($rig.Events -join ';')

    Set-Content -LiteralPath $settingsPath -Value $pristine -Encoding utf8NoBOM
    $rig = New-VehicleRig -SetHook { throw 'registry write failed (injected)' }
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($null -ne $r.Error -and (& $readSwitch) -eq $false) -Name 'vehicle open, variable write fails: refused, switch still false' -Detail $r.All

    $rig = New-VehicleRig -GetOverride { param($n) $otherProof }.GetNewClosure()
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($r.Error -match 'VARIABLE_READBACK_FAILED' -and (& $readSwitch) -eq $false) -Name 'vehicle open, variable reads back different: refused, switch still false' -Detail $r.All

    $rig = New-VehicleRig -GetOverride { param($n) $null }
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($r.Error -match 'VARIABLE_READBACK_FAILED' -and (& $readSwitch) -eq $false) -Name 'vehicle open, variable reads back absent: refused, switch still false' -Detail $r.All

    foreach ($case in @(
            @{ Name = 'a running client'; Rig = (New-VehicleRig -Running $true); Request = (& $request 'Open' $testProof); Expect = 'CLIENT_RUNNING' },
            @{ Name = 'a running client, closing'; Rig = (New-VehicleRig -Running $true); Request = (& $request 'Close' $null); Expect = 'CLIENT_RUNNING' },
            @{ Name = "another vehicle's configuration"; Rig = (New-VehicleRig); Request = (& $request 'Open' $testProof 'fb7244d8-e78f-4153-ab33-7fcb23fc67fe'); Expect = 'VEHICLE_IDENTITY_MISMATCH' },
            @{ Name = 'no proof'; Rig = (New-VehicleRig); Request = (& $request 'Open' $null); Expect = 'PROOF_NOT_RECEIVED' })) {
        Set-Content -LiteralPath $settingsPath -Value $pristine -Encoding utf8NoBOM
        $before = [IO.File]::ReadAllBytes($settingsPath)
        $rig = $case.Rig
        $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request $case.Request -Actions $rig.Actions }
        $same = [Linq.Enumerable]::SequenceEqual([byte[]] $before, [byte[]] [IO.File]::ReadAllBytes($settingsPath))
        Write-Result -Ok ($r.Error -match $case.Expect -and $same -and $rig.Events.Count -eq 0) -Name "vehicle: $($case.Name) is refused with nothing changed" -Detail $r.All
    }
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request @{ state = 'Open'; installRoot = (Join-Path $work 'nowhere'); onboardInstanceId = $instanceId; proof = $testProof } -Actions (New-VehicleRig).Actions }
    Write-Result -Ok ($r.Error -match 'NO_INSTALLATION') -Name 'vehicle: no installation is refused' -Detail $r.All

    foreach ($case in @(@{ Line = ''; Expect = 'REQUEST_NOT_RECEIVED' }, @{ Line = 'not json'; Expect = 'REQUEST_NOT_RECEIVED' }, @{ Line = '{"state":"Open","proof":"ABC"}'; Expect = 'PROOF_MALFORMED' })) {
        $r = Invoke-Captured { Read-V2RecoveryWindowRequest -Line $case.Line }
        Write-Result -Ok ($r.Error -match $case.Expect) -Name "request '$($case.Line)' is refused ($($case.Expect))" -Detail $r.All
    }

    # ----------------------------------------------------------------- server ---
    $sentinels = @{
        DOTNET_ENVIRONMENT = 'Production'
        CONTROL_SERVER_ONBOARD_CREDENTIAL = "sentinel-onboard-$([guid]::NewGuid().ToString('N'))"
        CONTROL_SERVER_MES_INGEST_SHARED_SECRET = "sentinel-mes-$([guid]::NewGuid().ToString('N'))"
        CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL = "sentinel-fault-$([guid]::NewGuid().ToString('N'))"
    }
    $baseEnvironment = [string[]] @('DOTNET_ENVIRONMENT', 'CONTROL_SERVER_ONBOARD_CREDENTIAL', 'CONTROL_SERVER_MES_INGEST_SHARED_SECRET', 'CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL' |
            ForEach-Object { "$_=$($sentinels[$_])" })
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    $hkcu.CreateSubKey($testKeyPath).Close()
    $configPath = Join-Path $work 'appsettings.Production.json'
    $readRegistry = { [string[]] @(Read-V2RegistryMultiString -Root $hkcu -Path $testKeyPath) }

    function New-ServerRig {
        param([string[]] $Environment, [string] $Status = 'Running', [AllowNull()] $Config = '{"RiotCreateDispatch":{"enabled":false}}',
            [datetime] $ConfigWrittenUtc = [datetime]::new(2000, 1, 1, 0, 0, 0, [DateTimeKind]::Utc), $ProcessStartedUtc = [datetime]::new(2001, 1, 1, 0, 0, 0, [DateTimeKind]::Utc),
            $Journeys = @{ Journeys = @() }, [scriptblock] $Connections = { @() }, [scriptblock] $WriteOverride)
        Write-V2RegistryMultiString -Root $hkcu -Path $testKeyPath -Value $Environment
        $rig = @{ Events = [System.Collections.Generic.List[string]]::new(); Status = $Status }
        $rig.Actions = @{
            ReadEnvironment = { & $readRegistry }
            WriteEnvironment = $WriteOverride ?? { param([string[]] $v) $rig.Events.Add('write'); Write-V2RegistryMultiString -Root $hkcu -Path $testKeyPath -Value $v }.GetNewClosure()
            MergeEntry = { param($e, $n, $v) Set-ParallelServiceEnvironmentEntry -Environment $e -Name $n -Value $v }
            ServiceStatus = { $rig.Status }.GetNewClosure()
            PreInstallRefusal = {
                Get-ParallelPreInstallRefusal -ServiceExists $true -ServiceStatus $Status -ServiceName '8005 AGV ControlServer V2' -ConfigurationPath $configPath `
                    -ConfigurationText $Config -ConfigurationWriteTimeUtc $ConfigWrittenUtc -ProcessStartTimeUtc $ProcessStartedUtc
            }.GetNewClosure()
            JourneyState = { $Journeys }.GetNewClosure()
            Connections = $Connections
            RestartService = {
                $entry = @(& $readRegistry | Where-Object { $_ -like 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=*' }).Count
                $rig.Events.Add("restart with entry $entry")
            }.GetNewClosure()
        }
        return $rig
    }
    function Invoke-Server($rig, [hashtable] $req, [string] $Service = '8005 AGV ControlServer V2') {
        return Invoke-Captured { Invoke-V2RecoveryWindowServer -Request $req -ServiceName $Service -OnboardPort 58105 -Actions $rig.Actions }
    }
    function Test-ServerLeak($r) {
        foreach ($v in @($testProof, $otherProof) + @($sentinels.Values | Where-Object { $_ -ne 'Production' })) { if ($r.All.Contains($v)) { return $true } }
        return $false
    }
    $withEntry = [string[]] @($baseEnvironment[0..1] + "CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=$testProof" + $baseEnvironment[2..3])

    $rig = New-ServerRig -Environment $baseEnvironment
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
    $now = & $readRegistry
    Write-Result -Ok ($null -eq $r.Error -and ($now -join "`n") -ceq (($baseEnvironment + "CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=$testProof") -join "`n")) `
        -Name 'server set: every other entry kept in order, the entry appended' -Detail ($r.All + "`n" + (($now | ForEach-Object { ($_ -split '=', 2)[0] }) -join ', '))
    Write-Result -Ok (($rig.Events -join ';') -ceq 'write;restart with entry 1') -Name 'server set: the restart comes after the write, with the entry in place' -Detail ($rig.Events -join ';')
    Write-Result -Ok (-not (Test-ServerLeak $r)) -Name 'server set prints no proof and no other entry value' -Detail ''

    $rig = New-ServerRig -Environment $withEntry
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
    Write-Result -Ok ($null -eq $r.Error -and $r.Text -match 'NO_CHANGE' -and $rig.Events.Count -eq 0) -Name 'server set when the entry already holds the proof: no write, no restart' -Detail ($r.All + ' ' + ($rig.Events -join ';'))

    $rig = New-ServerRig -Environment $withEntry
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $otherProof }
    Write-Result -Ok ($null -eq $r.Error -and ((& $readRegistry) -join "`n") -ceq (($baseEnvironment + "CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=$otherProof") -join "`n") -and ($rig.Events -join ';') -ceq 'write;restart with entry 1') `
        -Name 'server set over a different value: replaced, others kept, restarted' -Detail ($r.All + ' ' + ($rig.Events -join ';'))
    Write-Result -Ok (-not (Test-ServerLeak $r)) -Name '... and prints neither value' -Detail ''

    $rig = New-ServerRig -Environment $withEntry
    $r = Invoke-Server $rig @{ mode = 'remove' }
    Write-Result -Ok ($null -eq $r.Error -and ((& $readRegistry) -join "`n") -ceq ($baseEnvironment -join "`n") -and ($rig.Events -join ';') -ceq 'write;restart with entry 0') `
        -Name 'server remove: only the entry goes, others kept in order, restart after' -Detail ($r.All + ' ' + ($rig.Events -join ';'))
    $rig = New-ServerRig -Environment $baseEnvironment
    $r = Invoke-Server $rig @{ mode = 'remove' }
    Write-Result -Ok ($r.Text -match 'NO_CHANGE' -and $rig.Events.Count -eq 0) -Name 'server remove when absent: no write, no restart' -Detail $r.All

    $rig = New-ServerRig -Environment $baseEnvironment -Status 'Stopped' -ProcessStartedUtc $null
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
    Write-Result -Ok ($null -eq $r.Error -and ($rig.Events -join ';') -ceq 'write') -Name 'server set on a stopped service: written, not restarted' -Detail ($r.All + ' ' + ($rig.Events -join ';'))

    foreach ($mode in @(@{ mode = 'check'; target = 'set'; proof = $testProof }, @{ mode = 'check'; target = 'remove' })) {
        $rig = New-ServerRig -Environment ($mode.target -eq 'set' ? $baseEnvironment : $withEntry)
        $before = (& $readRegistry) -join "`n"
        $r = Invoke-Server $rig $mode
        Write-Result -Ok ($r.Text -match 'CHECK_PASSED' -and $rig.Events.Count -eq 0 -and ((& $readRegistry) -join "`n") -ceq $before) -Name "server check ($($mode.target)): passes, writes nothing, restarts nothing" -Detail $r.All
    }
    $rig = New-ServerRig -Environment $withEntry
    $r = Invoke-Server $rig @{ mode = 'status'; proof = $testProof }
    Write-Result -Ok ($r.Text -match 'ENTRY=same' -and $rig.Events.Count -eq 0 -and -not (Test-ServerLeak $r)) -Name 'server status: same, nothing written, no value printed' -Detail $r.All
    $r = Invoke-Server $rig @{ mode = 'status' }
    Write-Result -Ok ($r.Text -match 'ENTRY=different') -Name 'server status without the stored proof: present reads different' -Detail $r.All

    $refusals = @(
        @{ Name = 'the MVP service name'; Rig = @{}; Service = '8005 AGV ControlServer\'; Expect = 'MVP_SERVICE_REFUSED' },
        @{ Name = 'an open dispatch gate'; Rig = @{ Config = '{"RiotCreateDispatch":{"enabled":true}}' }; Expect = 'UPGRADE_REFUSED_DISPATCH_OPEN' },
        @{ Name = 'an unreadable configuration'; Rig = @{ Config = 'not json' }; Expect = 'INSTALLED_CONFIGURATION_UNREADABLE' },
        @{ Name = 'a missing configuration'; Rig = @{ Config = $null }; Expect = 'INSTALLED_CONFIGURATION_MISSING' },
        @{ Name = 'a service not settled'; Rig = @{ Status = 'StopPending' }; Expect = 'SERVICE_NOT_SETTLED' },
        @{ Name = 'a configuration newer than the process'; Rig = @{ ConfigWrittenUtc = [datetime]::new(2002, 1, 1, 0, 0, 0, [DateTimeKind]::Utc) }; Expect = 'CONFIGURATION_CHANGED_SINCE_START' },
        @{ Name = 'an unknown process start time'; Rig = @{ ProcessStartedUtc = $null }; Expect = 'SERVICE_START_TIME_UNKNOWN' },
        @{ Name = 'a RiotCreateDispatch__ override'; Rig = @{ Environment = [string[]] ($baseEnvironment + 'RiotCreateDispatch__enabled=true') }; Expect = 'DISPATCH_GATE_OVERRIDDEN' },
        @{ Name = 'a journey not Completed'; Rig = @{ Journeys = @{ Journeys = @(@{ JourneyId = 'j-1'; Stage = 'Dispatched' }) } }; Expect = 'JOURNEYS_IN_PROGRESS' },
        @{ Name = 'journeys that cannot be read'; Rig = @{ Journeys = @{ Error = 'there is no file' } }; Expect = 'JOURNEY_STATE_UNREADABLE' },
        @{ Name = 'a connected vehicle'; Rig = @{ Connections = { @('172.19.204.53') } }; Expect = 'CONNECTED_VEHICLES: ' },
        @{ Name = 'connections that cannot be read'; Rig = @{ Connections = { throw 'CIM failed (injected)' } }; Expect = 'CONNECTIONS_UNREADABLE' }
    )
    foreach ($case in $refusals) {
        foreach ($req in @(@{ mode = 'set'; proof = $testProof }, @{ mode = 'remove' })) {
            $arguments = $case.Rig.Clone()
            if (-not $arguments.ContainsKey('Environment')) { $arguments['Environment'] = ($req.mode -eq 'set') ? $baseEnvironment : $withEntry }
            elseif ($req.mode -eq 'remove') { $arguments['Environment'] = [string[]] ($withEntry + 'RiotCreateDispatch__enabled=true') }
            $rig = New-ServerRig @arguments
            $before = (& $readRegistry) -join "`n"
            $r = Invoke-Server $rig $req ($case.ContainsKey('Service') ? $case.Service : '8005 AGV ControlServer V2')
            Write-Result -Ok ($r.Error -match [regex]::Escape($case.Expect) -and $rig.Events.Count -eq 0 -and ((& $readRegistry) -join "`n") -ceq $before -and -not (Test-ServerLeak $r)) `
                -Name "server $($req.mode): $($case.Name) is refused, no write, no restart" -Detail ($r.All + ' events: ' + ($rig.Events -join ';'))
        }
    }

    $rig = New-ServerRig -Environment $baseEnvironment -Connections { @('172.19.204.53') }
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof; allowConnectedVehicles = $true }
    Write-Result -Ok ($null -eq $r.Error -and $r.Text -match 'WARNING: CONNECTED_VEHICLES' -and ($rig.Events -join ';') -ceq 'write;restart with entry 1') `
        -Name 'server set with allowConnectedVehicles: a warning, then write and restart' -Detail $r.All
    $rig = New-ServerRig -Environment $baseEnvironment -Journeys @{ Journeys = @(@{ JourneyId = 'j-1'; Stage = 'Dispatched' }) }
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof; allowConnectedVehicles = $true }
    Write-Result -Ok ($r.Error -match 'JOURNEYS_IN_PROGRESS' -and $rig.Events.Count -eq 0) -Name 'allowConnectedVehicles does not let a journey through' -Detail $r.All

    # A write that does not read back: the original goes back, nothing restarts.
    # Only the first write is faulty; the write-back goes through the same action and must land.
    $faulty = @{ Writes = 0 }
    $rig = New-ServerRig -Environment $baseEnvironment -WriteOverride {
        param([string[]] $v)
        $faulty.Writes++
        Write-V2RegistryMultiString -Root $hkcu -Path $testKeyPath -Value @($v | Where-Object { $faulty.Writes -gt 1 -or $_ -notlike 'CONTROL_SERVER_MES_INGEST_SHARED_SECRET=*' })
    }.GetNewClosure()
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
    Write-Result -Ok ($r.Error -match 'ENVIRONMENT_READBACK_FAILED' -and $rig.Events.Count -eq 0 -and ((& $readRegistry) -join "`n") -ceq ($baseEnvironment -join "`n")) `
        -Name 'a write that drops an entry is caught, the original written back, nothing restarted' -Detail $r.All

    # Static: the server entry script reads connections without swallowing errors (review L2).
    $serverEntry = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-v2-recovery-window.ps1'))
    Write-Result -Ok ($serverEntry -match 'Get-NetTCPConnection -ErrorAction Stop' -and $serverEntry -notmatch 'Get-NetTCPConnection[^\r\n]*SilentlyContinue') `
        -Name 'the server entry reads connections with -ErrorAction Stop' -Detail ''

    # ================================================================ Part 3 ===

    Write-Host ''
    Write-Host 'Part 3: no deployment script opens the window'
    $remoteOps = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    foreach ($relative in 'onboard-hmi\scripts\06-deploy-onboard-hmi.ps1', 'factory-server\scripts\19-deploy-control-server-parallel.ps1') {
        $text = [IO.File]::ReadAllText((Join-Path $remoteOps $relative))
        $named = @(@('CONTROL_SERVER_RECOVERY_PROOF', 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF', 'recoveryResumeEnabled') | Where-Object { $text.Contains($_) })
        Write-Result -Ok ($named.Count -eq 0) -Name "$relative names no recovery variable and does not touch the switch" -Detail ($named -join ', ')
    }
} finally {
    try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testKeyPath, $false) } catch { }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed ? 'Red' : 'Green')
exit ($script:Failed ? 1 : 0)
