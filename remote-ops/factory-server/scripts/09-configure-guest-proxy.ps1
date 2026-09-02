#Requires -Version 7
<#
.SYNOPSIS
    Point a guest's outbound HTTP(S) at the control machine's proxy. Runs in the
    guest, not the host.

.DESCRIPTION
    The guest and the factory server cannot reach github.com:443 directly
    (verified 2026-09-02; DNS resolves correctly, the TCP handshake does not
    complete). The chosen long-term route is the control machine's Clash proxy,
    which the guest reaches because its WinNAT egress lands on the factory
    server's network stack and from there the enterprise network is routable.

    Machine-level environment variables are set, so a service started afterwards
    inherits them, and git is configured at system level for the same reason.

    **The proxy address is the control machine's Wi-Fi interface and is
    DHCP-assigned.** When it changes, CI stops working with connection timeouts.
    Re-run this script with the new -ProxyAddress and restart the runner service;
    that is the whole fix. Check the current address on the control machine with
    Get-NetIPAddress and ignore the Clash TUN adapter (198.18.x.x) and the
    vEthernet ones.

.PARAMETER ProxyAddress
    host:port of the proxy. Default is the control machine's Clash HTTP port.

.PARAMETER NoProxy
    Comma-separated hosts that must not go through the proxy. NuGet is excluded
    because it is directly reachable and measurably faster that way; the local
    and guest-network addresses are excluded so intra-network traffic never
    loops out to the control machine.

.PARAMETER Remove
    Undo: clear the variables and the git settings.

.EXAMPLE
    pwsh -NoProfile -File 09-configure-guest-proxy.ps1
    pwsh -NoProfile -File 09-configure-guest-proxy.ps1 -ProxyAddress 172.19.162.99:7890
    pwsh -NoProfile -File 09-configure-guest-proxy.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$ProxyAddress = '172.19.162.241:7890',
    [string]$NoProxy = 'localhost,127.0.0.1,192.168.200.1,192.168.200.50,172.19.205.222,api.nuget.org,globalcdn.nuget.org',
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gitExe = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
$hasGit = Test-Path -LiteralPath $gitExe

if ($Remove) {
    foreach ($name in 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy') {
        [Environment]::SetEnvironmentVariable($name, $null, 'Machine')
    }
    if ($hasGit) {
        & $gitExe config --system --unset http.proxy 2>$null
        & $gitExe config --system --unset https.proxy 2>$null
    }
    Write-Output '代理配置已清除。runner 服务需要重启才生效。'
    exit 0
}

$url = "http://$ProxyAddress"

Write-Output "正在验证 $url 是否可用 ..."
try {
    $r = Invoke-WebRequest 'https://github.com' -Proxy $url -Method Head -UseBasicParsing -TimeoutSec 30
    Write-Output "  github.com 经代理返回 HTTP $($r.StatusCode)。"
}
catch {
    throw "代理 $url 不可用：$($_.Exception.Message)`n控制端是否开着、Clash 是否勾了「允许局域网连接」、地址是否变了？"
}

# Both cases are set: .NET reads the upper-case ones, curl and much of the
# unix-derived tooling reads the lower-case ones, and neither falls back.
foreach ($name in 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy') {
    [Environment]::SetEnvironmentVariable($name, $url, 'Machine')
}
foreach ($name in 'NO_PROXY', 'no_proxy') {
    [Environment]::SetEnvironmentVariable($name, $NoProxy, 'Machine')
}

if ($hasGit) {
    & $gitExe config --system http.proxy $url
    & $gitExe config --system https.proxy $url
}

Write-Output ''
Write-Output '=== 已写入（机器级，新进程与新服务生效）==='
Write-Output "HTTP_PROXY / HTTPS_PROXY   $url"
Write-Output "NO_PROXY                   $NoProxy"
if ($hasGit) {
    Write-Output ("git http.proxy             " + (& $gitExe config --system http.proxy))
}
Write-Output ''
Write-Output '注意：已在运行的进程和服务不会读到这些变量，需要重启。'
