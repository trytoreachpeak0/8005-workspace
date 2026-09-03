# AGV 上位机远程运维实验（remote-ops/onboard-hmi）

目标：把车载上位机（onboard HMI）从"只能人肉到现场操作"变成"可远程自动化部署、更新、巡检、操作"。
当前 3 台车，未来更多，方案必须按台数线性扩展。

本目录是实验记录，不属于任何已有 git 仓库，不受 `8005-agv-onboard-hmi` 只读约束影响
（本目录只产出运维脚本与记录，**不修改** HMI 仓库任何文件）。

---

## 从哪读起

| 你要做什么 | 读哪个 |
| --- | --- |
| **日常运维已接入的车** | [docs/USAGE.md](docs/USAGE.md) |
| **找某个文件、凭据、配置在哪** | [docs/ASSETS.md](docs/ASSETS.md) |
| 理解为什么这么设计 | 本文件第 2 节「架构决策」 |
| 知道 SSH 能做什么、不能做什么 | 本文件第 3 节（**GUI 限制，很重要**） |
| 接一台新车进来 | [docs/USAGE.md](docs/USAGE.md) 第 7 节 |
| 连不上了要排错 | [docs/USAGE.md](docs/USAGE.md) 第 4 节 |
| 换控制端机器 | `scripts/05-setup-control-host.ps1` |
| 把一台车恢复原状 | [docs/USAGE.md](docs/USAGE.md) 第 8 节 |

> **接手前提**：这条通道的私钥在控制端本机 `C:\Users\szy\.ssh\agv_ops_ed25519`，
> **不在本目录里**（故意的，见 ASSETS.md 第 2 节）。没有它连不上任何车。
> 换机器前先把它拷出来。

当前状态：**阶段 1 完成**，1 号车 `ssh agv01` 可用，仅公钥认证。
`agv02`/`agv03` 尚未分配 IP。

---

## 1. 已确认的事实

### 控制端（本机）

| 项 | 值 |
| --- | --- |
| 主机名 | `LAB-WIN-01` |
| OS | Windows 11 Pro 25H2 (10.0.26200) |
| 企业内网地址 | `172.19.162.241/24`，网关 `172.19.162.1`，Wi-Fi |
| PowerShell | 7.6.5 |
| OpenSSH 客户端 | 已装（OpenSSH 10.5p1） |
| OpenSSH 服务端 | 未装（推模式下不需要） |
| SSH 运维密钥 | 已生成 `~/.ssh/agv_ops_ed25519`（ed25519，无 passphrase） |

baseline 全文：`evidence/probe-LAB-WIN-01-20260901-172941.txt`

### 上位机 1 号（实验机，已探明）

| 项 | 值 |
| --- | --- |
| 主机名 | `DESKTOP-94OA6CK` |
| OS | Windows 10 专业版 22H2 (10.0.19045)，装机日期 2023-09-13 |
| 硬件 | O.E.M. 白牌，7.8 GB RAM，C 盘可用 97 GB |
| 登录账户 | `HT`，**本地管理员**，**空密码** |
| PowerShell 7 | 7.6.5 已装 |
| OpenSSH 服务端 | 未装 |
| LAN IP | `192.168.71.180/24`（**静态配置**，非 DHCP），网关 `192.168.71.1` |
| 第二网口 | 「以太网 6」`169.254.248.61`，无 DHCP —— 触控屏自带两个网口，此口未接 |
| 外网 | **不通**（`1.1.1.1:443` 失败，DNS 解析失败） |
| 到本机 | ping 通，445/3389/5985 可达，仅 2 跳 |
| 防火墙 | Domain 开启，Private/Public **关闭** |
| RDP | 关闭 |
| VNC | **RealVNC Server 运行中**，监听 5800/5900 |
| WinRM | 运行中，自动启动 |
| dotnet runtime | **未安装** |
| HMI 应用 | **尚未部署过** |
| 同机软件 | `C2000Service.exe` = IO 模块连接工具（监听 8000/9786，平时不开）；`PaceCatView` = 雷达连接工具（平时不开） |

