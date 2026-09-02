#Requires -Version 7
<#
.SYNOPSIS
    Installs or upgrades MesIngest on the factory server. Runs ON that server.

.DESCRIPTION
    Driven by 13-deploy-mes-ingest-server.ps1 on the control host, which stages
    the package zip and a deployment config next to it and then invokes this over
    SSH. It can also be run by hand from an SSH session when a deployment needs
    to be resumed or inspected.

    The order matters and is not arbitrary:

      1. verify the zip hash before anything is unpacked — a truncated scp is the
         failure this catches, and it is silent otherwise;
      2. ensure the database and the dedicated SQL login exist. The Host itself
         bootstraps the schema into an empty database on first start (ADR-mes-0017),
         so this only creates the container, never a table;
      3. stop the service, keep the current install as <root>.previous, unpack;
      4. write appsettings.Local.json with an ACL that excludes ordinary users —
         it holds the SQL and Oracle passwords and the bearer token;
      5. start, then poll /api/v2/contract until it answers. A first start
         against an empty database builds schema v29 and is not instant.

    Everything here is idempotent except the package swap. Re-running after a
    failure is the intended recovery, not an exception.

    The deployment config carries three secrets in plaintext for the seconds it
    exists on disk. It is deleted at the end of a successful run, and its
    directory is created with a restrictive ACL. Passwords never appear on a
    command line, in a log, or in the service's own event-log output.

.PARAMETER PackageZip
    The MesIngest-<stamp>-<sha>.zip produced by the release workflow.

.PARAMETER ExpectedSha256
    Hex SHA-256 of that zip, from the .sha256 file beside it.

.PARAMETER DeploymentConfigPath
    JSON written by the control host. Deleted on success.

.PARAMETER Rollback
    Swap <root>.previous back into place and restart, ignoring every other
    parameter. Does not touch the database — see UPGRADE.md, a database rollback
    is a separate, attended operation.

