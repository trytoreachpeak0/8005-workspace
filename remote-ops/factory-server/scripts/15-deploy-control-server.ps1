#Requires -Version 7
<#
.SYNOPSIS
    Deploys the ControlServer half of a WIRE_TO_GATE release package to the
    factory server. Runs on the control host.

.DESCRIPTION
    The delivery half of the CD path. CI builds and verifies the joint package
    but deploys nothing; this script carries the server half the last hop:

        GitHub artifact -> control host -> scp -> factory01 -> install

    That shape is the same one 13-deploy-mes-ingest-server.ps1 already uses, and
    for the same reason. The runner lives on win11-01, a Hyper-V guest of the
    factory server; giving it an SSH key into its own host would mean any code
    that reaches that runner reaches the production AGV stack. Routing through
    the control host keeps a human in the path without making the deployment
    manual.

    The onboard half of the same package goes to the vehicles with
    remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1. Deploy the server
    first: the onboard client needs a reachable projection endpoint before it
    will leave RecoveryRequired.

.PARAMETER RunId
    GitHub Actions run to deploy. Omit to take the most recent successful
    `release` run.

.PARAMETER PackagePath
    Deploy a zip already on disk instead of downloading one. The matching
    .sha256 file must sit beside it.

.PARAMETER Rollback
    Swap the previous package back in on the server. Downloads nothing.

.PARAMETER ListenAddress
    Address the onboard NDJSON transport binds. The default is the server's
    em4 address -- the interface that carries the plant network -- rather than
    0.0.0.0, which would also expose the service on the Hyper-V internal switch
    where the CI runner lives.

.PARAMETER WhatIf
    Stage and verify everything, print the remote command, and stop before
    touching the server.

.EXAMPLE
    ./15-deploy-control-server.ps1

.EXAMPLE
    ./15-deploy-control-server.ps1 -RunId 12345678

.EXAMPLE
    ./15-deploy-control-server.ps1 -Rollback
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Download')]
param(
    [Parameter(ParameterSetName = 'Download')]
    [string] $RunId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [string] $PackagePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch] $Rollback,

    [string] $SshAlias = 'factory01',

    [string] $Repository = 'trytoreachpeak0/8005-agv-control-server',

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\control-server-deployment.xml'),

    [string] $PackageRoot = 'D:\zhengyushao\ControlServer',

    [string] $OpsRoot = 'D:\zhengyushao\control-server-ops',

    [string] $StagingRoot = 'D:\zhengyushao\control-server-staging',

    [string] $ListenAddress = '172.19.205.222',

    [string] $HealthBindAddress = '172.19.205.222',

    [ValidateRange(1, 65535)]
    [int] $OnboardPort = 58005,

    [ValidateRange(1, 65535)]
    [int] $HealthPort = 58007
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$scriptRoot = $PSScriptRoot
$installerSource = Join-Path $scriptRoot 'control-server\Install-ControlServerRemote.ps1'
# .Replace rather than -replace: the right-hand side of -replace is a regular
# expression, where a lone backslash is an error rather than a backslash.
$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Invoke-Ssh {
    param([string[]] $Arguments)
    $output = & ssh $SshAlias @Arguments 2>&1
    $output | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed (exit $LASTEXITCODE)" }
    return $output
}

