#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for 15-deploy-control-server.ps1's release-run gate (8005-workspace#10).

.DESCRIPTION
    Drives the deployment script in a child pwsh, always with -WhatIf, with gh, ssh and scp replaced
    by functions of the same name (a function shadows a native command of the same name). The gh
    stand-in answers from a per-case scenario -- the run object `gh api` returns, and the artifact
    `gh run download` produces -- and records every call. ssh, scp, Invoke-WebRequest and
    Find-NetRoute record the call and throw. GH_HOST points at an invalid host and SshAlias at a
    name that resolves nowhere, so even a stand-in that failed to shadow could not reach GitHub or
    the factory server.

    What it pins:
      * without -RunId the script refuses, and neither picks a run itself nor downloads;
      * a run on a v2 branch (fp/v2-impl, field/cs*) is refused before any download, and the
        refusal names the run, its branch and its commit;
      * a successful release.yml run on ControlServer_MVP or field/agv01-* reaches the WhatIf stop;
      * a package whose release-manifest.json names another ControlServer commit than the run's
        head is refused, and before anything reaches the server;
      * a run of another workflow file, or an unsuccessful run, is refused before any download;
      * -PackagePath still deploys a local package without asking GitHub anything.

.PARAMETER ScriptPath
    The deployment script under test. Defaults to the sibling 15-deploy-control-server.ps1; pass
    an older copy to watch the cases go red.

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/control-server/Test-DeployControlServer.ps1
#>
[CmdletBinding()]
param(
    [string] $ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '15-deploy-control-server.ps1')
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

$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$work = Join-Path ([IO.Path]::GetTempPath()) "test-deploy-control-server-$PID"
New-Item -ItemType Directory -Path $work -Force | Out-Null

# A secret store with throwaway values, so the script gets past its secret check. DPAPI-protected
# like the real one, but it lives and dies in $work.
$secretPath = Join-Path $work 'secrets.xml'
@{
    RiotCallApiKey = ConvertTo-SecureString 'selftest-riot' -AsPlainText -Force
    OnboardCredential = ConvertTo-SecureString 'selftest-onboard' -AsPlainText -Force
} | Export-Clixml -LiteralPath $secretPath

# Runs inside the child. Everything the stand-ins need comes from the scenario file; every call
# they see goes to calls.log, one line each.
$driver = @'
param([string] $ScenarioPath)
$ErrorActionPreference = 'Stop'
$scenario = Get-Content -Raw -LiteralPath $ScenarioPath | ConvertFrom-Json
$callLog = $scenario.CallLog
$env:GH_HOST = 'selftest.invalid'
$env:GH_TOKEN = 'selftest-not-a-token'

function Add-Call { param([string] $Line) Add-Content -LiteralPath $callLog -Value $Line -WhatIf:$false }

