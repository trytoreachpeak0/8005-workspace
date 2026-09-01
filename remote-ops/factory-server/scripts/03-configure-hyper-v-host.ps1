#Requires -Version 7
<#
.SYNOPSIS
    厂区服务器 WIN-0HD72AV4K31 的 Hyper-V 宿主配置。幂等，可重复跑。

.DESCRIPTION
    Hyper-V 角色本身不在这里装——那一步要停机重启，见 ../README.md 第 4 节的执行
    记录。本脚本做的是角色装好、重启完之后的宿主侧配置：

      1. 默认虚拟机与虚拟硬盘路径指向 D:\zhengyushao\Hyper-V\
      2. Internal 虚拟交换机 + 宿主侧网关地址 + NAT
      3. Windows Defender 的 Hyper-V 排除项

    **有意不做的事：**

    - **绝不在 em4 上建 External 虚拟交换机。** em4 是这台机器唯一插了线的网卡，
      承载 172.19.205.222，也就是 SSH 生命线。建 External 交换机时 Hyper-V 会把物理
      网卡绑给交换机、在宿主侧新建 vEthernet 并重走 IP 配置；这中间地址会短暂消失，
      迁移不成功就再也连不上，只能走向日葵 / VNC / 到机房。Internal 交换机不绑定任何
      物理网卡，没有这个风险。将来要接企业网，等有人去机房把 em1 的线插上再说。
    - **不动火绒。** 它没有命令行接口，排除项只能在它自己的图形界面里加。见
      ../docs/USAGE.md 第 8 节。
    - **不碰 SQL Server、不碰 SQAGV、不格式化任何卷。**

.PARAMETER Root
    Hyper-V 数据根目录。用户 2026-09-01 要求本机所有新建目录都收在 D:\zhengyushao 下。

.PARAMETER SwitchName
    Internal 虚拟交换机名。

.PARAMETER Prefix
    客户机网段。192.168.200.0/24 是沿用 8005---AGV 里票 07 的异机取证环境
    （宿主 .1、客户机 .50），将来复现那套联调时地址能直接对上。

.EXAMPLE
    scp scripts/03-configure-hyper-v-host.ps1 factory01:C:/temp/agv-ops/
    ssh factory01 "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\agv-ops\03-configure-hyper-v-host.ps1"

.NOTES
    2026-09-01 首次执行。
#>
[CmdletBinding()]
param(
    [string]$Root       = 'D:\zhengyushao\Hyper-V',
    [string]$SwitchName = 'AGV-Internal',
    [string]$Prefix     = '192.168.200.0/24',
    [string]$HostAddress = '192.168.200.1',
    [byte]  $PrefixLength = 24,
    [string]$NatName    = 'AGV-NAT'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# pwsh 7 默认通过 Windows PowerShell 兼容会话代理 Hyper-V 模块，返回的是
# Deserialized.* 对象，绑不上 Set-VMFirmware -BootOrder / -FirstBootDevice 这类
# 接受 VMComponentObject 的参数。-SkipEditionCheck 让 pwsh 原生加载模块，对象类型
# 变回 Microsoft.HyperV.PowerShell.*，问题消失。不需要退回 powershell.exe。
Import-Module Hyper-V -SkipEditionCheck

if (-not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    throw 'Hyper-V 尚未生效（HypervisorPresent = False）。先装角色并重启，见 ../README.md 第 4 节。'
}

Write-Host '1/4 目录' -ForegroundColor Cyan
$vmPath  = Join-Path $Root 'VirtualMachines'
$vhdPath = Join-Path $Root 'VirtualHardDisks'
New-Item -ItemType Directory -Force -Path $vmPath, $vhdPath | Out-Null
Set-VMHost -VirtualMachinePath $vmPath -VirtualHardDiskPath $vhdPath
Get-VMHost | Select-Object VirtualMachinePath, VirtualHardDiskPath | Format-List

Write-Host '2/4 Internal 虚拟交换机（不绑定任何物理网卡）' -ForegroundColor Cyan
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Write-Host "  已存在，跳过：$SwitchName"
} else {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Host "  已创建：$SwitchName"
}

Write-Host '3/4 宿主侧网关地址' -ForegroundColor Cyan
$alias = "vEthernet ($SwitchName)"
$existing = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object IPAddress -eq $HostAddress
if ($existing) {
    Write-Host "  已存在，跳过：$HostAddress/$PrefixLength on $alias"
} else {
    New-NetIPAddress -InterfaceAlias $alias -IPAddress $HostAddress -PrefixLength $PrefixLength | Out-Null
    Write-Host "  已配置：$HostAddress/$PrefixLength on $alias"
}

Write-Host '4/4 NAT 与 Defender 排除项' -ForegroundColor Cyan
if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
    Write-Host "  NAT 已存在，跳过：$NatName"
} else {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $Prefix | Out-Null
    Write-Host "  NAT 已创建：$NatName -> $Prefix"
}

# WinNAT 不带 DHCP，客户机必须配静态地址。装机时 OOBE 的联网步骤会因此卡住，
# 绕法见 ../docs/USAGE.md 第 8 节。
Add-MpPreference -ExclusionPath $Root
Add-MpPreference -ExclusionExtension '.vhdx', '.avhdx', '.vhd'
Add-MpPreference -ExclusionProcess 'vmms.exe', 'vmwp.exe', 'vmcompute.exe'
$p = Get-MpPreference
Write-Host "  Defender 排除路径 : $($p.ExclusionPath -join ', ')"
Write-Host "  Defender 排除扩展 : $($p.ExclusionExtension -join ', ')"
Write-Host "  Defender 排除进程 : $($p.ExclusionProcess -join ', ')"

Write-Host "`n=== 核验：em4 必须原样 ===" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { '{0,-26} {1}/{2}' -f $_.InterfaceAlias, $_.IPAddress, $_.PrefixLength }

Write-Host "`n完成。火绒的排除项还要人工在它的界面里加（本脚本做不到）。" -ForegroundColor Green
