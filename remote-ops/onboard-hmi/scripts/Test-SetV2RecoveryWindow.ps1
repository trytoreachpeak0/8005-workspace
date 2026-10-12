#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for 18-set-v2-recovery-window.ps1 (8005-workspace#25).

.DESCRIPTION
    Nothing here reaches a vehicle or a server, and the real secret store is never read or written.

    Part 1 runs the script itself, as `pwsh -File` the way an operator does, with ssh and scp replaced
    by fakes at the front of PATH. The fakes record every call (and what reached standard input) and
    answer with canned lines. The store is a throwaway file under a temporary directory. It pins:
      * with no -SshAlias, with agv01, with the MVP service name or install root, the script refuses
        before ssh or scp is called;
      * -WhatIf calls neither and writes no store;
      * opening checks the server first (read-only), then the vehicle, then the server entry, and a
        refused server check leaves the vehicle untouched;
      * one proof serves both vehicles; closing one keeps the server entry while the other is open,
        and closing the last removes it and deletes the store;
      * the proof reaches the machines on standard input only -- never in a staged script, a command
        line, or the script's output.

    Part 2 runs the server body in its read-only 'check' mode on this machine, against a local service
    and a configuration file in the temporary directory: missing service, dispatch gate open, gate not
    a boolean, a connected vehicle (a loopback connection) refused and, with -AllowConnectedVehicles,
    warned, a file written after the process started, and a missing proof. 'set' and 'remove' are never
    run here; that they change nothing before the same checks is pinned by the order of the text.

    Part 3: neither deployment script names the recovery variables, so neither opens the window.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/Test-SetV2RecoveryWindow.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$target = Join-Path $PSScriptRoot '18-set-v2-recovery-window.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "test-v2-recovery-window-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$fakeBin = Join-Path $work 'bin'
$staged = Join-Path $work 'staged'
$secret = Join-Path $work 'store\w2g-v2-recovery-window.xml'
$log = Join-Path $work 'ssh-log.jsonl'
New-Item -ItemType Directory -Force -Path $fakeBin, $staged | Out-Null

