#Requires -Version 7
<#
.SYNOPSIS
    Sets the guest's outbound HTTP(S) egress policy for CI. Runs in the guest,
    not the host.

.DESCRIPTION
    Two modes.

      Proxy (default since the afternoon of 2026-09-08) — github.com,
        codeload.github.com and api.github.com go through the control
        machine's Clash proxy; everything in -NoProxy stays direct. That day
        did come: github.com's IP stopped answering from the plant while
        api.github.com's kept answering. See the second block below.

      Direct — nothing uses the proxy. This was the default for one morning,
        after a port-pool leak that had masqueraded as a GitHub block was
        fixed. Reach for it only after measuring that github.com really does
        answer directly.

    Read the next two paragraphs before changing modes. The first says the
    evidence that once justified Proxy was an artifact; the second says the
    same symptom later turned out to be real. The symptoms are identical --
    a 21-second TCP connect timeout -- and only one measurement separates
    them: whether the factory server's own ephemeral port pool is exhausted.

    Until 2026-09-08 this guest sent everything through the proxy, and the
    survey that seemed to prove github.com needed it read like this — the left
    column measured 0/8, so github.com "had to" be proxied:

      | 端点                        | 直连(坏) | 过代理 | 直连(修好后) |
      | github.com HTTPS            |    0/8   | 12/12  |    12/12     |
      | codeload.github.com HTTPS   |    0/3   |   ✓    |    12/12     |
      | results-receiver HTTPS      |   12/12  | 10/12  |    12/12     |
      | blob.core.windows.net HTTPS |   11/12  |   —    |    12/12     |

    Nothing about GitHub or the plant firewall changed between those columns.
    What changed is that AgvAmhs was stopped on the factory server. It had
    leaked 10330 AMQP connections into RabbitMQ over six days, occupying 64% of
    that host's 16384 ephemeral ports — and WinNAT borrows from that same pool
    for every connection it translates on this guest's behalf. When it could not
    borrow one the SYN was dropped silently and the guest saw a 21-second TCP
    connect timeout. Five release runs died that way; so did the "direct"
    measurements, which is why they pointed at the wrong culprit.

    The A/B that settled it, taken from this guest at one instant:
    92/92 to 192.168.200.1 (no NAT) against 72/92 through NAT to a target the
    factory server itself reached 198/198. After 17-disable-amhs-stack.ps1:
    177/177 and 177/177. See 8005-agv-control-server issue #7.

    Then, the same afternoon, the block became real and Proxy came back. This
    time the port pool was healthy (269/16384, 1.6%), AgvAmhs was still
    stopped, and the factory server itself reached baidu.com, microsoft.com
    and api.github.com (20.205.243.168) 4/4 -- while github.com
    (20.205.243.166) answered 0/8. DNS was clean, returning the real GitHub
    addresses. Two IPs one digit apart, one reachable and one not, with local
    egress proven: that is a block, not a local fault. The guest measured
    codeload.github.com at 3/6 direct -- intermittent is what this looks like
    -- and 6/6 through the proxy. g1 run 34209440540 failed on checkout, then
    passed in 40s on rerun after this script was run with -Mode Proxy.

    Two things worth keeping from that hunt:

      * Switching nodes inside Clash is NOT a fix for anything. It was tried,
        github.com through the proxy went from 2/10 failures to 10/10
        successes, and the next release failed identically. The proxy's
        upstream was never the problem.
      * A probe that only reaches the transport tells you nothing here. TCP
        connect succeeded while TLS timed out, because the connect is small and
        the port pool ran out under load. Measure with a real request and a
        45-second timeout.

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
    Bypass list, Proxy mode only. Two rules govern what may go in it:

      * .NET does not treat an entry as a domain suffix — measured 2026-09-07,
        `github.com` bypasses github.com but not api.github.com — so anything a
        .NET client reaches needs its own full hostname. curl, the Node toolkit
        and the runner do match parent domains.
      * Never add a bare `github.com`. Under a suffix-matching client that would
        also bypass codeload.github.com — and codeload is the host Proxy mode
        exists to carry, so action downloads would start failing on any runner
        with a cold _actions cache, which is a slow thing to notice.

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
    pwsh -NoProfile -File 09-configure-guest-proxy.ps1 -Mode Proxy -ProxyAddress 172.19.162.99:7890
#>
[CmdletBinding()]
param(
    [ValidateSet('Direct', 'Proxy')]
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
