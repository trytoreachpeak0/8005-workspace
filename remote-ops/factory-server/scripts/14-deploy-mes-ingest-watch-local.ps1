#Requires -Version 7
<#
.SYNOPSIS
    Installs the MesIngest Watch client on this control host, pointed at the
    Host running on the factory server.

.DESCRIPTION
    Takes the same release artifact as the server deployment and unpacks only
    watch/ from it, so the client on this machine and the service on the server
    are always built from one commit. Watch refuses to interpret business data
    when the contract version or capability set does not match exactly, which
    makes a version skew here a visible failure rather than a subtly wrong
    screen — but there is no reason to arrange one.

    The Host binds beyond localhost on the server, so every request needs
    `Authorization: Bearer <SharedSecret>`. The token comes from the same DPAPI
    store as the server deployment; the two ends cannot drift apart unless the
    secret is rotated and only one side is redeployed.

    The retired local install at C:\MesIngest is left alone. Its service is
    stopped and disabled and its databases are gone, but the directory still
    holds the Oracle credentials this deployment was seeded from. Delete it by
    hand once the server has been running long enough to trust.

.PARAMETER InstallRoot
    Where the Watch client lands. A directory of its own rather than the retired
    install, so that "what is running" has one answer.

.PARAMETER BaseUrl
    Host API root. Defaults to the factory server over the enterprise network.

.PARAMETER Shortcut
    Desktop shortcut to create or repoint. Defaults to the existing one, which
    currently points into the retired install.

.EXAMPLE
    ./14-deploy-mes-ingest-watch-local.ps1

.EXAMPLE
    ./14-deploy-mes-ingest-watch-local.ps1 -PackagePath D:\pkg\MesIngest-20260902-101500-a5236ee.zip
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Download')]
param(
    [Parameter(ParameterSetName = 'Download')]
    [string] $RunId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [string] $PackagePath,

    [string] $Repository = 'trytoreachpeak0/8005-mes-ingest',

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\mes-ingest-deployment.xml'),

    [string] $InstallRoot = 'C:\MesIngest-Watch',

    [string] $BaseUrl = 'http://172.19.205.222:5088',

    [string] $Shortcut = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'MesIngest Watch.lnk'),

    [ValidateRange(1, 300)]
    [int] $RequestTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

Write-Step "Watch deployment to $InstallRoot"

# The route to the server must not go through the Clash TUN adapter, which
# answers for hosts that are not there and makes every port look open. This is
# the same check remote-ops applies before trusting any probe.
$target = ([Uri]$BaseUrl).Host
if ($target -as [ipaddress]) {
    $iface = (Find-NetRoute -RemoteIPAddress $target -ErrorAction SilentlyContinue |
        Select-Object -First 1).InterfaceAlias
    if ($iface -like '*Clash*') {
        throw "The route to $target goes through '$iface'. Watch would be talking to the TUN adapter, not the server. Fix the bypass route (01-control-host-route.ps1) first."
    }
    Write-Step "Route to $target is via '$iface'"
}

if (-not (Test-Path -LiteralPath $SecretPath)) {
    throw "No secret store at $SecretPath. Run mes-ingest\Set-MesIngestSecret.ps1 first."
}
$secrets = Import-Clixml -LiteralPath $SecretPath
if (-not $secrets.ContainsKey('SharedSecret') -or -not $secrets['SharedSecret']) {
    throw "SharedSecret is missing from $SecretPath."
}
$sharedSecret = [System.Net.NetworkCredential]::new('', $secrets['SharedSecret']).Password

$localStage = Join-Path $env:TEMP "mes-ingest-watch-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $localStage -Force | Out-Null