.EXAMPLE
    pwsh -File Install-MesIngestServer.ps1 `
        -PackageZip D:\zhengyushao\mes-ingest-staging\MesIngest-20260902-101500-a5236ee.zip `
        -ExpectedSha256 3f2a... `
        -DeploymentConfigPath D:\zhengyushao\mes-ingest-ops\deploy-config.json

.EXAMPLE
    pwsh -File Install-MesIngestServer.ps1 -Rollback
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string] $PackageZip,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedSha256,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string] $DeploymentConfigPath,

    [Parameter(ParameterSetName = 'Rollback')]
    [switch] $Rollback,

    [string] $InstallRoot = 'D:\zhengyushao\MesIngest',

    [string] $ServiceName = 'MesIngest'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$previousRoot = "$InstallRoot.previous"

function Write-Step {
    param([string] $Message)
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message)
}

function Stop-MesIngestService {
    param([string] $Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    if ($svc.Status -ne 'Stopped') {
        Write-Step "Stopping service $Name"
        Stop-Service -Name $Name -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(90))
    }
    # A stopped service can still have a live process for a moment; the directory
    # rename below fails with a sharing violation if we do not wait it out.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Process -Name 'MesIngest.Host' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    return $true
}

function Set-SecretFileAcl {
    param([string] $Path)
    # Break inheritance and grant only SYSTEM (the service identity) and the
    # local Administrators group. Everything this file holds is a credential.
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', 'None', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-SqlNonQuery {
    param([string] $Sql, [string] $ServerInstance)

    # Piped through stdin rather than -Q or -i: a password in -Q lands in the
    # process command line, and -i needs a file that briefly holds it on disk.
    #
    # $OutputEncoding must not carry a BOM. PowerShell writes the encoding's
    # preamble ahead of the first piped byte, and sqlcmd then parses EF BB BF as
    # part of the statement:
    #
    #     消息 102，级别 15，状态 1 ... "﻿"附近有语法错误。
    #
    # This host's $PROFILE sets a BOM-carrying UTF-8 encoding for the console, so
    # an interactive SSH session hits it while `pwsh -NoProfile` does not. Setting
    # it here rather than relying on -NoProfile means the function is correct
    # either way. The assignment is function-scoped, so it reverts on return.
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $out = $Sql | & sqlcmd -S $ServerInstance -E -b 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed (exit $LASTEXITCODE): $($out -join [Environment]::NewLine)"
    }
    return $out
}

# ---------------------------------------------------------------- rollback ---

if ($Rollback) {
    if (-not (Test-Path -LiteralPath $previousRoot)) {
        throw "No previous install to roll back to: $previousRoot"
    }
    Write-Step "Rolling back $InstallRoot <- $previousRoot"
    [void](Stop-MesIngestService -Name $ServiceName)

    $failed = "$InstallRoot.rollback-failed"
    if (Test-Path -LiteralPath $failed) { Remove-Item -LiteralPath $failed -Recurse -Force }
    if (Test-Path -LiteralPath $InstallRoot) { Rename-Item -LiteralPath $InstallRoot -NewName (Split-Path -Leaf $failed) }
    Rename-Item -LiteralPath $previousRoot -NewName (Split-Path -Leaf $InstallRoot)

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Start-Service -Name $ServiceName
        Write-Step "Service $ServiceName started from the previous package"
    }
    Write-Step "Rolled back. The failed package is kept at $failed"
    Write-Step 'The database was NOT rolled back; see UPGRADE.md if that is needed.'
    return
}

# ----------------------------------------------------------------- install ---

Write-Step "MesIngest deployment starting on $env:COMPUTERNAME as $env:USERNAME"

if (-not (Test-Path -LiteralPath $PackageZip)) { throw "Package not found: $PackageZip" }
if (-not (Test-Path -LiteralPath $DeploymentConfigPath)) { throw "Deployment config not found: $DeploymentConfigPath" }

Write-Step 'Verifying package hash'
$actual = (Get-FileHash -LiteralPath $PackageZip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
    throw "Package hash mismatch. Expected $ExpectedSha256, got $actual. Do not deploy this file."
}
Write-Step "Hash OK ($actual)"

$cfg = Get-Content -LiteralPath $DeploymentConfigPath -Raw | ConvertFrom-Json

# ------------------------------------------------------- database & login ---

$sqlInstance = $cfg.sqlServer
$database = $cfg.database
$sqlLogin = $cfg.sqlLogin

Write-Step "Ensuring database [$database] and login [$sqlLogin] on $sqlInstance"

# CREATE DATABASE only. The Host builds schema v29 into an empty database on
# first start and refuses any database that is neither empty nor an exact match,
# so creating tables here would break the deployment rather than help it.
$ensureDatabase = @"
SET NOCOUNT ON;
IF DB_ID(N'$database') IS NULL
BEGIN
    CREATE DATABASE [$database];
    PRINT N'created database $database';
END
ELSE
    PRINT N'database $database already exists';
"@
Invoke-SqlNonQuery -Sql $ensureDatabase -ServerInstance $sqlInstance | Write-Output

# The login password reaches sqlcmd through stdin, so it never appears in the
# command line of any process. CHECK_POLICY follows the machine policy; a
# password generated by Set-MesIngestSecret.ps1 or chosen by the operator has to
# satisfy it either way.
$escapedPassword = $cfg.sqlPassword -replace "'", "''"
$ensureLogin = @"
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$sqlLogin')
BEGIN
    CREATE LOGIN [$sqlLogin] WITH PASSWORD = N'$escapedPassword', CHECK_POLICY = ON;
    PRINT N'created login $sqlLogin';
END
ELSE
BEGIN
    ALTER LOGIN [$sqlLogin] WITH PASSWORD = N'$escapedPassword';
    PRINT N'login $sqlLogin exists; password reset to the stored value';
END

USE [$database];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$sqlLogin')
BEGIN
    CREATE USER [$sqlLogin] FOR LOGIN [$sqlLogin];
    PRINT N'created database user $sqlLogin';
END
-- db_owner and nothing wider. The Host owns its schema inside this one database
-- and has no business anywhere else on this instance, least of all SQAGV.
IF IS_ROLEMEMBER(N'db_owner', N'$sqlLogin') = 0
BEGIN
    ALTER ROLE [db_owner] ADD MEMBER [$sqlLogin];
    PRINT N'granted db_owner on $database';
END
"@
Invoke-SqlNonQuery -Sql $ensureLogin -ServerInstance $sqlInstance | Write-Output

# ------------------------------------------------------------ package swap ---

$serviceExisted = Stop-MesIngestService -Name $ServiceName

# Exactly one generation is kept. Two would make "which one is previous" a
# question someone has to answer under pressure.
if (Test-Path -LiteralPath $InstallRoot) {
    if (Test-Path -LiteralPath $previousRoot) {
        Write-Step "Discarding the older generation at $previousRoot"
        Remove-Item -LiteralPath $previousRoot -Recurse -Force
    }
    Write-Step "Keeping the current install as $previousRoot"
    Rename-Item -LiteralPath $InstallRoot -NewName (Split-Path -Leaf $previousRoot)
}

Write-Step "Unpacking to $InstallRoot"
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Expand-Archive -LiteralPath $PackageZip -DestinationPath $InstallRoot -Force

$hostExe = Join-Path $InstallRoot 'service\MesIngest.Host.exe'
if (-not (Test-Path -LiteralPath $hostExe)) {
    throw "Unpacked package has no service\MesIngest.Host.exe. Wrong archive layout?"
}

$version = Get-Content -LiteralPath (Join-Path $InstallRoot 'VERSION.txt') -Raw
Write-Step "Package contents:`n$version"

