# 厂区服务器日常使用手册

通道已打通（2026-09-01）。本文是"怎么用"，架构和决策理由见
[../README.md](../README.md)。

---

## 0. 接手前必读

**这条通道的私钥不在本仓库里。** 它在控制端本机的
`C:\Users\szy\.ssh\agv_srv_ed25519`，无 passphrase。没有这个文件就连不上。
换机器、重装系统、清空用户目录后都得重走第 6 节。

它**不是**车载上位机那把 `agv_ops_ed25519`，两把钥匙互不通用（README 决策三）。

其余边界：

- **本目录可写**，随便加脚本和记录。
- 能连上这台机器**不等于**能改它上面跑的代码所属的仓库。写权限只看根 `CLAUDE.md`。
- **这台服务器上跑着一整套在用的 AGV 服务**（`AgvAmhs` 5160、`AGV.Web` 8081、
  nginx 9093、RabbitMQ、Redis、SQL Server 1433）。任何全局性改动——防火墙、
  重启、装角色——都会影响它们，动手前先确认。
- `HistoryResetAcknowledgement` 和 `StoragePressurePause` 的恢复**不允许**通过这条
  通道执行，必须在服务器本地控制台做（README 第 6 节）。

---

## 1. 三十秒自检

```bash
ssh factory01 "'{0}@{1}  pwsh {2}  C盘剩余 {3} GB' -f \$env:USERNAME, \$env:COMPUTERNAME, \$PSVersionTable.PSVersion, [math]::Round((Get-PSDrive C).Free/1GB,1)"
```

正常输出：

```
agvops@WIN-0HD72AV4K31  pwsh 7.6.5  C盘剩余 105.3 GB
```

中文不乱码说明 `$PROFILE` 里的 UTF-8 设置生效了。乱码了就重装 profile（第 5 节）。

---

## 2. 连接信息

| 项 | 值 |
| --- | --- |
| 别名 | `factory01` |
| 入口 | `172.19.205.222:22`（企业内网直连，**无 NAT、无端口转发**） |
| 账户 | `agvops`（本地管理员，SSH 会话持完整管理员令牌） |
| 认证 | **仅公钥**，密码认证已关闭 |
| 私钥 | `C:\Users\szy\.ssh\agv_srv_ed25519` |
| 远程 shell | `pwsh` 7.6.5 |
| 应急密码 | `%LOCALAPPDATA%\AgvOpsSecrets\agv-server-agvops.xml`（DPAPI，见第 4 节） |

服务器 host key 指纹（首次连接或怀疑被顶包时核对）：

```
ED25519  SHA256:MdSrvKUDqaD0Py5rJ3tHlmP79JJl3yx/JChvrBGPo0w
RSA      SHA256:e4vkqECN8MORcEY4PynlzPfU7DDYhoc2730IleadJjY
ECDSA    SHA256:jJwAGsmXTGAXJdPsjrocFRbHw3eztrIrr3ZPBwpngQk
```

`ssh_config` 用的是 `StrictHostKeyChecking accept-new`：首次连接自动记录，之后
指纹变了会**拒绝连接**并报警。真换了机器要先删旧条目：

```bash
ssh-keygen -R 172.19.205.222
```

---

## 3. 常用操作

### 跑命令

```bash
ssh factory01 "Get-Process | Sort-Object WS -Descending | Select-Object -First 5 ProcessName,@{n='MB';e={[math]::Round(\$_.WS/1MB,1)}}"
```

Bash 里写 PowerShell 要把 `$` 转义成 `\$`，否则会被 Bash 先吃掉。

**复杂脚本别硬塞进一行。** 引号和转义层层嵌套很容易把命令搅坏——本次施工就在这里
栽过一次，一段带 `{0}` 格式化和嵌套引号的命令被 Bash 拆得面目全非。写成 `.ps1`
传过去跑（见下）。

### 传文件

```bash
# 推
scp 本地文件.ps1 factory01:C:/temp/agv-ops/

# 拉
scp factory01:C:/temp/agv-ops/日志.txt ./evidence/

# 推整个目录
scp -r 本地目录 factory01:C:/temp/agv-ops/
```

远程路径用**正斜杠**（`C:/temp/agv-ops/`），反斜杠会被 scp 当转义符。

### 传了就跑（脚本化操作的标准姿势）

```bash
scp 我的脚本.ps1 factory01:C:/temp/agv-ops/ && \
ssh factory01 "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\agv-ops\我的脚本.ps1"
```

