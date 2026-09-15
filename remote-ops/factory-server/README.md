# AGV 厂区服务器远程运维（remote-ops/factory-server）

目标：把厂区服务器 `WIN-0HD72AV4K31` 变成可远程自动化部署、巡检、操作的目标机。
这台机器未来要承载 MES ingest 与 WIRE_TO_GATE 控制服务，并从它出发连到车载上位机
和雷达服务器；当前所有部署测试仍在控制端本机上进行。

本目录可写。**能通过这里够到这台机器，不等于获得那台机器上运行的代码所属仓库的写
权限**——写权限只看根 `CLAUDE.md`。

---

## 从哪读起

| 你要做什么 | 读哪个 |
| --- | --- |
| **日常运维这台服务器** | [docs/USAGE.md](docs/USAGE.md) |
| 理解为什么从 WinRM 换成 SSH | 本文件第 3 节 |
| 知道这台机器上跑着什么、不能碰什么 | 本文件第 2 节 |
| 连不上了要排错 | [docs/USAGE.md](docs/USAGE.md) 第 4 节 |
| **在这台机器上跑虚拟机** | [docs/USAGE.md](docs/USAGE.md) 第 8 节 |
| **部署 MesIngest（CD）** | [docs/mes-ingest-cd.md](docs/mes-ingest-cd.md) |
| 把服务器恢复到没装过这套东西的状态 | [docs/USAGE.md](docs/USAGE.md) 第 7 节 |

> **接手前提**：私钥在控制端本机 `C:\Users\szy\.ssh\agv_srv_ed25519`，**不在本目录
> 里**。没有它连不上。它和上位机用的 `agv_ops_ed25519` 是**两把不同的钥匙**，
> 见第 3 节决策三。

当前状态：**通道已打通并加固**（2026-09-01），`ssh factory01` 可用，仅公钥认证。

---

## 1. 已确认的事实（2026-09-01 实测）

### 服务器

| 项 | 值 |
| --- | --- |
| 主机名 | `WIN-0HD72AV4K31` |
| OS | Windows Server 2016 Standard，build `14393.9418` |
| 硬件 | Lenovo ThinkSystem SR650，Xeon Gold 6240，36 逻辑核，31.5 GB RAM |
| 磁盘 | `C:` 234.6 GB（可用 105.3）；`D:` 210.9 GB（可用 163.2） |
| 域 | `WORKGROUP`，未加域 |
| 企业内网地址 | `172.19.205.222/24`（网卡 `em4`），网关 `172.19.205.1` |
| 其余三个网口 | `em1`/`em2`/`em3` 均为 `169.254.x`，未接线 |
| DNS | `172.19.1.31`、`172.19.1.32` |
| **外网** | **通**，直连无代理。`github.com:443` 实测 HTTP 200 |
| PowerShell | Windows PowerShell 5.1 与 **pwsh 7.6.5** 并存 |
| 远程端点 | `PowerShell.7`、`PowerShell.7.6.5` 已注册（pwsh 安装时自带） |
| SQL Server | 唯一实例 `MSSQLSERVER`（`MSSQL16.MSSQLSERVER` = SQL Server 2022，16.0.1190.2，**Developer Edition**），**自动-延迟启动**，混合验证模式 |
| SQL 数据库 | `SQAGV`（生产 AGV 库，**不归本工作区管，不要碰**）、`DWDiagnostics`/`DWConfiguration`/`DWQueue`（PolyBase 自带）。`MesIngest` 已于 2026-09-01 按用户要求删除 |
| Hyper-V | **已安装并生效**（2026-09-01，第 4 节阶段 2）。`HypervisorPresent = True`，虚拟机配置版本上限 **8.0** |
| 虚拟交换机 | `AGV-Internal`（Internal，**不绑定任何物理网卡**）+ 宿主侧 `192.168.200.1/24` + NAT `AGV-NAT` |
| 防火墙 | **Domain profile 开启；Private 与 Public 均关闭**。`em4` 属 Private |

