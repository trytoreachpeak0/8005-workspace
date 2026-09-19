#Requires -Version 7
<#
.SYNOPSIS
    Install win11-01-control-server-desktop: an interactive (session 1) runner
    for 8005-agv-control-server on vm01, labelled cs-desktop. Runs on the
    control machine, not the guest.

.DESCRIPTION
    The control server's real-rig L2 starts the onboard WPF client and
    slots-simulator as real windows and drives them with UI Automation. That
    needs the logged-on desktop, which the two existing control-server runners
    (Windows services in session 0) do not have. The user approved moving
    real-rig runs off the control laptop onto vm01 on 2026-09-19
    (ci-research/real-rig-bottleneck.md in the v2 workspace, plan b).

    This is the same shape as win11-01-mes-ingest-desktop, and it reuses the
    same installer: 10-install-github-runner.ps1 -Interactive registers a
    logon-triggered scheduled task (GitHubRunner-<name>, user agvops,
    LogonType Interactive, RunLevel Highest) that starts run.cmd minimised in
    the autologon session. A personal account binds a runner to one repository,
    so the mes-ingest one cannot be borrowed.

    Labels, and why each one is or is not there:
      - cs-desktop: what l2.yml's real-rig job selects on.
      - not headless: l2.yml and release.yml select [self-hosted, headless];
        this runner must never pick those up, or a synthetic run would land on
        the golden-renderer desktop.
      - not cs-test: test.yml selects that; it belongs to the second service
        runner only.
      - not golden-renderer: that label is 8005-mes-ingest's contract.

    The registration token never touches the control machine's disk, a command
    line on either machine, or this script's output. It goes from `gh api`
    into memory, then over ssh stdin into the token file the installer
    consumes, and that file is removed in `finally` whether or not the install
    succeeded. config.cmd itself still receives it as an argument inside the
    guest; that is the runner's own interface and the token is single-use and
    expires within the hour.

    Proxy: nothing to do here. The runner reads only the machine-level
    http_proxy/https_proxy/NO_PROXY variables that 09-configure-guest-proxy.ps1
    set, and a process started at logon inherits them.

.PARAMETER Remove
    Unregister the runner from GitHub, delete its scheduled task and its
    directory. Waits for nothing: check it is idle first
    (gh api repos/trytoreachpeak0/8005-agv-control-server/actions/runners).

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/18-install-control-server-desktop-runner.ps1
#>
[CmdletBinding()]
param(
    [string]$SshAlias = 'vm01',
    [string]$Repository = 'trytoreachpeak0/8005-agv-control-server',
    [string]$RunnerName = 'win11-01-control-server-desktop',
    [string]$Labels = 'win11-01,dotnet8,cs-desktop',
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guestOps = 'C:\agv-ops'
$guestInstaller = "$guestOps\10-install-github-runner.ps1"
$guestTokenPath = "$guestOps\runner-token-$RunnerName.txt"
$installDir = "C:\actions-runner\$RunnerName"
$taskName = "GitHubRunner-$RunnerName"

function Invoke-Guest {
    param([Parameter(Mandatory)][string]$Script, [string]$InputText)
    # -EncodedCommand keeps quoting out of the ssh/cmd/pwsh chain; the script
    # itself never carries a secret, so its appearing in a process listing is
    # harmless. Secrets travel on stdin only.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $InputText | ssh $SshAlias "pwsh -NoProfile -NonInteractive -EncodedCommand $encoded"
    }
    else {
        ssh $SshAlias "pwsh -NoProfile -NonInteractive -EncodedCommand $encoded"
    }
    if ($LASTEXITCODE -ne 0) { throw "客户机上的步骤返回 $LASTEXITCODE。" }
}

if ($Remove) {
    $token = gh api -X POST "repos/$Repository/actions/runners/remove-token" --jq .token
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw '取不到 remove-token。' }
    try {
        Invoke-Guest -InputText $token -Script @"
`$ErrorActionPreference = 'Stop'
`$token = [Console]::In.ReadToEnd().Trim()
Stop-ScheduledTask -TaskName '$taskName' -ErrorAction SilentlyContinue
Get-Process Runner.Listener, Runner.Worker -ErrorAction SilentlyContinue |
    Where-Object { `$_.Path -like '$installDir\*' } | Stop-Process -Force
Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath '$installDir\.runner') {
    Push-Location '$installDir'
    try { & .\config.cmd remove --token `$token } finally { Pop-Location }
}
Remove-Item -LiteralPath '$installDir' -Recurse -Force -ErrorAction SilentlyContinue
'已移除 $RunnerName。'
"@
    }
    finally { $token = $null }
    return
}

$installer = Join-Path $PSScriptRoot '10-install-github-runner.ps1'
scp -q $installer "${SshAlias}:$($guestInstaller -replace '\\', '/')"
if ($LASTEXITCODE -ne 0) { throw "scp 安装脚本到 $SshAlias 失败。" }

$token = gh api -X POST "repos/$Repository/actions/runners/registration-token" --jq .token
if ($LASTEXITCODE -ne 0 -or -not $token) { throw '取不到 registration-token。' }
try {
    # Token file written from stdin, installer run, token file removed in the
    # same guest process so that no failure path can leave it behind.
    Invoke-Guest -InputText $token -Script @"
`$ErrorActionPreference = 'Stop'
try {
    [IO.File]::WriteAllText('$guestTokenPath', [Console]::In.ReadToEnd().Trim())
    & pwsh -NoProfile -File '$guestInstaller' ``
        -RepoUrl 'https://github.com/$Repository' ``
        -TokenPath '$guestTokenPath' ``
        -RunnerName '$RunnerName' ``
        -Labels '$Labels' ``
        -Interactive
    if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
}
finally {
    # The installer deletes it on success; this covers every other path.
    if (Test-Path -LiteralPath '$guestTokenPath') { Remove-Item -LiteralPath '$guestTokenPath' -Force }
}
exit 0
"@
}
finally { $token = $null }

Invoke-Guest -Script @"
if (Test-Path -LiteralPath '$guestTokenPath') { throw '令牌文件没被删掉：$guestTokenPath' }
Get-Process Runner.Listener -IncludeUserName -ErrorAction SilentlyContinue |
    Where-Object { `$_.Path -like '$installDir\*' } |
    Select-Object Id, SessionId, UserName | Format-Table -AutoSize | Out-String | Write-Output
"@

Write-Output "=== GitHub 侧（$Repository）==="
gh api "repos/$Repository/actions/runners" --jq '.runners[] | [.name, .status, .busy, ([.labels[].name] | join(","))] | @tsv'
Write-Output ''
Write-Output "下一步：更新 8005-workspace 根 CLAUDE.md 的 runner 表。"
