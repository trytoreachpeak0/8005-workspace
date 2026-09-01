#Requires -Version 7
<#
.SYNOPSIS
    在厂区服务器上创建一台可安装 Windows 11 的 Hyper-V 虚拟机。

.DESCRIPTION
    前置：Hyper-V 角色已装并重启生效，03-configure-hyper-v-host.ps1 已跑过
    （路径、Internal 交换机、NAT、Defender 排除项都在）。

    Windows 11 对客户机的硬要求是 **第 2 代 + Secure Boot + TPM 2.0**，三者缺一
    装不上。本脚本把这三样一次配齐：

    - Gen 2 虚拟机。Gen 1 是 BIOS 引导，装不了 Win11。
    - Secure Boot：Gen 2 默认就是 On + MicrosoftWindows 模板，脚本仍显式设一遍，
      因为"默认值"不是可以依赖的契约。
    - vTPM：必须先 Set-VMKeyProtector -NewLocalKeyProtector 建本地密钥保护器，
      再 Enable-VMTPM，顺序反了会失败。**2026-09-01 实测在 Windows Server 2016
      的 Hyper-V 上可用**（TpmEnabled = True），不需要 LabConfig 那套绕过。

    虚拟机配置版本固定是 8.0，那是 Server 2016 支持的上限。**这意味着控制端
    （Windows 11 宿主，配置版本 12.0）上的虚拟机无法导入到这台服务器**——配置版本
    只能升不能降。要在这台机器上有同样的环境，只能像本脚本这样重新建。

.PARAMETER Name
    虚拟机名。

.PARAMETER IsoPath
    安装介质。2026-09-01 在机的是 D:\zhengyushao\Windows.iso，实测为
    Windows 11 24H2，build 10.0.26100.1，UEFI 引导文件齐全。

.EXAMPLE
    scp scripts/04-create-win11-vm.ps1 factory01:C:/temp/agv-ops/
    ssh factory01 "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\agv-ops\04-create-win11-vm.ps1"

.NOTES
    2026-09-01 首次执行，创建 win11-01。
    装系统本身是交互操作，走向日葵 / VNC 进图形界面用 VMConnect 做，见
    ../docs/USAGE.md 第 8 节。
#>
[CmdletBinding()]
param(
    [string]$Name       = 'win11-01',
    [string]$IsoPath    = 'D:\zhengyushao\Windows.iso',
    [string]$Root       = 'D:\zhengyushao\Hyper-V',
    [string]$SwitchName = 'AGV-Internal',
    [int]   $ProcessorCount = 4,
    [int64] $MemoryBytes = 4GB,
    [int64] $DiskBytes   = 80GB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 见 03-configure-hyper-v-host.ps1 里同一段注释：不加 -SkipEditionCheck，
# Set-VMFirmware -BootOrder 会因为拿到 Deserialized.* 对象而绑参数失败。
Import-Module Hyper-V -SkipEditionCheck

$vhd   = Join-Path $Root "VirtualHardDisks\$Name.vhdx"
$vmDir = Join-Path $Root 'VirtualMachines'

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "虚拟机 $Name 已存在。" }
if (Test-Path $vhd)          { throw "VHDX 已存在：$vhd" }
if (-not (Test-Path $IsoPath)) { throw "找不到 ISO：$IsoPath" }

Write-Host '1/5 创建 Gen 2 虚拟机' -ForegroundColor Cyan
New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryBytes `
       -NewVHDPath $vhd -NewVHDSizeBytes $DiskBytes `
       -SwitchName $SwitchName -Path $vmDir | Out-Null
# 静态内存：装机阶段比动态内存可预期。装完可以改成动态。
# AutomaticStartAction = Nothing：这是台生产服务器，宿主重启后虚拟机不该自己起来抢内存。
Set-VM -Name $Name -ProcessorCount $ProcessorCount -StaticMemory `
       -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Production

Write-Host '2/5 挂载 ISO' -ForegroundColor Cyan
Add-VMDvdDrive -VMName $Name -Path $IsoPath

Write-Host '3/5 Secure Boot' -ForegroundColor Cyan
Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

Write-Host '4/5 vTPM（顺序不能反）' -ForegroundColor Cyan
Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
Enable-VMTPM -VMName $Name

Write-Host '5/5 引导顺序 DVD → 硬盘' -ForegroundColor Cyan
Set-VMFirmware -VMName $Name -BootOrder (Get-VMDvdDrive -VMName $Name), (Get-VMHardDiskDrive -VMName $Name)

Write-Host "`n=== 核验 ===" -ForegroundColor Cyan
Get-VM -Name $Name | Select-Object Name, State, Generation, Version, ProcessorCount,
    @{n = 'MemGB'; e = { $_.MemoryStartup / 1GB } }, DynamicMemoryEnabled,
    AutomaticStartAction, AutomaticStopAction | Format-List
$fw = Get-VMFirmware -VMName $Name
"SecureBoot         : $($fw.SecureBoot)"
"SecureBootTemplate : $($fw.SecureBootTemplate)"
"TpmEnabled         : $((Get-VMSecurity -VMName $Name).TpmEnabled)"
'BootOrder          :'
$fw.BootOrder | ForEach-Object { "  $($_.Device.Path)" }

Write-Host @"

完成。接下来是交互步骤，SSH 做不了：

  1. 向日葵 / VNC 进服务器桌面，运行 virtmgmt.msc
  2. 双击 $Name 打开 VMConnect（用基本会话，不要用增强会话）
  3. 启动，看到 "Press any key to boot from CD or DVD" 时 5 秒内按键
     —— 不按就会超时落到空白硬盘，报 "No UEFI-compatible file system was found"
  4. OOBE 卡在强制联网时：Shift+F10 → oobe\bypassnro

  装完在客户机里配静态地址（NAT 不带 DHCP）：
    IP 192.168.200.50/24   网关 192.168.200.1   DNS 172.19.1.31
"@ -ForegroundColor Green
