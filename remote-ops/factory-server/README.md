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
| SQL Server | 默认实例 `MSSQLSERVER`（`MSSQL16.MSSQLSERVER` = SQL Server 2022），自动启动 |
| Hyper-V | 角色 `Available` 未安装；固件虚拟化与 SLAT 均支持 |
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

## 4. 阶段 1 执行记录（2026-09-01 完成）

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

### 途中踩到并已解决的坑

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

---

## 5. 未做的事

| 事项 | 状态 |
| --- | --- |
| Hyper-V 角色安装、虚拟机从控制端迁过来 | 未做，用户明确本轮不碰 |
| SQL Server 从控制端迁移过来 | 未做，同上 |
| MES ingest / WIRE_TO_GATE 部署到这台机器 | 未做，当前仍在控制端本机测试 |
| 打开 Private profile 防火墙并收紧入站 | 未做，见决策五 |
| 从服务器出发连车载上位机与雷达服务器的通道 | 只验证了 TCP 可达，未建立 |

装 Hyper-V 需要重启，且会把宿主变成根分区，第 1 节那张服务表上的东西全部受影响。
这件事必须先和用户约停机窗口。

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
│   └── agv_srv_ed25519.pub         运维公钥（私钥不在仓库里）
├── scripts/                        只放这台服务器特有的脚本
│   ├── 01-control-host-route.ps1   控制端：绕开 Clash TUN 的路由，带 -Remove
│   └── 02-remove-winrm-channel.ps1 服务器：拆除旧 WinRM 通道（已执行）
└── evidence/                       ⛔ 不进 git
    └── probe-*.txt                 环境快照。重跑方式见 docs/USAGE.md 第 3 节
```

通用脚本不在这里，在 `../onboard-hmi/scripts/`（决策四）：`01-probe.ps1`、
`02-bootstrap-sshd.ps1`、`03-harden-sshd.ps1`、`agvops-profile.ps1`。
