#Requires -Version 7
<#
.SYNOPSIS
    抓 Hyper-V 客户机的屏幕缩略图存成 PNG。

.DESCRIPTION
    SSH 通道看不到客户机的画面。装系统、改引导、排查蓝屏这类事全发生在图形层，
    Get-VM 只会告诉你 State = Running，看不出它其实卡在 "No operating system was
    loaded"。这个脚本走 Msvm_VirtualSystemManagementService 的
    GetVirtualSystemThumbnailImage，把客户机当前画面取回来，配合 scp 拉到控制端
    就能看。不需要 VNC，也不需要客户机装任何东西——数据来自 Hyper-V 本身。

    它是诊断工具，不是操作工具：能看不能点。真要交互还是得走向日葵 / VNC 开
    VMConnect。

.PARAMETER VMName
    客户机名（Msvm_ComputerSystem 的 ElementName）。

.EXAMPLE
    scp scripts/vm-screenshot.ps1 factory01:C:/temp/agv-ops/
    ssh factory01 "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\agv-ops\vm-screenshot.ps1 -VMName win11-01"
    scp factory01:C:/temp/agv-ops/vm-screen.png ./

.NOTES
    2026-09-01 用它定位了 win11-01 第一次引导失败的真因：引导顺序是对的，只是
    "Press any key to boot from CD or DVD" 超时后落到了空白硬盘上。没有截图的话，
    从 State = Running / CPUUsage = 0 这两个值猜不出来。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$OutPath = 'C:\temp\agv-ops\vm-screen.png',
    [int]$Width  = 1024,
    [int]$Height = 768
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ns  = 'root\virtualization\v2'
$svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$vm  = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
if (-not $vm) { throw "找不到虚拟机：$VMName" }

$sd = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData |
      Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' } |
      Select-Object -First 1

$r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage `
     -Arguments @{ TargetSystem = $sd; WidthPixels = [uint16]$Width; HeightPixels = [uint16]$Height }
if ($r.ReturnValue -ne 0) {
    throw "GetVirtualSystemThumbnailImage 失败，ReturnValue=$($r.ReturnValue)（虚拟机没在运行时会失败）"
}

# 像素格式是 RGB565。Hyper-V 返回的字节数比 Width*Height*2 多 4——按 ImageData.Length
# 整体拷贝会写爆 LockBits 的缓冲区，触发 CLR 致命错误 0x80131506 直接崩掉整个 pwsh
# 进程（不是可捕获的异常）。必须按精确长度拷。
$src  = [byte[]]$r.ImageData
$need = $Width * $Height * 2
$bmp  = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$bd   = $bmp.LockBits(
            (New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)),
            [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
            [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
try {
    [System.Runtime.InteropServices.Marshal]::Copy($src, 0, $bd.Scan0, $need)
} finally {
    $bmp.UnlockBits($bd)
}

New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"$OutPath ($([math]::Round((Get-Item $OutPath).Length / 1KB, 1)) KB)"
