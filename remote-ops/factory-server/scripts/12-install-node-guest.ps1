#Requires -Version 7
<#
.SYNOPSIS
    Install Node.js and pnpm inside a guest. Runs in the guest, not the host.

.DESCRIPTION
    8005-agv-protocol's G1 gate is `pnpm g1`, a Node script. Nothing else in the
    workspace needs Node, which is why the guest did not have it — and neither
    does the control machine, so that gate has never actually run on a machine
    here. A runner for that repository is the first place it will.

    The version is pinned rather than "current LTS" for the same reason the .NET
    SDK is: a toolchain that drifts produces failures that look like code
    defects. pnpm comes from corepack, which ships with Node.

    Downloads go through the proxy configured by 09-configure-guest-proxy.ps1
    when nodejs.org is not directly reachable; -InstallerPath takes a locally
    staged MSI instead.

.EXAMPLE
    pwsh -NoProfile -File 12-install-node-guest.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '24.20.0',
    [string]$PnpmVersion = 'latest',
    [string]$InstallerPath,
    [string]$WorkDir = 'C:\agv-ops\downloads',
    [switch]$KeepInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$nodeExe = Join-Path $env:ProgramFiles 'nodejs\node.exe'

if (Test-Path -LiteralPath $nodeExe) {
    $current = (& $nodeExe --version) -replace '^v', ''
    if ($current -eq $Version) {
        Write-Output "Node $current 已安装，跳过安装。"
    }
    else {
        Write-Output "已安装 Node $current，将换成 $Version。"
        Remove-Item Env:\NODE_SKIP -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $nodeExe) -or ((& $nodeExe --version) -replace '^v', '') -ne $Version) {
    $msiName = "node-v$Version-x64.msi"
    $msi = $InstallerPath ? (Resolve-Path -LiteralPath $InstallerPath).Path : (Join-Path $WorkDir $msiName)

    if (-not (Test-Path -LiteralPath $msi)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        $url = "https://nodejs.org/dist/v$Version/$msiName"
        Write-Output "正在下载 $msiName ..."
        $previousProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing -TimeoutSec 600 }
        finally { $ProgressPreference = $previousProgress }
    }
    Write-Output ("使用安装包 {0}（{1} MB）。" -f (Split-Path $msi -Leaf), [math]::Round((Get-Item $msi).Length / 1MB, 1))

    Write-Output '正在静默安装 ...'
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
    if ($proc.ExitCode -notin @(0, 3010)) {
        throw "msiexec 返回 $($proc.ExitCode)。安装包保留在 $msi 供排查。"
    }
    if (-not $KeepInstaller -and -not $InstallerPath) {
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $nodeExe)) { throw "安装后仍未找到 $nodeExe。" }
}

# corepack ships with Node and is how pnpm is meant to be installed; a global
# `npm i -g pnpm` would put a second, unmanaged copy on PATH.
$nodeDir = Join-Path $env:ProgramFiles 'nodejs'
$corepack = Join-Path $nodeDir 'corepack.cmd'
if (-not (Test-Path -LiteralPath $corepack)) { throw "找不到 corepack：$corepack" }

# corepack resolves `node` through PATH. A just-installed Node is on the machine
# PATH but not on this process's, which only new processes inherit — without this
# `corepack enable` fails with a which() lookup error that names nothing useful.
if ($env:PATH -notlike "*$nodeDir*") { $env:PATH = $nodeDir + [IO.Path]::PathSeparator + $env:PATH }

Write-Output '正在启用 corepack 并安装 pnpm ...'
& $corepack enable
if ($LASTEXITCODE -ne 0) { throw "corepack enable 返回 $LASTEXITCODE。" }
& $corepack prepare "pnpm@$PnpmVersion" --activate
if ($LASTEXITCODE -ne 0) { throw "corepack prepare 返回 $LASTEXITCODE。" }

Write-Output ''
Write-Output ('node     ' + (& $nodeExe --version))
Write-Output ('npm      ' + (& (Join-Path $nodeDir 'npm.cmd') --version))
$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
Write-Output ('pnpm     ' + ($pnpm ? ((& pnpm --version) + '  ' + $pnpm.Source) : '(未找到)'))
