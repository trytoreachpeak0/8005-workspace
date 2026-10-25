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
param(
    [Parameter(Mandatory = $true)][string] $ControlServerRepository,

    # Internal: set by the outer run. The cases run in a child process, because the journey reader
    # loads e_sqlite3.dll from the temporary install root and a loaded native DLL cannot be deleted
    # while its process lives; the outer process removes the directory after the child has exited.
    [string] $InnerWork
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

if (-not $InnerWork) {
    $outerWork = Join-Path ([IO.Path]::GetTempPath()) "test-v2-recovery-window-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Force -Path $outerWork | Out-Null
    try {
        & pwsh -NoLogo -NoProfile -NonInteractive -File $PSCommandPath -ControlServerRepository $ControlServerRepository -InnerWork $outerWork
        $code = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $outerWork -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $outerWork) {
        Write-Host "  FAIL  the temporary directory $outerWork could not be removed after the run" -ForegroundColor Red
        exit 1
    }
    exit $code
}

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$target = Join-Path $PSScriptRoot '18-set-v2-recovery-window.ps1'
$csParallel = Join-Path (Resolve-Path -LiteralPath $ControlServerRepository).Path 'scripts\parallel'
$work = $InnerWork
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
if ($key -cmatch ':check$') { 'ENTRY=absent'; 'CONNECTED_VEHICLES=0'; 'CHECK_PASSED' }
if ($key -cmatch ':Status$' -and $env:FAKE_VEHICLE_STATUS) { $env:FAKE_VEHICLE_STATUS -split '\|' }
if ($key -cmatch ':status$' -and $env:FAKE_SERVER_STATUS) { $env:FAKE_SERVER_STATUS -split '\|' }
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
        param([string[]] $Arguments, [string] $FailMatch, [switch] $NoRepository, [string] $VehicleStatus, [string] $ServerStatus)
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $staged | Remove-Item -Force
        $saved = @{ PATH = $env:PATH; FAKE_SSH_LOG = $env:FAKE_SSH_LOG; FAKE_SCP_DIR = $env:FAKE_SCP_DIR; FAKE_SSH_FAIL_MATCH = $env:FAKE_SSH_FAIL_MATCH
            FAKE_VEHICLE_STATUS = $env:FAKE_VEHICLE_STATUS; FAKE_SERVER_STATUS = $env:FAKE_SERVER_STATUS }
        try {
            $env:PATH = "$fakeBin;$env:PATH"
            $env:FAKE_SSH_LOG = $log
            $env:FAKE_SCP_DIR = $staged
            $env:FAKE_SSH_FAIL_MATCH = $FailMatch
            $env:FAKE_VEHICLE_STATUS = $VehicleStatus
            $env:FAKE_SERVER_STATUS = $ServerStatus
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

    # ---- -VehicleOnly (review S-b) ----
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-VehicleOnly')
    Write-Result -Ok ($run.Exit -ne 0 -and $run.Calls.Count -eq 0 -and $run.Output -match 'only closes') -Name '-VehicleOnly without -Revert is refused before any call' -Detail $run.Output
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03')
    $proof = (Get-Store).Proof
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert') -FailMatch 'server-v2-recovery-window:check'
    Write-Result -Ok ($run.Exit -ne 0 -and $run.Output -match '-VehicleOnly' -and @($run.Calls | Where-Object { $_.alias -eq 'agv03' }).Count -eq 0 -and (Get-Store).Open -eq 'agv03') `
        -Name 'closing the last vehicle on a busy instance: refused, vehicle untouched, and the message names -VehicleOnly' -Detail $run.Output
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert', '-VehicleOnly') -FailMatch 'server-v2-recovery-window'
    Assert-Runs $run 'agv03:agv-v2-recovery-window:Close' '-Revert -VehicleOnly on the last vehicle: the vehicle only, even with the server refusing everything'
    Write-Result -Ok ($run.Exit -eq 0 -and @($run.Calls | Where-Object { $_.alias -eq 'factory01' }).Count -eq 0 -and (Get-Store).Proof -ceq $proof -and (Get-Store).Open -eq '') `
        -Name '... factory01 not reached; the store keeps the proof with no vehicle open (the server residue)' -Detail "open: $((Get-Store).Open)"

    # ---- -Status computes the residue (review L-c) ----
    $statusCase = {
        param([string] $Label, [string] $Vehicle, [string] $Server, [string] $Expect)
        $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Status') -VehicleStatus $Vehicle -ServerStatus $Server
        $line = @($run.Output -split "`n" | Where-Object { $_ -match '^RESIDUE: ' }) -join ' '
        Write-Result -Ok ($run.Exit -eq 0 -and $line -match $Expect) -Name "-Status, $Label" -Detail "RESIDUE line: '$line'"
    }
    & $statusCase 'server entry left after -VehicleOnly: reported' 'recoveryResumeEnabled=False|CONTROL_SERVER_RECOVERY_PROOF=absent' 'ENTRY=same' 'the server entry reads same while no vehicle is recorded open'
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Close > factory01:server-v2-recovery-window:remove' '... and a later -Revert, with the instance idle, removes it'
    Write-Result -Ok (-not (Test-Path -LiteralPath $secret)) -Name '... and deletes the store' -Detail ''
    & $statusCase 'nothing open, nothing left: none' 'recoveryResumeEnabled=False|CONTROL_SERVER_RECOVERY_PROOF=absent' 'ENTRY=absent' '^RESIDUE: none$'
    & $statusCase 'a close stopped after the switch (variable left): reported' 'recoveryResumeEnabled=False|CONTROL_SERVER_RECOVERY_PROOF=different' 'ENTRY=absent' 'not recorded open but CONTROL_SERVER_RECOVERY_PROOF reads different'
    & $statusCase 'a switch left on: reported' 'recoveryResumeEnabled=True|CONTROL_SERVER_RECOVERY_PROOF=absent' 'ENTRY=absent' 'not recorded open but its switch reads True'
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03')
    & $statusCase 'open and consistent: none' 'recoveryResumeEnabled=True|CONTROL_SERVER_RECOVERY_PROOF=same' 'ENTRY=same' '^RESIDUE: none$'
    & $statusCase 'an open stopped after the variable (switch still off): reported' 'recoveryResumeEnabled=False|CONTROL_SERVER_RECOVERY_PROOF=same' 'ENTRY=same' 'recorded open but reads switch=False'
    & $statusCase 'an open whose server write was refused: reported' 'recoveryResumeEnabled=True|CONTROL_SERVER_RECOVERY_PROOF=same' 'ENTRY=absent' 'the server entry reads absent while agv03 is recorded open'
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Remove-Item -LiteralPath $secret -Force -ErrorAction SilentlyContinue

    # ---- -RecoveryJourneyId (8005-workspace#58) ----
    $siteAgv03 = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\site-agv03.json') | ConvertFrom-Json
    $serverRequests = { param($run) @($run.Calls | Where-Object { $_.key -like 'factory01:*' } | ForEach-Object { $_.stdin | ConvertFrom-Json -AsHashtable }) }
    $journeyRefusals = [ordered]@{
        '-RecoveryJourneyId with -Status'              = @('-SshAlias', 'agv03', '-Status', '-RecoveryJourneyId', 'j-1')
        '-RecoveryJourneyId with -Revert -VehicleOnly' = @('-SshAlias', 'agv03', '-Revert', '-VehicleOnly', '-RecoveryJourneyId', 'j-1')
        '-RecoveryJourneyId with a quote in it'        = @('-SshAlias', 'agv03', '-RecoveryJourneyId', "j-1' OR '1'='1")
    }
    foreach ($case in $journeyRefusals.GetEnumerator()) {
        $run = Invoke-Target -Arguments $case.Value
        Write-Result -Ok ($run.Exit -ne 0 -and $run.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $secret)) -Name "$($case.Key) is refused before ssh or scp is called" -Detail "exit $($run.Exit), $($run.Calls.Count) call(s)`n$($run.Output)"
    }
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-RecoveryJourneyId', 'journey:40c5532e-d97d-4b29-a5bd-bf5343ea01dc|g102')
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Open > factory01:server-v2-recovery-window:set' 'open agv03 -RecoveryJourneyId: the same three runs'
    $named = @(& $serverRequests $run | Where-Object { $_['recoveryJourney'] -and $_['recoveryJourney']['journeyId'] -ceq 'journey:40c5532e-d97d-4b29-a5bd-bf5343ea01dc|g102' -and
            $_['recoveryJourney']['agvId'] -ceq $siteAgv03.agvId -and $_['recoveryJourney']['vehicleKey'] -ceq $siteAgv03.vehicleSafety.expectedVehicleKey })
    Write-Result -Ok ($named.Count -eq 2) -Name "... both server requests name the journey with site-agv03.json's agvId and expectedVehicleKey" -Detail (@(& $serverRequests $run | ForEach-Object { ($_['recoveryJourney'] | ConvertTo-Json -Compress) }) -join ' | ')
    $vehicleRequests = @($run.Calls | Where-Object { $_.key -like 'agv03:*' } | ForEach-Object { $_.stdin | ConvertFrom-Json -AsHashtable })
    Write-Result -Ok (@($vehicleRequests | Where-Object { $_.Contains('recoveryJourney') }).Count -eq 0) -Name '... and the vehicle request does not carry it' -Detail ''
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert', '-RecoveryJourneyId', 'journey:40c5532e-d97d-4b29-a5bd-bf5343ea01dc|g102')
    Assert-Runs $run 'factory01:server-v2-recovery-window:check > agv03:agv-v2-recovery-window:Close > factory01:server-v2-recovery-window:remove' '-Revert -RecoveryJourneyId: check, vehicle, remove'
    Write-Result -Ok (@(& $serverRequests $run | Where-Object { $_['recoveryJourney']['journeyId'] -ceq 'journey:40c5532e-d97d-4b29-a5bd-bf5343ea01dc|g102' }).Count -eq 2 -and -not (Test-Path -LiteralPath $secret)) `
        -Name '... both server requests name the journey, and the store is deleted' -Detail ''
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03')
    Write-Result -Ok ($run.Exit -eq 0 -and @(& $serverRequests $run | Where-Object { $_.Contains('recoveryJourney') }).Count -eq 0) -Name 'without -RecoveryJourneyId no server request carries recoveryJourney (unchanged)' -Detail ''
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Remove-Item -LiteralPath $secret -Force -ErrorAction SilentlyContinue

    # ---- an unreadable store ----
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $secret) | Out-Null
    Set-Content -LiteralPath $secret -Value 'not a clixml file'
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    Write-Result -Ok ($run.Exit -ne 0 -and $run.Calls.Count -eq 0 -and $run.Output -match 'STORE_UNREADABLE') -Name 'an unreadable store is refused before any call' -Detail $run.Output
    Remove-Item -LiteralPath $secret -Force

    # ================================================================ Part 2 ===

    Write-Host ''
    Write-Host 'Part 2: the remote halves with the production actions (New-V2VehicleActions, New-V2ServerActions), run for real'

    Import-Module (Join-Path $csParallel 'ParallelInstance.psm1') -Force
    Import-Module (Join-Path $csParallel 'ParallelHost.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'V2RecoveryWindow.psm1') -Force
    $testProof = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $otherProof = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    $hkcu.CreateSubKey("$testKeyPath\Environment").Close()

    function Invoke-Captured([scriptblock] $Block) {
        # Every stream, Write-Host included, as text; the error too.
        $text = ''; $failure = $null
        try { $text = (& $Block *>&1 | ForEach-Object { "$_" }) -join "`n" } catch { $failure = $_.Exception.Message }
        return @{ Text = $text; Error = $failure; All = "$text`n$failure" }
    }

    # ---------------------------------------------------- the production wiring ---
    $agvEntry = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'agv-v2-recovery-window.ps1'), [ref]$null, [ref]$null)
    $vehicleCalls = @($agvEntry.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-V2VehicleActions' }, $true))
    Write-Result -Ok ($vehicleCalls.Count -eq 1 -and $vehicleCalls[0].CommandElements.Count -eq 1) -Name 'the vehicle entry builds its actions with New-V2VehicleActions and no arguments' -Detail (@($vehicleCalls | ForEach-Object { $_.Extent.Text }) -join ' | ')
    $serverEntryAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'server-v2-recovery-window.ps1'), [ref]$null, [ref]$null)
    $serverCalls = @($serverEntryAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-V2ServerActions' }, $true))
    $serverArgs = @($serverCalls | ForEach-Object { $_.CommandElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName }) -join ','
    $serverArgText = $serverCalls.Count ? $serverCalls[0].Extent.Text : ''
    Write-Result -Ok ($serverCalls.Count -eq 1 -and $serverArgs -ceq 'ServiceName,InstallRoot,DataRoot,OnboardPort' -and $serverArgText.Contains('-ServiceName $layout.ServiceName') -and
        $serverArgText.Contains('-InstallRoot $layout.InstallRoot') -and $serverArgText.Contains('-DataRoot $layout.DataRoot') -and $serverArgText.Contains('-OnboardPort $onboardPort')) `
        -Name 'the server entry passes only the installed layout to New-V2ServerActions' -Detail $serverArgText
    $runCalls = @($serverEntryAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^Invoke-V2RecoveryWindowServer' }, $true) | ForEach-Object { $_.GetCommandName() })
    Write-Result -Ok (($runCalls -join ',') -ceq 'Invoke-V2RecoveryWindowServerRun') -Name 'the server entry runs through Invoke-V2RecoveryWindowServerRun (elevation, MVP fingerprint)' -Detail ($runCalls -join ',')
    $onboardPortLine = @($serverEntryAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$onboardPort' }, $true))
    Write-Result -Ok ($onboardPortLine.Count -eq 1 -and $onboardPortLine[0].Right.Extent.Text -ceq "[int] `$definition['onboardPort']") -Name "the server entry's onboard port is the installed definition's" -Detail (@($onboardPortLine | ForEach-Object { $_.Extent.Text }) -join ' | ')

    Write-Result -Ok ((New-V2VehicleActions).Description -ceq 'variables HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment; client process SQCD.Agv.Wpf') `
        -Name 'New-V2VehicleActions defaults: machine variables in HKLM, client process SQCD.Agv.Wpf' -Detail (New-V2VehicleActions).Description
    $defaultServer = New-V2ServerActions -ServiceName '8005 AGV ControlServer V2' -InstallRoot 'C:\Program Files\8005 AGV\ControlServer.V2' -DataRoot 'C:\ProgramData\8005\ControlServer.V2' -OnboardPort 58105
    Write-Result -Ok ($defaultServer.Description -ceq 'registry HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\8005 AGV ControlServer V2; configuration C:\Program Files\8005 AGV\ControlServer.V2\appsettings.Production.json; onboard port 58105' -and
        $defaultServer.RegistryPath -ceq 'SYSTEM\CurrentControlSet\Services\8005 AGV ControlServer V2') `
        -Name "New-V2ServerActions defaults: the V2 service's own key in HKLM" -Detail $defaultServer.Description
    $r = Invoke-Captured { New-V2ServerActions -ServiceName '8005 AGV ControlServer' -InstallRoot 'C:\x' -DataRoot 'C:\y' -OnboardPort 1 }
    Write-Result -Ok ($r.Error -match 'MVP_SERVICE_REFUSED') -Name 'New-V2ServerActions refuses the MVP service name' -Detail $r.All

    # The defaults every case below replaces -- the stop and the start (with recorders; 8005-workspace#68 split the restart
    # so the journeys and RIoT are read again between them), the RIoT GET (with a fake) and the elevation check (with
    # { $true }) -- are pinned by their text here, since no case runs them (review L1).
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'V2RecoveryWindow.psm1'), [ref]$null, [ref]$null)
    $factory = $moduleAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-V2ServerActions' }, $true)
    $controlDefault = { param([string] $Name) @($factory.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $Name }, $true)) }
    $stopDefault = @(& $controlDefault '$stop'); $startDefault = @(& $controlDefault '$start')
    Write-Result -Ok ($stopDefault.Count -eq 1 -and $stopDefault[0].Right.Extent.Text -ceq '$StopService ?? { Stop-Service -Name $ServiceName -Force }.GetNewClosure()' -and
        $startDefault.Count -eq 1 -and $startDefault[0].Right.Extent.Text -ceq '$StartService ?? { Start-Service -Name $ServiceName }.GetNewClosure()') `
        -Name 'the default stop and start act on the service named by -ServiceName, and nothing else' -Detail (@($stopDefault + $startDefault | ForEach-Object { $_.Extent.Text }) -join ' | ')
    $serviceNameWrites = @($factory.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ieq '$ServiceName' }, $true))
    Write-Result -Ok ($serviceNameWrites.Count -eq 0) -Name '... and New-V2ServerActions never reassigns -ServiceName' -Detail (@($serviceNameWrites | ForEach-Object { $_.Extent.Text }) -join ' | ')
    $restartCalls = @($factory.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match 'Restart-Service|Stop-Service|Start-Service' }, $true))
    Write-Result -Ok ($restartCalls.Count -eq 2 -and ((@($restartCalls | ForEach-Object { $_.Extent.Text }) -join ' | ') -ceq 'Stop-Service -Name $ServiceName -Force | Start-Service -Name $ServiceName')) `
        -Name '... and they are the only service control calls in New-V2ServerActions' -Detail (@($restartCalls | ForEach-Object { $_.Extent.Text }) -join ' | ')
    $riotDefault = @($factory.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Read-ParallelRiotGateFacts' }, $true))
    Write-Result -Ok ($riotDefault.Count -eq 1 -and $riotDefault[0].Extent.Text.Contains('-Direction Close') -and $riotDefault[0].Extent.Text.Contains('-Get $RiotGet')) `
        -Name "the journey state is read with control-server's Read-ParallelRiotGateFacts (8005-workspace#68), the GET left to it unless a test passes one" -Detail (@($riotDefault | ForEach-Object { $_.Extent.Text }) -join ' | ')
    $elevated = @($factory.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | ForEach-Object { $_.KeyValuePairs } |
            Where-Object { $_.Item1.Extent.Text -ceq 'IsElevated' })
    Write-Result -Ok ($elevated.Count -eq 1 -and $elevated[0].Item2.Extent.Text -ceq '{ ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }') `
        -Name 'the default elevation check asks Windows whether this process is an administrator' -Detail (@($elevated | ForEach-Object { $_.Item2.Extent.Text }) -join ' | ')
    $nonAdmin = -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($nonAdmin) {
        Write-Result -Ok (-not (& $defaultServer.IsElevated)) -Name '... and, run here unelevated, it says no' -Detail ''
    }

    # The client check, for real: a process named SQCD.Agv.Wpf (a copy of ping.exe) is seen by the default actions.
    $dummyDirectory = Join-Path $work 'dummy-client'
    New-Item -ItemType Directory -Force -Path $dummyDirectory | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination (Join-Path $dummyDirectory 'SQCD.Agv.Wpf.exe')
    $dummy = Start-Process -FilePath (Join-Path $dummyDirectory 'SQCD.Agv.Wpf.exe') -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        Start-Sleep -Milliseconds 300
        Write-Result -Ok ((& (New-V2VehicleActions).ClientRunning) -eq $true) -Name 'the default actions see a running SQCD.Agv.Wpf' -Detail ''
    } finally {
        Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }

    # ---------------------------------------------------------------- vehicle ---
    $installRoot = Join-Path $work 'OnboardHmi'
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    $settingsPath = Join-Path $installRoot 'appsettings.json'
    $instanceId = 'dce47db2-b531-4f27-9737-af60bec96beb'
    $pristine = [ordered]@{ agvId = 'test-car'; wireToGate = [ordered]@{ onboardInstanceId = $instanceId; recoveryResumeEnabled = $false; unableToChargeEntryEnabled = $true; port = 58105 } } | ConvertTo-Json -Depth 5
    $readSwitch = { (Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).wireToGate.recoveryResumeEnabled }
    $variableNames = { $k = $hkcu.OpenSubKey("$testKeyPath\Environment"); try { @($k.GetValueNames()) } finally { $k.Close() } }

    # The production actions against a temporary key, with a recorder in front of the write. The recorder
    # calls the real write; -SetHook / -GetOverride inject a failure.
    function New-VehicleRig {
        param([bool] $Running = $false, [scriptblock] $SetHook, [scriptblock] $GetOverride)
        $real = New-V2VehicleActions -EnvironmentRoot $hkcu -EnvironmentPath "$testKeyPath\Environment" -ProcessName "no-such-process-$([guid]::NewGuid().ToString('N'))"
        $rig = @{ Events = [System.Collections.Generic.List[string]]::new(); Real = $real }
        $rig.Actions = @{
            ClientRunning = $Running ? { $true } : $real.ClientRunning
            GetMachineVariable = $GetOverride ?? $real.GetMachineVariable
            SetMachineVariable = {
                param($n, $v)
                $rig.Events.Add("set $n $([string]::IsNullOrEmpty($v) ? 'delete' : 'value') with switch $(& $readSwitch)")
                if ($SetHook) { & $SetHook }
                & $real.SetMachineVariable $n $v
            }.GetNewClosure()
        }
        return $rig
    }
    $request = { param($state, $proofValue, $instance = $instanceId)
        $r = @{ state = $state; installRoot = $installRoot; onboardInstanceId = $instance }
        if ($proofValue) { $r['proof'] = $proofValue }
        $r
    }
    $variableNow = { & (New-V2VehicleActions -EnvironmentRoot $hkcu -EnvironmentPath "$testKeyPath\Environment").GetMachineVariable 'CONTROL_SERVER_RECOVERY_PROOF' }

    Set-Content -LiteralPath $settingsPath -Value $pristine -Encoding utf8NoBOM
    $rig = New-VehicleRig
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($null -eq $r.Error -and (& $readSwitch) -eq $true -and (& $variableNow) -ceq $testProof) `
        -Name 'vehicle open: switch true and the variable (in the registry) holds the proof' -Detail $r.All
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
    Write-Result -Ok ($null -eq $r.Error -and (& $readSwitch) -eq $false -and $null -eq (& $variableNow) -and (& $variableNames) -notcontains 'CONTROL_SERVER_RECOVERY_PROOF') `
        -Name 'vehicle close: switch false, the variable deleted from the key (no empty value left)' -Detail ($r.All + ' names: ' + ((& $variableNames) -join ','))
    Write-Result -Ok (($rig.Events -join ';') -ceq 'set CONTROL_SERVER_RECOVERY_PROOF delete with switch False') -Name 'vehicle close (S1): the variable is deleted only after the switch is off' -Detail ($rig.Events -join ';')

    Set-Content -LiteralPath $settingsPath -Value $pristine -Encoding utf8NoBOM
    $rig = New-VehicleRig -SetHook { throw 'registry write failed (injected)' }
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($null -ne $r.Error -and (& $readSwitch) -eq $false) -Name 'vehicle open, variable write fails: refused, switch still false' -Detail $r.All

    $rig = New-VehicleRig -GetOverride { param($n) $otherProof }.GetNewClosure()
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($r.Error -match 'VARIABLE_READBACK_FAILED' -and (& $readSwitch) -eq $false) -Name 'vehicle open, variable reads back different: refused, switch still false' -Detail $r.All
    & $rig.Real.SetMachineVariable 'CONTROL_SERVER_RECOVERY_PROOF' $null

    $rig = New-VehicleRig -GetOverride { param($n) $null }
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $rig.Actions }
    Write-Result -Ok ($r.Error -match 'VARIABLE_READBACK_FAILED' -and (& $readSwitch) -eq $false) -Name 'vehicle open, variable reads back absent: refused, switch still false' -Detail $r.All
    & $rig.Real.SetMachineVariable 'CONTROL_SERVER_RECOVERY_PROOF' $null

    foreach ($case in @(
            @{ Name = 'a running client'; Rig = (New-VehicleRig -Running $true); Request = (& $request 'Open' $testProof); Expect = 'CLIENT_RUNNING' },
            @{ Name = 'a running client, closing'; Rig = (New-VehicleRig -Running $true); Request = (& $request 'Close' $null); Expect = 'CLIENT_RUNNING' },
            @{ Name = "another vehicle's configuration"; Rig = (New-VehicleRig); Request = (& $request 'Open' $testProof 'fb7244d8-e78f-4153-ab33-7fcb23fc67fe'); Expect = 'VEHICLE_IDENTITY_MISMATCH' },
            @{ Name = 'a blank identity on both sides'; Rig = (New-VehicleRig); Request = (& $request 'Open' $testProof ' '); Blank = $true; Expect = 'VEHICLE_IDENTITY_MISMATCH' },
            @{ Name = 'no proof'; Rig = (New-VehicleRig); Request = (& $request 'Open' $null); Expect = 'PROOF_NOT_RECEIVED' })) {
        $text = $case.ContainsKey('Blank') ? $pristine.Replace($instanceId, ' ') : $pristine
        Set-Content -LiteralPath $settingsPath -Value $text -Encoding utf8NoBOM
        $before = [IO.File]::ReadAllBytes($settingsPath)
        $rig = $case.Rig
        $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request $case.Request -Actions $rig.Actions }
        $same = [Linq.Enumerable]::SequenceEqual([byte[]] $before, [byte[]] [IO.File]::ReadAllBytes($settingsPath))
        Write-Result -Ok ($r.Error -match $case.Expect -and $same -and $rig.Events.Count -eq 0 -and $null -eq (& $variableNow)) -Name "vehicle: $($case.Name) is refused with nothing changed" -Detail $r.All
    }
    $r = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request @{ state = 'Open'; installRoot = (Join-Path $work 'nowhere'); onboardInstanceId = $instanceId; proof = $testProof } -Actions (New-VehicleRig).Actions }
    Write-Result -Ok ($r.Error -match 'NO_INSTALLATION') -Name 'vehicle: no installation is refused' -Detail $r.All

    foreach ($case in @(@{ Line = ''; Expect = 'REQUEST_NOT_RECEIVED' }, @{ Line = 'not json'; Expect = 'REQUEST_NOT_RECEIVED' }, @{ Line = '{"state":"Open","proof":"ABC"}'; Expect = 'PROOF_MALFORMED' })) {
        $r = Invoke-Captured { Read-V2RecoveryWindowRequest -Line $case.Line }
        Write-Result -Ok ($r.Error -match $case.Expect) -Name "request '$($case.Line)' is refused ($($case.Expect))" -Detail $r.All
    }

    # ----------------------------------------------------------------- server ---
    # New-V2ServerActions with a real local service (its real status), a temporary key standing for the
    # Services key, a temporary install and data root, a real loopback port, and a recorded restart. The
    # SQLite reader needs Microsoft.Data.Sqlite; it is borrowed from the NuGet cache into the install root.
    $stoppedService = (Get-Service | Where-Object { $_.Status -eq 'Stopped' -and $_.Name -notmatch '^8005|[^\w.-]' } | Select-Object -First 1).Name
    $runningService = Get-CimInstance Win32_Service -Filter "State='Running'" | Where-Object {
        $_.ProcessId -and $_.Name -notmatch '^8005|[^\w.-]' -and (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue)?.StartTime } | Select-Object -First 1 -ExpandProperty Name
    $serverInstall = Join-Path $work 'ControlServer.V2'
    $serverData = Join-Path $work 'ControlServer.V2-data'
    New-Item -ItemType Directory -Force -Path $serverInstall, $serverData | Out-Null
    $configPath = Join-Path $serverInstall 'appsettings.Production.json'
    $databasePath = Join-Path $serverData 'controlserver.db'
    $connectionString = ([ordered]@{ ControlServer = "Data Source=$databasePath" } | ConvertTo-Json -Compress)
    function Set-Config([string] $Gate = 'false', [datetime] $WrittenUtc = [datetime]::new(2000, 1, 1, 0, 0, 0, [DateTimeKind]::Utc), [string] $Raw) {
        [IO.File]::WriteAllText($configPath, ($Raw ? $Raw : "{`"RiotCreateDispatch`":{`"enabled`":$Gate},`"ConnectionStrings`":$connectionString}"))
        [IO.File]::SetLastWriteTimeUtc($configPath, $WrittenUtc)
    }

    $nuget = $env:NUGET_PACKAGES ?? (Join-Path $env:USERPROFILE '.nuget\packages')
    $pick = { param($package, $relative) Get-ChildItem -Path (Join-Path $nuget "$package\*\$relative") -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1 }
    $sqliteParts = @(
        (& $pick 'microsoft.data.sqlite.core' 'lib\net8.0\Microsoft.Data.Sqlite.dll'),
        (& $pick 'sqlitepclraw.core' 'lib\netstandard2.0\SQLitePCLRaw.core.dll'),
        (& $pick 'sqlitepclraw.provider.e_sqlite3' 'lib\net6.0-windows7.0\SQLitePCLRaw.provider.e_sqlite3.dll'),
        (& $pick 'sqlitepclraw.bundle_e_sqlite3' 'lib\netstandard2.0\SQLitePCLRaw.batteries_v2.dll'),
        (& $pick 'sqlitepclraw.lib.e_sqlite3' 'runtimes\win-x64\native\e_sqlite3.dll'))
    $haveSqlite = @($sqliteParts | Where-Object { $_ }).Count -eq 5
    if ($haveSqlite) { $sqliteParts | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $serverInstall } }
    # 8005-workspace#68: the RIoT the server half reads, as the installed service would read it -- appsettings.json in the
    # install root names the key's variable, the key is in the service Environment (a sentinel) -- and answered by a fake
    # passed as -RiotGet. Every vehicle stands still (agv03's reading on its charger, 2026-10-11) unless its key is in
    # $riotNow.Moving; the non-final listing carries $riotNow.Orders.
    [IO.File]::WriteAllText((Join-Path $serverInstall 'appsettings.json'), '{"RIoT":{"baseUrl":"http://riot.selftest","callApiKeyEnvironmentVariable":"CONTROL_SERVER_RIOT_CALL_API_KEY"}}')
    $riotNow = @{ Moving = [System.Collections.Generic.HashSet[string]]::new(); Orders = [System.Collections.Generic.List[object]]::new(); Calls = [System.Collections.Generic.List[string]]::new() }
    $riotGet = {
        param([string] $Path)
        $riotNow.Calls.Add($Path)
        if ($Path -match '^/api/task/v1/task/getVehicleInfo/(.+)$') {
            $key = [uri]::UnescapeDataString($Matches[1])
            $moving = $riotNow.Moving.Contains($key)
            $body = [ordered]@{
                vehicle = [ordered]@{ movementState = ($moving ? 'MT_RUNNING' : 'MT_FINISHED'); controlState = 'CONTROL_STATE_OK'; emergencyState = 'OK'; breakSwitchState = 'MOVABLE'
                    locationState = 'LOCATION_STATE_RUNNING'; speed = ($moving ? 0.5 : 0); mode = 'MODE_AUTO' }
                vehicleTaskInfo = [ordered]@{ key = $key; procState = ($moving ? 'EXECUTING' : 'IDLE'); processingOrder = $moving; enable = $true; integrationLevel = 'ON_LINE' }
            }
            return @{ Status = 200; Content = (ConvertTo-Json -InputObject $body -Depth 5 -Compress) }
        }
        if ($Path.StartsWith('/api/order/v1/orderRecord?')) {
            $records = @($riotNow.Orders)
            return @{ Status = 200; Content = (ConvertTo-Json -InputObject ([ordered]@{ code = '0'; message = 'ok'; result = [ordered]@{ current = 1; size = 100; total = $records.Count; records = $records } }) -Depth 6 -Compress) }
        }
        return @{ Status = 404; Content = '' }
    }.GetNewClosure()

    function New-Database([string[]] $Stages, [hashtable[]] $Journeys = @(), [string[]] $FaultedAgvIds = @()) {
        Remove-Item -LiteralPath $databasePath -Force -ErrorAction SilentlyContinue
        foreach ($assembly in 'SQLitePCLRaw.core.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll', 'SQLitePCLRaw.batteries_v2.dll', 'Microsoft.Data.Sqlite.dll') {
            Add-Type -LiteralPath (Join-Path $serverInstall $assembly) -ErrorAction SilentlyContinue
        }
        try { [SQLitePCL.Batteries_V2]::Init() } catch { }
        $writer = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$databasePath;Pooling=False")
        $writer.Open()
        $command = $writer.CreateCommand()
        $i = 0
        $rows = @($Stages | ForEach-Object { $i++; "INSERT INTO JourneyRuntimes VALUES ('j-$i', '$_', 'car', 'K', 'p$i', NULL, '2026-10-12 09:00:00+08:00', NULL);" }) -join "`n"
        $rows += "`n" + (@($Journeys | ForEach-Object {
                    "INSERT INTO JourneyRuntimes VALUES ('$($_.Id)', '$($_.Stage)', '$($_.AgvId)', '$($_.VehicleKey)', 'p-$($_.Id)', NULL, '2026-10-19 14:37:00+08:00', $($_.Block ? "'$($_.Block)'" : 'NULL'));" }) -join "`n")
        $rows += "`n" + (@($FaultedAgvIds | ForEach-Object { "INSERT INTO VehicleFaultStates VALUES ('$_', 'Blocked', 'EMERGENCY_STOP_LATCHED');" }) -join "`n")
        $command.CommandText = @"
CREATE TABLE JourneyRuntimes (JourneyId TEXT PRIMARY KEY, Stage TEXT, AgvId TEXT, VehicleKey TEXT, PickupUpperId TEXT, GateUpperId TEXT, CreatedAt TEXT, BlockReasonCode TEXT);
CREATE TABLE OrderIntents (MovementLegId TEXT PRIMARY KEY, UpperId TEXT, VehicleKey TEXT, Status TEXT, OrderId TEXT, CreateAttemptCount INTEGER, CreateAttemptId TEXT, DispatchAuditVersion INTEGER, ExperimentalCreateAuthorizationId TEXT, CreatedAt TEXT);
CREATE TABLE RiotDispatchAuditEvents (AuditEventId TEXT PRIMARY KEY, MovementLegId TEXT, Phase TEXT, Outcome TEXT, AttemptId TEXT, ReturnedOrderId TEXT, ResultPresent INTEGER);
CREATE TABLE VehicleFaultStates (AgvId TEXT PRIMARY KEY, Level TEXT, EvidenceCode TEXT);
$rows
"@
        $null = $command.ExecuteNonQuery(); $command.Dispose(); $writer.Dispose()
    }

    $sentinels = @{
        DOTNET_ENVIRONMENT = 'Production'
        CONTROL_SERVER_ONBOARD_CREDENTIAL = "sentinel-onboard-$([guid]::NewGuid().ToString('N'))"
        CONTROL_SERVER_MES_INGEST_SHARED_SECRET = "sentinel-mes-$([guid]::NewGuid().ToString('N'))"
        CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL = "sentinel-fault-$([guid]::NewGuid().ToString('N'))"
        # 8005-workspace#68: the key RIoT is read with, from the service Environment as the product installer writes it.
        CONTROL_SERVER_RIOT_CALL_API_KEY = "sentinel-riot-$([guid]::NewGuid().ToString('N'))"
    }
    $baseEnvironment = [string[]] @('DOTNET_ENVIRONMENT', 'CONTROL_SERVER_ONBOARD_CREDENTIAL', 'CONTROL_SERVER_MES_INGEST_SHARED_SECRET', 'CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL',
            'CONTROL_SERVER_RIOT_CALL_API_KEY' | ForEach-Object { "$_=$($sentinels[$_])" })
    $withEntry = [string[]] @($baseEnvironment[0..1] + "CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=$testProof" + $baseEnvironment[2..($baseEnvironment.Count - 1)])
    $servicesPath = "$testKeyPath\Services"
    $freePort = { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }

    function New-ServerRig {
        param([string] $Service = $stoppedService, [string[]] $Environment = $baseEnvironment, [int] $Port = (& $freePort))
        $hkcu.CreateSubKey("$servicesPath\$Service").Close()
        Write-V2RegistryMultiString -Root $hkcu -Path "$servicesPath\$Service" -Value $Environment
        $rig = @{ Events = [System.Collections.Generic.List[string]]::new(); Service = $Service; Path = "$servicesPath\$Service"; OnStop = $null }
        # The stop and the start recorded with the entry as the registry holds it then; -OnStop (set on the rig) is what
        # happens while the service is down -- a vehicle somebody drives off in RIoT, say (8005-workspace#68).
        $rig.Actions = New-V2ServerActions -ServiceName $Service -InstallRoot $serverInstall -DataRoot $serverData -OnboardPort $Port `
            -RegistryRoot $hkcu -ServicesPath $servicesPath -RiotGet $riotGet -StopService {
            $entry = @(Read-V2RegistryMultiString -Root $hkcu -Path $rig.Path | Where-Object { $_ -like 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=*' }).Count
            $rig.Events.Add("stop with entry $entry")
            if ($rig.OnStop) { & $rig.OnStop }
        }.GetNewClosure() -StartService {
            $entry = @(Read-V2RegistryMultiString -Root $hkcu -Path $rig.Path | Where-Object { $_ -like 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=*' }).Count
            $rig.Events.Add("start with entry $entry")
        }.GetNewClosure()
        $realWrite = $rig.Actions.WriteEnvironment
        $rig.Actions.WriteEnvironment = { param([string[]] $v) $rig.Events.Add('write'); & $realWrite $v }.GetNewClosure()
        $rig.Actions.IsElevated = { $true }
        return $rig
    }
    function Read-Rig($rig) { [string[]] @(Read-V2RegistryMultiString -Root $hkcu -Path $rig.Path) }
    function Invoke-Server($rig, [hashtable] $req) {
        return Invoke-Captured { Invoke-V2RecoveryWindowServerRun -Request $req -ServiceName $rig.Service -OnboardPort 58105 -Actions $rig.Actions }
    }
    function Test-ServerLeak($r) {
        foreach ($v in @($testProof, $otherProof) + @($sentinels.Values | Where-Object { $_ -ne 'Production' })) { if ($r.All.Contains($v)) { return $true } }
        return $false
    }
    function Assert-Refused($rig, [hashtable] $req, [string] $expect, [string] $name) {
        $before = (Read-Rig $rig) -join "`n"
        $r = Invoke-Server $rig $req
        Write-Result -Ok ($r.Error -match [regex]::Escape($expect) -and $rig.Events.Count -eq 0 -and ((Read-Rig $rig) -join "`n") -ceq $before -and -not (Test-ServerLeak $r)) `
            -Name "server $($req.mode): $name is refused, no write, no restart" -Detail ($r.All + ' events: ' + ($rig.Events -join ';'))
    }

    Write-Result -Ok ([bool] $stoppedService) -Name "a stopped local service stands in for the V2 service ($stoppedService)" -Detail 'none found'
    Write-Result -Ok ([bool] $runningService) -Name "a running local service with a readable start time stands in too ($runningService)" -Detail 'none found'

    # Refusals that come before the journey reader, so they need no SQLite.
    foreach ($req in @(@{ mode = 'set'; proof = $testProof }, @{ mode = 'remove' })) {
        $env0 = ($req.mode -eq 'set') ? $baseEnvironment : $withEntry
        Set-Config -Gate 'true'
        Assert-Refused (New-ServerRig -Environment $env0) $req 'UPGRADE_REFUSED_DISPATCH_OPEN' 'an open dispatch gate (the real pre-install check, a real stopped service)'
        Set-Config -Raw 'not json'
        Assert-Refused (New-ServerRig -Environment $env0) $req 'INSTALLED_CONFIGURATION_UNREADABLE' 'an unreadable configuration'
        Remove-Item -LiteralPath $configPath
        Assert-Refused (New-ServerRig -Environment $env0) $req 'INSTALLED_CONFIGURATION_MISSING' 'a missing configuration'
        Set-Config
        Assert-Refused (New-ServerRig -Environment ([string[]] ($env0 + 'RiotCreateDispatch__enabled=true'))) $req 'DISPATCH_GATE_OVERRIDDEN' 'a RiotCreateDispatch__ override'
        if ($runningService) {
            Set-Config -WrittenUtc ([datetime]::UtcNow.AddMinutes(5))
            Assert-Refused (New-ServerRig -Service $runningService -Environment $env0) $req 'CONFIGURATION_CHANGED_SINCE_START' "a configuration newer than the running process ($runningService)"
        }
        Set-Config
        # A vehicle connected: a real loopback connection on the onboard port.
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
        $busyPort = $listener.LocalEndpoint.Port
        $client = [Net.Sockets.TcpClient]::new(); $client.Connect([Net.IPAddress]::Loopback, $busyPort); $accepted = $listener.AcceptTcpClient()
        try {
            Assert-Refused (New-ServerRig -Environment $env0 -Port $busyPort) $req 'CONNECTED_VEHICLES: ' 'a connected vehicle (a real loopback connection)'
        } finally { $accepted.Dispose(); $client.Dispose(); $listener.Stop() }
        # No database file: the real reader reports it, and that refuses.
        Remove-Item -LiteralPath $databasePath -Force -ErrorAction SilentlyContinue
        Assert-Refused (New-ServerRig -Environment $env0) $req 'JOURNEY_STATE_UNREADABLE' 'journeys that cannot be read (no database file)'
        $rig = New-ServerRig -Environment $env0
        $rig.Actions.Connections = { throw 'CIM failed (injected)' }
        Assert-Refused $rig $req 'CONNECTIONS_UNREADABLE' 'connections that cannot be read'
    }

    $rig = New-ServerRig -Environment $baseEnvironment
    $rig.Actions.RegistryPath = "$servicesPath\8005 AGV ControlServer"
    Assert-Refused $rig @{ mode = 'set'; proof = $testProof } 'REGISTRY_PATH_REFUSED' 'actions that write the MVP service key'
    $rig = New-ServerRig -Environment $baseEnvironment
    $rig.Actions.RegistryPath = "$servicesPath\other-service"
    Assert-Refused $rig @{ mode = 'set'; proof = $testProof } 'REGISTRY_PATH_REFUSED' "actions that write another service's key"
    $rig = New-ServerRig -Environment $baseEnvironment
    $rig.Actions.IsElevated = { $false }
    Assert-Refused $rig @{ mode = 'set'; proof = $testProof } 'NOT_ELEVATED' 'a run that is not elevated'

    $rig = New-ServerRig -Environment $withEntry
    $r = Invoke-Server $rig @{ mode = 'status'; proof = $testProof }
    Write-Result -Ok ($r.Text -match 'ENTRY=same' -and $r.Text -match 'SERVICE=Stopped' -and $rig.Events.Count -eq 0 -and -not (Test-ServerLeak $r)) -Name 'server status: same, the real service status, nothing written, no value printed' -Detail $r.All
    $r = Invoke-Server $rig @{ mode = 'status' }
    Write-Result -Ok ($r.Text -match 'ENTRY=different') -Name 'server status without the stored proof: present reads different' -Detail $r.All
    $rig = New-ServerRig -Environment $withEntry
    $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
    Write-Result -Ok ($null -eq $r.Error -and $r.Text -match 'NO_CHANGE' -and $rig.Events.Count -eq 0) -Name 'server set when the entry already holds the proof: no write, no restart' -Detail ($r.All + ' ' + ($rig.Events -join ';'))

    # ---- 8005-workspace#68: Get-V2RecoveryJourneyRefusal by vehicle, pure. -VehicleMotion is control-server's
    # Get-ParallelGateVehicleMotion answer (one entry per vehicle, Reasons empty when it stands still), $null when the staged
    # control-server predates #68 and cannot tell -- then every journey not Completed refuses, as before.
    $motion = { param([string] $Key, [string] $AgvId, [string[]] $Reasons = @()) [ordered]@{ VehicleKey = $Key; AgvId = $AgvId; Journeys = @(); Reasons = [string[]] $Reasons } }
    $row = { param([string] $Id, [string] $Stage, [string] $AgvId, [string] $Key) [ordered]@{ JourneyId = $Id; Stage = $Stage; AgvId = $AgvId; VehicleKey = $Key } }
    $charging = & $row 'journey:charge-1|g1' 'AwaitingPickupArrival' 'car1' 'K1'
    $stuckRow = & $row 'j-target' 'Blocked' 'car3' 'K3'
    $named = @{ journeyId = 'j-target'; agvId = 'car3'; vehicleKey = 'K3' }
    $readStuck = { param($id) @{ Found = $true; JourneyId = 'j-target'; Stage = 'Blocked'; BlockReasonCode = 'LOAD_RESULT_REQUIRES_RECOVERY'; AgvId = 'car3'; VehicleKey = 'K3' } }
    $readReleased = { param($id) @{ Found = $true; JourneyId = 'j-target'; Stage = 'AwaitingLoadResult'; BlockReasonCode = $null; AgvId = 'car3'; VehicleKey = 'K3' } }
    $readNever = { param($id) throw 'closing must not read the named row' }
    $still = @((& $motion 'K1' 'car1'), (& $motion 'K3' 'car3'))
    $k1Moving = @((& $motion 'K1' 'car1' @('RIOT_MOTION_ACTIVE (movementState MT_RUNNING, speed 0.5)')), (& $motion 'K3' 'car3'))
    $k3Moving = @((& $motion 'K1' 'car1'), (& $motion 'K3' 'car3' @('RIOT_NONFINAL_ORDER_PRESENT (o-9 / u-9 orderState 3)')))
    $refusalCases = @(
        @{ Name = 'opening, a charging journey on a vehicle standing still'; Target = 'set'; Open = @($charging); Motion = $still; Expect = $null }
        @{ Name = 'opening, a charging journey on a vehicle RIoT shows moving'; Target = 'set'; Open = @($charging); Motion = $k1Moving; Expect = 'JOURNEYS_IN_PROGRESS'; Has = @('car1', 'RIOT_MOTION_ACTIVE') }
        @{ Name = 'opening, the vehicles not judged (a control-server from before #68)'; Target = 'set'; Open = @($charging); Motion = $null; Expect = 'JOURNEYS_IN_PROGRESS'; Has = @('not judged') }
        @{ Name = 'opening, no answer for the vehicle'; Target = 'set'; Open = @($charging); Motion = @((& $motion 'K3' 'car3')); Expect = 'JOURNEYS_IN_PROGRESS'; Has = @('K1') }
        @{ Name = 'opening, named stuck journey and a charging vehicle standing still'; Target = 'set'; Open = @($stuckRow, $charging); Rj = $named; Read = $readStuck; Motion = $still; Expect = $null }
        @{ Name = 'opening, named stuck journey and a charging vehicle moving'; Target = 'set'; Open = @($stuckRow, $charging); Rj = $named; Read = $readStuck; Motion = $k1Moving; Expect = 'RECOVERY_JOURNEY_NOT_ALONE'; Has = @('car1'); HasNot = @('j-target (') }
        @{ Name = 'opening, named stuck journey released back to the engine'; Target = 'set'; Open = @($stuckRow); Rj = $named; Read = $readReleased; Motion = $still; Expect = 'RECOVERY_JOURNEY_NOT_AWAITING_RECOVERY' }
        @{ Name = 'opening, named stuck journey not among the open ones, the rest standing still'; Target = 'set'; Open = @($charging); Rj = $named; Read = $readNever; Motion = $still; Expect = $null }
        @{ Name = 'closing, the named journey gone on to its next pickup stop, its vehicle standing still (field instance 1)'; Target = 'remove'; Open = @((& $row 'j-target' 'AwaitingPickupArrival' 'car3' 'K3')); Rj = $named; Read = $readNever; Motion = $still; Expect = $null }
        @{ Name = 'closing, the named journey released back to the engine, standing still'; Target = 'remove'; Open = @($stuckRow); Rj = $named; Read = $readNever; Motion = $still; Expect = $null }
        @{ Name = "closing, the named journey's vehicle with an unfinished RIoT order"; Target = 'remove'; Open = @($stuckRow); Rj = $named; Read = $readNever; Motion = $k3Moving; Expect = 'JOURNEYS_IN_PROGRESS'; Has = @('car3', 'RIOT_NONFINAL_ORDER_PRESENT') }
        @{ Name = 'closing, another vehicle moving: only it is named'; Target = 'remove'; Open = @($stuckRow, $charging); Rj = $named; Read = $readNever; Motion = $k1Moving; Expect = 'JOURNEYS_IN_PROGRESS'; Has = @('car1'); HasNot = @('car3') }
        @{ Name = 'closing, the vehicles not judged'; Target = 'remove'; Open = @($stuckRow); Rj = $named; Read = $readNever; Motion = $null; Expect = 'JOURNEYS_IN_PROGRESS'; Has = @('not judged') }
        @{ Name = 'closing without a named journey, a charging vehicle standing still'; Target = 'remove'; Open = @($charging); Motion = $still; Expect = $null }
        @{ Name = 'nothing open'; Target = 'set'; Open = @(); Motion = $null; Expect = $null })
    foreach ($case in $refusalCases) {
        $r = Invoke-Captured { Get-V2RecoveryJourneyRefusal -Open $case.Open -RecoveryJourney $case['Rj'] -ReadRow ($case['Read'] ?? $readNever) -Target $case.Target -VehicleMotion $case.Motion }
        $got = $r.Error ? "THREW: $($r.Error)" : ($r.Text ? $r.Text : $null)
        $has = @($case['Has'] | Where-Object { $_ } | Where-Object { $null -eq $got -or -not $got.Contains($_) })
        $hasNot = @($case['HasNot'] | Where-Object { $_ } | Where-Object { $null -ne $got -and $got.Contains($_) })
        Write-Result -Ok ($has.Count -eq 0 -and $hasNot.Count -eq 0 -and ($null -eq $case.Expect ? ($null -eq $got) : ($null -ne $got -and $got.StartsWith("$($case.Expect):") -and $got.EndsWith('Nothing was changed.')))) `
            -Name "journey refusal by vehicle (8005-workspace#68): $($case.Name) -> $($case.Expect ?? 'allowed')" -Detail "got: $got missing: $($has -join ', ') unwanted: $($hasNot -join ', ')"
    }

    Write-Result -Ok $haveSqlite -Name 'Microsoft.Data.Sqlite and SQLitePCLRaw are in the NuGet cache (the journey reader needs them)' -Detail "looked under $nuget"
    if ($haveSqlite) {
        Set-Config
        $wantAfter = { param([string] $Mode, [string] $Proof = $testProof) ($Mode -eq 'set') ? (($baseEnvironment + "CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=$Proof") -join "`n") : ($baseEnvironment -join "`n") }
        foreach ($req in @(@{ mode = 'set'; proof = $testProof }, @{ mode = 'remove' })) {
            $env0 = ($req.mode -eq 'set') ? $baseEnvironment : $withEntry
            New-Database @('Completed', 'Dispatched')
            # 8005-workspace#68: a journey not Completed holds the restart only when its vehicle may be under way.
            $riotNow.Moving.Clear(); $null = $riotNow.Moving.Add('K')
            Assert-Refused (New-ServerRig -Environment $env0) $req 'JOURNEYS_IN_PROGRESS' 'a journey not Completed on a vehicle RIoT shows moving (a real SQLite store)'
            Assert-Refused (New-ServerRig -Environment $env0) ($req + @{ allowConnectedVehicles = $true }) 'JOURNEYS_IN_PROGRESS' 'a journey not Completed on a vehicle RIoT shows moving, with allowConnectedVehicles'
            $riotNow.Moving.Clear()
            $riotNow.Orders.Add([ordered]@{ id = 7; orderId = 'o-7'; upperId = 'u-7'; orderState = 3; appointVehicleKey = 'K'; executeVehicleKey = 'K' })
            Assert-Refused (New-ServerRig -Environment $env0) $req 'RIOT_NONFINAL_ORDER_PRESENT' 'a journey not Completed on a vehicle standing with an unfinished RIoT order'
            $riotNow.Orders.Clear()
            New-Database @('Completed', 'Dispatched') -FaultedAgvIds @('car')
            Assert-Refused (New-ServerRig -Environment $env0) $req 'VEHICLE_FAULT' 'a journey not Completed on a vehicle standing still but holding a fault'
            New-Database @('Completed', 'Dispatched')
            $riotNow.Calls.Clear()
            $rig = New-ServerRig -Environment $env0
            $r = Invoke-Server $rig $req
            Write-Result -Ok ($null -eq $r.Error -and ((Read-Rig $rig) -join "`n") -ceq (& $wantAfter $req.mode) -and ($rig.Events -join ';') -ceq 'write' -and
                $riotNow.Calls -ccontains '/api/task/v1/task/getVehicleInfo/K') `
                -Name "server $($req.mode) (8005-workspace#68): a journey not Completed on a vehicle RIoT shows standing still (one on its charger, say) -- passes, written" -Detail ($r.All + ' events: ' + ($rig.Events -join ';') + ' riot: ' + ($riotNow.Calls -join ' | '))
            Write-Result -Ok (-not (Test-ServerLeak $r)) -Name "... and server $($req.mode) prints neither the proof nor the RIoT key nor any other entry value" -Detail ''
        }
        # ---- a named recovery journey (8005-workspace#58), against a real SQLite store ----
        $target = @{ journeyId = 'j-target'; agvId = 'car3'; vehicleKey = 'K3' }
        $stuck = @{ Id = 'j-target'; Stage = 'Blocked'; Block = 'LOAD_RESULT_REQUIRES_RECOVERY'; AgvId = 'car3'; VehicleKey = 'K3' }
        $withTarget = { param([hashtable] $req) $req + @{ recoveryJourney = $target } }
        foreach ($req in @(@{ mode = 'set'; proof = $testProof }, @{ mode = 'remove' })) {
            $env0 = ($req.mode -eq 'set') ? $baseEnvironment : $withEntry
            $riotNow.Moving.Clear()
            Set-Config
            New-Database @('Completed', 'Completed') -Journeys @($stuck)
            $rig = New-ServerRig -Environment $env0
            $r = Invoke-Server $rig (& $withTarget $req)
            $line = ($req.mode -eq 'set') ? 'RECOVERY_JOURNEY=j-target awaits recovery on car3' : 'RECOVERY_JOURNEY=j-target named'
            Write-Result -Ok ($null -eq $r.Error -and ((Read-Rig $rig) -join "`n") -ceq (& $wantAfter $req.mode) -and ($rig.Events -join ';') -ceq 'write' -and $r.Text.Contains($line)) `
                -Name "server $($req.mode) with recoveryJourney: the target Blocked on LOAD_RESULT_REQUIRES_RECOVERY, the rest Completed -- passes, written" -Detail ($r.All + ' events: ' + ($rig.Events -join ';'))
            Write-Result -Ok (-not (Test-ServerLeak $r)) -Name "... and server $($req.mode) prints no proof and no other entry value" -Detail ''
            $rig = New-ServerRig -Environment $env0
            $r = Invoke-Server $rig @{ mode = 'check'; target = $req.mode; recoveryJourney = $target; proof = $testProof }
            Write-Result -Ok ($r.Text -match 'CHECK_PASSED' -and $rig.Events.Count -eq 0) -Name "server check ($($req.mode)) with recoveryJourney: passes, writes nothing" -Detail $r.All

            # The same stuck journey not named: before 8005-workspace#68 it refused like any journey in progress; now its
            # vehicle is asked, and only a vehicle that may be under way refuses.
            $null = $riotNow.Moving.Add('K3')
            Assert-Refused (New-ServerRig -Environment $env0) $req 'JOURNEYS_IN_PROGRESS' 'the same stuck journey without recoveryJourney, its vehicle moving'
            $riotNow.Moving.Clear()
            $r = Invoke-Server (New-ServerRig -Environment $env0) @{ mode = 'check'; target = $req.mode; proof = $testProof }
            Write-Result -Ok ($r.Text -match 'CHECK_PASSED') -Name "server check ($($req.mode)) without recoveryJourney (8005-workspace#68): the stuck journey's vehicle standing still passes" -Detail $r.All
            # Another journey not Completed: it refuses through its vehicle, and only then.
            New-Database @('Completed', 'Dispatched') -Journeys @($stuck)
            $null = $riotNow.Moving.Add('K')
            Assert-Refused (New-ServerRig -Environment $env0) (& $withTarget $req) ($req.mode -eq 'set' ? 'RECOVERY_JOURNEY_NOT_ALONE' : 'JOURNEYS_IN_PROGRESS') 'recoveryJourney with another journey not Completed on a vehicle RIoT shows moving'
            $riotNow.Moving.Clear()
            $r = Invoke-Server (New-ServerRig -Environment $env0) @{ mode = 'check'; target = $req.mode; recoveryJourney = $target; proof = $testProof }
            Write-Result -Ok ($r.Text -match 'CHECK_PASSED') -Name "server check ($($req.mode)) with recoveryJourney (8005-workspace#68): another journey not Completed on a vehicle standing still passes" -Detail $r.All
            New-Database @('Completed') -Journeys @($stuck)
            $null = $riotNow.Moving.Add('K3')
            Assert-Refused (New-ServerRig -Environment $env0) ($req + @{ recoveryJourney = @{ journeyId = 'j-other'; agvId = 'car3'; vehicleKey = 'K3' } }) ($req.mode -eq 'set' ? 'RECOVERY_JOURNEY_NOT_ALONE' : 'JOURNEYS_IN_PROGRESS') 'recoveryJourney naming another journey than the stuck one, whose vehicle moves'
            $riotNow.Moving.Clear()
            # Opening checks the named journey; closing (8005-workspace#68, the field's instance 1 of 2026-10-21) does not.
            $named = @(
                @{ Label = 'on another vehicle'; Journey = $(& { $j = $stuck.Clone(); $j.AgvId = 'car2'; $j.VehicleKey = 'K2'; $j }); Expect = 'RECOVERY_JOURNEY_VEHICLE_MISMATCH' }
                @{ Label = 'with the right agvId but another vehicleKey'; Journey = $(& { $j = $stuck.Clone(); $j.VehicleKey = 'K2'; $j }); Expect = 'RECOVERY_JOURNEY_VEHICLE_MISMATCH' }
                @{ Label = 'Blocked / ONBOARD_SESSION_LOST'; Journey = $(& { $j = $stuck.Clone(); $j.Block = 'ONBOARD_SESSION_LOST'; $j }); Expect = 'RECOVERY_JOURNEY_NOT_AWAITING_RECOVERY' }
                @{ Label = 'Blocked / LoadCompensationResult_NOT_RECONCILED_ON_ENDED_DEMAND'; Journey = $(& { $j = $stuck.Clone(); $j.Block = 'LoadCompensationResult_NOT_RECONCILED_ON_ENDED_DEMAND'; $j }); Expect = 'RECOVERY_JOURNEY_NOT_AWAITING_RECOVERY' }
                @{ Label = 'AwaitingLoadResult / LOAD_RESULT_REQUIRES_RECOVERY'; Journey = $(& { $j = $stuck.Clone(); $j.Stage = 'AwaitingLoadResult'; $j }); Expect = 'RECOVERY_JOURNEY_NOT_AWAITING_RECOVERY' }
                @{ Label = 'Blocked / no reason'; Journey = $(& { $j = $stuck.Clone(); $j.Block = $null; $j }); Expect = 'RECOVERY_JOURNEY_NOT_AWAITING_RECOVERY' })
            foreach ($case in $named) {
                New-Database @('Completed') -Journeys @($case.Journey)
                if ($req.mode -eq 'set') {
                    Assert-Refused (New-ServerRig -Environment $env0) (& $withTarget $req) $case.Expect "recoveryJourney $($case.Label)"
                } else {
                    $rig = New-ServerRig -Environment $env0
                    $r = Invoke-Server $rig (& $withTarget $req)
                    Write-Result -Ok ($null -eq $r.Error -and ((Read-Rig $rig) -join "`n") -ceq (& $wantAfter 'remove') -and ($rig.Events -join ';') -ceq 'write') `
                        -Name "server remove with recoveryJourney $($case.Label) (8005-workspace#68): the window is closed regardless, written" -Detail ($r.All + ' events: ' + ($rig.Events -join ';'))
                }
            }
            # The other checks still hold with a named journey.
            New-Database @('Completed') -Journeys @($stuck)
            Set-Config -Gate 'true'
            Assert-Refused (New-ServerRig -Environment $env0) (& $withTarget $req) 'UPGRADE_REFUSED_DISPATCH_OPEN' 'recoveryJourney with the dispatch gate open'
            Set-Config
            Assert-Refused (New-ServerRig -Environment ([string[]] ($env0 + 'RiotCreateDispatch__enabled=true'))) (& $withTarget $req) 'DISPATCH_GATE_OVERRIDDEN' 'recoveryJourney with a RiotCreateDispatch__ override'
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
            $busyPort = $listener.LocalEndpoint.Port
            $client = [Net.Sockets.TcpClient]::new(); $client.Connect([Net.IPAddress]::Loopback, $busyPort); $accepted = $listener.AcceptTcpClient()
            try {
                Assert-Refused (New-ServerRig -Environment $env0 -Port $busyPort) (& $withTarget $req) 'CONNECTED_VEHICLES: ' 'recoveryJourney with a connected vehicle'
            } finally { $accepted.Dispose(); $client.Dispose(); $listener.Stop() }
            Assert-Refused (New-ServerRig -Environment $env0) ($req + @{ recoveryJourney = @{ journeyId = 'j-target' } }) 'REQUEST_RECOVERY_JOURNEY_MALFORMED' 'a recoveryJourney without agvId and vehicleKey'
        }
        foreach ($block in 'UNLOAD_RESULT_REQUIRES_RECOVERY', 'LoadCompensationResult_NOT_RECONCILED') {
            $j = $stuck.Clone(); $j.Block = $block
            New-Database @('Completed') -Journeys @($j)
            $rig = New-ServerRig -Environment $baseEnvironment
            $r = Invoke-Server $rig @{ mode = 'check'; target = 'set'; proof = $testProof; recoveryJourney = $target }
            Write-Result -Ok ($r.Text -match 'CHECK_PASSED') -Name "server check with recoveryJourney: Blocked / $block also awaits recovery" -Detail $r.All
        }
        New-Database @('Completed')
        $rig = New-ServerRig -Environment $withEntry
        $r = Invoke-Server $rig @{ mode = 'remove'; recoveryJourney = $target }
        Write-Result -Ok ($null -eq $r.Error -and ($rig.Events -join ';') -ceq 'write' -and $r.Text -notmatch 'RECOVERY_JOURNEY=') -Name 'server remove with recoveryJourney once the journey is Completed: an idle instance, passes as before' -Detail $r.All
        $rig = New-ServerRig -Environment $baseEnvironment
        $rig.Actions.JourneyRow = { param($id) @{ Error = 'disk gone (injected)' } }
        New-Database @('Completed') -Journeys @($stuck)
        Assert-Refused $rig (& $withTarget @{ mode = 'set'; proof = $testProof }) 'JOURNEY_STATE_UNREADABLE' 'recoveryJourney whose row cannot be read (opening)'
        $rig = New-ServerRig -Environment $withEntry
        $rig.Actions.JourneyRow = { param($id) throw 'closing must not read the named row (injected)' }
        $r = Invoke-Server $rig (& $withTarget @{ mode = 'remove' })
        Write-Result -Ok ($null -eq $r.Error -and ((Read-Rig $rig) -join "`n") -ceq ($baseEnvironment -join "`n")) -Name 'server remove with recoveryJourney (8005-workspace#68): the named row is not read at all, so one that cannot be read does not hold the close' -Detail $r.All

        # ---- 8005-workspace#68: the field's instance 1 of 2026-10-21, closed clean in every state the named journey can be in ----
        # The window was opened for ed84063a|g101 (Blocked on the load result); at 12:46 the screen handed the fault cargo over,
        # the demand ended Cancelled, the session went back to Ready, and the journey went on to two more pickup stops
        # (AwaitingPickupArrival) with the gate closed. The -Revert -RecoveryJourneyId was refused then and the server entry
        # stayed behind. Each state below: the server entry goes, and the vehicle half takes the switch and the variable off.
        $instance1 = @(
            @{ Label = 'still awaiting recovery'; Journeys = @($stuck); Stages = @('Completed') }
            @{ Label = 'Completed'; Journeys = @($(& { $j = $stuck.Clone(); $j.Stage = 'Completed'; $j.Block = $null; $j })); Stages = @() }
            @{ Label = 'demand Cancelled by the fault cargo handoff, the journey on to its next pickup stops'; Journeys = @($(& { $j = $stuck.Clone(); $j.Stage = 'AwaitingPickupArrival'; $j.Block = $null; $j })); Stages = @() })
        foreach ($case in $instance1) {
            New-Database $case.Stages -Journeys $case.Journeys
            $rig = New-ServerRig -Environment $withEntry
            $r = Invoke-Server $rig (& $withTarget @{ mode = 'remove' })
            Set-Content -LiteralPath $settingsPath -Value $pristine -Encoding utf8NoBOM
            $vehicle = New-VehicleRig
            $null = Invoke-V2RecoveryWindowVehicle -Request (& $request 'Open' $testProof) -Actions $vehicle.Actions
            $closed = Invoke-Captured { Invoke-V2RecoveryWindowVehicle -Request (& $request 'Close' $null) -Actions $vehicle.Actions }
            $entryLeft = @(Read-Rig $rig | Where-Object { $_ -like 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=*' }).Count
            Write-Result -Ok ($null -eq $r.Error -and $entryLeft -eq 0 -and $null -eq $closed.Error -and (& $readSwitch) -eq $false -and $null -eq (& $variableNow)) `
                -Name "close with -RecoveryJourneyId, the named journey $($case.Label) (8005-workspace#68, field instance 1): the server entry, the switch and the vehicle variable are all gone" `
                -Detail ($r.All + ' | vehicle: ' + $closed.All)
        }
        New-Database @('Completed') -Journeys @($stuck)
        $row = Read-V2JourneyRuntimeRow -DatabasePath $databasePath -AssemblyDirectory $serverInstall -JourneyId "j-target' OR '1'='1"
        Write-Result -Ok ($row['Found'] -eq $false) -Name 'the journey row reader takes the id as a parameter, not as SQL' -Detail ($row | ConvertTo-Json -Compress)
        New-Database @('Completed')

        $rig = New-ServerRig -Environment $baseEnvironment
        $r = Invoke-Server $rig @{ mode = 'check'; target = 'set'; proof = $testProof }
        Write-Result -Ok ($r.Text -match 'CHECK_PASSED' -and $rig.Events.Count -eq 0 -and ((Read-Rig $rig) -join "`n") -ceq ($baseEnvironment -join "`n")) -Name 'server check (set): passes on an idle instance, writes nothing' -Detail $r.All
        $rig = New-ServerRig -Environment $withEntry
        $r = Invoke-Server $rig @{ mode = 'check'; target = 'remove' }
        Write-Result -Ok ($r.Text -match 'CHECK_PASSED' -and $rig.Events.Count -eq 0 -and ((Read-Rig $rig) -join "`n") -ceq ($withEntry -join "`n")) -Name 'server check (remove): passes on an idle instance, writes nothing' -Detail $r.All

        $rig = New-ServerRig -Environment $baseEnvironment
        $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
        Write-Result -Ok ($null -eq $r.Error -and ((Read-Rig $rig) -join "`n") -ceq (& $wantAfter 'set') -and ($rig.Events -join ';') -ceq 'write' -and $r.Text -match 'fingerprint unchanged') `
            -Name 'server set on a stopped service: others kept in order, entry appended, not restarted, MVP fingerprint compared' -Detail ($r.All + ' ' + ($rig.Events -join ';'))
        Write-Result -Ok (-not (Test-ServerLeak $r)) -Name 'server set prints no proof and no other entry value' -Detail ''
        $rig = New-ServerRig -Environment $withEntry
        $r = Invoke-Server $rig @{ mode = 'remove' }
        Write-Result -Ok ($null -eq $r.Error -and ((Read-Rig $rig) -join "`n") -ceq ($baseEnvironment -join "`n") -and ($rig.Events -join ';') -ceq 'write') -Name 'server remove: only the entry goes, others kept in order' -Detail ($r.All + ' ' + ($rig.Events -join ';'))
        $rig = New-ServerRig -Environment $baseEnvironment
        $r = Invoke-Server $rig @{ mode = 'remove' }
        Write-Result -Ok ($r.Text -match 'NO_CHANGE' -and $rig.Events.Count -eq 0) -Name 'server remove when absent: no write, no restart' -Detail $r.All

        if ($runningService) {
            $rig = New-ServerRig -Service $runningService -Environment $withEntry
            $r = Invoke-Server $rig @{ mode = 'set'; proof = $otherProof }
            Write-Result -Ok ($null -eq $r.Error -and ((Read-Rig $rig) -join "`n") -ceq (& $wantAfter 'set' $otherProof) -and ($rig.Events -join ';') -ceq 'write;stop with entry 1;start with entry 1') `
                -Name "server set on a running service ($runningService): replaced, others kept, stopped and started after the write" -Detail ($r.All + ' ' + ($rig.Events -join ';'))
            Write-Result -Ok (-not (Test-ServerLeak $r)) -Name '... and prints neither value' -Detail ''
            $rig = New-ServerRig -Service $runningService -Environment $withEntry
            $r = Invoke-Server $rig @{ mode = 'remove' }
            Write-Result -Ok ($null -eq $r.Error -and ($rig.Events -join ';') -ceq 'write;stop with entry 0;start with entry 0') -Name 'server remove on a running service: stopped and started after the entry is gone' -Detail ($r.All + ' ' + ($rig.Events -join ';'))
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start()
            $busyPort = $listener.LocalEndpoint.Port
            $client = [Net.Sockets.TcpClient]::new(); $client.Connect([Net.IPAddress]::Loopback, $busyPort); $accepted = $listener.AcceptTcpClient()
            try {
                $rig = New-ServerRig -Service $runningService -Environment $baseEnvironment -Port $busyPort
                $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof; allowConnectedVehicles = $true }
                Write-Result -Ok ($null -eq $r.Error -and $r.Text -match 'WARNING: CONNECTED_VEHICLES' -and ($rig.Events -join ';') -ceq 'write;stop with entry 1;start with entry 1') `
                    -Name 'server set with allowConnectedVehicles and a real connection: a warning, then write, stop and start' -Detail $r.All
            } finally { $accepted.Dispose(); $client.Dispose(); $listener.Stop() }

            # ---- 8005-workspace#68: read again after the stop. A vehicle driven off by hand in RIoT between the first read
            # and the restart is caught there: the Environment is put back as it was, the service started again, refused.
            foreach ($req in @(@{ mode = 'set'; proof = $testProof }, @{ mode = 'remove' })) {
                $env0 = ($req.mode -eq 'set') ? $baseEnvironment : $withEntry
                New-Database @('Completed', 'Dispatched')
                $riotNow.Moving.Clear()
                $rig = New-ServerRig -Service $runningService -Environment $env0
                $rig.OnStop = { $null = $riotNow.Moving.Add('K') }.GetNewClosure()
                $r = Invoke-Server $rig $req
                $entries = ($req.mode -eq 'set') ? 'write;stop with entry 1;write;start with entry 0' : 'write;stop with entry 0;write;start with entry 1'
                Write-Result -Ok ($r.Error -match '^AFTER_STOP JOURNEYS_IN_PROGRESS:' -and $r.Error.Contains('RIOT_MOTION_ACTIVE') -and ((Read-Rig $rig) -join "`n") -ceq ($env0 -join "`n") -and
                    ($rig.Events -join ';') -ceq $entries -and -not (Test-ServerLeak $r)) `
                    -Name "server $($req.mode) on a running service (8005-workspace#68): a vehicle that starts moving while the service is stopped -> refused after the stop, the Environment put back, started again" `
                    -Detail ($r.All + ' events: ' + ($rig.Events -join ';'))
                $riotNow.Moving.Clear()
            }
            New-Database @('Completed')
        }

        # The MVP fingerprint is compared: a change between before and after fails the run.
        $rig = New-ServerRig -Environment $baseEnvironment
        $calls = @{ n = 0 }
        $rig.Actions.MvpFingerprint = { $calls.n++; [ordered]@{ present = $true; processId = $calls.n } }.GetNewClosure()
        $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
        Write-Result -Ok ($r.Error -match 'The MVP service changed' -and $calls.n -eq 2) -Name 'a changed MVP fingerprint fails the run' -Detail $r.All

        # A write that does not read back: the original goes back, nothing restarts.
        $faulty = @{ Writes = 0 }
        $rig = New-ServerRig -Environment $baseEnvironment
        $path = $rig.Path
        $rig.Actions.WriteEnvironment = {
            param([string[]] $v)
            $faulty.Writes++
            Write-V2RegistryMultiString -Root $hkcu -Path $path -Value @($v | Where-Object { $faulty.Writes -gt 1 -or $_ -notlike 'CONTROL_SERVER_MES_INGEST_SHARED_SECRET=*' })
        }.GetNewClosure()
        $r = Invoke-Server $rig @{ mode = 'set'; proof = $testProof }
        Write-Result -Ok ($r.Error -match 'ENVIRONMENT_READBACK_FAILED' -and $rig.Events.Count -eq 0 -and ((Read-Rig $rig) -join "`n") -ceq ($baseEnvironment -join "`n")) `
            -Name 'a write that drops an entry is caught, the original written back, nothing restarted' -Detail $r.All
    }

    # ------------------------------------------------- control-server#564: the installed cutover ---
    Write-Host ''
    Write-Host 'The installed definition as a production cutover (control-server#564, review MW3 and S5)'
    $parallelDefinition = @{ instanceId = 'selftest' }
    $cutoverInstalled = @{ instanceId = 'selftest'; productionCutover = @{ approvalRecord = 'x'; phase = 'trial' } }
    $a = Get-V2InstalledCutoverArgument -Definition $cutoverInstalled -ModuleKnowsCutover $true
    Write-Result -Ok ($a -is [hashtable] -and $a.Count -eq 1 -and $a['ProductionCutover'] -eq $true) -Name 'an installed cutover definition is asserted with -ProductionCutover' -Detail (ConvertTo-Json $a -Compress)
    $a = Get-V2InstalledCutoverArgument -Definition $parallelDefinition -ModuleKnowsCutover $true
    Write-Result -Ok ($a -is [hashtable] -and $a.Count -eq 0) -Name 'a parallel definition is asserted without it' -Detail (ConvertTo-Json $a -Compress)
    $a = Get-V2InstalledCutoverArgument -Definition $parallelDefinition -ModuleKnowsCutover $false
    Write-Result -Ok ($a -is [hashtable] -and $a.Count -eq 0) -Name 'a parallel definition with a module from before #564: as before' -Detail (ConvertTo-Json $a -Compress)
    $r = Invoke-Captured { Get-V2InstalledCutoverArgument -Definition $cutoverInstalled -ModuleKnowsCutover $false }
    Write-Result -Ok ($r.Error -match '^CHECKOUT_PREDATES_CUTOVER:') -Name 'a cutover definition with a module from before #564 is refused, saying which checkout to use' -Detail $r.All
    if (Get-Command Test-ParallelProductionCutoverDefinition -ErrorAction SilentlyContinue) {
        $real = @{ instanceId = 'selftest'; productionCutover = @{ approvalRecord = 'x'; phase = 'trial' } }
        $a = Get-V2InstalledCutoverArgument -Definition $real -ModuleKnowsCutover $true
        Write-Result -Ok ((Test-ParallelProductionCutoverDefinition -Definition $real) -and $a['ProductionCutover'] -eq $true) -Name '... and agrees with the staged module''s own Test-ParallelProductionCutoverDefinition' -Detail (ConvertTo-Json $a -Compress)
    }
    $serverText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'server-v2-recovery-window.ps1'))
    Write-Result -Ok ($serverText.Contains('$cutoverArgument = Get-V2InstalledCutoverArgument -Definition $definition') -and
            $serverText.Contains('-ModuleKnowsCutover ((Get-Command Get-ParallelCutoverContractVersion -ErrorAction SilentlyContinue) -and (Get-ParallelCutoverContractVersion) -ge 2)') -and
            $serverText.Contains('-ForStopDirection @cutoverArgument')) `
        -Name 'the server entry asserts the installed definition with the argument Get-V2InstalledCutoverArgument gives' -Detail 'pinned text missing'

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
