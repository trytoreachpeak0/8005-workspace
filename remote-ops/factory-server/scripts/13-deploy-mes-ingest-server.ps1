#Requires -Version 7
<#
.SYNOPSIS
    Deploys a MesIngest release package to the factory server. Runs on the
    control host.

.DESCRIPTION
    The delivery half of the CD path. CI builds and verifies the package but
    deploys nothing; this script carries it the last hop:

        GitHub artifact -> control host -> scp -> factory01 -> install

    That shape is deliberate. The runner lives on win11-01, a Hyper-V guest of
    the factory server, and giving it an SSH key into its own host would mean any
    code that reaches that runner reaches the production AGV stack. Routing
    through the control host keeps a human in the path without making the
    deployment manual.

    Secrets come from the DPAPI store written by
    mes-ingest/Set-MesIngestSecret.ps1. They are assembled into a deployment
    config, copied to a restricted directory on the server, consumed by the
    installer, and deleted there. They never appear on a command line, in the
    CI log, or in this repository.

.PARAMETER RunId
    GitHub Actions run to deploy. Omit to take the most recent successful
    `release` run on main.

.PARAMETER PackagePath
    Deploy a zip already on disk instead of downloading one. The matching
    .sha256 file must sit beside it.

.PARAMETER Rollback
    Swap the previous package back in on the server. Downloads nothing.

.PARAMETER OracleDataSource
    MES source TNS descriptor. The default is the one the retired control-host
    install was polling; it is not a secret, unlike the account password.

.PARAMETER WhatIf
    Stage and verify everything, print the remote command, and stop before
    touching the server.

.EXAMPLE
    ./13-deploy-mes-ingest-server.ps1

.EXAMPLE
    ./13-deploy-mes-ingest-server.ps1 -RunId 12345678

.EXAMPLE
    ./13-deploy-mes-ingest-server.ps1 -Rollback
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

    [string] $Repository = 'trytoreachpeak0/8005-mes-ingest',

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\mes-ingest-deployment.xml'),

    [string] $InstallRoot = 'D:\zhengyushao\MesIngest',

    [string] $OpsRoot = 'D:\zhengyushao\mes-ingest-ops',

    [string] $StagingRoot = 'D:\zhengyushao\mes-ingest-staging',

    [ValidateRange(1, 65535)]
    [int] $Port = 5088,

    [string] $SqlServer = 'localhost',

    [string] $Database = 'MesIngest',

    [string] $SqlLogin = 'mesingest',

    [string] $OracleUser = 'fwmes',

    [string] $OracleDataSource = '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=172.19.1.152)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=SQMES)))',

    [ValidateSet('Thin', 'Thick')]
    [string] $OracleMode = 'Thin',

    [string] $OracleInstantClientDir = '',

    [string] $OracleThickOdbcDriver = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$scriptRoot = $PSScriptRoot
