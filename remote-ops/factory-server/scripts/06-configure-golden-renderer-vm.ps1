#Requires -Version 7
<#
.SYNOPSIS
    Configure a Hyper-V guest to the golden-renderer / CI-runner specification.

.DESCRIPTION
    Runs on the Hyper-V host (factory01). Brings one guest to the hardware
    specification required by two roles it now carries together:

      * golden WPF renderer — needs a 1920x1080 desktop, which a Hyper-V guest
        only reports when ResolutionType is Single; the Default type negotiates
        with the vmconnect window and lands on 1024x768 with no session attached;
      * self-hosted GitHub Actions runner — needs enough cores and, more to the
        point, static memory. Dynamic memory had assigned this guest 2.5 GB of
        its 4 GB startup, which starves a restore/build/test cycle.

    Idempotent. When every setting already matches it leaves the guest running
    and does not restart it. Processor count, memory and video resolution cannot
    be changed while a VM runs, so any real change costs one graceful restart.

.PARAMETER VMName
    Guest to configure. Defaults to win11-01.

.PARAMETER ProcessorCount
    Virtual processors. Must not exceed the host's logical processor count.

.PARAMETER MemoryBytes
    Static memory. Dynamic memory is switched off: the golden renderer wants a
    predictable machine, and a build under memory pressure is the slow path.

.PARAMETER ShutdownTimeoutSeconds
    How long to wait for a graceful guest shutdown before giving up. This script
    never forces power off — a hard stop on a Windows guest risks the VHDX.

.EXAMPLE
    pwsh -NoProfile -File 06-configure-golden-renderer-vm.ps1
    pwsh -NoProfile -File 06-configure-golden-renderer-vm.ps1 -VMName win11-02 -ProcessorCount 8
#>
[CmdletBinding()]
param(
    [string]$VMName = 'win11-01',
    [int]$ProcessorCount = 20,
    [long]$MemoryBytes = 8GB,
    [int]$HorizontalResolution = 1920,
    [int]$VerticalResolution = 1080,
    [int]$ShutdownTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# pwsh 7 proxies the Hyper-V module through a Windows PowerShell compatibility
# session without this, which returns Deserialized.* objects that Set-VM* cannot
# accept. Read-only Get-* would still work, so the failure appears late.
Import-Module Hyper-V -SkipEditionCheck

$vm = Get-VM -Name $VMName -ErrorAction Stop

$hostCores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
if ($ProcessorCount -gt $hostCores) {
    throw "ProcessorCount $ProcessorCount exceeds the host's $hostCores logical processors."
}

$video = Get-VMVideo -VMName $VMName

$changes = @()
if ($vm.ProcessorCount -ne $ProcessorCount) {
    $changes += "vCPU $($vm.ProcessorCount) -> $ProcessorCount"
}
if ($vm.DynamicMemoryEnabled -or $vm.MemoryStartup -ne $MemoryBytes) {
    $was = "$([math]::Round($vm.MemoryStartup / 1GB, 1)) GB" + ($vm.DynamicMemoryEnabled ? ' 动态' : ' 静态')
    $changes += "内存 $was -> $([math]::Round($MemoryBytes / 1GB, 1)) GB 静态"
}
if ($video.ResolutionType -ne 'Single' -or
    $video.HorizontalResolution -ne $HorizontalResolution -or
    $video.VerticalResolution -ne $VerticalResolution) {
    $changes += "分辨率 $($video.ResolutionType) $($video.HorizontalResolution)x$($video.VerticalResolution) -> Single ${HorizontalResolution}x${VerticalResolution}"
}

if ($changes.Count -eq 0) {
    Write-Output "$VMName 已符合规格，未做改动（State = $($vm.State)）。"
    exit 0
}

Write-Output "待应用的改动："
$changes | ForEach-Object { Write-Output "  - $_" }

$wasRunning = $vm.State -eq 'Running'
if ($wasRunning) {
    Write-Output "正在优雅关机 $VMName ..."
    Stop-VM -Name $VMName -Force -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSeconds)
    while ((Get-VM -Name $VMName).State -ne 'Off') {
        if ((Get-Date) -gt $deadline) {
            throw "$VMName 在 $ShutdownTimeoutSeconds 秒内没有关机。未做任何配置改动，也不会强制断电——请手动检查客户机。"
        }
        Start-Sleep -Seconds 3
    }
    Write-Output "已关机。"
}

Set-VMProcessor -VMName $VMName -Count $ProcessorCount
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes $MemoryBytes
Set-VMVideo -VMName $VMName -ResolutionType Single `
    -HorizontalResolution $HorizontalResolution -VerticalResolution $VerticalResolution

if ($wasRunning) {
    Write-Output "正在启动 $VMName ..."
    Start-VM -Name $VMName
}

$vm = Get-VM -Name $VMName
$video = Get-VMVideo -VMName $VMName
Write-Output ''
Write-Output "=== $VMName 当前配置 ==="
Write-Output ("State                {0}" -f $vm.State)
Write-Output ("ProcessorCount       {0}" -f $vm.ProcessorCount)
Write-Output ("Memory               {0} GB {1}" -f [math]::Round($vm.MemoryStartup / 1GB, 1), ($vm.DynamicMemoryEnabled ? '动态' : '静态'))
Write-Output ("Video                {0} {1}x{2}" -f $video.ResolutionType, $video.HorizontalResolution, $video.VerticalResolution)