function gh {
    # The caller runs under -WhatIf, and preference variables are dynamically scoped.
    $WhatIfPreference = $false
    Add-Call ("gh " + ($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'api' -and $args[1] -match '/actions/runs/(\d+)$') {
        $run = $scenario.Runs.PSObject.Properties[$Matches[1]]
        if ($null -eq $run) { $global:LASTEXITCODE = 1; return }
        return ($run.Value | ConvertTo-Json -Compress)
    }
    if ($args[0] -eq 'run' -and $args[1] -eq 'list') {
        # What the pre-#10 script asked: the newest successful release run in the repository.
        return $scenario.NewestRunId
    }
    if ($args[0] -eq 'run' -and $args[1] -eq 'download') {
        $id = $args[2]
        $dir = $args[[array]::IndexOf($args, '--dir') + 1]
        $artifact = Join-Path $dir "WireToGate-selftest-$id"
        $content = Join-Path $dir "content-$id"
        New-Item -ItemType Directory -Path $artifact, $content -Force | Out-Null
        $manifest = @{ components = @{
                controlServer = @{ commit = $scenario.ManifestCommit }
                onboardHmi = @{ commit = 'a52cb9af00000000000000000000000000000000' } } } | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath (Join-Path $content 'release-manifest.json') -Value $manifest
        Set-Content -LiteralPath (Join-Path $content 'payload.txt') -Value "run $id"
        $zip = Join-Path $artifact "WireToGate-selftest-$id.zip"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($content, $zip)
        Remove-Item -LiteralPath $content -Recurse -Force
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$zip.sha256" -Value "$hash *$(Split-Path -Leaf $zip)"
        Set-Content -LiteralPath (Join-Path $artifact 'release-manifest.json') -Value $manifest
        return
    }
    $global:LASTEXITCODE = 1
}
function ssh { Add-Call ("ssh " + ($args -join ' ')); throw 'self-test: ssh is forbidden' }
function scp { Add-Call ("scp " + ($args -join ' ')); throw 'self-test: scp is forbidden' }
function Invoke-WebRequest { Add-Call 'Invoke-WebRequest'; throw 'self-test: Invoke-WebRequest is forbidden' }
function Find-NetRoute { Add-Call 'Find-NetRoute'; throw 'self-test: Find-NetRoute is forbidden' }

$arguments = @{}
foreach ($p in $scenario.Arguments.PSObject.Properties) { $arguments[$p.Name] = $p.Value }
$errorText = $null
try {
    & $scenario.ScriptPath @arguments -WhatIf *>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $scenario.OutputLog -WhatIf:$false
} catch {
    $errorText = $_.Exception.Message
}
@{ Error = $errorText } | ConvertTo-Json | Set-Content -LiteralPath $scenario.ResultPath -WhatIf:$false
'@
$driverPath = Join-Path $work 'driver.ps1'
Set-Content -LiteralPath $driverPath -Value $driver

$mvpSha = '670bdd45f1a2b3c4d5e6f708192a3b4c5d6e7f80'
$fieldSha = 'e896b4b1cadf72ea25fc823804a631dfff325b6c'
$v2Sha = 'e03d8e8b34aabbccddeeff00112233445566778a'
$fieldV2Sha = '2fe490d738630212a4a73b99345d0739402672a8'
function New-Run {
    param([string] $Branch, [string] $Sha, [string] $Path = '.github/workflows/release.yml', [string] $Conclusion = 'success')
    @{ head_branch = $Branch; head_sha = $Sha; path = $Path; conclusion = $Conclusion; status = 'completed'; name = 'release' }
}
$runs = @{
    '101' = New-Run -Branch 'ControlServer_MVP' -Sha $mvpSha
    '102' = New-Run -Branch 'field/agv01-670bdd45' -Sha $fieldSha
    '201' = New-Run -Branch 'fp/v2-impl' -Sha $v2Sha
    '202' = New-Run -Branch 'field/cs566-v3-2fe490d7' -Sha $fieldV2Sha
    '301' = New-Run -Branch 'ControlServer_MVP' -Sha $mvpSha -Path '.github/workflows/l2.yml'
    '302' = New-Run -Branch 'ControlServer_MVP' -Sha $mvpSha -Conclusion 'failure'
}

$caseNumber = 0
function Invoke-Case {
    param([hashtable] $Arguments, [string] $ManifestCommit, [string] $NewestRunId = '201')
    $script:caseNumber++
    $dir = Join-Path $work "case-$script:caseNumber"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $scenario = @{
        ScriptPath = $ScriptPath
        Arguments = $Arguments + @{ SecretPath = $secretPath; SshAlias = 'selftest-no-such-host.invalid' }
        Runs = $runs
        NewestRunId = $NewestRunId
        ManifestCommit = $ManifestCommit
        CallLog = Join-Path $dir 'calls.log'
        OutputLog = Join-Path $dir 'output.log'
        ResultPath = Join-Path $dir 'result.json'
    }
    $scenarioPath = Join-Path $dir 'scenario.json'
    $scenario | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $scenarioPath
    $childOutput = & pwsh -NoProfile -NonInteractive -File $driverPath -ScenarioPath $scenarioPath 2>&1
    $calls = @(if (Test-Path -LiteralPath $scenario.CallLog) { Get-Content -LiteralPath $scenario.CallLog })
    $output = @(if (Test-Path -LiteralPath $scenario.OutputLog) { Get-Content -LiteralPath $scenario.OutputLog })
    $result = if (Test-Path -LiteralPath $scenario.ResultPath) { Get-Content -Raw -LiteralPath $scenario.ResultPath | ConvertFrom-Json } else { $null }
    [pscustomobject]@{
        Error = $result ? $result.Error : "driver produced no result: $($childOutput -join ' ')"
        Calls = $calls
        Downloaded = @($calls | Where-Object { $_ -like 'gh run download*' }).Count -gt 0
        Picked = @($calls | Where-Object { $_ -like 'gh run list*' }).Count -gt 0
        Remote = @($calls | Where-Object { $_ -match '^(ssh|scp|Invoke-WebRequest|Find-NetRoute)' }).Count -gt 0
        ReachedWhatIfStop = [bool]($output -match 'WhatIf: stopping before the server is touched')
    }
}
function Format-Case { param($Case) "error: $($Case.Error); calls: $($Case.Calls -join ' | ')" }

Write-Host "15-deploy-control-server.ps1 release-run gate ($ScriptPath)" -ForegroundColor Cyan
try {
    # 1. No -RunId: refused, nothing picked, nothing downloaded. The newest run is a v2 one, as on
    #    2026-10-10 (run 38040930792 on field/cs566-v3-2fe490d7).
    $c = Invoke-Case -Arguments @{} -ManifestCommit $fieldV2Sha -NewestRunId '202'
    Write-Result -Ok ($c.Error -match 'RunId' -and -not $c.Picked -and -not $c.Downloaded -and -not $c.Remote) `
        -Name 'without -RunId the script refuses, picks no run and downloads nothing' -Detail (Format-Case $c)

    # 2. v2 branches: refused before the download, naming run, branch and commit.
    foreach ($id in @('201', '202')) {
        $run = $runs[$id]
        $c = Invoke-Case -Arguments @{ RunId = $id } -ManifestCommit $run.head_sha
        Write-Result -Ok ($null -ne $c.Error -and $c.Error.Contains($id) -and $c.Error.Contains($run.head_branch) -and
                $c.Error.Contains($run.head_sha) -and -not $c.Downloaded -and -not $c.Remote) `
            -Name "a run on $($run.head_branch) is refused before the download, naming run, branch and commit" -Detail (Format-Case $c)
    }

    # 3. MVP branches: through to the WhatIf stop, with the run read back and the package downloaded.
    foreach ($id in @('101', '102')) {
        $run = $runs[$id]
        $c = Invoke-Case -Arguments @{ RunId = $id } -ManifestCommit $run.head_sha
        Write-Result -Ok ($null -eq $c.Error -and $c.ReachedWhatIfStop -and $c.Downloaded -and -not $c.Remote) `
            -Name "a successful release.yml run on $($run.head_branch) reaches the WhatIf stop" -Detail (Format-Case $c)
    }

    # 4. Manifest commit differs from the run's head: refused after the download, before the server.
    $c = Invoke-Case -Arguments @{ RunId = '101' } -ManifestCommit $v2Sha
    Write-Result -Ok ($null -ne $c.Error -and $c.Error.Contains($v2Sha) -and $c.Error.Contains($mvpSha) -and
            -not $c.ReachedWhatIfStop -and -not $c.Remote) `
        -Name 'a package whose manifest names another ControlServer commit than the run is refused' -Detail (Format-Case $c)

    # 5. Another workflow file, and an unsuccessful release run: refused before the download.
    $c = Invoke-Case -Arguments @{ RunId = '301' } -ManifestCommit $mvpSha
    Write-Result -Ok ($null -ne $c.Error -and $c.Error.Contains('l2.yml') -and -not $c.Downloaded -and -not $c.Remote) `
        -Name 'a run of a workflow other than release.yml is refused before the download' -Detail (Format-Case $c)
    $c = Invoke-Case -Arguments @{ RunId = '302' } -ManifestCommit $mvpSha
    Write-Result -Ok ($null -ne $c.Error -and $c.Error.Contains('failure') -and -not $c.Downloaded -and -not $c.Remote) `
        -Name 'an unsuccessful release run is refused before the download' -Detail (Format-Case $c)

    # 6. The local path is unchanged: no GitHub call at all.
    $local = Join-Path $work 'local'
    New-Item -ItemType Directory -Path (Join-Path $local 'content') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $local 'content\payload.txt') -Value 'local'
    $localZip = Join-Path $local 'WireToGate-local.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $local 'content'), $localZip)
    Set-Content -LiteralPath "$localZip.sha256" -Value "$((Get-FileHash -LiteralPath $localZip -Algorithm SHA256).Hash.ToLowerInvariant()) *WireToGate-local.zip"
    $c = Invoke-Case -Arguments @{ PackagePath = $localZip } -ManifestCommit $mvpSha
    Write-Result -Ok ($null -eq $c.Error -and $c.ReachedWhatIfStop -and @($c.Calls | Where-Object { $_ -like 'gh *' }).Count -eq 0 -and -not $c.Remote) `
        -Name '-PackagePath deploys a local package without asking GitHub' -Detail (Format-Case $c)
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
