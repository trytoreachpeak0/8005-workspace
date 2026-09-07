#Requires -Version 7
<#
.SYNOPSIS
    Sets the guest's outbound HTTP(S) egress policy for CI. Runs in the guest,
    not the host.

.DESCRIPTION
    Two modes. What changed on 2026-09-07 is not the mode but the bypass list:
    the Actions plane moved off the proxy and onto the direct path.

      Proxy (default) — github.com and codeload.github.com go through the
        control machine's Clash proxy, because the plant network will not carry
        them. Everything else in -NoProxy is direct: the runner's control
        plane, the artifact upload, NuGet.

      Direct — nothing uses the proxy. Correct on the day github.com:443 stops
        being blocked. -Mode Direct verifies that before it commits to it.

    The measurements behind the split, taken from the guest on 2026-09-07/08
    with a 45-second timeout (a shorter one turns a slow path into a fake
    failure, which is how an earlier round of this got misread):

      | 端点                        | 直连  | 过代理 |
      | github.com HTTPS            |  0/8  | 12/12  |
      | codeload.github.com HTTPS   |  0/3  |   ✓    |
      | github.com:22 (TCP)         | 11/11 |   —    |
      | results-receiver HTTPS      | 12/12 | 10/12  |
      | blob.core.windows.net HTTPS | 11/12 |   —    |

    Two conclusions, pointing in opposite directions. github.com over HTTPS
    needs the proxy. The Actions plane is better off without it — the two
    failures on the proxied row are `SocketException 10060 (172.19.162.241:7890)`,
    the proxy hop itself, which is precisely what killed five release runs in a
    row on 2026-09-07: CreateArtifact, FinalizeArtifact and a git fetch, each a
    21-second TCP connect timeout to the proxy rather than to GitHub. See
    8005-agv-control-server issue #7.

    Switching nodes inside Clash is NOT the fix. It was tried: github.com
    through the proxy went from 2/10 failures to 10/10 successes, and the next
    release failed in exactly the same way. The bad leg is guest-to-proxy, not
    the proxy's own upstream.

    The end state that removes the proxy from CI altogether is SSH checkout —
    github.com:22 is direct and was the only endpoint that never failed a
    measurement — but that needs a deploy key per repository, so it is a
    separate decision, not something this script can do.

    Two places carry the setting:
      * machine-level environment variables — the runner, every action it runs,
        and the job's own tooling
      * git system config — actions/checkout

    Not three. The .proxy and .noproxy files that 10-install-github-runner.ps1
    used to write are inert: this runner version takes its proxy from
    http_proxy/https_proxy/HTTP_PROXY/HTTPS_PROXY/NO_PROXY and nothing else —
    its own log says so when they are absent, and the string `.proxy` does not
    appear in any of its assemblies (checked 2026-09-07). They are deleted here
    rather than maintained, because a file that looks like configuration and
    changes nothing costs an hour of debugging the first time it matters.

    A process reads its environment once, at start, so the change only lands on
    a restart. This script restarts the runner services — and refuses to while
    a job is running, because killing a job on this machine has cost 4h14m of
    dead runner session before.

.PARAMETER Mode
    Proxy (default) or Direct.

.PARAMETER ProxyAddress
    host:port of the proxy. The control machine's Wi-Fi address; check it there
    with Get-NetIPAddress, ignoring the Clash TUN adapter (198.18.x.x) and the
    vEthernet ones.

.PARAMETER NoProxy
    Comma-separated bypass list. Two rules govern what may go in it:

      * .NET does not treat an entry as a domain suffix — measured 2026-09-07,
        `github.com` bypasses github.com but not api.github.com — so anything a
        .NET client reaches needs its own full hostname. curl, the Node toolkit
        and the runner do match parent domains.
      * Never add a bare `github.com`. Under a suffix-matching client that would
        also bypass codeload.github.com, which is blocked direct, and action
        downloads would start failing on any runner with a cold _actions cache.

    blob.core.windows.net is a parent domain on purpose: the artifact blob host
    is assigned per upload (productionresultssa0, sa1, ...) and only Node ever
    talks to it.

.PARAMETER RunnerRoot
    Directory holding the runner installations, one subdirectory each.