改造完成后的完整快照在 `evidence/probe-WIN-0HD72AV4K31-20260901-202150.txt`（不进 git）。
改造**之前**那份快照已按用户要求删除——它是工作区内最后一处原样记录着旧 WinRM
账户布局的文件。决策相关的内容都已提炼进本文件第 3 节，没有信息损失。

### 这台机器上正在跑的东西

**它不是一台空机器。** 动任何全局性配置前先看这张表：

| 服务 | 端口 | 路径 |
| --- | --- | --- |
| `AgvAmhs.exe` | 5160 | `D:\AgvAmhs` |
| `AGV.Web.exe`（服务名 `AGVWebApi`） | 8081 | `D:\webapp` |
| nginx 1.25.1 | 9093 | `D:\nginx-1.25.1` |
| RabbitMQ（Erlang OTP 15.2.7.2） | 5672 / 15672 / 25672 | — |
| Redis | 6379（仅 127.0.0.1） | `D:\redis` |
| SQL Server 2022 + PolyBase | 1433 | `C:\Program Files\Microsoft SQL Server` |
| RealVNC Server | 5800 / 5900 | — |
| AweSun（向日葵）远控 | 仅回环 | `C:\Program Files\Oray\AweSun` |
| 火绒 `HipsDaemon` | 51651（仅回环） | `C:\Program Files (x86)\Huorong` |