# The remote side reads pwsh through a temporary file rather than an inline
# -Command: quoting a PowerShell expression through bash, ssh and pwsh in one
# line is a reliable source of silently mangled arguments.
function Invoke-RemoteScript {
    param([string] $LocalPath, [string[]] $ArgumentList)
    $remote = "$OpsRoot\$(Split-Path -Leaf $LocalPath)"
    & scp -q $LocalPath "${SshAlias}:$(& $toPosix $remote)"
    if ($LASTEXITCODE -ne 0) { throw "scp of $LocalPath failed (exit $LASTEXITCODE)" }
    $quoted = $ArgumentList | ForEach-Object {
        if ($_ -match '^-\w' -or $_ -notmatch '\s') { $_ } else { "'$_'" }
    }
    Invoke-Ssh @("pwsh -NoProfile -File `"$remote`" $($quoted -join ' ')")
}

Write-Step "ControlServer deployment to $SshAlias"

# ------------------------------------------------------------------ rollback ---

if ($Rollback) {
    if (-not $PSCmdlet.ShouldProcess($SshAlias, 'Roll back ControlServer to the previous package')) { return }
    Invoke-RemoteScript -LocalPath $installerSource -ArgumentList @(
        '-Rollback'
        '-PackageRoot', $PackageRoot
    )
    Write-Step 'Rollback complete.'
    Write-Step 'The onboard half was NOT rolled back. The two ends do not negotiate'
    Write-Step 'versions -- roll the vehicles back too, or they will simply stop connecting.'
    return
}

# ------------------------------------------------------------------- secrets ---

if (-not (Test-Path -LiteralPath $SecretPath)) {
    throw "No secret store at $SecretPath. Run control-server\Set-ControlServerSecret.ps1 -Import first."
}
$secrets = Import-Clixml -LiteralPath $SecretPath
foreach ($key in @('RiotCallApiKey', 'OnboardCredential')) {
    if (-not $secrets.ContainsKey($key) -or -not $secrets[$key]) {
        throw "Secret '$key' is missing from $SecretPath. Run Set-ControlServerSecret.ps1."
    }
}
$plain = @{}
foreach ($key in @('RiotCallApiKey', 'OnboardCredential', 'MesIngestSharedSecret')) {
    if ($secrets.ContainsKey($key) -and $secrets[$key]) {
        $plain[$key] = [System.Net.NetworkCredential]::new('', $secrets[$key]).Password
    }
}
Write-Step 'Secrets loaded from the DPAPI store'

# ------------------------------------------------------------------- package ---

# -WhatIf:$false on every local staging operation below. SupportsShouldProcess
# puts the whole script into WhatIf mode, which would otherwise skip creating
# this directory and then fail reading from it. WhatIf here means "do not touch
# the server", not "do not use a scratch directory" -- and staging for real is
# what lets the dry run verify the hash and render the config.
$localStage = Join-Path $env:TEMP "control-server-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $localStage -Force -WhatIf:$false | Out-Null

try {
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        $zip = (Resolve-Path -LiteralPath $PackagePath).Path
        Write-Step "Using local package $zip"
    } else {
        if (-not $RunId) {
            Write-Step "Finding the most recent successful release run in $Repository"
            $RunId = & gh run list --repo $Repository --workflow release.yml `
                --status success --limit 1 --json databaseId --jq '.[0].databaseId'
            if ($LASTEXITCODE -ne 0 -or -not $RunId) {
                throw "No successful release run found in $Repository. Trigger one: gh workflow run release.yml --repo $Repository -f onboard_commit=<sha>"
            }
        }
        Write-Step "Downloading artifact from run $RunId"
        & gh run download $RunId --repo $Repository --dir $localStage
        if ($LASTEXITCODE -ne 0) { throw "gh run download failed (exit $LASTEXITCODE)" }

        $zip = @(Get-ChildItem -LiteralPath $localStage -Filter '*.zip' -Recurse -File) |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $zip) { throw "Run $RunId produced no zip artifact." }
        Write-Step "Downloaded $(Split-Path -Leaf $zip)"
    }

    # The hash travels beside the zip rather than only in GitHub's metadata, so
    # the same check works for a locally built package and for a downloaded one.
    $hashFile = "$zip.sha256"
    if (-not (Test-Path -LiteralPath $hashFile)) {
        throw "Missing hash file $hashFile. Refusing to deploy an unverified package."
    }
    $expected = ((Get-Content -LiteralPath $hashFile -Raw) -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        throw "Package hash mismatch on the control host. Expected $expected, got $actual."
    }
    Write-Step "Package hash verified ($actual)"

    # The release identity travels beside the zip too. Printing the onboard
    # commit here is the only place an operator sees, before the deployment,
    # which onboard build this server half expects on the other end.
    # Beside the zip, not under the staging root: gh run download unpacks the
    # artifact into a subdirectory, and a locally built package is not under the
    # staging root at all. The zip's own directory is the one place both have it.
    $manifestFile = @(Get-ChildItem -LiteralPath (Split-Path -Parent $zip) -Filter 'release-manifest.json' -File) |
        Select-Object -First 1
    if ($manifestFile) {
        $manifest = Get-Content -Raw -LiteralPath $manifestFile.FullName | ConvertFrom-Json
        Write-Step "ControlServer commit: $($manifest.components.controlServer.commit)"
        Write-Step "OnboardHmi commit:    $($manifest.components.onboardHmi.commit)"
        Write-Step 'Deploy that same onboard commit with 06-deploy-onboard-hmi.ps1.'
    }

    # -------------------------------------------------------------- config ---

    $config = [ordered]@{
        listenAddress = $ListenAddress
        healthBindAddress = $HealthBindAddress
        onboardPort = $OnboardPort
        healthPort = $HealthPort
        riotCallApiKey = $plain['RiotCallApiKey']
        onboardCredential = $plain['OnboardCredential']
        mesIngestSharedSecret = $plain['MesIngestSharedSecret']
    }
    $configPath = Join-Path $localStage 'deploy-config.json'
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM -WhatIf:$false

    if (-not $PSCmdlet.ShouldProcess($SshAlias, "Deploy $(Split-Path -Leaf $zip) to $PackageRoot")) {
        Write-Step 'WhatIf: stopping before the server is touched.'
        Write-Step "Would copy: $zip -> ${SshAlias}:$StagingRoot"
        Write-Step "Would run:  Install-ControlServerRemote.ps1 -PackageZip ... -ExpectedSha256 $actual"
        Write-Step "Would bind: tcp://${ListenAddress}:$OnboardPort and http://${HealthBindAddress}:$HealthPort"
        return
    }

    # ------------------------------------------------------------ transfer ---

    # Both directories are created with inheritance broken. deploy-config.json
    # holds three plaintext secrets for the length of one install, and the
    # server has interactive logins other than the one running this.
    Write-Step "Preparing $OpsRoot and $StagingRoot on $SshAlias"
    $prepare = @"
