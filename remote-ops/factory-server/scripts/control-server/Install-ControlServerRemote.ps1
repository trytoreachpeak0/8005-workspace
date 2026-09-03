#Requires -Version 7
<#
.SYNOPSIS
    Installs or upgrades the ControlServer half of a WIRE_TO_GATE release
    package. Runs ON the factory server, invoked by 15-deploy-control-server.ps1
    from the control host.

.DESCRIPTION
    This is orchestration only. The install itself is done by the product
    scripts that ship inside the package -- scripts\Install-ControlServerLocal.ps1
    for a first install and scripts\Update-ControlServerLocal.ps1 for an upgrade
    -- because those two carry the backup, ACL, lifecycle-check and rollback
    behaviour that RELEASE-CANDIDATE.md sections 4.2 and 4.5 document. Nothing
    here reimplements them.

    What this script adds around them:

      * hash verification before anything is unpacked;
      * the secrets, placed where the product scripts expect to find them
        (user scope for the RIoT key, machine scope for the onboard credential)
        rather than on a command line;
      * the MesIngest bearer token, which the product scripts do not inject;
      * firewall rules for the two ports a non-loopback deployment exposes;
      * one previous generation kept on disk, so -Rollback is a real operation
        and not a re-download.

.PARAMETER PackageZip
    The release zip already copied to the staging directory.

.PARAMETER ExpectedSha256
    Hash the control host verified before copying. Verified again here: a
    truncated scp is exactly the failure this catches.

.PARAMETER DeploymentConfigPath
    JSON holding the secrets and the listen addresses. Deleted when this script
    finishes, however it finishes.

.PARAMETER Rollback
    Reinstall the previous generation from PackageRoot.previous. Downloads
    nothing and needs no config.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string] $PackageZip,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string] $ExpectedSha256,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string] $DeploymentConfigPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch] $Rollback,

    [string] $PackageRoot = 'D:\zhengyushao\ControlServer',

    [string] $ServiceName = '8005 AGV ControlServer'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$previousRoot = "$PackageRoot.previous"
$resultRoot = 'D:\zhengyushao\control-server-ops\results'
# Matches Install-ControlServerLocal.ps1's -DataRoot default; the log directory
# under it is where the service's Serilog file sink writes.
$script:dataRoot = 'C:\ProgramData\8005\ControlServer'

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message)
}

function Assert-Administrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run elevated.'
    }
}

# The product install and upgrade scripts have different parameter sets and
# different preconditions, and which one applies is a property of the machine,
# not of the caller's intent. Deciding it here keeps one command on the control
# host for both the first deployment and every one after it.
function Invoke-ProductInstaller {
    param([string] $PackageDirectory, [string] $ResultPath, [string] $DiagnosticPath)

    $scripts = Join-Path $PackageDirectory 'scripts'
    $payload = Join-Path $PackageDirectory 'controlserver'
    if (-not (Test-Path -LiteralPath $payload -PathType Container)) {
        throw "The package has no controlserver directory: $payload"
    }

    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Step 'Upgrading the existing service with Update-ControlServerLocal.ps1'
        & (Join-Path $scripts 'Update-ControlServerLocal.ps1') `
            -PackagePath $payload -ResultPath $ResultPath -DiagnosticPath $DiagnosticPath `
            -VerifySafetyProjectionReadOnly
    } else {
        Write-Step 'First install with Install-ControlServerLocal.ps1'
        & (Join-Path $scripts 'Install-ControlServerLocal.ps1') `
            -PackagePath $payload -ResultPath $ResultPath -DiagnosticPath $DiagnosticPath `
            -ListenAddress $script:listenAddress -HealthBindAddress $script:healthBindAddress `
            -OnboardPort $script:onboardPort -HealthPort $script:healthPort `
            -CopyUserRiotSecretToMachine
    }
}

Assert-Administrator
New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultPath = Join-Path $resultRoot "install-$runId.json"
$diagnosticPath = Join-Path $resultRoot "install-$runId.log"

# ---------------------------------------------------------------- rollback ---

