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

    The guest's page file is the one setting the host cannot reach, so it is a
    second mode of this script, run inside the guest: `ssh vm01`, then
    `pwsh -File 06-configure-golden-renderer-vm.ps1 -GuestPageFile`. It pins
    C:\pagefile.sys to a fixed size (4 GB) instead of the system-managed 512 MB.
    Why (2026-09-18, authorized by the user for 8005-agv-control-server#130): the
    guest's commit limit is RAM plus page file, 8.7 GB with 512 MB of page file.
    That control-server's L2 now runs four lanes at about 0.7 GB of committed
    memory each, and one onboard-hmi CI round adds about 2.9 GB; together they
    pass 8.7 GB, and past the limit an allocation fails outright rather than
    slowing down. With 4 GB the limit is 12.0 GB. The change takes effect at the
    next boot; this mode never restarts the guest itself, because the guest
    carries six runners and a restart under a running job wedges it -- restart
    only when all six are idle.

.PARAMETER VMName
    Guest to configure. Defaults to win11-01.

.PARAMETER ProcessorCount
    Virtual processors. Must not exceed the host's logical processor count.

.PARAMETER MemoryBytes
    Static memory. Dynamic memory is switched off: the golden renderer wants a
    predictable machine, and a build under memory pressure is the slow path.

.PARAMETER GuestPageFile
    Run inside the guest instead of on the host: set the fixed page file size and
    report whether a restart is still needed. Touches no Hyper-V setting.

.PARAMETER PageFileMB
    The fixed page file size for -GuestPageFile, initial and maximum alike.

.PARAMETER ShutdownTimeoutSeconds
    How long to wait for a graceful guest shutdown before giving up. This script
    never forces power off — a hard stop on a Windows guest risks the VHDX.

.EXAMPLE
    pwsh -NoProfile -File 06-configure-golden-renderer-vm.ps1
    pwsh -NoProfile -File 06-configure-golden-renderer-vm.ps1 -VMName win11-02 -ProcessorCount 8
    pwsh -NoProfile -File 06-configure-golden-renderer-vm.ps1 -GuestPageFile   # inside the guest
#>
[CmdletBinding()]
param(
    [string]$VMName = 'win11-01',
    [int]$ProcessorCount = 20,
    [long]$MemoryBytes = 8GB,
    [int]$HorizontalResolution = 1920,
    [int]$VerticalResolution = 1080,
    [int]$ShutdownTimeoutSeconds = 180,
    [switch]$GuestPageFile,
    [ValidateRange(1024, 65536)]
    [int]$PageFileMB = 4096
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($GuestPageFile) {
    $computer = Get-CimInstance Win32_ComputerSystem
    $setting = Get-CimInstance Win32_PageFileSetting | Where-Object Name -eq 'C:\pagefile.sys'
    $settingOk = -not $computer.AutomaticManagedPagefile -and $null -ne $setting -and
        $setting.InitialSize -eq $PageFileMB -and $setting.MaximumSize -eq $PageFileMB
    if (-not $settingOk) {
        if ($computer.AutomaticManagedPagefile) {
            $computer | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
            # Switching automatic management off leaves a C:\pagefile.sys entry at 0/0 (system managed).
            $setting = Get-CimInstance Win32_PageFileSetting | Where-Object Name -eq 'C:\pagefile.sys'
        }
        if ($null -ne $setting) {
            $setting | Set-CimInstance -Property @{ InitialSize = [uint32]$PageFileMB; MaximumSize = [uint32]$PageFileMB }
        } else {
            New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                Name = 'C:\pagefile.sys'; InitialSize = [uint32]$PageFileMB; MaximumSize = [uint32]$PageFileMB } | Out-Null
        }
        Write-Output "页面文件已设为固定 $PageFileMB MB。"
    } else {
        Write-Output "页面文件设置已是固定 $PageFileMB MB，未做改动。"
    }
    $allocated = @(Get-CimInstance Win32_PageFileUsage | Where-Object Name -eq 'C:\pagefile.sys')[0]?.AllocatedBaseSize
    $limitGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVirtualMemorySize / 1MB, 2)
    Write-Output "当前已分配 $allocated MB，已提交内存上限 $limitGB GB。"
    if ($allocated -ne $PageFileMB) {
        Write-Output "还没生效：要重启客户机。先确认六个 runner 都空闲（gh api repos/<仓>/actions/runners 的 busy），再 Restart-Computer。"
    }
    exit 0
}

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
Write-Output '页面文件在客户机里另配：ssh 进客户机跑本脚本 -GuestPageFile。'