另有 `GeminiBrowserSrv` 跑在 `C:\Users\Administrator\AppData\Local\GeminiBrowser\`。

### 网络路径

控制端 `172.19.162.241`（Wi-Fi）与服务器 `172.19.205.222` 在同一企业内网的不同
网段，之间由企业路由转发，**没有 NAT，也没有 CPE**——这是它和车载上位机最大的
不同，SSH 直接连 22 端口即可，不需要端口转发。

**服务器出站实测**（从服务器侧发起，真实结果）：

| 目标 | 结果 |
| --- | --- |
| `172.19.162.210:22022`（1 号车 CPE 的 SSH 转发） | 通 |
| `172.19.162.210:5900`（1 号车 VNC） | 通 |
| `172.19.162.241:445`（控制端） | 通 |
| `github.com:443`、`download.microsoft.com:443` | 通 |
| `1.1.1.1:443` | 不通（企业出口只放行了部分目标） |

也就是说"未来从 factory-server 连上位机"这条路已经验证可行。

---

## 2. ⚠ 控制端的 Clash TUN 会让所有探测结果失真

这一条独立于服务器，是控制端本机的问题，但不知道它会把排错带进沟里。

Clash for Windows 以 TUN 模式运行，在 `Clash` 适配器上装了 `128.0.0.0/1`
（RouteMetric 0）的路由。`172.19.205.222` 落在这个前缀里，于是所有发往服务器的
包都会先进隧道。Clash 的规则表里有 `IP-CIDR,172.16.0.0/12,DIRECT,no-resolve`，
所以流量最终还是直连出去了、通道能用——**但 TUN 自己应答 ICMP，也自己先完成 TCP
握手再去拨号**。2026-09-01 实测：

- `ping 172.19.199.199`（不存在的地址）→ Success，0 ms
- 服务器的 7 / 9999 / 31337 / 54321 端口 → 全部 "OPEN"
- 连 `172.19.205.221` 这个地址本身都"OPEN"

车载上位机不受影响：Wi-Fi 上有 `172.19.162.0/24` 的直连路由，比 `/1` 更明细，
本来就赢。

**已修复**，用 `scripts/01-control-host-route.ps1`：在 Wi-Fi 上加一条
`172.19.205.0/24 → 172.19.162.1` 的路由，靠最长前缀匹配压过 Clash 的 `/1`，流量
根本不进 TUN。这条路由同时写进活动路由表和持久化注册表，重启后仍在，且**不依赖
Clash 的配置**——订阅更新、切换 profile、Clash 直接退出，都不影响。

修复后复测：22 / 1433 / 5985 报 OPEN，9999 / 31337 报 closed；同网段的 `.3` 和
`.77` 不回应，`.199` 和 `.250` 回应（那是真实存在的主机）。探测恢复真实。

回退：`pwsh -File scripts/01-control-host-route.ps1 -Remove`，或手工
`route delete 172.19.205.0 mask 255.255.255.0`。

> 脚本里用的是 `route.exe -p add` 而不是 `New-NetRoute`。原因写在脚本注释里：
> 本控制端（Windows 11 25H2）上 `New-NetRoute -PolicyStore PersistentStore`
> 无论用 `-InterfaceIndex` 还是 `-InterfaceAlias` 都报
> `Invalid parameter PolicyStore PersistentStore`，路由重启即失。

---

## 3. 架构决策

### 决策一：SSH，不用 WinRM —— 并且把旧的 WinRM 通道整个拆掉

前一版方案走 WinRM 5985 + `codex-ops`/`codex-admin` 双账户。它有几个问题在
2026-09-01 的盘点里全部暴露：

1. **双账户模型从来没真正生效过。** `codex-ops` 连不上：默认的
   `microsoft.powershell` 端点 SDDL 是空的，回落到 RootSDDL
   `O:NSG:BAD:P(A;;GA;;;BA)(A;;GR;;;IU)`——非管理员只拿到 `GenericRead`，建不了
   会话，一律"拒绝访问"。改走 `PowerShell.7` 端点则报 `pwrshplugin` 故障。
   实际能用的只有管理员账户一条路，"日常任务先用低权账户"这个安全设计从未生效。

2. **文档里的防火墙加固不成立。** `AGV-WinRM-Management-PC` 规则（只放行
   `172.19.162.241` 到 5985）确实在，但 `em4` 网卡属 Private 类别，而 **Private
   profile 整体是关闭的**——没有任何入站过滤。同时前一版声称已禁用的
   `WINRM-HTTP-In-TCP` 与 `-PUBLIC` 两条默认规则又都变回启用状态。

3. **它要求关掉远程 UAC 令牌过滤。** `LocalAccountTokenFilterPolicy = 1` 让**所有**
   本地管理员账户在网络登录时拿到完整令牌，是为 WinRM 让路才加的。

4. **文档的前提整个过时了。** 声称 build `14393.1884`、无互联网、只有 PS 5.1；实测
   是 `14393.9418`、外网直连、pwsh 7.6.5 已装。

SSH 逐条解决：单端口、公钥免密、不需要 `TrustedHosts`、命令行工具可直接驱动、
与车载上位机同一套操作习惯。**并且不需要 `LocalAccountTokenFilterPolicy`**——已实测
验证：SSH 会话中 `agvops` 的令牌里 `BUILTIN\Administrators` 是 Enabled group，
完整性级别 High（`S-1-16-12288`），`SeDebugPrivilege`、`SeLoadDriverPrivilege`、
`SeTakeOwnershipPrivilege` 全部 Enabled。该注册表值已删除，恢复 Windows 默认。

拆除动作由 `scripts/02-remove-winrm-channel.ps1` 执行，脚本头部逐条写明删了什么、
为什么、以及**有意不动**哪些（WinRM 服务本身和 Windows 自带的防火墙规则是系统
默认，不是前一版新增的，删我们加的东西就等于恢复默认）。

### 决策二：单个 `agvops` 管理员账户，不再分两层

上一版的两层模型在 WinRM 下没跑通（决策一第 1 条）。SSH 下双层是可行的，但这台
机器上要做的事——部署 Windows 服务、管 SQL Server、将来装 Hyper-V——基本都需要
管理员。因此先用一个 `agvops` 本地管理员，与车载上位机的账户名保持一致。
需要时再加低权账户不难，反过来才麻烦。

`agvops` 的密码由控制端随机生成，**只存进控制端的 DPAPI 文件
`%LOCALAPPDATA%\AgvOpsSecrets\agv-server-agvops.xml`，全程没有打印到任何终端或日志**。
它只在 VNC / 向日葵 / 物理控制台应急时用得到，日常一律走公钥。

### 决策三：独立密钥，不复用上位机那把

车载上位机用 `~/.ssh/agv_ops_ed25519`，这台服务器用 `~/.ssh/agv_srv_ed25519`。
两者是不同的信任域：服务器上跑着 SQL Server 和整套生产服务栈，上位机是现场设备。
分开的代价是多管一把钥匙，收益是任一把泄露时可以独立轮换，不必同时换掉全部车辆。

公钥副本在 `config/agv_srv_ed25519.pub`，私钥不进任何仓库。

### 决策四：复用上位机的脚本，不另写一套

`01-probe.ps1`、`02-bootstrap-sshd.ps1`、`03-harden-sshd.ps1`、`agvops-profile.ps1`
四个脚本是通用的 Windows 操作，直接用 `../onboard-hmi/scripts/` 下的原件，本目录
不复制。**本目录的 `scripts/` 只放这台服务器特有的东西。**

复用时唯一要忽略的是 `02-bootstrap-sshd.ps1` 跑完打印的那段 CPE 端口转发指引——
那是给车载上位机的，这台服务器没有 CPE 也没有 NAT。

### 决策五：不打开防火墙 profile

`em4` 属 Private 类别，而 Private profile 是关闭的，等于这台机器在企业内网上完全
没有入站过滤。这是**既有状况，不是本次造成的**。

有意不去打开它：这台机器上跑着 5160、8081、9093、1433、5672、15672、5900 等一堆
在用的端口，贸然启用防火墙很可能打断生产服务。这件事应该单独规划、单独安排窗口。

直接后果是 **SSH 的 22 端口对整个企业内网开放**。因此仅公钥认证在这里不是可选项
而是必须项，密码认证已关闭（`PasswordAuthentication no`、
`KbdInteractiveAuthentication no`、`PermitEmptyPasswords no`），实测强制密码登录
返回 `Permission denied (publickey)`。

---

### 决策六：Internal 虚拟交换机 + NAT，**绝不碰 `em4`**

装了 Hyper-V 就要给虚拟机接网，最自然的做法是在 `em4` 上建 External 虚拟交换机。
**这台机器上不能这么做。**

`em4` 是四个网口里唯一插了线的，承载 `172.19.205.222`，也就是这条 SSH 通道本身。
建 External 交换机时 Hyper-V 会把物理网卡绑给虚拟交换机、在宿主侧新建
`vEthernet (...)` 并重走 IP 配置——这中间地址会短暂消失，迁移不成功就再也连不上，
只剩向日葵 / VNC / 到机房三条后路。为了给虚拟机接网而赌上运维通道本身，不划算。

改用 Internal 交换机：不绑定任何物理网卡，创建过程对宿主网络零影响。代价是虚拟机
默认没有外网，用 `New-NetNat` 补上——宿主当 NAT 网关，客户机走 `192.168.200.0/24`。

`192.168.200.0/24` 这个网段是**沿用的，不是新选的**：`8005---AGV` 里
`.scratch/onboard-controlserver-plaintext-transport` 票 07 的异机取证环境就是宿主
`.1`、客户机 `.50`。将来要在这台服务器上复现那套联调，地址能直接对上。

**WinNAT 不带 DHCP**，客户机必须配静态地址。直接后果是 Windows 11 的 OOBE 强制联网
那一步会卡住，绕法写在 [docs/USAGE.md](docs/USAGE.md) 第 8 节。这个代价是知情接受的
——替代方案是装 DHCP Server 角色，而那东西一旦绑错网卡就会往企业内网发地址，风险
远大于收益。

将来有人去机房把 `em1` 的线插上，再在 `em1` 上建 External 交换机接企业网。两种交换机
可以并存，虚拟机挂两块网卡即可。**`em4` 永远不参与。**

### 决策七：虚拟机在服务器上重建，不从控制端迁移

用户 2026-09-01 明确本轮范围：本机的虚拟机和数据库都不迁移，在服务器上直接起新的。

即使想迁也迁不了，这里有一条硬约束值得记下来：**控制端（Windows 11）上那四台虚拟机
的配置版本是 12.0，而 Windows Server 2016 的 Hyper-V 支持上限是 8.0。配置版本只能升
不能降**，导出再导入这条路根本不通。

这条约束同时意味着：将来若要在这台服务器上重建 `8005---AGV` 那套黄金渲染机
（`gpt_win11`），它会是**另一台机器**而不是同一台。金机的视觉基线绑在一整套校准环境
上（主机名、1920x1080、96 DPI、浅色、zh-CN、Microsoft YaHei UI + Consolas、
SoftwareOnly），换宿主换 Hyper-V 版本之后必须重拍并由用户重新逐张审批。用户
2026-09-01 已知情并选择先只做到"能装上 Windows 11"，金机重建暂缓。

---

## 4. 执行记录

### 阶段 1：SSH 通道（2026-09-01 完成）

| 项 | 最终状态 |
| --- | --- |
| SSH 服务端 | `OpenSSH 10.0.0.0p2` 离线包安装，服务 Automatic，监听 22 |
| 入口 | `172.19.205.222:22`，直连，无端口转发 |
| 运维账户 | `agvops`，本地管理员，随机密码存控制端 DPAPI |
| 公钥 | `C:\ProgramData\ssh\administrators_authorized_keys`，ACL = `SYSTEM` + `BUILTIN\Administrators` |
| 认证方式 | **仅公钥** |
| 默认 shell | `pwsh` 7.6.5 |
| 会话编码 | `$PROFILE` 强制 UTF-8，中文不乱码 |
| 加固备份 | `C:\ProgramData\ssh\sshd_config.backup-20260901-201040` |
| 控制端别名 | `factory01`（`~/.ssh/config`，副本在 `config/ssh_config.factory`） |
| 旧 WinRM 通道 | 账户、防火墙规则、注册表策略、用户配置文件目录**全部已清除** |

离线包与车载上位机用的是同一个文件，SHA256
`23F50F3458C4C5D0B12217C6A5DDFDE0137210A30FA870E98B29827F7B43ABA5`，推送后在服务器
上复算一致。版本与来源见 `../onboard-hmi/docs/ASSETS.md`。

> Server 2016 **没有** `OpenSSH.Server` 这个 Windows Capability（那是 1809 /
> Server 2019 之后才有的），所以只能走离线 zip 这条路。服务器虽然能上网，
> `Add-WindowsCapability` 也一样装不了。

服务器 host key 指纹：

```
ED25519  SHA256:MdSrvKUDqaD0Py5rJ3tHlmP79JJl3yx/JChvrBGPo0w
RSA      SHA256:e4vkqECN8MORcEY4PynlzPfU7DDYhoc2730IleadJjY
ECDSA    SHA256:jJwAGsmXTGAXJdPsjrocFRbHw3eztrIrr3ZPBwpngQk
```

#### 阶段 1 途中踩到并已解决的坑

1. **Clash TUN 劫持**（第 2 节）。这是最花时间的一个，因为它让所有排错手段先失效。

2. **`New-NetRoute -PolicyStore PersistentStore` 在控制端不可用**，改用
   `route.exe -p add`。

3. **`$u.SID.Value` 在服务器上取不到值**。pwsh 7 通过 Windows PowerShell 兼容会话
   调用 `Microsoft.PowerShell.LocalAccounts`，SID 是反序列化对象，没有 `.Value`
   属性。改用 `"$($u.SID)"`。

4. **staging 目录被提前清掉**导致改动后快照丢失，重采了一次。`C:\temp\agv-ops`
   是一次性目录，用完即删，需要留档的东西先 `scp` 回 `evidence/`。

5. **删被删账户的用户配置文件目录，`Remove-Item` 会失败。** 账户一删它的 SID 就
   不再解析，留在受保护子目录上的 ACL 连管理员都拒——具体卡在
   `AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup`——递归删除删到
   一半失败，留下半截残骸，`ProfileList` 注册表项也还在。正确做法是删
   `Win32_UserProfile` 实例，让 Windows 自己接管所有权、卸载 hive、删目录、清
   注册表项：

   ```powershell
   Get-CimInstance Win32_UserProfile |
     Where-Object { $_.LocalPath -eq 'C:\Users\<账户>' -and -not $_.Special } |
     Remove-CimInstance
   ```

   已写进 `scripts/02-remove-winrm-channel.ps1` 的 `-RemoveProfiles` 分支。

### 阶段 2：Hyper-V（2026-09-01 完成）

停机窗口 23:31:16 → 23:37:58，约 6 分半，**两次重启**（装角色一次，hypervisor 初始化
再一次）。用户当场授权。事前抓了一份服务基线，重启后逐条比对。

| 项 | 最终状态 |
| --- | --- |
| 角色 | `Hyper-V` + `Hyper-V-PowerShell` + `RSAT-Hyper-V-Tools`，`HypervisorPresent = True` |
| 数据根 | `D:\zhengyushao\Hyper-V\{VirtualMachines,VirtualHardDisks}`（用户要求新目录都收在 `D:\zhengyushao` 下） |
| 虚拟交换机 | `AGV-Internal`（Internal）+ 宿主 `192.168.200.1/24` + NAT `AGV-NAT` |
| Defender 排除项 | 路径 `D:\zhengyushao\Hyper-V`；扩展名 `.vhdx`/`.avhdx`/`.vhd`；进程 `vmms.exe`/`vmwp.exe`/`vmcompute.exe` |
| 火绒排除项 | 已加（2026-09-02 由用户在界面完成）。火绒 6.0.0.4，无命令行接口，只能人工加 |
| 首台虚拟机 | `win11-01`：Gen 2 / 版本 8.0 / 4 vCPU / 4 GB 静态 / 动态 VHDX 上限 80 GB / Secure Boot On + `MicrosoftWindows` / **vTPM True** / 引导 DVD→硬盘 |
| 安装介质 | `D:\zhengyushao\installer\Windows.iso`，实测 Windows 11 24H2，build `10.0.26100.1`，UEFI 引导文件齐全 |
| 客户机 | `DESKTOP-F9HC40O`，Windows 11 专业版 `26200.9168`（装后已联网更新），已激活，pwsh 7.6.5，`agvops` 本地管理员 |
| 客户机通道 | `ssh vm01` → `agvops@192.168.200.50`，经 `factory01` 跳板，**仅公钥**，第三把密钥 `agv_vm_ed25519` |

重启后核验：第 1 节服务表上的东西全部回到基线状态，11 个监听端口与重启前完全相同，
`em4` 的 `172.19.205.222` 未变，`C:`/`D:` 的分配单元仍是 4096——**全程没有格式化任何卷**。

两个事前不确定、现在有实测结论的点：

- **vTPM 在 Windows Server 2016 上可用。** `Set-VMKeyProtector -NewLocalKeyProtector`
  接 `Enable-VMTPM` 跑通，`TpmEnabled = True`。装 Win11 24H2 不需要 LabConfig 那套
  绕过 TPM/Secure Boot 检查的手段。
- **重启比预期快。** 单次从下重启指令到 SSH 恢复约 2 分 45 秒，两次共约 6 分半。
  66 GB 的 `AGV_log.ldf` 没有拖慢数据库恢复（`Recovery is complete` 在开机后约 2 分钟）。

装系统本身没做——那是交互操作，由用户在 VMConnect 里完成。

#### 阶段 2 途中踩到并已解决的坑

6. **pwsh 7 里 Hyper-V 模块返回的是 `Deserialized.*` 对象**，`Set-VMFirmware` 的
   `-BootOrder` / `-FirstBootDevice` 这类接受 `VMComponentObject` 的参数一律绑不上。
   这和坑 3 是同一个根因：pwsh 通过 Windows PowerShell 兼容会话代理这些模块。
   解法是 **`Import-Module Hyper-V -SkipEditionCheck`**，让 pwsh 原生加载模块，对象
   类型立刻变回 `Microsoft.HyperV.PowerShell.*`。**不需要退回 `powershell.exe`**，
   PS7 基线不用为此破例。两个新脚本开头都有这一行。

7. **`MSSQLSERVER` 是"自动-延迟启动"**，重启后约两分钟才上线。`Get-Service` 的
   `StartType` 只显示 `Automatic`，**不显示延迟标志**，拿它跟基线比对会误判成
   "服务没起来"。要看真相得查 `Win32_Service` 的 `DelayedAutoStart`。本次因此虚惊
   一场，还差点多余地手工拉起服务。

8. **Hyper-V 缩略图 API 返回的字节数比 `Width*Height*2` 多 4 个字节。** 按
   `ImageData.Length` 整体 `Marshal.Copy` 会写爆 `LockBits` 的缓冲区，触发 CLR 致命
   错误 `0x80131506`，**直接崩掉整个 pwsh 进程**——不是可以 try/catch 的异常。必须按
   精确长度拷贝，见 `scripts/vm-screenshot.ps1` 里的注释。

9. **全新 Windows 11 客户机会把 Internal + NAT 这个网络判成「公用」，把自己封死。**
   NLA 判定网关可达性时，这种网络缺少所需特征，于是归入公用配置文件——默认挡掉 ICMP
   和几乎所有入站。症状极具误导性：**宿主既 ping 不通也连不上 22，而客户机自己上网、
   Windows Update、装软件全都正常**，看起来像是 sshd 或跳板的问题。真因是客户机防火墙。
   解法是把网卡归到专用并显式加 22 的入站规则（作用域限定宿主网段即可），已并入
   `scripts/05-bootstrap-guest-sshd.ps1` 第 5 步。

10. **`Write-Host` 的输出无法被 `>` 重定向捕获**，它走的是 information 流。本次让用户
    在客户机里把脚本输出重定向到文件，结果拿到一个 0 字节的空文件，白跑一趟。要留档就用
    `Write-Output`（走标准输出）、`| Tee-Object`，或 `6>&1` 把 information 流并进去。

---

## 5. 未做的事

| 事项 | 状态 |
| --- | --- |
| ~~在 `win11-01` 里装 Windows 11~~ | **已完成**（2026-09-01，用户在 VMConnect 里装的），`ssh vm01` 可用 |
| 装第二个 SQL 命名实例到 `D:` | 未做。用户已选定方案 B（独立实例而非共用现有实例），尚未执行 |
| 重建黄金渲染机 / `plaintext_onboard_07` | 未做，用户 2026-09-01 明确暂缓，见决策七 |
| MES ingest / WIRE_TO_GATE 部署到这台机器 | 未做，当前仍在控制端本机测试 |
| 打开 Private profile 防火墙并收紧入站 | 未做，见决策五 |
| 在 `em1` 上建 External 交换机接企业网 | 未做，等有人去机房插线，见决策六 |
| 从服务器出发连车载上位机与雷达服务器的通道 | 只验证了 TCP 可达，未建立 |

**有意不做、且不要自作主张去做的：**

- **`SQAGV` 一律不碰。** 用户 2026-09-01 明确"不是我的生产数据库，不用你关心"。
  它是 FULL 恢复模式、`log_reuse_wait_desc = LOG_BACKUP`、最后一次备份 2025-12-22、
  日志 `AGV_log.ldf` 已涨到 66 GB（数据文件才 0.51 GB）。**知道这个状况，但不要去
  备份、改恢复模式、收缩日志或建作业。**
- **`max server memory` 已于 2026-09-15 设为 8192 MB（8 GB）。** 早先这里写"默认不改"，
  理由是开机三小时 `sqlservr` 仍只占 1.23 GB、实例数据才约 1.7 GB、缓冲池没东西可缓存。
  那个前提在 MES ingest 部署到本机后失效了：MesIngest 库涨到约 4.8 GB，未设上限的 SQL
  把空闲 RAM 全用作数据页与执行计划缓存，提交内存涨到 12.4 GB，主机可用内存一度只剩
  3.7 GB。经用户授权设 8 GB 上限后当场降到 8.0 GB（不重启），主机可用回到 6.7 GB；那约
  2.5 GB 计划缓存是可丢弃缓存、封顶即被回收，不是泄漏。8 GB 装得下当前实例数据（共约
  6.4 GB），只是缓存余量小些，纯性能取舍，可随时调整。改动方式：以 `sa` 连库执行
  `sp_configure 'max server memory (MB)', 8192; RECONFIGURE`。这是承载 `SQAGV` 的共享实例
  的设置，再动之前掂量对 `SQAGV` 的影响。将来塞多台虚拟机时重新评估这个值。
- **`agvops` 已于 2026-09-15 提为该实例的 sysadmin**（此前只有 `dbcreator` + `ALTER ANY
  LOGIN`）。提权用的是用户提供的 `sa` 密码执行 `ALTER SERVER ROLE sysadmin ADD MEMBER`，
  `sa` 本身未改。此后从 factory01 用 `sqlcmd -S . -E` 即可读全部 server-state DMV（内存、
  等待、计划缓存），不必再绕 WMI 性能计数器。
- **停 PolyBase 默认不改。** `SQLPBDMS` / `SQLPBENGINE`（`mpdwsvc`，约 1.7 GB 私有内存）
  仍在跑，除非确有需要否则不动它——它也是共享实例的一部分。

---

## 6. 安全边界

- **仅公钥认证是硬要求**，不是偏好。22 端口对整个企业内网开放（决策五）。
- 私钥只存控制端 `~/.ssh/`，不进任何 git 仓库，不拷到服务器。
- `agvops` 的应急密码只在控制端 DPAPI 里，不打印、不进仓库、不进聊天。
- **这台机器上有两套杀软同时运行**（火绒 + Windows Defender），以及 `SMB1` 功能
  处于安装状态。两者都是既有状况，本次未动，但部署前值得单独评估。
- 服务器现在能上网了。前一版文档把"不能上网"当作跳过安全更新的理由，那个理由
  已经不存在——用户正在逐步补更新，build 从 `14393.1884` 推到了 `14393.9418`。

### SQL Server 边界（沿用前一版，仍然有效）

- 部署后优先 Windows 身份验证。Windows 本地管理员**不**自动等同于 SQL Server 的
  `sysadmin`，部署身份与应用运行身份分开建最小权限。
- 不用 `sa` 作为运维日常凭据。
- SQL Server 的 TCP 端口不因运维需要对外开放；程序与数据库同机时优先本机连接。
- 查询输出脱敏。

### 不可远程执行的操作

根据 [ADR-mes-0028](https://github.com/trytoreachpeak0/8005---AGV/blob/main/docs/adr/mes/0028-high-risk-state-recovery-is-local-administration.md)
（本地在 `8005---AGV/docs/adr/mes/` 下），`HistoryResetAcknowledgement` 和
`StoragePressurePause` 的恢复**不得通过远程通道执行**。这两类操作只允许授权管理员
在数据库主机的本地控制台运行 MesIngestLocalAdministration CLI/PowerShell 命令，
并保留完整审计。

**这条边界不因通道从 WinRM 换成 SSH 而改变。** `agvops` 同样不能绕过它。

---

## 目录结构

```
remote-ops/factory-server/
├── README.md                       架构、决策理由、执行记录（本文件）
├── docs/
│   └── USAGE.md                    日常怎么用（接手先读这个）
├── config/
│   ├── ssh_config.factory          ~/.ssh/config 里 factory01 那段的副本
│   ├── ssh_config.vm               ~/.ssh/config 里 vm01 那段的副本（经 factory01 跳板）
│   └── agv_srv_ed25519.pub         运维公钥（私钥不在仓库里）
├── scripts/                            只放这台服务器特有的脚本
│   ├── 01-control-host-route.ps1       控制端：绕开 Clash TUN 的路由，带 -Remove
│   ├── 02-remove-winrm-channel.ps1     服务器：拆除旧 WinRM 通道（已执行）
│   ├── 03-configure-hyper-v-host.ps1   服务器：Hyper-V 宿主配置，幂等（已执行）
│   ├── 04-create-win11-vm.ps1          服务器：建 Win11 虚拟机（已执行，产出 win11-01）
│   ├── 05-bootstrap-guest-sshd.ps1     **客户机内**：开通 SSH 通道（已执行）
│   └── vm-screenshot.ps1               服务器：抓客户机屏幕存 PNG，远程排查装机用
└── evidence/                       ⛔ 不进 git
    └── probe-*.txt                 环境快照。重跑方式见 docs/USAGE.md 第 3 节
```

通用脚本不在这里，在 `../onboard-hmi/scripts/`（决策四）：`01-probe.ps1`、
`02-bootstrap-sshd.ps1`、`03-harden-sshd.ps1`、`agvops-profile.ps1`。