if ($Rollback) {
    if (-not (Test-Path -LiteralPath $previousRoot -PathType Container)) {
        throw "No previous generation at $previousRoot. Nothing to roll back to."
    }
    Write-Step "Rolling back to the package in $previousRoot"

    # Swap the directories rather than copy, so rolling back a rollback is the
    # same operation again.
    $swap = "$PackageRoot.rollback-$runId"
    if (Test-Path -LiteralPath $PackageRoot) { Move-Item -LiteralPath $PackageRoot -Destination $swap }
    Move-Item -LiteralPath $previousRoot -Destination $PackageRoot
    if (Test-Path -LiteralPath $swap) { Move-Item -LiteralPath $swap -Destination $previousRoot }

    # A rollback always upgrades in place -- the service exists by definition,
    # so Update-ControlServerLocal.ps1 runs and these four are not consulted.
    $script:listenAddress = '0.0.0.0'
    $script:healthBindAddress = '0.0.0.0'
    $script:onboardPort = 58005
    $script:healthPort = 58007
    Invoke-ProductInstaller -PackageDirectory $PackageRoot -ResultPath $resultPath -DiagnosticPath $diagnosticPath
    Write-Step "Rolled back. Result: $resultPath"
    return
}

# ------------------------------------------------------------------ verify ---