try {
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        $zip = (Resolve-Path -LiteralPath $PackagePath).Path
    } else {
        if (-not $RunId) {
            $RunId = & gh run list --repo $Repository --workflow release.yml `
                --status success --limit 1 --json databaseId --jq '.[0].databaseId'
            if ($LASTEXITCODE -ne 0 -or -not $RunId) {
                throw "No successful release run found in $Repository."
            }
        }
        Write-Step "Downloading artifact from run $RunId"
        & gh run download $RunId --repo $Repository --dir $localStage
        if ($LASTEXITCODE -ne 0) { throw "gh run download failed (exit $LASTEXITCODE)" }
        $zip = @(Get-ChildItem -LiteralPath $localStage -Filter '*.zip' -Recurse -File) |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $zip) { throw "Run $RunId produced no zip artifact." }
    }

    $hashFile = "$zip.sha256"
    if (-not (Test-Path -LiteralPath $hashFile)) { throw "Missing hash file $hashFile." }
    $expected = ((Get-Content -LiteralPath $hashFile -Raw) -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "Package hash mismatch. Expected $expected, got $actual." }
    Write-Step "Package hash verified ($actual)"

    if (-not $PSCmdlet.ShouldProcess($InstallRoot, "Install Watch from $(Split-Path -Leaf $zip)")) {
        Write-Step 'WhatIf: nothing was written.'
        return
    }

    $extract = Join-Path $localStage 'extract'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $watchSource = Join-Path $extract 'watch'
    if (-not (Test-Path -LiteralPath (Join-Path $watchSource 'MesIngest.Watch.exe'))) {
        throw "The package has no watch\MesIngest.Watch.exe; it was probably built with -SkipWatch."
    }

    # A running Watch holds its own binaries open. It is a read-only client, so
    # closing it loses nothing but the current screen.
    $running = @(Get-Process -Name 'MesIngest.Watch' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Step "Closing $($running.Count) running Watch process(es)"
        $running | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    $previousRoot = "$InstallRoot.previous"
    if (Test-Path -LiteralPath $InstallRoot) {
        if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
        Rename-Item -LiteralPath $InstallRoot -NewName (Split-Path -Leaf $previousRoot)
        Write-Step "Previous Watch kept at $previousRoot"
    }

    Write-Step "Installing to $InstallRoot"
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $watchSource '*') -Destination $InstallRoot -Recurse -Force
    Copy-Item -Path (Join-Path $extract 'VERSION.txt') -Destination $InstallRoot -Force

    $watchLocal = [ordered]@{
        Watch = [ordered]@{
            BaseUrl = $BaseUrl
            RenderingMode = 'SoftwareOnly'
            RefreshSeconds = 2
            RequestTimeoutSeconds = $RequestTimeoutSeconds
            SharedSecret = $sharedSecret
        }
    }
    $configPath = Join-Path $InstallRoot 'appsettings.Local.json'
    $watchLocal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

    # The bearer token is in this file. Break inheritance and keep it to this
    # user plus the local administrators.
    $acl = Get-Acl -LiteralPath $configPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    foreach ($identity in @($env:USERNAME, 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', 'None', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $configPath -AclObject $acl
    Write-Step "Wrote $configPath -> $BaseUrl"

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Shortcut)
    $lnk.TargetPath = Join-Path $InstallRoot 'MesIngest.Watch.exe'
    $lnk.WorkingDirectory = $InstallRoot
    $lnk.Description = 'MesIngest 盯盘客户端（只读，连厂区服务器）'
    $lnk.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    Write-Step "Shortcut repointed: $Shortcut"

    Write-Step 'Checking the Host is reachable from here'
    try {
        $contract = Invoke-RestMethod -Uri "$BaseUrl/api/v2/contract" `
            -Headers @{ Authorization = "Bearer $sharedSecret" } -TimeoutSec 15
        Write-Step "Host answered: version=$($contract.contractVersion) schema=$($contract.schemaVersion)"
    } catch {
        Write-Warning "Watch is installed, but $BaseUrl did not answer: $($_.Exception.Message)"
        Write-Warning 'Deploy the server side first (13-deploy-mes-ingest-server.ps1), then start Watch.'
    }

    Write-Step "Done. Launch from the desktop shortcut or $InstallRoot\MesIngest.Watch.exe"

} finally {
    if (Test-Path -LiteralPath $localStage) {
        Remove-Item -LiteralPath $localStage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
