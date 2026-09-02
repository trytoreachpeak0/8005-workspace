#Requires -Version 7
<#
.SYNOPSIS
    Install the pinned .NET SDK inside a guest. Runs in the guest, not the host.

.DESCRIPTION
    Installs the workspace-pinned SDK from the official installer rather than
    dotnet-install.ps1, because the .exe also carries the WindowsDesktop runtime
    that the WPF golden-renderer suites need; the install script's SDK archive
    is not guaranteed to.

    The pinned version is the one in every repository's global.json. See
    8005-agv-program/docs/adr/cross/0056-dotnet-toolchain-baseline.md. Do not
    install a different SDK here to "fix" a build — rollForward is disable, so a
    mismatch is meant to fail loudly.

    Idempotent: an already-installed matching SDK is left alone.

.PARAMETER Version
    SDK version to install. Defaults to the workspace baseline.

.PARAMETER WorkDir
    Where the installer is downloaded. Removed afterwards unless -KeepInstaller.

.EXAMPLE
    pwsh -NoProfile -File 07-install-dotnet-sdk-guest.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '8.0.424',
    [string]$WorkDir = 'C:\agv-ops\downloads',
    [switch]$KeepInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dotnetExe = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'

function Get-InstalledSdks {
    if (-not (Test-Path -LiteralPath $dotnetExe)) { return @() }
    & $dotnetExe --list-sdks 2>$null | ForEach-Object { ($_ -split ' ')[0] }
}

if ($Version -in (Get-InstalledSdks)) {
    Write-Output "SDK $Version 已安装，跳过。"
    & $dotnetExe --list-sdks
    exit 0
}

$url = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$Version/dotnet-sdk-$Version-win-x64.exe"
$installer = Join-Path $WorkDir "dotnet-sdk-$Version-win-x64.exe"

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

Write-Output "正在下载 $url ..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# Invoke-WebRequest's progress bar makes a 200 MB download roughly an order of
# magnitude slower over a non-interactive session.
$previousProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
    Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 600
}
finally {
    $ProgressPreference = $previousProgress
}
$sw.Stop()
$sizeMb = [math]::Round((Get-Item $installer).Length / 1MB, 1)
Write-Output ("下载完成 {0} MB，用时 {1} 秒。" -f $sizeMb, [math]::Round($sw.Elapsed.TotalSeconds, 1))

Write-Output '正在静默安装 ...'
$proc = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
# 3010 is "success, reboot required" and is normal for an SDK over an existing runtime.
if ($proc.ExitCode -notin @(0, 3010)) {
    throw "安装程序返回 $($proc.ExitCode)。安装包保留在 $installer 供排查。"
}
if ($proc.ExitCode -eq 3010) {
    Write-Output '安装程序要求重启（3010）。SDK 可用，重启可稍后安排。'
}

if (-not $KeepInstaller) { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }

$installed = Get-InstalledSdks
if ($Version -notin $installed) {
    throw "安装后仍未找到 SDK $Version。当前：$($installed -join ', ')"
}

Write-Output ''
Write-Output '=== SDK ==='
& $dotnetExe --list-sdks
Write-Output '=== Runtime ==='
& $dotnetExe --list-runtimes
