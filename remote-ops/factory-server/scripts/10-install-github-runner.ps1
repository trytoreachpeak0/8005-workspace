#Requires -Version 7
<#
.SYNOPSIS
    Install and register a self-hosted GitHub Actions runner as a Windows
    service. Runs in the guest, not the host.

.DESCRIPTION
    trytoreachpeak0 is a personal account, not an organisation, so a runner
    registers against exactly one repository. Running CI for several
    repositories on this machine means several runner instances in separate
    directories with separate service names — which is what -InstallDir and
    -RunnerName are for.

    That has a consequence worth stating plainly: separate runners take jobs
    concurrently, and the golden-renderer suites require an exclusive desktop.
    Cross-repository exclusion is not something GitHub's `concurrency` can
    express, so it stays the desktop mutex's job inside 8005-mes-ingest. Do not
    rely on "one runner at a time" to provide it.

    The registration token is read from a file rather than a parameter so it
    never reaches a process listing, a shell history or a transcript. It is
    valid for one hour and is consumed by registration; the file is deleted
    afterwards. It is not the runner's long-lived credential — that is
    .credentials in the runner directory, created by config.cmd.

    Service mode runs the runner in session 0, which is correct for everything
    that does not touch a desktop. The WPF golden-renderer suites need an
    interactive session and therefore a different runner started from a logged-on
    desktop; that is a later step and needs autologon first.

.PARAMETER RepoUrl
    Full repository URL, e.g. https://github.com/trytoreachpeak0/riot-sdk

.PARAMETER TokenPath
    File containing the registration token and nothing else. Deleted on success.

.PARAMETER Labels
    Extra labels beyond the defaults. Workflows select the runner with these.

.EXAMPLE
    pwsh -NoProfile -File 10-install-github-runner.ps1 `
        -RepoUrl https://github.com/trytoreachpeak0/riot-sdk `
        -TokenPath C:\agv-ops\runner-token.txt `
        -RunnerName win11-01-riot-sdk -Labels 'win11-01,dotnet8'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoUrl,
    [Parameter(Mandatory)][string]$TokenPath,
    [Parameter(Mandatory)][string]$RunnerName,
    [string]$Labels = 'win11-01',
    [string]$Version = '2.337.0',
    [string]$InstallDir,
    [string]$InstallerPath,
    [string]$WorkDir = 'C:\agv-ops\downloads'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $InstallDir) { $InstallDir = "C:\actions-runner\$RunnerName" }

if (-not (Test-Path -LiteralPath $TokenPath)) {
    throw "找不到令牌文件：$TokenPath"
}
$token = (Get-Content -LiteralPath $TokenPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($token)) { throw "令牌文件是空的：$TokenPath" }

if (Test-Path -LiteralPath (Join-Path $InstallDir '.runner')) {
    Write-Output "$InstallDir 已经注册过 runner。要重装先执行 config.cmd remove。"
    Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue |
        Select-Object Name, Status | Format-Table -AutoSize | Out-String | Write-Output
    exit 0
}

$zipName = "actions-runner-win-x64-$Version.zip"
$zip = $InstallerPath ? (Resolve-Path -LiteralPath $InstallerPath).Path : (Join-Path $WorkDir $zipName)

if (-not (Test-Path -LiteralPath $zip)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $url = "https://github.com/actions/runner/releases/download/v$Version/$zipName"
    Write-Output "正在下载 $zipName ..."
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600 }
    finally { $ProgressPreference = $previousProgress }
}
Write-Output ("使用安装包 {0}（{1} MB）。" -f (Split-Path $zip -Leaf), [math]::Round((Get-Item $zip).Length / 1MB, 1))

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $InstallDir -Force

# The runner reads .proxy itself. The environment variables set by
# 09-configure-guest-proxy.ps1 cover the job's own tooling; this covers the
# runner's control-plane traffic, which starts before any job environment exists.
$proxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine')
if ($proxy) {
    Set-Content -LiteralPath (Join-Path $InstallDir '.proxy') -Value $proxy -NoNewline -Encoding ascii
    $noProxy = [Environment]::GetEnvironmentVariable('NO_PROXY', 'Machine')
    if ($noProxy) {
        Set-Content -LiteralPath (Join-Path $InstallDir '.noproxy') -Value $noProxy -NoNewline -Encoding ascii
    }
    Write-Output "已写入 .proxy（$proxy）。"
}

Write-Output '正在注册并安装为服务 ...'
Push-Location $InstallDir
try {
    & .\config.cmd --unattended --url $RepoUrl --token $token `
        --name $RunnerName --labels $Labels --work '_work' --runasservice --replace
    if ($LASTEXITCODE -ne 0) { throw "config.cmd 返回 $LASTEXITCODE。" }
}
finally {
    Pop-Location
}

Remove-Item -LiteralPath $TokenPath -Force -ErrorAction SilentlyContinue

$svc = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*$RunnerName*" } | Select-Object -First 1
if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name $svc.Name }

Write-Output ''
Write-Output '=== runner 服务 ==='
Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Output