全文：`evidence/probe-DESKTOP-94OA6CK-20270206-200310.txt`

### 网络路径（已实测）

```
本机 172.19.162.241 ──企业内网──> CPE2458 WAN 172.19.162.210
                                      │ NAT
                                      ↓ LAN 192.168.71.1
                                 上位机 192.168.71.180  (静态)
```

- CPE：北京节点通 **CPE2458**，WAN 侧 `172.19.162.210`，本机 ping 通（约 6-12 ms）。
- traceroute 全程仅 2 跳，中间没有额外网关。
- **CPE WAN 侧端口实测**：

  | 端口 | 状态 | 实际是什么 |
  | --- | --- | --- |
  | 22 | 开 | **CPE 自己的 dropbear SSH**（banner `SSH-2.0-dropbear`）—— 被占用 |
  | 80 | 开 | CPE 管理页面 |
  | 5900 | 开 | **已转发到上位机的 RealVNC**（banner `RFB 005.000`，RealVNC 特有版本号） |
  | 443 / 8080 / 8000 | 关 | — |

- 结论：**端口转发已被现网验证可用**（5900 那条就是）。

- **CPE 转发表已占用的公用端口**（2027-02 查看管理页）：
  `80, 443, 502, 2222, 5001, 5002, 5003, 5010, 5900, 8001, 8005, 8008, 8009`
  ——多为 IO 模块（Modbus 502）与雷达相关。加上 CPE 自用的 22。

- SSH 因此选 **外部 22022**（TCP）→ `192.168.71.180:22`。选它是因为不在上述占用列表内、
  避开了工业协议密集的低端口区、又低于 Windows 动态端口范围（49152+）不会被临时端口抢。

- ARP 表里另有 `172.19.162.248`（MAC `a0-62-60-73-0b-bb`，与 .210 的
  `a0-62-60-74-50-82` 同一 OUI），疑似另一台车的 CPE，但那两台车尚未分配 IP。

---

## 2. 架构决策

### 决策一：SSH，不用 WinRM

- 单端口，跨 NAT 端口转发只需一条规则；WinRM 是 5985/5986 且对代理不友好。
- 工作组环境下 WinRM 要配 `TrustedHosts` + 明文 HTTP 或自签证书，繁琐且降安全性。
- SSH 公钥认证天然免密，适合无人值守；密码不落地。
- `ssh` / `scp` 是标准命令，Claude 可直接驱动，无需额外封装。
- Windows 10 内置 OpenSSH Server，非第三方组件。

WinRM 保留为备用通道（两端都已运行），不作主路径。

### 决策二：默认 shell 设为 PowerShell 7

sshd 默认 shell 是 `cmd.exe`。设为 `pwsh.exe` 后远程命令可直接用 PowerShell
语法与对象管道，`-EncodedCommand` 也能规避引号转义问题。两端都已装 7.6.5。

### 决策三：只允许公钥认证

上位机的 SSH 经端口转发暴露在企业内网，必须禁用密码认证、仅信任运维公钥。
分两步执行（先装通道保留密码 → 验证公钥能登 → 再禁密码），顺序不可颠倒。

### 决策四：部署采用"版本目录 + 原子切换"

```
C:\AGV\releases\1.4.2\        <- 新版本推到这里
C:\AGV\releases\1.4.1\        <- 上一版，保留用于回滚
C:\AGV\current  ->  junction 指向 releases\1.4.2
```

原地覆盖的问题：推包时应用若在运行会锁文件，失败后现场处于半新半旧的不可知状态。

### 决策五：建专用运维账户 `agvops`，不用 HT

这是 probe 结果逼出来的决策。

`HT` 是**空密码**账户（`PasswordRequired: False`，且 `AutoAdminLogon: 0`、
注册表无 `DefaultPassword`）—— 开机直进桌面不是因为配了自动登录，
而是因为账户根本没密码，Windows 对唯一无密码账户会跳过登录界面。