try {
    if (-not (Test-Path -LiteralPath $PackageZip -PathType Leaf)) {
        throw "Package not found: $PackageZip"
    }
    $actual = (Get-FileHash -LiteralPath $PackageZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Package hash mismatch on the server. Expected $expected, got $actual."
    }
    Write-Step "Package hash verified ($actual)"

    $config = Get-Content -Raw -LiteralPath $DeploymentConfigPath | ConvertFrom-Json
    $script:listenAddress = $config.listenAddress
    $script:healthBindAddress = $config.healthBindAddress
    $script:onboardPort = [int]$config.onboardPort
    $script:healthPort = [int]$config.healthPort

    # -------------------------------------------------------------- unpack ---

    $staged = "$PackageRoot.incoming-$runId"
    if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
    Expand-Archive -LiteralPath $PackageZip -DestinationPath $staged -Force
    Write-Step "Unpacked to $staged"

    $manifestPath = Join-Path $staged 'release-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The package carries no release-manifest.json; refusing to install it.'
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    Write-Step ('Release: controlserver {0}  onboard {1}' -f
        $manifest.components.controlServer.commit.Substring(0, 7),
        $manifest.components.onboardHmi.commit.Substring(0, 7))

    # ------------------------------------------------------------- secrets ---

    # Install-ControlServerLocal.ps1 reads the RIoT key from the *user* scope and
    # the onboard credential from the *machine* scope, and throws when either is
    # missing. Both reads go to the registry rather than to this process's
    # environment block, so setting them here is visible to the child process.
    [Environment]::SetEnvironmentVariable('CONTROL_SERVER_RIOT_CALL_API_KEY', $config.riotCallApiKey, 'User')
    [Environment]::SetEnvironmentVariable('CONTROL_SERVER_ONBOARD_CREDENTIAL', $config.onboardCredential, 'Machine')
    Write-Step 'Secrets placed in the scopes the product installer reads'

    # ------------------------------------------------------------- install ---

    Invoke-ProductInstaller -PackageDirectory $staged -ResultPath $resultPath -DiagnosticPath $diagnosticPath

    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "The product installer produced no result file at $resultPath."
    }
    $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
    Write-Step "Installer result written to $resultPath"

    # ---------------------------------------------------- MesIngest secret ---

    # Neither product script injects this one. MesIngest binds 0.0.0.0 on this
    # machine, so its middleware requires a Bearer token from every caller
    # including the loopback one -- and ControlServer becomes such a caller the
    # moment JourneyRuntime is enabled. Appending it now means enabling
    # JourneyRuntime later is a configuration change, not a redeployment.
    if ($config.PSObject.Properties.Name -contains 'mesIngestSharedSecret' -and $config.mesIngestSharedSecret) {
        $key = "SYSTEM\CurrentControlSet\Services\$ServiceName"
        $registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($key, $true)
        if ($null -eq $registryKey) { throw "Cannot open the service registry key: $key" }
        try {
            [string[]]$environment = @($registryKey.GetValue('Environment'))
            $environment = @($environment | Where-Object { $_ -notlike 'CONTROL_SERVER_MES_INGEST_SHARED_SECRET=*' })
            $environment += "CONTROL_SERVER_MES_INGEST_SHARED_SECRET=$($config.mesIngestSharedSecret)"
            $registryKey.SetValue('Environment', $environment, [Microsoft.Win32.RegistryValueKind]::MultiString)
        } finally {
            $registryKey.Close()
        }
        Restart-Service -Name $ServiceName -Force
        Write-Step 'MesIngest bearer token added to the service environment; service restarted'
    }

    # ------------------------------------------------------------ firewall ---

    # A non-loopback deployment is only reachable if these are open, and section
    # 11.1 is explicit that opening them is the exposure: the health, version
    # and runtime-session endpoints share Kestrel's single binding with the
    # vehicle-safety projection.
    foreach ($port in @($script:onboardPort, $script:healthPort)) {
        $ruleName = "8005 AGV ControlServer $port"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $port -Profile Any | Out-Null
    }
    Write-Step "Firewall open for TCP $($script:onboardPort) and $($script:healthPort)"

    # --------------------------------------------------------------- check ---

    # Loopback only. Whether the onboard machines can reach the non-loopback
    # binding is a different question, answered from the control host, which at
    # least sits on another machine. Server 2016 has no curl.exe, so this uses
    # -NoProxy to get the same "read the body, do not trust a handshake"
    # property RELEASE-CANDIDATE.md section 4.4 asks for.
    $probeHost = if ($script:healthBindAddress -in @('0.0.0.0', '*', '+', '::', '[::]')) {
        '127.0.0.1'
    } else {
        $script:healthBindAddress
    }
    $live = Invoke-WebRequest -Uri "http://${probeHost}:$($script:healthPort)/health/live" `
        -NoProxy -TimeoutSec 15 -UseBasicParsing
    if ($live.StatusCode -ne 200) { throw "health/live returned $($live.StatusCode)." }
    Write-Step "health/live 200: $($live.Content)"

    # ------------------------------------------------------------ shortcuts ---

    # ControlServer is a Windows service built on Microsoft.NET.Sdk.Web with
    # UseWindowsService -- it has no window and nothing to double-click. A
    # shortcut to ControlServer.Host.exe would start a *second* instance that
    # fights the service for port 58005 and for the same SQLite file, so the
    # desktop gets the two things an operator actually needs instead: the logs,
    # and a readiness page they can refresh.
    $desktop = 'C:\Users\Public\Desktop'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $logDirectory = Join-Path $script:dataRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        $lnk = $shell.CreateShortcut((Join-Path $desktop '8005 ControlServer 日志.lnk'))
        $lnk.TargetPath = $logDirectory
        $lnk.Description = '8005 AGV ControlServer 运行日志（NDJSON，按天滚动）'
        $lnk.Save()
        Write-Step "Desktop shortcut: 8005 ControlServer 日志 -> $logDirectory"
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }

    # A .url rather than a .lnk: this one opens in a browser, and the readiness
    # body is the thing worth reading -- a handshake proves nothing here.
    $readyUrl = "http://${probeHost}:$($script:healthPort)/health/ready"
    $urlPath = Join-Path $desktop '8005 ControlServer 健康检查.url'
    @(
        '[InternetShortcut]'
        "URL=$readyUrl"
    ) | Set-Content -LiteralPath $urlPath -Encoding ascii
    Write-Step "Desktop shortcut: 8005 ControlServer 健康检查 -> $readyUrl"

    # ---------------------------------------------------- generation swap ---

    if (Test-Path -LiteralPath $previousRoot) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
    if (Test-Path -LiteralPath $PackageRoot) { Move-Item -LiteralPath $PackageRoot -Destination $previousRoot }
    Move-Item -LiteralPath $staged -Destination $PackageRoot
    Write-Step "Package at $PackageRoot; previous generation kept at $previousRoot"

    Write-Step 'Deployment complete.'
    Write-Output "RESULT_PATH=$resultPath"

    # The two product scripts do not write the same result schema. A first
    # install reports onboardTransportEndpoint and httpEndpoint; an upgrade
    # reports healthEndpoint and neither of the others, because it keeps the
    # existing appsettings.Production.json and therefore does not decide the
    # bindings at all. Reading a field only one of them writes crashed the
    # first upgrade that followed a successful install.
    foreach ($pair in @(
        @{ Label = 'ONBOARD_ENDPOINT'; Fields = @('onboardTransportEndpoint') }
        @{ Label = 'HEALTH_ENDPOINT';  Fields = @('httpEndpoint', 'healthEndpoint') }
    )) {
        $value = $null
        foreach ($field in $pair.Fields) {
            if ($result.PSObject.Properties.Name -contains $field) {
                $value = $result.$field
                break
            }
        }
        if ($value) {
            Write-Output "$($pair.Label)=$value"
        } else {
            Write-Output "$($pair.Label)=(unchanged; the upgrade kept the existing binding)"
        }
    }

} finally {
    # The config held three plaintext secrets for the length of one install.
    if ($DeploymentConfigPath -and (Test-Path -LiteralPath $DeploymentConfigPath)) {
        Remove-Item -LiteralPath $DeploymentConfigPath -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path (Split-Path -Parent $PackageRoot) -Directory -Filter '*.incoming-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