`C:\temp\agv-ops` 是一次性 staging 目录，用完即删。**要留档的输出先 `scp` 拉回
`evidence/` 再清目录**，顺序反了就没了。

二进制包推完校验哈希：

```bash
ssh factory01 "(Get-FileHash C:\temp\agv-ops\包.zip -Algorithm SHA256).Hash"
sha256sum 包.zip | cut -d' ' -f1 | tr 'a-f' 'A-F'
```

### 常见巡检

```bash
# 磁盘
ssh factory01 "Get-PSDrive -PSProvider FileSystem | Select-Object Name,@{n='FreeGB';e={[math]::Round(\$_.Free/1GB,1)}}"

# AGV 服务栈状态
ssh factory01 "Get-Service AgvAmhs,AGVWebApi,MSSQLSERVER,RabbitMQ,Redis,start-nginx,sshd | Select-Object Name,Status,StartType"

# 内存与负载
ssh factory01 "Get-CimInstance Win32_OperatingSystem | Select-Object @{n='总GB';e={[math]::Round(\$_.TotalVisibleMemorySize/1MB,1)}},@{n='可用GB';e={[math]::Round(\$_.FreePhysicalMemory/1MB,1)}}"

# 最近的系统错误
ssh factory01 "Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2} -MaxEvents 10 | Select-Object TimeCreated,Id,ProviderName"

# SSH 自身的日志（排查登录失败很有用）
ssh factory01 "Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 20 | Select-Object TimeCreated,Message"

# 开机时长
ssh factory01 "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime"
```

### 完整环境快照

通用探测脚本在上位机目录下，是只读的，随时可跑：

```bash
ssh factory01 "New-Item -ItemType Directory -Path C:\temp\agv-ops -Force | Out-Null"
scp ../onboard-hmi/scripts/01-probe.ps1 factory01:C:/temp/agv-ops/
ssh factory01 "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\agv-ops\01-probe.ps1 -ControlHost 172.19.162.241" > /dev/null
NAME=$(ssh factory01 "(Get-ChildItem C:\temp\agv-ops\probe-*.txt | Sort-Object LastWriteTime | Select-Object -Last 1).Name" | tr -d '\r')
scp "factory01:C:/temp/agv-ops/$NAME" evidence/
ssh factory01 "Remove-Item C:\temp\agv-ops -Recurse -Force"
```

拉回来的文件与 `evidence/` 里的基线对比，就能看出机器有什么变化。

---

## 4. 连不上怎么办

按这个顺序切，能快速定位是哪一层坏的。

### 第 0 层：先确认你的探测结果可信

**如果控制端的 Clash 在跑 TUN 模式，而绕行路由不在，那么下面所有 ping 和端口测试
都会返回假的"成功"。** 先验一下：

```bash
ssh factory01 "hostname"      # 这个不会骗人
```

或者直接检查路由：

```powershell
Find-NetRoute -RemoteIPAddress 172.19.205.222 | Select-Object -First 1 IPAddress,InterfaceAlias
```

`InterfaceAlias` 应该是 `Wi-Fi`。如果显示 `Clash`，说明绕行路由掉了，重新加上：

```powershell
pwsh -ExecutionPolicy Bypass -File scripts\01-control-host-route.ps1
```

来龙去脉见 [../README.md](../README.md) 第 2 节。

### 第 1 层：网络通不通

```bash
ping 172.19.205.222
```

不通 → 控制端不在企业内网，或路由变了。检查本机 Wi-Fi 是否连着 `172.19.162.x`。

### 第 2 层：22 端口开着吗

```bash
ssh -v factory01 2>&1 | head -5
```

看得到 `Connection established` 说明 TCP 通了。超时 → 服务器上 sshd 停了，或者
有人打开了 Private profile 的防火墙但没放行 22（README 决策五）。

### 第 3 层：sshd 活着吗

TCP 通但握手失败 → 走 **VNC / 向日葵应急通道**（第 7 节），进去执行：

```powershell
Get-Service sshd
Start-Service sshd
Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 20
```

### 第 4 层：认证失败

报 `Permission denied (publickey)` 说明网络和 sshd 都正常，纯粹是公钥问题。

1. **私钥不在或不对**：

   ```bash
   ssh-keygen -y -f C:/Users/szy/.ssh/agv_srv_ed25519
   # 和 config/agv_srv_ed25519.pub 比对
   ```