空密码账户受 Windows `LimitBlankPasswordUse` 策略限制，**不允许网络登录**，
SSH 用 HT 大概率失败。两个坏解法都不采纳：

- 给 HT 设密码 → 破坏开机直进桌面，那是 AGV 依赖的生产行为。
- 关掉 `LimitBlankPasswordUse` → HT 空密码可被 SMB 登录（445 正开着），安全性明显下降。

因此新建 `agvops` 本地管理员账户，随机强密码，SSH 专用。HT 保持原样跑 HMI。
副作用是运维通道与生产账户天然隔离，权限审计更清晰。

### 决策六：HMI 用 self-contained 发布

上位机**没有 dotnet runtime，也没有外网**。装 runtime 等于再引入一次离线分发。
直接 `dotnet publish -r win-x64 --self-contained` 出自包含包，运行时随应用走，
版本锁定在制品里，升级 runtime 就是换一个 release 目录。代价是包体大几十 MB，
C 盘 97 GB 可用，不构成问题。

### 决策七：OpenSSH 必须离线安装

`Add-WindowsCapability` 需要 Windows Update 或本地 FoD 源，上位机外网不通，
这条路走不通。改用官方 `OpenSSH-Win64.zip` 离线包。

---

## 3. ⚠ 关键限制：SSH 进不去图形桌面

这一条直接决定"让 Claude 自动化操作这个系统"能做到什么程度。

Windows 会话隔离：sshd 作为服务跑在 **Session 0**，HT 的桌面在 **Session 1**。
SSH 会话里启动的 GUI 程序，窗口出现在 Session 0 的不可见桌面上，
**看不见、点不到、截不了屏**。

| 能力 | SSH 单独能否做到 |
| --- | --- |
| 跑命令、读写文件、查日志、查进程、改注册表 | ✅ |
| 装软件、推送新版本、重启服务 | ✅ |
| 重启机器、查性能、抓事件日志 | ✅ |
| 启停 HMI 应用进程 | ⚠ 能杀，但**起不到 HT 的桌面上** |
| 截取 HMI 界面、点击按钮、模拟操作 | ❌ |

补齐 GUI 层的两条路：

- **路线 A（看 + 人工操作）**：RealVNC **已经装好且已转发**，现成可用。
  人能看能点，但无法自动化驱动。
- **路线 B（自动化操作，最终形态）**：在 HT 会话里常驻一个小 agent
  （登录自启的计划任务），监听 localhost 端口；SSH 侧（agvops）连该端口下发
  "截图 / 点击 / 读控件"请求。HMI 是 WPF，用 UI Automation 直接读控件树、
  点按钮，比截图打坐标稳得多。agvops 与 HT 分属不同会话不影响此方案，
  两者通过 localhost 通信。

先做通 SSH 底座，GUI 层放阶段 5。

---

## 4. 分阶段计划

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 0 | 探明上位机现状 | ✅ 完成（本机 + 上位机 1 号） |
| 1 | 上位机装 sshd + agvops + 公钥；CPE 配 22022 转发；打通 SSH | ✅ **完成** 2027-02-06 |
| 2 | 本机侧封装：ssh config 别名、批量执行、文件推送 | 🟡 别名与编码已就绪，批量封装待做 |
| 3 | 自动化部署：self-contained 发布、版本目录、原子切换、回滚、健康检查 | 🔲 |
| 4 | 巡检与遥测：定期采集日志、磁盘、进程状态 | 🔲 |
| 5 | GUI 自动化 agent（UI Automation） | 🔲 |

---

## 5. 阶段 1 操作步骤

### 运维密钥

