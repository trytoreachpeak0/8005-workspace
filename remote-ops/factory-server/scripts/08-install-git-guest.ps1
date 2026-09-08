#Requires -Version 7
<#
.SYNOPSIS
    Install Git for Windows inside a guest. Runs in the guest, not the host.

.DESCRIPTION
    A self-hosted GitHub Actions runner needs git on PATH; actions/checkout
    falls back to a REST tarball without it and git-dependent steps then fail in
    confusing ways.

    The guest reaches github.com directly, so the download this script performs
    works as written. That was not true between 2026-09-02 and 2026-09-08, and
    this comment used to say so: github.com:443 appeared unreachable from both
    the guest and the factory server. The cause turned out to be WinNAT on the
    host running out of ephemeral ports, not anything about GitHub — see
    8005-agv-control-server issue #7.

    -InstallerPath is kept for a guest that really is offline. Stage it with:

        curl -sL -o Git-2.55.0.5-64-bit.exe \
          https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe
        scp Git-2.55.0.5-64-bit.exe vm01:C:/agv-ops/downloads/
        ssh vm01 "pwsh -NoProfile -File C:\agv-ops\08-install-git-guest.ps1 -InstallerPath C:\agv-ops\downloads\Git-2.55.0.5-64-bit.exe"

    The version is pinned rather than "latest" so the CI machine and the control
    machine resolve the same git. CRLFOption is pinned for a sharper reason: the
    two must agree on line endings, or a build passes in one place and fails in
    the other for reasons that look like a code defect. CRLFAlways is
    core.autocrlf=true, which is what the control machine has at system level.
    Per-file byte rules in a repository's .gitattributes still win, which is what
    keeps 8005-mes-ingest's two SHA-256-pinned query.sql files byte-stable.

.EXAMPLE
    pwsh -NoProfile -File 08-install-git-guest.ps1 -InstallerPath C:\agv-ops\downloads\Git-2.55.0.5-64-bit.exe
#>
[CmdletBinding()]
param(
    [string]$Version = '2.55.0.5',
    [string]$Tag = 'v2.55.0.windows.5',
    [string]$InstallerPath,
    [string]$WorkDir = 'C:\agv-ops\downloads',
    [switch]$KeepInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gitExe = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'

if (Test-Path -LiteralPath $gitExe) {
    $current = (& $gitExe --version) -replace '^git version ', ''
    if ($current -like "$Version*") {
        Write-Output "git $current 已安装，跳过。"
        exit 0
    }
    Write-Output "已安装 git $current，将换成 $Version。"
}

$staged = $false
if ($InstallerPath) {
    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        throw "找不到 -InstallerPath 指定的安装包：$InstallerPath"
    }
    $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
    $staged = $true
    Write-Output ("使用已暂存的安装包 {0}（{1} MB）。" -f (Split-Path $installer -Leaf), [math]::Round((Get-Item $installer).Length / 1MB, 1))
}
else {
    $installer = Join-Path $WorkDir "Git-$Version-64-bit.exe"
    $url = "https://github.com/git-for-windows/git/releases/download/$Tag/Git-$Version-64-bit.exe"
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    Write-Output "正在下载 $url ..."
    Write-Output '如果这一步挂住，说明本机到 github.com 不通——改用 -InstallerPath 从控制端暂存。'
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 300
    }
    finally {
        $ProgressPreference = $previousProgress
    }
}

Write-Output '正在静默安装 ...'
$installArgs = @(
    '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-',
    '/o:PathOption=Cmd',
    '/o:CRLFOption=CRLFAlways'
)
$proc = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "安装程序返回 $($proc.ExitCode)。安装包保留在 $installer 供排查。"
}

if (-not $KeepInstaller -and -not $staged) {
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $gitExe)) { throw "安装后仍未找到 $gitExe。" }

Write-Output ''
Write-Output ('git        ' + ((& $gitExe --version) -replace '^git version ', ''))
Write-Output ('autocrlf   ' + (& $gitExe config --system core.autocrlf))