.PARAMETER SkipRunnerRestart
    Write the configuration and stop. The runners keep the old setting until
    they are restarted by hand.

.EXAMPLE
    pwsh -NoProfile -File 09-configure-guest-proxy.ps1

.EXAMPLE
    pwsh -NoProfile -File 09-configure-guest-proxy.ps1 -Mode Direct
    pwsh -NoProfile -File 09-configure-guest-proxy.ps1 -ProxyAddress 172.19.162.99:7890
#>
[CmdletBinding()]
param(
    [ValidateSet('Proxy', 'Direct')]
    [string]$Mode = 'Proxy',

    [string]$ProxyAddress = '172.19.162.241:7890',

    [string[]]$NoProxy = @(
        'localhost'
        '127.0.0.1'
        '192.168.200.1'
        '192.168.200.50'
        '172.19.205.222'
        'api.nuget.org'
        'globalcdn.nuget.org'
        'objects.githubusercontent.com'
        'actions.githubusercontent.com'
        'pipelines.actions.githubusercontent.com'
        'results-receiver.actions.githubusercontent.com'
        'broker.actions.githubusercontent.com'
        'blob.core.windows.net'
    ),

    [string]$RunnerRoot = 'C:\actions-runner',

    [switch]$SkipRunnerRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$proxyUrl = "http://$ProxyAddress"
$noProxyValue = $NoProxy -join ','

# HEAD on the root of each: the status code is irrelevant, an answer is the
# point. Blob storage returns 400 and the Actions hosts 404 when asked like
# this; both mean the TLS handshake completed with the real service.
#
# api.nuget.org is deliberately absent. It redirects to nuget.azure.cn, which
# fails often enough on its own to make this gate lie about the proxy; restore
# has its own retries and has never been the thing that broke.
$mustBeDirect = @(
    'https://objects.githubusercontent.com/'
    'https://pipelines.actions.githubusercontent.com/'
    'https://results-receiver.actions.githubusercontent.com/'
    'https://broker.actions.githubusercontent.com/'
    'https://productionresultssa0.blob.core.windows.net/'
)
$mustGoThroughProxy = @(
    'https://github.com/'
    'https://codeload.github.com/'
    'https://api.github.com/'
)

# 45 seconds, three attempts. This path stalls for ten to sixteen seconds at a
# time; a 15-second probe reports those stalls as outages and sends whoever
# reads it chasing the wrong thing.
function Test-Endpoint([string]$Url, [string]$Proxy) {
    $last = '没有异常信息'
    foreach ($attempt in 1..3) {
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $request = @{ Uri = $Url; Method = 'Head'; TimeoutSec = 45; SkipHttpErrorCheck = $true }
            if ($Proxy) { $request.Proxy = $Proxy } else { $request.NoProxy = $true }
            $response = Invoke-WebRequest @request
            return [pscustomobject]@{ Ok = $true; Detail = "HTTP $($response.StatusCode)，$($sw.ElapsedMilliseconds) ms，第 $attempt 次" }
        }
        catch {
            $last = $_.Exception.Message -replace "`r?`n", ' '
        }
    }
    return [pscustomobject]@{ Ok = $false; Detail = "三次都失败：$last" }
}

# What this mode claims, checked before anything is written.
$checks = [ordered]@{}
foreach ($url in $mustBeDirect) { $checks[$url] = $null }
foreach ($url in $mustGoThroughProxy) { $checks[$url] = ($Mode -eq 'Direct') ? $null : $proxyUrl }

Write-Output "正在验证 $Mode 模式下 CI 需要的端点（每个最多试三次，单次 45 秒）..."
$failed = @()
foreach ($url in $checks.Keys) {
    $via = $checks[$url] ? '过代理' : '直连  '
    $result = Test-Endpoint -Url $url -Proxy $checks[$url]
    Write-Output ("  {0} {1,-58} {2}" -f $via, $url, ($result.Ok ? "OK  $($result.Detail)" : "失败  $($result.Detail)"))
    if (-not $result.Ok) { $failed += "$via $url" }
}
if ($failed.Count -gt 0) {
    throw ("$Mode 模式下有 $($failed.Count) 个端点不可达，没有改动任何配置：" + [Environment]::NewLine +
        '  ' + ($failed -join ([Environment]::NewLine + '  ')) + [Environment]::NewLine +
        '直连失败：把该主机从 -NoProxy 里去掉，让它走代理。过代理失败：先查控制端——开着吗、Clash 开着吗、勾了「允许局域网连接」吗、地址变了吗。')
}