公钥（已内置进 `02-bootstrap-sshd.ps1` 的默认参数）：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDsJSPXBPihtqYQKyITbOMP4eI0zs3p1JFfU3GB7LwRB agv-ops@LAB-WIN-01
```

私钥在 `C:\Users\szy\.ssh\agv_ops_ed25519`，无 passphrase —— 无人值守自动化的
必要权衡，代价是拿到这台笔记本等于拿到所有上位机。缓解：此钥只用于 AGV 运维不复用；
后续若上跳板机，密钥应挪到跳板机并加 ACL。

### 离线包（已备好）

| 项 | 值 |
| --- | --- |
| 文件 | `payload/OpenSSH-Win64.zip` |
| 版本 | `10.0.0.0p2-Preview`（2025-10-27） |
| 大小 | 5,704,583 bytes |
| SHA256 | `23F50F3458C4C5D0B12217C6A5DDFDE0137210A30FA870E98B29827F7B43ABA5` |
| 来源 | https://github.com/PowerShell/Win32-OpenSSH/releases |

Win32-OpenSSH 所有 release 都带 `Preview`/`Beta` 后缀但 `prerelease=False`，
这是该项目惯例 —— 它从不发"正式版"标签，Windows 内置的 OpenSSH 即由这些构建而来。
`10.0.0.0p2` 就是当前最新稳定发布。

### 步骤

1. **本机启动分发服务**（管理员 PowerShell 7，会临时开 8080 入站，退出时自动撤销）：

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\04-serve-payload.ps1
   ```

   它会打印一行给上位机用的命令，内含 zip 的 SHA256。

   > **坑（已修）**：本机有一堆虚拟网卡 —— Hyper-V 交换机 `192.168.200.1` /
   > `172.22.80.1`、Clash 隧道 `198.18.0.1`、若干 169.254 链路本地地址 ——
   > 它们在 `Get-NetIPAddress` 的输出里排在企业内网地址前面，上位机一个都连不到。
   > 脚本初版"取第一个非环回地址"因此选中了 Hyper-V 的 `192.168.200.1`，
   > 上位机拉包直接超时。现改为用 `Find-NetRoute` 反查"到 CPE 实际会用哪个源地址"，
   > 并把所有本机地址列出来、标记选中项。启动后**核对一眼**箭头是否指向
   > `172.19.162.241`；不对就用 `-BindAddress 172.19.162.241` 显式指定。
   >
   > 附带一提：服务绑定的是 `http://+:8080/`（所有接口），所以即便打印的 URL
   > 选错了地址，换成正确 IP 也能直接用，不必重启服务。

2. **在上位机 VNC 里粘那一行**（管理员 PowerShell 7）。它会拉包、**校验 SHA256**、
   校验通过才执行 bootstrap。

   bootstrap 会创建 `agvops`、装 sshd、装公钥、开防火墙，并**打印一次 agvops 的
   随机密码（不落盘，务必抄下来）**。该密码仅用于 VNC/控制台应急，日常走公钥。

3. **在 CPE 管理页配端口转发**（`http://172.19.162.210`）：

   | 字段 | 值 |
   | --- | --- |
   | 公用端口 | `22022` |
   | 协议 | `TCP` |
   | 内部 IP | `192.168.71.180` |
   | 内部端口 | `22` |

   **不要用外部 22 口**（CPE 自己的 dropbear），也别用 2222（已被占用）。
   上位机已是静态 IP，不需 DHCP 保留。

4. **从本机验证**：

   ```bash
   ssh agv01
   ```

   `~/.ssh/config` 已配好 `agv01` 别名（`agvops@172.19.162.210:22022` + 运维密钥），
   等价于 `ssh -i C:\Users\szy\.ssh\agv_ops_ed25519 -p 22022 agvops@172.19.162.210`。

