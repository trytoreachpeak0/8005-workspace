#Requires -Version 7
<#
.SYNOPSIS
    在 Hyper-V 的 Windows 客户机里开通 SSH 运维通道（公钥认证，无密码）。

.DESCRIPTION
    **在客户机里跑，不是在宿主上跑。** 前置是客户机已装 pwsh 7：

        msiexec /i <路径>\PowerShell-7.6.5-win-x64.msi /qn /norestart

    把安装包送进客户机不需要任何凭据，宿主上一条 Copy-VMFile 就行（客户机的
    「来宾服务接口」要先启用）：

        Import-Module Hyper-V -SkipEditionCheck
        Enable-VMIntegrationService -VMName <VM> -Name '来宾服务接口'
        Copy-VMFile -Name <VM> -SourcePath <本地> -DestinationPath C:\agv-ops\<文件> `
                    -CreateFullPath -FileSource Host

    为什么用公钥不用密码：工作区对远程通道的一贯做法是日常走公钥、密码只留一份
    DPAPI 应急件（README 决策二、决策三）。密码一旦说出口就进了对话记录和日志，
    而公钥不需要任何一方知道秘密。密钥用专用的第三把 agv_vm_ed25519，不复用上位机
    或服务器那两把——不同信任域分开，任一把泄露可以独立轮换。

    第 5 步的网络配置文件与防火墙**不是可选的**，见 .NOTES。

.NOTES
    2026-09-01 首次在 win11-01（Windows 11 24H2 -> 26200.9168）上执行。

    **第 5 步是这台机器上最花时间的坑。** 全新 Windows 11 接在 Internal 交换机 +
    WinNAT 上时，这个网络缺少 NLA 判定网关可达性所需的特征，会被判成「未识别网络」
    并归入**公用**配置文件。公用配置默认挡掉 ICMP 和几乎所有入站——症状是宿主既
    ping 不通也连不上 22，而客户机自己上网、更新、装东西一切正常。第一版脚本漏了
    这步，结果 sshd 明明在跑却谁也进不来，排查方向很容易跑偏到 sshd 配置或跳板上。

    另一个小坑：脚本里的进度用 Write-Host 打印时**无法被 `>` 重定向捕获**（它走的是
    information 流）。要把输出留档就用 `| Tee-Object` 或 `6>&1 >` 。本脚本的关键结论
    用 Write-Output 走标准输出，可以直接重定向。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublicKey,
    [string]$HostSubnet = '192.168.200.0/24',
    [int]   $Port = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw '需要管理员权限：以管理员身份运行 pwsh。' }

Write-Host '1/5 安装 OpenSSH 服务端' -ForegroundColor Cyan
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -eq 'Installed') { Write-Host '  已安装，跳过' }
else { Add-WindowsCapability -Online -Name $cap.Name | Out-Null; Write-Host "  已安装 $($cap.Name)" }

Write-Host '2/5 启动服务并设为自动' -ForegroundColor Cyan
Set-Service sshd -StartupType Automatic
Start-Service sshd

Write-Host '3/5 写入公钥' -ForegroundColor Cyan
# 管理员组成员的公钥不放 ~/.ssh/authorized_keys，而是这个全局文件——Windows OpenSSH
# 就是这么设计的，放错地方 sshd 会静默拒绝登录，且不告诉你原因。
$akFile   = "$env:ProgramData\ssh\administrators_authorized_keys"
$existing = (Test-Path $akFile) ? @(Get-Content $akFile) : @()
if ($existing -contains $PublicKey) { Write-Host '  公钥已在，跳过' }
else {
    # UTF-8 无 BOM：带 BOM 的话 sshd 读不出第一行
    [IO.File]::WriteAllLines($akFile,
        @($existing | Where-Object { $_ -and $_.Trim() }) + $PublicKey,
        (New-Object Text.UTF8Encoding $false))
    Write-Host '  已写入'
}
# sshd 会静默拒绝任何 SYSTEM 与 Administrators 之外还有写权限的 authorized-keys 文件。
icacls $akFile /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F' | Out-Null

Write-Host '4/5 关闭密码认证，默认 shell 设为 pwsh' -ForegroundColor Cyan
$cfg = "$env:ProgramData\ssh\sshd_config"
Copy-Item $cfg "$cfg.backup-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
$lines = @(Get-Content $cfg)
$want  = [ordered]@{
    PubkeyAuthentication         = 'yes'
    PasswordAuthentication       = 'no'
    KbdInteractiveAuthentication = 'no'
    PermitEmptyPasswords         = 'no'
}
foreach ($k in $want.Keys) {
    $lines = @($lines | Where-Object { $_ -notmatch "^\s*#?\s*$k\s" }) + "$k $($want[$k])"
}
[IO.File]::WriteAllLines($cfg, $lines, (New-Object Text.UTF8Encoding $false))
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value (Get-Command pwsh).Source

Write-Host '5/5 网络配置文件与防火墙（漏了这步前面全白做，见 .NOTES）' -ForegroundColor Cyan
foreach ($p in Get-NetConnectionProfile) {
    if ($p.NetworkCategory -ne 'Private') {
        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
        Write-Host "  $($p.InterfaceAlias)：$($p.NetworkCategory) -> Private"
    }
}
# 作用域限定宿主网段而不是「任何位置」：客户机在隔离的 Internal 交换机上，本来就只有
# 宿主够得到它，规则写窄不花额外代价。
foreach ($r in @(
    @{ Name = 'AGV-SSH-In-From-Host';  Display = 'AGV ops SSH (from Hyper-V host)';  Proto = 'TCP' }
    @{ Name = 'AGV-ICMP-In-From-Host'; Display = 'AGV ops ICMP (from Hyper-V host)'; Proto = 'ICMPv4' }
)) {
    if (Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $r.Name -Enabled True
    } elseif ($r.Proto -eq 'TCP') {
        New-NetFirewallRule -Name $r.Name -DisplayName $r.Display -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow -RemoteAddress $HostSubnet `
            -Profile Any -Enabled True | Out-Null
    } else {
        New-NetFirewallRule -Name $r.Name -DisplayName $r.Display -Direction Inbound `
            -Protocol ICMPv4 -IcmpType 8 -Action Allow -RemoteAddress $HostSubnet `
            -Profile Any -Enabled True | Out-Null
    }
    Write-Host "  $($r.Name) 就绪"
}
Restart-Service sshd

# 结论走标准输出，可以直接 > 重定向留档（进度那些 Write-Host 不行，见 .NOTES）
Write-Output ''
Write-Output "计算机名 : $env:COMPUTERNAME"
Write-Output "账户     : $env:USERNAME"
Write-Output "地址     : $((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress)"
Write-Output "sshd     : $((Get-Service sshd).Status)"
Write-Output "配置文件 : $((Get-NetConnectionProfile | Select-Object -First 1).NetworkCategory)"
Write-Output '把「账户」这一行告诉控制端即可，密码不需要。'