try {
    # ------------------------------------------------------------------ fakes ---

    # Named ssh.ps1 and scp.ps1 at the front of PATH, so the script's `& ssh` finds them before
    # ssh.exe. ssh: records alias, command and what was piped in; answers a server check with the
    # lines a passing check prints. FAKE_SSH_FAIL_MATCH makes a matching -File call exit 1.
    Set-Content -LiteralPath (Join-Path $fakeBin 'ssh.ps1') -Encoding utf8NoBOM -Value @'
$stdin = @($input) -join "`n"
[ordered]@{ alias = $args[0]; command = ($args[1..($args.Count - 1)] -join ' '); stdin = $stdin } |
    ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FAKE_SSH_LOG -Encoding utf8NoBOM
$command = $args[1..($args.Count - 1)] -join ' '
if ($command -match '-File' -and $env:FAKE_SSH_FAIL_MATCH -and $command -match $env:FAKE_SSH_FAIL_MATCH) { 'REFUSED (fake)'; exit 1 }
if ($command -match 'server-check\.ps1') { 'ENTRY=absent'; 'CONNECTED_VEHICLES=0'; 'CHECK_PASSED' }
exit 0
'@
    Set-Content -LiteralPath (Join-Path $fakeBin 'scp.ps1') -Encoding utf8NoBOM -Value @'
$source = $args[-2]
Copy-Item -LiteralPath $source -Destination (Join-Path $env:FAKE_SCP_DIR ("{0:D3}-{1}" -f @(Get-ChildItem $env:FAKE_SCP_DIR).Count, (Split-Path -Leaf $source)))
[ordered]@{ alias = ($args[-1] -split ':')[0]; command = 'scp'; stdin = '' } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FAKE_SSH_LOG -Encoding utf8NoBOM
exit 0
'@

    function Invoke-Target {
        param([string[]] $Arguments, [string] $FailMatch)
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $staged | Remove-Item -Force
        $saved = @{ PATH = $env:PATH; FAKE_SSH_LOG = $env:FAKE_SSH_LOG; FAKE_SCP_DIR = $env:FAKE_SCP_DIR; FAKE_SSH_FAIL_MATCH = $env:FAKE_SSH_FAIL_MATCH }
        try {
            $env:PATH = "$fakeBin;$env:PATH"
            $env:FAKE_SSH_LOG = $log
            $env:FAKE_SCP_DIR = $staged
            $env:FAKE_SSH_FAIL_MATCH = $FailMatch
            $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $target @Arguments -SecretPath $secret 2>&1 | ForEach-Object { "$_" }
            $exit = $LASTEXITCODE
        } finally {
            foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
        }
        $calls = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json } })
        $bodies = @(Get-ChildItem -LiteralPath $staged | Sort-Object Name | ForEach-Object { @{ Name = $_.Name; Text = [IO.File]::ReadAllText($_.FullName) } })
        return @{ Exit = $exit; Output = ($output -join "`n"); Calls = $calls; Bodies = $bodies }
    }

    function Get-StoredProof {
        if (-not (Test-Path -LiteralPath $secret)) { return $null }
        $s = Import-Clixml -LiteralPath $secret
        return @{ Proof = [Net.NetworkCredential]::new('', $s['RecoveryProof']).Password; Open = @($s['OpenVehicles']) }
    }

    # The -File runs, in order, as "alias:name".
    function Get-FileRuns($run) {
        return @($run.Calls | Where-Object { $_.command -match "-File '[^']*\\([\w-]+)\.ps1'" } |
                ForEach-Object { "$($_.alias):$([regex]::Match($_.command, "\\([\w-]+)\.ps1'").Groups[1].Value)" })
    }

    function Assert-ProofOnlyOnStdin($run, [string] $proof, [string] $label) {
        $leak = @()
        if ($run.Output.Contains($proof)) { $leak += 'script output' }
        if (@($run.Calls | Where-Object { $_.command.Contains($proof) }).Count) { $leak += 'an ssh/scp command line' }
        if (@($run.Bodies | Where-Object { $_.Text.Contains($proof) }).Count) { $leak += 'a staged script' }
        Write-Result -Ok ($leak.Count -eq 0) -Name "$label`: the proof appears in no output, command line or staged script" -Detail ($leak -join ', ')
    }

    Write-Host 'Part 1: the script, with fake ssh and scp'

    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$errors)
    Write-Result -Ok (@($errors).Count -eq 0) -Name '18-set-v2-recovery-window.ps1 parses' -Detail (@($errors) -join ' | ')

    # ------------------------------------------------------------- refusals ---

    $refusals = [ordered]@{
        'no -SshAlias'                    = @()
        '-SshAlias agv01'                 = @('-SshAlias', 'agv01')
        '-SshAlias agv01 -Revert'         = @('-SshAlias', 'agv01', '-Revert')
        'the MVP service name'            = @('-SshAlias', 'agv03', '-ServiceName', '8005 AGV ControlServer')
        'the MVP service name, other case' = @('-SshAlias', 'agv03', '-ServiceName', ' 8005 agv controlserver ')
        'the MVP install root'            = @('-SshAlias', 'agv03', '-ServerInstallRoot', 'C:\Program Files\8005 AGV\ControlServer\')
    }
    foreach ($case in $refusals.GetEnumerator()) {
        $run = Invoke-Target -Arguments $case.Value
        Write-Result -Ok ($run.Exit -ne 0 -and $run.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $secret)) `
            -Name "$($case.Key) is refused before ssh or scp is called" `
            -Detail "exit $($run.Exit), $($run.Calls.Count) call(s), store written: $(Test-Path -LiteralPath $secret)"
    }

    # --------------------------------------------------------------- WhatIf ---

    foreach ($arguments in @(@('-SshAlias', 'agv03', '-WhatIf'), @('-SshAlias', 'agv02', '-Revert', '-WhatIf'))) {
        $run = Invoke-Target -Arguments $arguments
        Write-Result -Ok ($run.Exit -eq 0 -and $run.Calls.Count -eq 0 -and -not (Test-Path -LiteralPath $secret) -and $run.Output -match 'WhatIf: stopping') `
            -Name "$($arguments -join ' '): no ssh, no scp, no store" `
            -Detail "exit $($run.Exit), $($run.Calls.Count) call(s), store written: $(Test-Path -LiteralPath $secret)`n$($run.Output)"
    }

    # ---------------------------------------------- a refused server check ---

    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03') -FailMatch 'server-check'
    $runs = Get-FileRuns $run
    Write-Result -Ok ($run.Exit -ne 0 -and ($runs -join ',') -eq 'factory01:v2-recovery-window-server-check' -and
        @($run.Calls | Where-Object { $_.alias -eq 'agv03' }).Count -eq 0) `
        -Name 'a refused server check leaves the vehicle untouched' -Detail "exit $($run.Exit); runs: $($runs -join ', ')"
    $stored = Get-StoredProof
    Write-Result -Ok ($null -ne $stored -and $stored.Open.Count -eq 0) -Name '... and records no vehicle as open' -Detail "open: $($stored.Open -join ',')"
    Remove-Item -LiteralPath $secret -Force -ErrorAction SilentlyContinue

    # ------------------------------------------------- open, open, close, close ---

    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03')
    $stored = Get-StoredProof
    $runs = Get-FileRuns $run
    Write-Result -Ok ($run.Exit -eq 0) -Name 'open agv03 succeeds against the fakes' -Detail $run.Output
    Write-Result -Ok (($runs -join ',') -eq 'factory01:v2-recovery-window-server-check,agv03:v2-recovery-window-vehicle,factory01:v2-recovery-window-server') `
        -Name 'open agv03: server check, then vehicle, then server entry' -Detail ($runs -join ', ')
    Write-Result -Ok (@($run.Calls | Where-Object { $_.alias -notin @('agv03', 'factory01') }).Count -eq 0) `
        -Name 'open agv03 reaches only agv03 and factory01' -Detail (@($run.Calls | ForEach-Object { $_.alias } | Sort-Object -Unique) -join ', ')
    Write-Result -Ok ($null -ne $stored -and $stored.Proof -match '^[0-9a-f]{64}$' -and ($stored.Open -join ',') -eq 'agv03') `
        -Name 'open agv03 stores a 64-hex proof and records agv03 open' -Detail "open: $($stored ? ($stored.Open -join ',') : '(no store)')"
    $proof = $stored.Proof
    $fileCalls = @($run.Calls | Where-Object { $_.command -match '-File' })
    Write-Result -Ok (@($fileCalls | Where-Object { $_.stdin.Trim() -ceq $proof }).Count -eq 3) `
        -Name 'open agv03: each of the three remote runs receives the stored proof on standard input' `
        -Detail "$(@($fileCalls | Where-Object { $_.stdin.Trim() -ceq $proof }).Count) of $($fileCalls.Count)"
    Write-Result -Ok (@($run.Calls | Where-Object { $_.command -notmatch '-File' -and $_.stdin }).Count -eq 0) `
        -Name 'open agv03: nothing else is sent anything on standard input' -Detail ''
    Assert-ProofOnlyOnStdin $run $proof 'open agv03'
    $serverSet = @($run.Bodies | Where-Object { $_.Name -match 'v2-recovery-window-server-\d+\.ps1$' })
    Write-Result -Ok ($serverSet.Count -eq 1 -and $serverSet[0].Text.Contains("'8005 AGV ControlServer V2'") -and
        $serverSet[0].Text.Contains('CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF=$proof')) `
        -Name 'the server body targets the V2 service and writes CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF' -Detail ''
    $vehicle = @($run.Bodies | Where-Object { $_.Name -match 'vehicle' })
    Write-Result -Ok ($vehicle.Count -eq 1 -and $vehicle[0].Text.Contains("'CONTROL_SERVER_RECOVERY_PROOF', `$proof, 'Machine'") -and
        $vehicle[0].Text.Contains('C:\8005\OnboardHmi\appsettings.json')) `
        -Name 'the vehicle body writes CONTROL_SERVER_RECOVERY_PROOF in the site install root' -Detail ''

    $run = Invoke-Target -Arguments @('-SshAlias', 'agv02')
    $stored = Get-StoredProof
    Write-Result -Ok ($run.Exit -eq 0 -and $stored.Proof -ceq $proof -and ($stored.Open -join ',') -eq 'agv02,agv03') `
        -Name 'open agv02 reuses the same proof and records both open' -Detail "open: $($stored.Open -join ',')"
    Write-Result -Ok (@($run.Calls | Where-Object { $_.command -match '-File' -and $_.stdin.Trim() -ceq $proof }).Count -eq 3) `
        -Name 'open agv02 sends that same proof to both ends' -Detail ''
    Assert-ProofOnlyOnStdin $run $proof 'open agv02'

    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    $stored = Get-StoredProof
    $runs = Get-FileRuns $run
    Write-Result -Ok ($run.Exit -eq 0 -and ($runs -join ',') -eq 'agv03:v2-recovery-window-vehicle') `
        -Name 'close agv03 while agv02 is open: the vehicle only, the server entry stays' -Detail ($runs -join ', ')
    Write-Result -Ok ($stored.Proof -ceq $proof -and ($stored.Open -join ',') -eq 'agv02') `
        -Name '... and the store keeps the proof with agv02 open' -Detail "open: $($stored.Open -join ',')"
    Write-Result -Ok (@($run.Calls | Where-Object { $_.stdin }).Count -eq 0) -Name 'a close sends no proof anywhere' -Detail ''
    $vehicle = @($run.Bodies | Where-Object { $_.Name -match 'vehicle' })
    Write-Result -Ok ($vehicle.Count -eq 1 -and $vehicle[0].Text.Contains("'CONTROL_SERVER_RECOVERY_PROOF', [NullString]::Value, 'Machine'") -and
        $vehicle[0].Text.Contains("[bool]::Parse('false')")) `
        -Name 'the closing vehicle body sets the switch false and deletes the variable' -Detail ''

    $run = Invoke-Target -Arguments @('-SshAlias', 'agv02', '-Revert')
    $runs = Get-FileRuns $run
    Write-Result -Ok ($run.Exit -eq 0 -and ($runs -join ',') -eq 'agv02:v2-recovery-window-vehicle,factory01:v2-recovery-window-server') `
        -Name 'close the last open vehicle: the vehicle, then the server entry' -Detail ($runs -join ', ')
    Write-Result -Ok (-not (Test-Path -LiteralPath $secret)) -Name '... and the store is deleted' -Detail ''
    $serverRemove = @($run.Bodies | Where-Object { $_.Name -match 'v2-recovery-window-server-\d+\.ps1$' })
    Write-Result -Ok ($serverRemove.Count -eq 1 -and $serverRemove[0].Text -notmatch 'ReadLine') `
        -Name 'the removing server body reads no proof' -Detail ''

    # A close with no store at all (an earlier hand cleanup) still closes both ends.
    $run = Invoke-Target -Arguments @('-SshAlias', 'agv03', '-Revert')
    $runs = Get-FileRuns $run
    Write-Result -Ok ($run.Exit -eq 0 -and ($runs -join ',') -eq 'agv03:v2-recovery-window-vehicle,factory01:v2-recovery-window-server') `
        -Name 'close with no store closes the vehicle and the server entry' -Detail ($runs -join ', ')

    # --------------------------------------------- Part 2: the check, for real ---

    Write-Host ''
    Write-Host "Part 2: the server body's read-only check, on this machine"

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$null)
    $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ServerBody' }, $true)
    $readProofAssignment = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$readProof' }, $true)
    . ([scriptblock]::Create($readProofAssignment.Extent.Text))
    . ([scriptblock]::Create($function.Extent.Text))
    $serverVariable = 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF'

    # Static: in every mode, every refusal comes before the first writable open of the key.
    foreach ($mode in 'check', 'set', 'remove') {
        $ServiceName = 'X'; $ServerInstallRoot = 'C:\X'; $OnboardPort = 1
        $text = New-ServerBody -Mode $mode -AllowConnected $false
        $write = $text.IndexOf('OpenSubKey(`$key, `$true)'.Replace('`', ''))
        $lastThrow = $text.LastIndexOf('throw ')
        $checkReturn = $text.IndexOf("if ('$mode' -eq 'check') { 'CHECK_PASSED'; return }")
        Write-Result -Ok ($write -gt 0 -and $lastThrow -lt $write -and $checkReturn -gt 0 -and $checkReturn -lt $write) `
            -Name "server body '$mode': every refusal and the check's return precede the registry write" -Detail "write at $write, last throw at $lastThrow, check return at $checkReturn"
    }

    $configDirectory = Join-Path $work 'server-install'
    New-Item -ItemType Directory -Force -Path $configDirectory | Out-Null
    $configPath = Join-Path $configDirectory 'appsettings.Production.json'
    function Set-Config([string] $Json) {
        [IO.File]::WriteAllText($configPath, $Json)
        [IO.File]::SetLastWriteTimeUtc($configPath, [datetime]::new(2000, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
    }
    $testProof = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()

    function Invoke-Check {
        param([string] $Service, [int] $Port, [bool] $AllowConnected, [string] $Stdin = $testProof)
        $script:ServiceName = $Service; $script:ServerInstallRoot = $configDirectory; $script:OnboardPort = $Port
        $ServiceName = $Service; $ServerInstallRoot = $configDirectory; $OnboardPort = $Port
        $bodyPath = Join-Path $work "check-$([guid]::NewGuid().ToString('N').Substring(0, 6)).ps1"
        Set-Content -LiteralPath $bodyPath -Encoding utf8NoBOM -Value (New-ServerBody -Mode 'check' -AllowConnected $AllowConnected)
        $out = $Stdin | & pwsh -NoLogo -NoProfile -NonInteractive -File $bodyPath 2>&1 | ForEach-Object { "$_" }
        return @{ Exit = $LASTEXITCODE; Output = ($out -join "`n") }
    }

    $stopped = Get-Service | Where-Object { $_.Status -eq 'Stopped' -and $_.Name -notmatch '^8005|[''"$`]' } | Select-Object -First 1
    $freePort = { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }
    $idlePort = & $freePort

    $r = Invoke-Check -Service "no-such-service-$([guid]::NewGuid().ToString('N'))" -Port $idlePort -AllowConnected $false
    Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'SERVICE_MISSING') -Name 'a missing service is refused' -Detail $r.Output

    # Inside the body too, not only in the parameter validation: a body built for the MVP service refuses
    # before it opens a key. (This machine may carry an MVP service of that name from local installs.)
    $r = Invoke-Check -Service ' 8005 AGV ControlServer' -Port $idlePort -AllowConnected $false
    Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'Refusing the MVP service') -Name 'the server body itself refuses the MVP service' -Detail $r.Output

    $r = Invoke-Check -Service $stopped.Name -Port $idlePort -AllowConnected $false -Stdin ''
    Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'PROOF_NOT_RECEIVED') -Name 'no proof on standard input is refused' -Detail $r.Output

    Set-Config '{"RiotCreateDispatch":{"enabled":true}}'
    $r = Invoke-Check -Service $stopped.Name -Port $idlePort -AllowConnected $true
    Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'DISPATCH_GATE_OPEN') -Name 'an open dispatch gate is refused, even with -AllowConnectedVehicles' -Detail $r.Output

    Set-Config '{"RiotCreateDispatch":{"enabled":"false"}}'
    $r = Invoke-Check -Service $stopped.Name -Port $idlePort -AllowConnected $false
    Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'DISPATCH_GATE_UNKNOWN') -Name 'a gate that is not a boolean is refused' -Detail $r.Output

    Set-Config '{}'
    $r = Invoke-Check -Service $stopped.Name -Port $idlePort -AllowConnected $false
    Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'DISPATCH_GATE_UNKNOWN') -Name 'a configuration without the gate is refused' -Detail $r.Output

    Set-Config '{"RiotCreateDispatch":{"enabled":false}}'
    $r = Invoke-Check -Service $stopped.Name -Port $idlePort -AllowConnected $false
    Write-Result -Ok ($r.Exit -eq 0 -and $r.Output -match 'ENTRY=absent' -and $r.Output -match 'CHECK_PASSED' -and -not $r.Output.Contains($testProof)) `
        -Name 'gate closed, stopped service, nothing connected: the check passes and prints no value' -Detail $r.Output

    # A vehicle connected: a loopback connection on the "onboard port".
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $busyPort = $listener.LocalEndpoint.Port
    $client = [Net.Sockets.TcpClient]::new()
    $client.Connect([Net.IPAddress]::Loopback, $busyPort)
    $accepted = $listener.AcceptTcpClient()
    try {
        $r = Invoke-Check -Service $stopped.Name -Port $busyPort -AllowConnected $false
        Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'CONNECTED_VEHICLES: ') -Name 'a connected vehicle is refused' -Detail $r.Output
        $r = Invoke-Check -Service $stopped.Name -Port $busyPort -AllowConnected $true
        Write-Result -Ok ($r.Exit -eq 0 -and $r.Output -match 'WARNING: CONNECTED_VEHICLES' -and $r.Output -match 'CHECK_PASSED') `
            -Name 'with -AllowConnectedVehicles it is a warning' -Detail $r.Output
    } finally {
        $accepted.Dispose(); $client.Dispose(); $listener.Stop()
    }

    # A file written after the running process started. Needs a running service whose process start time
    # this account can read; skipped, and said so, when there is none.
    $running = Get-CimInstance Win32_Service -Filter "State='Running'" | Where-Object {
        $_.ProcessId -and $_.Name -notmatch '^8005|[''"$`]' -and (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue)?.StartTime } | Select-Object -First 1
    if ($running) {
        [IO.File]::WriteAllText($configPath, '{"RiotCreateDispatch":{"enabled":false}}')
        $r = Invoke-Check -Service $running.Name -Port $idlePort -AllowConnected $false
        Write-Result -Ok ($r.Exit -ne 0 -and $r.Output -match 'CONFIGURATION_CHANGED_SINCE_START') -Name "a file written after the process started is refused ($($running.Name))" -Detail $r.Output
        Set-Config '{"RiotCreateDispatch":{"enabled":false}}'
        $r = Invoke-Check -Service $running.Name -Port $idlePort -AllowConnected $false
        Write-Result -Ok ($r.Exit -eq 0 -and $r.Output -match 'CHECK_PASSED') -Name "an older file under a running service passes ($($running.Name))" -Detail $r.Output
    } else {
        $script:Skipped++
        Write-Host '  SKIP  the start-time check: no running service with a readable process start time' -ForegroundColor Yellow
    }

    # ------------------------------------------ Part 3: deployments stay shut ---

    Write-Host ''
    Write-Host 'Part 3: no deployment script opens the window'
    $remoteOps = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    foreach ($relative in 'onboard-hmi\scripts\06-deploy-onboard-hmi.ps1', 'factory-server\scripts\19-deploy-control-server-parallel.ps1') {
        $text = [IO.File]::ReadAllText((Join-Path $remoteOps $relative))
        $named = @('CONTROL_SERVER_RECOVERY_PROOF', 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF', 'recoveryResumeEnabled' | Where-Object { $text.Contains($_) })
        Write-Result -Ok ($named.Count -eq 0) -Name "$relative names no recovery variable and does not touch the switch" -Detail ($named -join ', ')
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$colour = $script:Failed ? 'Red' : 'Green'
Write-Host ("{0} passed, {1} failed, {2} skipped" -f $script:Passed, $script:Failed, $script:Skipped) -ForegroundColor $colour
exit ($script:Failed ? 1 : 0)