5. **登进去了再加固**：

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\03-harden-sshd.ps1
   ```

第 5 步跑在第 4 步之前会把 SSH 锁死 —— 虽然 VNC 还能进去救，但白跑一趟。

---

## 5.5 阶段 1 执行记录（2027-02-06 完成）

通道已打通并加固，`ssh agv01` 可用。

| 项 | 最终状态 |
| --- | --- |
| 上位机 SSH | `OpenSSH 10.0.0.0p2` 离线安装，服务 Automatic，监听 22 |
| 外部入口 | `172.19.162.210:22022`（TCP）→ `192.168.71.180:22` |
| 运维账户 | `agvops`，本地管理员，随机密码（仅 VNC/控制台应急用） |
| 公钥 | `administrators_authorized_keys`，ACL = `BUILTIN\Administrators` + `SYSTEM` |
| 认证方式 | **仅公钥**。`PasswordAuthentication no`、`KbdInteractiveAuthentication no`、`PermitEmptyPasswords no` |
| 默认 shell | `pwsh` 7.6.5 |
| 加固备份 | `C:\ProgramData\ssh\sshd_config.backup-20270206-210047` |

验证结果：全新连接 `BatchMode=yes` 纯公钥登录成功；强制密码认证被拒
（`Permission denied (publickey)`）。

### 途中踩到并已解决的坑

1. **`New-LocalUser -Description` 上限 48 字符**，原描述 56 字符导致建账户失败。
   已缩短，脚本里加了注释说明。

2. **分发服务选错本机地址**（详见步骤 1 的说明框）。改用 `Find-NetRoute` 反查。

3. **CPE 端口占用比预想多**。原定 2222 已被占用，实际可用端口需先查 CPE 转发表。
   最终选 22022。

4. **SSH 会话中文乱码**。sshd 会话的控制台代码页是 936(gb2312)，pwsh 按 UTF-8
   输出，导致所有非 ASCII 内容变乱码 —— 会影响读日志和报错。
   已装 `scripts/agvops-profile.ps1` 到 agvops 的 `$PROFILE`，每次 SSH 会话
   自动设 UTF-8，无需在每条命令里重复。

### 一个对后续运维重要的实测结论

**`Restart-Service sshd` 不会掐断已建立的 SSH 连接。** Windows OpenSSH 重启服务
只更换监听器，既有会话由独立子进程处理。因此"改配置 + 重启 sshd"这类操作可以
安全地远程完成，脚本能跑完整个流程（包括失败时的自动回滚），不必跑现场。

---

## 6. 待确认的事项

1. **HMI 制品从哪来** —— 由本机 `dotnet publish` 现出，还是有既定的构建产物来源？
   这决定阶段 3 的制品流水线形态。
2. **2 号车通道已就绪**（2026-09-03）。`ssh agv02` → `agvops@DESKTOP-94OA6CK`，
   CPE `172.19.162.179:22022`。第 7 节全流程已走完：sshd 已装、已加固（密码认证关闭，
   四项配置与 agv01 一致，实测强制走密码返回 `Permission denied (publickey)`）、
   已校时（原本 2027-02-08，快 158 天；现与 `172.19.205.222` 偏移 +0.0007s，
   w32time 自动启动）、UTF-8 profile 已装。

   **部署本身还没做。**`config/site-agv02.json` 里四个值仍是 `REPLACE_*`。

   **3 号车通道同样已就绪**（2026-09-03）。`ssh agv03` → `agvops@DESKTOP-94OA6CK`，
   CPE `172.19.162.70:22022`，转发到 `192.168.71.180:22`。加固、校时、UTF-8 profile
   三项都做完，与另两台车配置一致。部署本身同样还没做，`config/site-agv03.json` 里
   的值仍是 `REPLACE_*`。

3. **三台车都是同一个镜像克隆的，克隆后没个性化。** COMPUTERNAME 都是
   `DESKTOP-94OA6CK`，MachineGuid 都是 `6910ff68-24ae-4fcb-8e16-b6bbd5924490`，
   SMBIOS UUID 与 InstallDate 也相同，以太网 5 的 IP 都是 `192.168.71.180`（各在自己
   CPE 的 NAT 后面，不冲突）。**SSH 别名是从控制端区分三台车的唯一依据**，不要从机器
   本身推导身份。物理上确实是三台，各自不同的 MAC 与 SSH host key：

   | 别名 | MAC | ED25519 host key |
   | --- | --- | --- |
   | `agv01` | `68-ED-A4-9B-B5-5A` | `SHA256:kZR9F72fdrzs7kIvqEcWMAi8w9aRlosCS7orWCGWRCI` |
   | `agv02` | `68-ED-A4-9B-B5-CE` | `SHA256:7irq9yWgCqEkMIKZF7v5wvGasUFx+Dmd3g1vnIflduY` |
   | `agv03` | `68-ED-A4-9B-B5-D2` | `SHA256:/q4BBoyU4/DqU8DP9jhmn1kuuOd2hfKoHJu6vhHddNQ` |

4. **agv02 的以太网 6 配了 `192.168.71.221`，与以太网 5 的 `192.168.71.180` 同网段。**
   该口当前 `Disconnected`（触控屏自带的第二个网口，未接线），所以暂时无害；一旦接上
   线就是双网卡同网段、出向路由不确定。agv01 上这个口是 `169.254.x`，没被配过——所以
   是 agv02 单独被人改的。未处理，接线前要先决定拆掉哪一个。

已解答（2027-02）：

- `C2000Service.exe` = 连接 IO 模块的软件，平时不打开 → 与 HMI 部署无冲突，
  但它占着 8000/9786，HMI 若要监听端口需避开。
- `PaceCatView` = 连接雷达的软件，平时不打开。
- 「以太网 6」= 触控屏自带的第二个网口，未接线，非底盘/PLC 通道。

---

## 7. 安全边界

- `HT` 空密码是既有状况。probe **不读取**任何密码值。本方案不改动 HT，
  但需要记录：任何能碰到该机器控制台或 VNC 的人都能直接进桌面。
- 开放 SSH 端口后必须禁用密码认证（步骤 5），否则等于给企业内网一个爆破入口。
- `agvops` 密码由脚本随机生成、只显示一次、不落盘。
- 私钥只存本机 `~/.ssh/`，不进任何 git 仓库，不拷到上位机。
- 凡会改动上位机状态的脚本，头部必须写明改了什么、如何撤销。

---

## 目录结构

```
remote-ops/onboard-hmi/
├── README.md                     架构、决策理由、分阶段进展
├── docs/
│   ├── USAGE.md                  日常怎么用（接手先读这个）
│   └── ASSETS.md                 什么东西落在哪，含仓库外的资产
├── config/
│   ├── ssh_config.agv            agv 族的 ssh 片段，也是别名注册表
│   ├── site.example.json         现场值模板
│   ├── site-agv01.json           1 号车现场值
│   ├── site-agv02.json           2 号车，通道就绪，未部署
│   ├── site-agv03.json           3 号车，等装 sshd
│   └── agv_ops_ed25519.pub       运维公钥（私钥不在仓库里）
├── scripts/
│   ├── 01-probe.ps1              只读环境探测，随时可跑
│   ├── 02-bootstrap-sshd.ps1     装 sshd + 建 agvops + 装公钥（上位机跑）
│   ├── 03-harden-sshd.ps1        关密码认证，验证通了再跑（上位机跑）
│   ├── 04-serve-payload.ps1      临时 HTTP 分发（本机跑，非上位机）
│   ├── 05-setup-control-host.ps1 控制端重建与自检（本机跑）
│   └── agvops-profile.ps1        远程 $PROFILE，修 UTF-8 乱码
├── payload/                      ⛔ 不进 git
│   └── OpenSSH-Win64.zip         OpenSSH 10.0.0.0p2 离线包
└── evidence/                     ⛔ 不进 git
    └── probe-*.txt               probe 原始输出（控制端 + 1 号车基线）
```

标 ⛔ 的只存在于控制端本地，克隆出来是空的 —— 原因与重建方式见
[docs/ASSETS.md](docs/ASSETS.md) 第 1 节。