2. **authorized_keys 的 ACL 不对** —— Windows OpenSSH 最经典的坑。sshd 会**静默
   拒绝**任何 SYSTEM 和 Administrators 之外还有写权限的 authorized-keys 文件。
   VNC 进去修：

   ```powershell
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F'
   Restart-Service sshd
   ```

   正确的 ACL 只有两条：`BUILTIN\Administrators:(F)` 和 `NT AUTHORITY\SYSTEM:(F)`。

---

## 5. 维护动作

### 重装 UTF-8 profile（中文乱码时）

```bash
scp ../onboard-hmi/scripts/agvops-profile.ps1 factory01:C:/temp/agv-ops/ && \
ssh factory01 "New-Item -ItemType Directory -Path (Split-Path \$PROFILE) -Force | Out-Null; Copy-Item C:\temp\agv-ops\agvops-profile.ps1 \$PROFILE -Force"
```

### 恢复 sshd 配置（加固出问题时）

```bash
ssh factory01 "Get-ChildItem C:\ProgramData\ssh\sshd_config.backup-* | Select-Object Name,LastWriteTime"
ssh factory01 "Copy-Item 'C:\ProgramData\ssh\sshd_config.backup-20260901-201040' 'C:\ProgramData\ssh\sshd_config' -Force; Restart-Service sshd"
```

`Restart-Service sshd` **不会**掐断已建立的 SSH 连接（在上位机上实测过，Windows
OpenSSH 重启服务只更换监听器，既有会话由独立子进程处理）。所以"改配置 + 重启
sshd"可以安全地远程完成。

### 取回 agvops 的应急密码

只在需要用 VNC / 向日葵 / 物理控制台以 `agvops` 身份登录时才需要：

```powershell
(Import-Clixml "$env:LOCALAPPDATA\AgvOpsSecrets\agv-server-agvops.xml").GetNetworkCredential().Password
```

这个文件只能由创建它的 Windows 用户在控制端本机解密。**不要**把结果贴进聊天、
工单或任何日志。

### 控制端的绕行路由

```powershell
# 加（幂等，可重复跑）
pwsh -ExecutionPolicy Bypass -File scripts\01-control-host-route.ps1
# 撤
pwsh -ExecutionPolicy Bypass -File scripts\01-control-host-route.ps1 -Remove
```

两条都需要管理员。

---

## 6. 换控制端机器 / 重配公钥

1. 在新控制端生成密钥：

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/agv_srv_ed25519 -N "" -C "agv-srv-ops@新主机名"
   ```

2. 用 VNC / 向日葵 / 物理控制台进服务器，把新公钥追加到
   `C:\ProgramData\ssh\administrators_authorized_keys`，并重置 ACL：

   ```powershell
   Add-Content C:\ProgramData\ssh\administrators_authorized_keys '<新公钥整行>'
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F'
   Restart-Service sshd
   ```

   写文件时注意**不能有 BOM**。

3. 把 `config/ssh_config.factory` 的内容加进新机器的 `~/.ssh/config`，改掉
   `IdentityFile` 的路径。

4. 加绕行路由（如果新机器也跑 Clash TUN）：`scripts/01-control-host-route.ps1`。

5. 验证 `ssh factory01`，通了之后再从服务器上删掉旧公钥那一行。

---

## 7. 应急通道

SSH 彻底不通时的后路，两条都与 sshd 无关，sshd 挂了不影响它们：

| 通道 | 地址 | 说明 |
| --- | --- | --- |
| RealVNC Server | `172.19.205.222:5900` | 常驻运行 |
| AweSun（向日葵） | 客户端登录 | 常驻运行 |

物理控制台是最后一道后路。

---

## 8. Hyper-V 虚拟机

2026-09-01 起这台机器装了 Hyper-V。为什么这么配、当时做了什么，见
[../README.md](../README.md) 决策六、决策七与第 4 节阶段 2。

### 先记住这条：pwsh 7 要加 `-SkipEditionCheck`

```bash
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Get-VM | Select-Object Name,State,Version"
```

不加它，pwsh 会通过 Windows PowerShell 兼容会话代理 Hyper-V 模块，拿到的是
`Deserialized.*` 对象。**只读的 `Get-*` 照常能用**，所以问题不会立刻暴露；但凡是要把
对象再传回去的命令——`Set-VMFirmware -BootOrder`、`-FirstBootDevice`——都会报"无法将
`Deserialized.Microsoft.HyperV.PowerShell.*` 转换为 `VMComponentObject`"。

**不要因此退回 `powershell.exe`**，加这个参数就够了，PS7 基线不用破例。

### 能远程做什么、不能做什么

| 事 | 走哪 |
| --- | --- |
| 建虚拟机、改配置、启停、快照、查状态 | ✅ SSH |
| 传文件进 Windows 客户机（不需要客户机联网） | ✅ SSH，`Copy-VMFile`，见下 |
| 看客户机当前画面 | ✅ SSH，`vm-screenshot.ps1`（**只能看，不能点**） |
| **装系统、过 OOBE、按"任意键"** | ❌ 只能走向日葵 / VNC 开 VMConnect |

### 当前资产

| | |
| --- | --- |
| 数据根 | `D:\zhengyushao\Hyper-V\{VirtualMachines,VirtualHardDisks}` |
| 虚拟交换机 | `AGV-Internal`（Internal，**不绑定物理网卡**），宿主侧 `192.168.200.1/24` |
| NAT | `AGV-NAT`，`192.168.200.0/24`。**不带 DHCP，客户机必须配静态地址** |
| 虚拟机 | `win11-01`（Gen 2 / 4 vCPU / 4 GB 静态 / VHDX 上限 80 GB / Secure Boot + vTPM） |
| 安装介质 | `D:\zhengyushao\Windows.iso` = Windows 11 24H2 build `10.0.26100.1` |

**`em4` 上没有、也永远不要建 External 虚拟交换机**——它是唯一插了线的网卡，也是这条
SSH 通道本身，理由见 README 决策六。

### 日常查看

```bash
# 虚拟机清单
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Get-VM | Select-Object Name,State,CPUUsage,MemoryAssigned,Uptime"