$installerSource = Join-Path $scriptRoot 'mes-ingest\Install-MesIngestServer.ps1'
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
# line is a reliable source of silently mangled arguments. See the probe that
# lost its array literal to exactly that during the design of this script.
function Invoke-RemoteScript {
    param([string] $LocalPath, [string[]] $ArgumentList)
    $remote = "$OpsRoot\$(Split-Path -Leaf $LocalPath)"
    & scp -q $LocalPath "${SshAlias}:$(& $toPosix $remote)"
    if ($LASTEXITCODE -ne 0) { throw "scp of $LocalPath failed (exit $LASTEXITCODE)" }
    # Quote only what needs it. A switch such as -Rollback wrapped in quotes
    # stops being a parameter name and becomes a positional value, which pwsh
    # then rejects with a message that points nowhere near the cause.
    $quoted = $ArgumentList | ForEach-Object {
        if ($_ -match '^-\w' -or $_ -notmatch '\s') { $_ } else { "'$_'" }
    }
    Invoke-Ssh @("pwsh -NoProfile -File `"$remote`" $($quoted -join ' ')")
}

Write-Step "MesIngest deployment to $SshAlias"

# ---------------------------------------------------------------- rollback ---

if ($Rollback) {
    if (-not $PSCmdlet.ShouldProcess($SshAlias, "Roll back MesIngest to the previous package")) { return }
    Invoke-RemoteScript -LocalPath $installerSource -ArgumentList @(
        '-Rollback'
        '-InstallRoot', $InstallRoot
    )
    Write-Step 'Rollback complete.'
    return
}

# ----------------------------------------------------------------- secrets ---

if (-not (Test-Path -LiteralPath $SecretPath)) {
    throw "No secret store at $SecretPath. Run mes-ingest\Set-MesIngestSecret.ps1 first."
}
$secrets = Import-Clixml -LiteralPath $SecretPath
foreach ($key in @('SqlPassword', 'OraclePassword', 'SharedSecret')) {
    if (-not $secrets.ContainsKey($key) -or -not $secrets[$key]) {
        throw "Secret '$key' is missing from $SecretPath. Run Set-MesIngestSecret.ps1."
    }
}
$plain = @{}
foreach ($key in @('SqlPassword', 'OraclePassword', 'SharedSecret')) {
    $plain[$key] = [System.Net.NetworkCredential]::new('', $secrets[$key]).Password
}
Write-Step 'Secrets loaded from the DPAPI store'

# ----------------------------------------------------------------- package ---

$localStage = Join-Path $env:TEMP "mes-ingest-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $localStage -Force | Out-Null

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
                throw "No successful release run found in $Repository. Trigger one: gh workflow run release.yml --repo $Repository"
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

    # ------------------------------------------------------------- config ---

    $config = [ordered]@{
        installRoot = $InstallRoot
        serviceName = 'MesIngest'
        port = $Port
        urls = "http://0.0.0.0:$Port"
        sqlServer = $SqlServer
        database = $Database
        sqlLogin = $SqlLogin
        sqlPassword = $plain['SqlPassword']
        sharedSecret = $plain['SharedSecret']
        oracle = [ordered]@{
            user = $OracleUser
            password = $plain['OraclePassword']
            dataSource = $OracleDataSource
            mode = $OracleMode
            instantClientDir = $OracleInstantClientDir
            thickOdbcDriver = $OracleThickOdbcDriver
        }
        installWatch = $true
        publicDesktopShortcut = $true
        firewallRule = $true
    }

    $configPath = Join-Path $localStage 'deploy-config.json'
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

    if (-not $PSCmdlet.ShouldProcess($SshAlias, "Deploy $(Split-Path -Leaf $zip) to $InstallRoot")) {
        Write-Step 'WhatIf: stopping before the server is touched.'
        Write-Step "Would copy: $zip -> ${SshAlias}:$StagingRoot"
        Write-Step "Would run:  Install-MesIngestServer.ps1 -PackageZip ... -ExpectedSha256 $actual"
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
    & scp -q $preparePath "${SshAlias}:$(& $toPosix "$StagingRoot\prepare-dirs.ps1")" 2>$null
    if ($LASTEXITCODE -ne 0) {
        # First deployment: the staging directory does not exist yet.
        Invoke-Ssh @("New-Item -ItemType Directory -Force -Path '$StagingRoot' | Out-Null")
        & scp -q $preparePath "${SshAlias}:$(& $toPosix "$StagingRoot\prepare-dirs.ps1")"
        if ($LASTEXITCODE -ne 0) { throw "scp of prepare-dirs.ps1 failed (exit $LASTEXITCODE)" }
    }
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
        '-InstallRoot', $InstallRoot
    )

    Write-Step "Deployed. API: http://172.19.205.222:$Port/api/v2/contract (Bearer required)"
    Write-Step "Deploy a Watch on this machine with: ./14-deploy-mes-ingest-watch-local.ps1"

} finally {
    # The staged config held plaintext secrets; do not leave it in %TEMP%.
    if (Test-Path -LiteralPath $localStage) {
        Remove-Item -LiteralPath $localStage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $plain.Clear()
}
