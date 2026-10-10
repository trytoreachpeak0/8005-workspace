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

    TWIN SCRIPT. 19-deploy-control-server-parallel.ps1 deploys the v2 parallel instance to
    the same machine (control-server#262). It is a separate script on purpose -- this one
    cannot install the parallel instance and that one refuses the production names -- which
    also means a fix to one does not reach the other by itself. When a change here touches the
    machine rather than this deployment, look at the twin too.

    The onboard half of the same package goes to the vehicles with
    remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1. Deploy the server
    first: the onboard client needs a reachable projection endpoint before it
    will leave RecoveryRequired.

.PARAMETER RunId
    GitHub Actions `release` run to deploy. Required unless -PackagePath or
    -Rollback is given (8005-workspace#10). There is deliberately no "most
    recent successful run" default: release.yml also runs on the v2 line
    (fp/v2-impl, field/cs*), and the newest run in the repository is usually a
    v2 package -- deploying one here stops the production MVP line, because the
    two ends do not negotiate versions.

    Before anything is downloaded the run is read back and refused unless it
    is a successful run of .github/workflows/release.yml on an MVP branch:
    ControlServer_MVP, or the agv01 field line field/agv01-* (cut from
    ControlServer_MVP; see $MvpBranchPatterns). After the download the
    release-manifest.json inside the zip must name the run's head commit as
    the ControlServer commit.

    List candidate runs with:
        gh run list --repo trytoreachpeak0/8005-agv-control-server --workflow release.yml --branch ControlServer_MVP

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
    ./15-deploy-control-server.ps1 -RunId 12345678 -WhatIf

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

# Branches whose release runs may reach the production MVP service (8005-workspace#10). Read
# from the release history on 2026-10-10: production runs ControlServer_MVP and, since
# 2026-09-15, the agv01 field line field/agv01-670bdd45 (ControlServer_MVP at 670bdd45 plus
# field fixes; its last release is run 35672994834). Every other branch release.yml runs on is
# refused -- fp/v2-impl and field/cs* carry the v2 line and a newer protocol, and the newest run
# in the repository is usually one of those. Note field/agv01-* and field/cs* share a prefix:
# never widen this to field/*.
$MvpBranchPatterns = @('^ControlServer_MVP$', '^field/agv01-[0-9A-Za-z._-]+$')
$ReleaseWorkflowPath = '.github/workflows/release.yml'

# Reads the run back from GitHub and throws unless it is a successful release.yml run on an MVP
# branch. Uses the REST run object rather than `gh run view --json workflowName`: workflowName is
# the workflow's display name ("release"), not its file, so only `path` can tell release.yml apart
# from another workflow that happens to share the name.
function Assert-DeployableReleaseRun {
    param([string] $Id)
    $json = & gh api "repos/$Repository/actions/runs/$Id"
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw "Cannot read run $Id in $Repository (gh api exit $LASTEXITCODE)." }
    $run = $json | ConvertFrom-Json
    $identity = "run $Id (branch '$($run.head_branch)', commit $($run.head_sha), workflow $($run.path))"
    if ($run.path -cne $ReleaseWorkflowPath) {
        throw "Refusing $identity`: not a $ReleaseWorkflowPath run."
    }
    if ($run.conclusion -cne 'success') {
        throw "Refusing $identity`: conclusion is '$($run.conclusion)', not 'success'."
    }
    if (-not @($MvpBranchPatterns | Where-Object { $run.head_branch -cmatch $_ })) {
        throw ("Refusing $identity`: not an MVP branch. This script deploys the production MVP service; " +
            "only branches matching $($MvpBranchPatterns -join ' or ') are accepted. " +
            'The v2 parallel instance is deployed with 19-deploy-control-server-parallel.ps1.')
    }
    if ($run.head_sha -notmatch '^[0-9a-f]{40}$') { throw "Refusing $identity`: head commit is not a full SHA." }
    return $run
}

# The manifest inside the zip, not the copy beside it: the zip is what gets installed, and its
# hash was just checked against the .sha256 file.
function Assert-PackageFromCommit {
    param([string] $Zip, [string] $Commit, [string] $Id)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entry = $archive.GetEntry('release-manifest.json')
        if ($null -eq $entry) { throw "Refusing run $Id`: the package has no release-manifest.json." }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    $packaged = "$($manifest.components.controlServer.commit)"
    if ($packaged -ne $Commit) {
        throw "Refusing run $Id`: the package's release-manifest.json names ControlServer commit '$packaged', but the run built $Commit."
    }
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

# ------------------------------------------------------------ release run ---

# Before anything is downloaded or loaded, and outside every ShouldProcess: -WhatIf refuses the
# same runs a real deployment does.
if ($PSCmdlet.ParameterSetName -eq 'Download') {
    if (-not $RunId) {
        throw ("-RunId is required (8005-workspace#10): the newest release run is usually a v2 package. " +
            "List MVP runs with: gh run list --repo $Repository --workflow release.yml --branch ControlServer_MVP")
    }
    $releaseRun = Assert-DeployableReleaseRun -Id $RunId
    Write-Step "Run $RunId is a release of $($releaseRun.head_branch) at $($releaseRun.head_sha)"
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

    if ($PSCmdlet.ParameterSetName -eq 'Download') {
        Assert-PackageFromCommit -Zip $zip -Commit $releaseRun.head_sha -Id $RunId
        Write-Step "Package manifest names the run's commit $($releaseRun.head_sha)"
    }

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