# A package built from a dirty worktree cannot be traced back to a commit, which
# makes every later question about "what is actually running" unanswerable.
if ($version -match 'SourceDirty=True') {
    throw 'Refusing to deploy: the package was built from a dirty worktree (SourceDirty=True).'
}

# --------------------------------------------------------------- configure ---

Write-Step 'Writing service configuration'

$serviceLocal = [ordered]@{
    MesIngest = [ordered]@{
        Urls = $cfg.urls
        SharedSecret = $cfg.sharedSecret
        NewSqlServerConnectionString = "Server=$sqlInstance;Database=$database;User Id=$sqlLogin;Password=$($cfg.sqlPassword);TrustServerCertificate=True;Encrypt=False;Connect Timeout=30"
        SnapshotSource = 'Oracle'
        OracleUser = $cfg.oracle.user
        OraclePassword = $cfg.oracle.password
        OracleDataSource = $cfg.oracle.dataSource
        OracleMode = $cfg.oracle.mode
        OracleInstantClientDir = $cfg.oracle.instantClientDir
        OracleThickOdbcDriver = $cfg.oracle.thickOdbcDriver
    }
}

$serviceLocalPath = Join-Path $InstallRoot 'service\appsettings.Local.json'
$serviceLocal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $serviceLocalPath -Encoding utf8NoBOM
Set-SecretFileAcl -Path $serviceLocalPath
Write-Step "Wrote $serviceLocalPath (SYSTEM + Administrators only)"

if ($cfg.installWatch) {
    # Watch talks to the Host over the loopback on this machine even though the
    # Host binds wider; there is no reason for a local client to leave the box.
    # It still sends the bearer token, because a non-localhost binding makes
    # every request on every interface require one.
    $watchLocal = [ordered]@{
        Watch = [ordered]@{
            BaseUrl = "http://127.0.0.1:$($cfg.port)"
            RenderingMode = 'SoftwareOnly'
            RefreshSeconds = 2
            RequestTimeoutSeconds = 30
            SharedSecret = $cfg.sharedSecret
        }
    }
    $watchLocalPath = Join-Path $InstallRoot 'watch\appsettings.Local.json'
    $watchLocal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $watchLocalPath -Encoding utf8NoBOM
    Set-SecretFileAcl -Path $watchLocalPath
    Write-Step "Wrote $watchLocalPath (SYSTEM + Administrators only)"
}

# ----------------------------------------------------------------- service ---

