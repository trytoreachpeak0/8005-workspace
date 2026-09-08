#Requires -Version 7
<#
.SYNOPSIS
    Stops and permanently disables the AgvAmhs / RabbitMQ stack on the factory
    server. Runs on the server.

.DESCRIPTION
    AgvAmhs is a colleague's toy program, left running on this server by accident
    and never turned off (confirmed by Zhengyu Shao, 2026-09-08). It was never
    part of the production stack, so the leak below is not a defect anyone will
    fix — stopping it for good is the whole answer. RabbitMQ goes with it.

    Measured on 2026-09-08, after six days of uptime: AgvAmhs held 10330 open
    connections to RabbitMQ on port 5672 — one per leaked channel, none closed —
    plus the matching 10330 bound sockets. Between them they occupied 10473 of
    the host's 16384 ephemeral ports (49152-65535), 64% of the pool, growing by
    roughly 1700 a day.

    That is what broke CI. WinNAT has to borrow an ephemeral port from that same
    pool for every outbound connection it translates for the lab guest, and when
    it cannot, the SYN is dropped silently and the guest sees a 21-second connect
    timeout. Five release runs died that way. The proof is a same-instant
    A/B from the guest — 92/92 to the host directly (no NAT), 72/92 through NAT
    to the very same target the host itself reached 198/198. See
    8005-agv-control-server issue #7.

    Scope is deliberately narrow. AGVWebApi, MesIngest, the ControlServer service
    and SQL Server all keep running; neither service being disabled here has any
    dependent services, so nothing is stopped by association.

    -Revert puts both back to Automatic and starts them. It is a way back, not a
    plan: AgvAmhs stays off. Nothing on this host noticed RabbitMQ leaving, so if
    something later does need a broker, start RabbitMQ on its own rather than
    reverting both.

.PARAMETER Revert
    Undo: set both services back to Automatic and start them.

.EXAMPLE
    pwsh -NoProfile -File 17-disable-amhs-stack.ps1

.EXAMPLE
    pwsh -NoProfile -File 17-disable-amhs-stack.ps1 -Revert
#>
[CmdletBinding()]
param(
    [switch]$Revert
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# AgvAmhs first: it is RabbitMQ's client, and stopping the client before the
# broker keeps ten thousand connection resets out of the broker's shutdown path.
$services = @('AgvAmhs', 'RabbitMQ')

function Get-EphemeralUsage {
    $conns = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ge 49152 })
    [pscustomobject]@{
        Entries = $conns.Count
        Ports   = @($conns | Select-Object -ExpandProperty LocalPort -Unique).Count
    }
}

$before = Get-EphemeralUsage
Write-Output ("动作前：临时端口条目 {0}，去重端口 {1} / 16384（{2:P0}）" -f $before.Entries, $before.Ports, ($before.Ports / 16384))
Write-Output ''

Write-Output '=== 当前状态 ==='
foreach ($name in $services) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Output "  $name  (不存在)"; continue }
    Write-Output ("  {0,-10} State={1,-8} StartMode={2,-9} pid={3}" -f $svc.Name, $svc.State, $svc.StartMode, $svc.ProcessId)
}
Write-Output ''

if ($Revert) {
    foreach ($name in $services | Sort-Object -Descending) {
        # Reverse order on the way back up: the broker before its client.
        if (-not (Get-Service -Name $name -ErrorAction SilentlyContinue)) { continue }
        Set-Service -Name $name -StartupType Automatic
        Start-Service -Name $name
        Write-Output "已恢复并启动 $name（StartupType=Automatic）。"
    }
}
else {
    foreach ($name in $services) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Warning "服务 $name 不存在，跳过。"; continue }
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $name -Force
            Write-Output "已停止 $name。"
        }
        Set-Service -Name $name -StartupType Disabled
        Write-Output "已设为 Disabled：$name。"
    }

    # epmd is spawned by erl rather than by the service control manager, so it
    # can outlive the RabbitMQ service. It holds no ephemeral ports worth
    # counting, but leaving it behind makes the next reader wonder whether the
    # stack really stopped.
    foreach ($proc in Get-Process -Name 'epmd', 'erl', 'erlsrv', 'AgvAmhs' -ErrorAction SilentlyContinue) {
        Write-Output "残留进程 $($proc.ProcessName) (pid $($proc.Id))，结束它。"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Seconds 5

Write-Output ''
Write-Output '=== 动作后 ==='
foreach ($name in $services) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if ($svc) { Write-Output ("  {0,-10} State={1,-8} StartMode={2}" -f $svc.Name, $svc.State, $svc.StartMode) }
}
$remaining = @(Get-Process -Name 'epmd', 'erl', 'erlsrv', 'AgvAmhs' -ErrorAction SilentlyContinue)
Write-Output ("  残留进程：{0}" -f ($remaining.Count -eq 0 ? '无' : (($remaining | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ' ')))

$after = Get-EphemeralUsage
Write-Output ''
Write-Output ("临时端口条目 {0} → {1}，去重端口 {2} → {3} / 16384（{4:P0} → {5:P0}）" -f
    $before.Entries, $after.Entries, $before.Ports, $after.Ports, ($before.Ports / 16384), ($after.Ports / 16384))

Write-Output ''
Write-Output '=== 仍在运行的 AGV 相关服务（本脚本不碰）==='
Get-CimInstance Win32_Service |
    Where-Object { $_.State -eq 'Running' -and ($_.PathName -match 'AGV|SQCD|Mes' -or $_.Name -match 'MSSQL') } |
    Select-Object Name, State, StartMode | Format-Table -AutoSize | Out-String | Write-Output