foreach (`$d in @('$OpsRoot', '$StagingRoot')) {
    if (-not (Test-Path -LiteralPath `$d)) { New-Item -ItemType Directory -Path `$d -Force | Out-Null }
    `$acl = Get-Acl -LiteralPath `$d
    `$acl.SetAccessRuleProtection(`$true, `$false)
    foreach (`$r in @(`$acl.Access)) { [void]`$acl.RemoveAccessRule(`$r) }
    foreach (`$id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        `$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            `$id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath `$d -AclObject `$acl
    "ready: `$d"
}
"@
    $preparePath = Join-Path $localStage 'prepare-dirs.ps1'
    Set-Content -LiteralPath $preparePath -Value $prepare -Encoding utf8NoBOM
    Invoke-Ssh @("New-Item -ItemType Directory -Force -Path '$StagingRoot' | Out-Null")
    & scp -q $preparePath "${SshAlias}:$(& $toPosix "$StagingRoot\prepare-dirs.ps1")"
    if ($LASTEXITCODE -ne 0) { throw "scp of prepare-dirs.ps1 failed (exit $LASTEXITCODE)" }
    Invoke-Ssh @("pwsh -NoProfile -File `"$StagingRoot\prepare-dirs.ps1`"")

    Write-Step "Copying package ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
    $remoteZip = "$StagingRoot\$(Split-Path -Leaf $zip)"
    & scp -q $zip "${SshAlias}:$(& $toPosix $remoteZip)"
    if ($LASTEXITCODE -ne 0) { throw "scp of the package failed (exit $LASTEXITCODE)" }

    $remoteConfig = "$OpsRoot\deploy-config.json"
    & scp -q $configPath "${SshAlias}:$(& $toPosix $remoteConfig)"
    if ($LASTEXITCODE -ne 0) { throw "scp of the deployment config failed (exit $LASTEXITCODE)" }

    # ------------------------------------------------------------- install ---

    Write-Step 'Running the installer on the server'
    Invoke-RemoteScript -LocalPath $installerSource -ArgumentList @(
        '-PackageZip', $remoteZip
        '-ExpectedSha256', $actual
        '-DeploymentConfigPath', $remoteConfig
        '-PackageRoot', $PackageRoot
    )

    # --------------------------------------------------------------- check ---

    # The server checked loopback. This is the check that matters: a round trip
    # from another machine, reading the body. RELEASE-CANDIDATE.md section 4.4
    # is explicit that a handshake proves nothing on a host behind a global
    # proxy -- ping and TCP connect succeed against hosts that do not exist.
    Write-Step "Verifying http://${HealthBindAddress}:$HealthPort/health/live from this machine"
    $route = Find-NetRoute -RemoteIPAddress $HealthBindAddress -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty InterfaceAlias
    if ($route -eq 'Clash') {
        Write-Warning "The route to $HealthBindAddress goes through the Clash TUN adapter; this result is fiction."
        Write-Warning 'Install the bypass route: ./01-control-host-route.ps1'
    }
    try {
        $live = Invoke-WebRequest -Uri "http://${HealthBindAddress}:$HealthPort/health/live" `
            -NoProxy -TimeoutSec 20 -UseBasicParsing
        Write-Step "health/live $($live.StatusCode): $($live.Content)"
    } catch {
        throw "The server installed but is not reachable from this machine: $($_.Exception.Message)"
    }

    Write-Step "Deployed. Onboard NDJSON: tcp://${ListenAddress}:$OnboardPort"
    Write-Step "Vehicle safety: http://${HealthBindAddress}:$HealthPort/api/onboard/v1/vehicle-safety"
    Write-Step 'Next: deploy the matching onboard commit with'
    Write-Step '  remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1'

} finally {
    # The staged config held plaintext secrets; do not leave it in %TEMP%.
    if (Test-Path -LiteralPath $localStage) {
        Remove-Item -LiteralPath $localStage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    $plain.Clear()
}