# 某台的固件与安全配置
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Get-VMFirmware -VMName win11-01 | Select-Object SecureBoot,SecureBootTemplate; Get-VMSecurity -VMName win11-01 | Select-Object TpmEnabled"

# 磁盘实占（动态 VHDX 会长）
ssh factory01 "Get-VHD D:\zhengyushao\Hyper-V\VirtualHardDisks\win11-01.vhdx | Select-Object VhdType,FileSize,Size"

# 启停
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Start-VM win11-01"
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Stop-VM win11-01"
```

### 建一台新虚拟机

```bash
scp ../scripts/04-create-win11-vm.ps1 factory01:C:/temp/agv-ops/
ssh factory01 "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\agv-ops\04-create-win11-vm.ps1 -Name win11-02"
```

宿主侧配置（路径、交换机、NAT、Defender 排除项）是 `03-configure-hyper-v-host.ps1`，
幂等，怀疑被改动过随时可重跑。

### 看客户机画面

SSH 看不到图形层。`Get-VM` 说 `State = Running` 不代表它在正常跑——它可能卡在
"No operating system was loaded"，而 `CPUUsage = 0` 这个线索太弱，猜不出来。抓一张：

```bash
scp ../scripts/vm-screenshot.ps1 factory01:C:/temp/agv-ops/
ssh factory01 "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\agv-ops\vm-screenshot.ps1 -VMName win11-01"
scp factory01:C:/temp/agv-ops/vm-screen.png ./
```

虚拟机必须在运行状态，否则 API 报错。

### 传文件进 Windows 客户机（不需要客户机联网）

Server 2016 有 PowerShell Direct，宿主通过 VMBus 直接进 Windows 客户机。从控制端出发
是两跳，全程走已有的 SSH 通道：

```bash
scp 文件.zip factory01:D:/zhengyushao/vm-staging/
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Copy-VMFile -Name win11-01 -SourcePath 'D:\zhengyushao\vm-staging\文件.zip' -DestinationPath 'C:\staging\文件.zip' -CreateFullPath -FileSource Host"
```

前置：客户机要先启用 Guest Service Interface。

```bash
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Enable-VMIntegrationService -VMName win11-01 -Name 'Guest Service Interface'"
```

**只对 Windows 客户机有效**（Server 2016 / Win10 及以上）。Linux 客户机不支持
PowerShell Direct 和 `Copy-VMFile`，只能走网络、挂 ISO 或附加 VHDX——选客户机操作系统
时这是一个实际差别。

### 装 Windows 11：三个必踩的坑

装系统是交互操作，SSH 做不了。向日葵 / VNC 进服务器桌面 → `virtmgmt.msc` →
双击虚拟机开 VMConnect。**用基本会话，不要用增强会话。**

1. **"Press any key to boot from CD or DVD" 只给 5 秒。** 不按就超时，落到空白硬盘上
   报 `No UEFI-compatible file system was found`。看起来像配置错了，其实引导顺序是
   对的，只是没人按键——2026-09-01 首次启动 `win11-01` 就是这个现象。

2. **Windows 11 24H2 的 OOBE 强制联网。** NAT 不带 DHCP，客户机在 OOBE 阶段拿不到
   地址，这一步过不去。`Shift+F10` 打开命令行，二选一：

   ```
   oobe\bypassnro
   ```

   （执行后机器重启，会多出"我没有 Internet 连接"选项；26100.1 里这个脚本还在，
   是后来的累积更新才移除的）或者直接配静态地址：

   ```
   netsh interface ip set address name="Ethernet" static 192.168.200.50 255.255.255.0 192.168.200.1
   netsh interface ip set dns name="Ethernet" static 172.19.1.31
   ```

3. **装完记得配静态地址**（同上），否则客户机没有网。

### 火绒排除项——必须人工做

火绒 `HipsDaemon` 和 Windows Defender 在这台机器上同时运行。Defender 的排除项已由
`03-configure-hyper-v-host.ps1` 加好，**火绒的没有，也加不了——它没有命令行接口**。

在它的图形界面里加：

- 排除路径 `D:\zhengyushao\Hyper-V`
- 排除进程 `vmms.exe`、`vmwp.exe`、`vmcompute.exe`

漏了的症状是"虚拟机莫名其妙很卡"，极难往杀软上想。而且火绒是 HIPS 不只是杀毒，
理论上还可能拦 Hyper-V 的驱动——2026-09-01 装角色时它没有拦，但这不构成保证。

---

## 9. 完全撤销

把服务器恢复到没装过这套东西的状态：

```bash
ssh factory01 "
Stop-Service sshd
Set-Service sshd -StartupType Disabled
Remove-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-22' -ErrorAction SilentlyContinue
Remove-Item C:\ProgramData\ssh\administrators_authorized_keys -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue
Remove-LocalUser -Name agvops -ErrorAction SilentlyContinue
Remove-Item C:\temp\agv-ops -Recurse -Force -ErrorAction SilentlyContinue
"
```

跑完 SSH 就断了（本来就是目的）。之后还要做：

- 卸载 OpenSSH（需 VNC 进去跑）：
  `powershell -ExecutionPolicy Bypass -File 'C:\Program Files\OpenSSH\uninstall-sshd.ps1'`
  然后删掉 `C:\Program Files\OpenSSH` 和机器 `PATH` 里的那一项。
- 删 `C:\Users\agvops` 配置文件目录。
- 控制端：`ssh-keygen -R 172.19.205.222`、删 `~/.ssh/config` 里的 `factory01` 段、
  删 `~/.ssh/agv_srv_ed25519*`、删
  `%LOCALAPPDATA%\AgvOpsSecrets\agv-server-agvops.xml`、
  跑 `scripts/01-control-host-route.ps1 -Remove`。

`Administrator`、RealVNC、AweSun、SQL Server 和整套 AGV 服务全程没动过，不需要恢复。

**Hyper-V 是另一件事，不在上面这段的范围里。** 要连它一起撤（会再次重启并中断生产
服务，需要停机窗口）：

```bash
ssh factory01 "Import-Module Hyper-V -SkipEditionCheck; Get-VM | Stop-VM -TurnOff -Force; Get-VM | Remove-VM -Force"
ssh factory01 "Remove-NetNat -Name AGV-NAT -Confirm:\$false; Import-Module Hyper-V -SkipEditionCheck; Remove-VMSwitch -Name AGV-Internal -Force"
ssh factory01 "Uninstall-WindowsFeature -Name Hyper-V -IncludeManagementTools"
```

然后重启，再删 `D:\zhengyushao\Hyper-V` 和 Defender 的三类排除项。虚拟硬盘删了就
没了，先确认里面没有要留的东西。

**旧的 WinRM 通道没有恢复脚本**，那是有意的——重建它需要重新创建
`codex-ops`/`codex-admin`、重新加 `LocalAccountTokenFilterPolicy` 和防火墙规则，
而那正是本方案决定放弃的东西（README 决策一）。