$binPath = "`"$hostExe`""
$existing = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue

if ($existing) {
    if ($existing.PathName -ne $binPath) {
        Write-Step "Service binPath changed; updating to $binPath"
        & sc.exe config $ServiceName binPath= $binPath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed (exit $LASTEXITCODE)" }
    }
    if ($existing.StartMode -ne 'Auto') {
        Write-Step 'Setting service to automatic start'
        Set-Service -Name $ServiceName -StartupType Automatic
    }
} else {
    Write-Step "Creating service $ServiceName"
    # The Host sets ContentRoot to its own exe directory, so appsettings and
    # queries/ resolve even though a service process starts in System32.
    New-Service -Name $ServiceName `
        -BinaryPathName $binPath `
        -DisplayName 'MesIngest MES Task Ingest' `
        -StartupType Automatic | Out-Null
}

# ---------------------------------------------------------------- firewall ---

if ($cfg.firewallRule) {
    $ruleName = 'MesIngest Host HTTP'
    $shown = & netsh advfirewall firewall show rule name="$ruleName" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Adding firewall rule '$ruleName' (TCP $($cfg.port) inbound)"
        # Narrow on purpose: one port, TCP, inbound. em4 currently sits in the
        # Private profile and that profile is off, so this changes nothing today
        # — it exists so that turning a profile on later does not silently take
        # the service off the network.
        & netsh advfirewall firewall add rule `
            name="$ruleName" `
            dir=in action=allow protocol=TCP localport=$($cfg.port) `
            profile=any description='MesIngest read-only V2 API' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "netsh advfirewall add rule failed (exit $LASTEXITCODE)" }
    } else {
        Write-Step "Firewall rule '$ruleName' already present"
    }
}

# --------------------------------------------------------------- shortcut ---

if ($cfg.installWatch -and $cfg.publicDesktopShortcut) {
    $watchExe = Join-Path $InstallRoot 'watch\MesIngest.Watch.exe'
    if (Test-Path -LiteralPath $watchExe) {
        $lnkPath = 'C:\Users\Public\Desktop\MesIngest Watch.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = $watchExe
        $lnk.WorkingDirectory = (Split-Path -Parent $watchExe)
        $lnk.Description = 'MesIngest 盯盘客户端（只读）'
        $lnk.Save()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        Write-Step "Desktop shortcut: $lnkPath -> $watchExe"
    } else {
        Write-Warning 'installWatch is set but the package has no watch\MesIngest.Watch.exe; no shortcut created.'
    }
}

# ------------------------------------------------------------------- start ---

Write-Step "Starting service $ServiceName"
Start-Service -Name $ServiceName

# A first start against an empty database creates schema v29 before the API
# answers, so this waits minutes rather than seconds. A start failure surfaces
# in the Windows Application event log — the Host writes there when it runs as a
# service, and a configuration rejection is a startup exception, not a 500.
$healthUrl = "http://127.0.0.1:$($cfg.port)/api/v2/contract"
$headers = @{ Authorization = "Bearer $($cfg.sharedSecret)" }
$deadline = (Get-Date).AddMinutes(5)
$healthy = $false
$lastError = $null

Write-Step "Polling $healthUrl (up to 5 minutes; a first start builds the schema)"
while ((Get-Date) -lt $deadline) {
    $svc = Get-Service -Name $ServiceName
    if ($svc.Status -ne 'Running') {
        throw "Service $ServiceName is $($svc.Status). Check the Windows Application event log for MesIngest.Host."
    }
    try {
        $response = Invoke-RestMethod -Uri $healthUrl -Headers $headers -TimeoutSec 10
        $healthy = $true
        Write-Step "Contract: version=$($response.contractVersion) schema=$($response.schemaVersion)"
        break
    } catch {
        $lastError = $_.Exception.Message
        Start-Sleep -Seconds 5
    }
}

if (-not $healthy) {
    throw "Service started but $healthUrl never answered within 5 minutes. Last error: $lastError"
}

# --------------------------------------------------------------- clean up ---

# The config held three plaintext secrets. It has done its job.
Remove-Item -LiteralPath $DeploymentConfigPath -Force
Write-Step "Removed deployment config $DeploymentConfigPath"

Write-Step "MesIngest deployed to $InstallRoot and answering on port $($cfg.port)"
if (Test-Path -LiteralPath $previousRoot) {
    Write-Step "Previous package kept at $previousRoot (roll back with -Rollback)"
}
