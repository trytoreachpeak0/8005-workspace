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

    Two modes. Service mode (default) runs the runner in session 0, which is
    correct for everything that does not touch a desktop. -Interactive instead
    registers a scheduled task that starts the runner inside the logged-on
    desktop session, which the WPF golden-renderer suites require: session 0 has
    no interactive window station, and WPF fails there with dispatcher
    thread-affinity errors rather than anything that names the real cause.
    -Interactive therefore depends on autologon already being configured, so the
    session exists after an unattended reboot.

    Label the two apart. A workflow that selects only [self-hosted, win11-01]
    would be picked up by whichever runner is free, which is exactly wrong when
    one of them cannot draw. Service runners carry 'headless'; the interactive
    one carries 'golden-renderer'.

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
    [string]$WorkDir = 'C:\agv-ops\downloads',
    [switch]$Interactive,
    [string]$RunnerUser = 'agvops'
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

# No .proxy file is written here, deliberately. This used to write one, on the
# belief that the runner reads it for its own control-plane traffic. It does
# not: this runner version takes the proxy from http_proxy/https_proxy/
# HTTP_PROXY/HTTPS_PROXY/NO_PROXY and nothing else — its own log says exactly
# that when they are absent, and the string `.proxy` appears in none of its
# assemblies (checked 2026-09-07 while chasing 8005-agv-control-server issue #7,
# where a bypass list written into .noproxy looked applied and changed nothing).
#
# 09-configure-guest-proxy.ps1 sets those machine-level variables and deletes
# any leftover files. Run it before the runner service starts, or restart the
# service after.

Write-Output ($Interactive ? '正在注册 runner（交互式）...' : '正在注册并安装为服务 ...')
Push-Location $InstallDir
try {
    $configArgs = @(
        '--unattended', '--url', $RepoUrl, '--token', $token,
        '--name', $RunnerName, '--labels', $Labels, '--work', '_work', '--replace'
    )
    if (-not $Interactive) { $configArgs += '--runasservice' }
    & .\config.cmd @configArgs
    if ($LASTEXITCODE -ne 0) { throw "config.cmd 返回 $LASTEXITCODE。" }
}
finally {
    Pop-Location
}

if ($Interactive) {
    $taskName = "GitHubRunner-$RunnerName"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    # start /min keeps run.cmd's console off the visible desktop. It still owns a
    # taskbar button; the golden-renderer suites capture individual WPF windows
    # rather than the whole screen, so that does not reach a baseline.
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' `
        -Argument "/c start /min `"$RunnerName`" `"$InstallDir\run.cmd`"" `
        -WorkingDirectory $InstallDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $RunnerUser
    # Interactive logon type is the whole point: it puts the process in the user's
    # desktop session instead of session 0.
    $principal = New-ScheduledTaskPrincipal -UserId $RunnerUser -LogonType Interactive -RunLevel Highest
    # ExecutionTimeLimit 0 means no limit — the listener is meant to run forever.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
    Write-Output "已注册计划任务 $taskName（登录时启动，交互式会话）。"

    Start-ScheduledTask -TaskName $taskName
    Write-Output '已启动。'
}

Remove-Item -LiteralPath $TokenPath -Force -ErrorAction SilentlyContinue

if (-not $Interactive) {
    $svc = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$RunnerName*" } | Select-Object -First 1
    if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name $svc.Name }
}

Write-Output ''
Write-Output '=== runner 服务（headless）==='
Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue |
    Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Output
Write-Output '=== runner 计划任务（交互式）==='
Get-ScheduledTask -TaskName 'GitHubRunner-*' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State | Format-Table -AutoSize | Out-String | Write-Output