# --- machine-level environment ----------------------------------------------
$envProxy = ($Mode -eq 'Proxy') ? $proxyUrl : $null
foreach ($name in 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy') {
    [Environment]::SetEnvironmentVariable($name, $envProxy, 'Machine')
}
foreach ($name in 'NO_PROXY', 'no_proxy') {
    [Environment]::SetEnvironmentVariable($name, ($Mode -eq 'Proxy') ? $noProxyValue : $null, 'Machine')
}

# --- git ---------------------------------------------------------------------
$gitExe = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
$hasGit = Test-Path -LiteralPath $gitExe
if ($hasGit) {
    if ($Mode -eq 'Proxy') {
        & $gitExe config --system http.proxy $proxyUrl
        & $gitExe config --system https.proxy $proxyUrl
    }
    else {
        & $gitExe config --system --unset-all http.proxy 2>$null
        & $gitExe config --system --unset-all https.proxy 2>$null
    }
}

# --- clear the inert proxy files out of the runner directories ---------------
$runnerDirs = @(Get-ChildItem -LiteralPath $RunnerRoot -Directory -ErrorAction SilentlyContinue)
$removed = 0
foreach ($dir in $runnerDirs) {
    foreach ($leaf in '.proxy', '.noproxy', '.no_proxy', '.proxybypass') {
        $path = Join-Path $dir.FullName $leaf
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            $removed++
        }
    }
}
Write-Output "已从 $($runnerDirs.Count) 个 runner 目录里清掉 $removed 个无效的代理文件（runner 只认环境变量）。"

# --- restart the runners so they read it -------------------------------------
if ($SkipRunnerRestart) {
    Write-Warning 'runner 未重启，仍在用旧配置。'
}
else {
    $busy = @(Get-Process -Name 'Runner.Worker' -ErrorAction SilentlyContinue)
    if ($busy.Count -gt 0) {
        throw ("有 $($busy.Count) 个作业正在跑（Runner.Worker）。配置已写入，但没有重启 runner——" +
            '取消这台机器上正在跑的作业会让 runner 会话卡死数小时。等作业跑完后重跑本脚本，或者用 -SkipRunnerRestart 之后手工重启。')
    }

    foreach ($service in Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue) {
        Restart-Service -Name $service.Name -Force
        Write-Output "已重启服务 $($service.Name)。"
    }

    # The interactive runner is a scheduled task in the desktop session, not a
    # service. Restarting it needs that session to exist; over SSH (session 0)
    # it may not, and that is a warning rather than a failure.
    foreach ($task in Get-ScheduledTask -TaskName 'GitHubRunner-*' -ErrorAction SilentlyContinue) {
        try {
            Stop-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop
            Start-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop
            Write-Output "已重启计划任务 $($task.TaskName)。"
        }
        catch {
            Write-Warning "计划任务 $($task.TaskName) 没能重启：$($_.Exception.Message)。它要在桌面会话里跑，登录一次即可。"
        }
    }
}

Write-Output ''
Write-Output '=== 当前配置（机器级，新进程与新服务生效）==='
Write-Output ("模式                       {0}" -f $Mode)
Write-Output ("HTTP_PROXY / HTTPS_PROXY   {0}" -f ([Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Machine') ?? '(未设置)'))
Write-Output ("NO_PROXY                   {0}" -f ([Environment]::GetEnvironmentVariable('NO_PROXY', 'Machine') ?? '(未设置)'))
if ($hasGit) {
    $gitProxy = & $gitExe config --system --get http.proxy 2>$null
    Write-Output ("git http.proxy             {0}" -f ([string]::IsNullOrWhiteSpace($gitProxy) ? '(未设置)' : $gitProxy))
}
Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue |
    Select-Object Name, Status | Format-Table -AutoSize | Out-String | Write-Output
