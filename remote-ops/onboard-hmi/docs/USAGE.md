# 日常使用手册

通道已打通（阶段 1 完成，2027-02-06）。本文是"怎么用"，架构和决策理由见
[../README.md](../README.md)。

---

## 0. 接手前必读

**这条通道的私钥不在本仓库里。** 它在控制端本机的
`C:\Users\szy\.ssh\agv_ops_ed25519`，无 passphrase。没有这个文件就连不上任何上位机 ——
换机器、重装系统、清空用户目录后都得重新走一遍配公钥的流程（见第 7 节）。

其余边界：

- **本目录可写**，随便加脚本和记录。
- `8005-agv-onboard-hmi` 和 `slots-simulator` 是**只读**仓库，不许改（见根 `CLAUDE.md`）。
  本目录只从它们读，不往里写。
- 上位机是**生产设备**（会动的 AGV）。实验那台目前停机，但别默认其它台也停着。
  改动前先确认车的状态。

---

## 1. 三十秒自检

```bash
ssh agv01 "'{0}@{1}  pwsh {2}  磁盘剩余 {3} GB' -f \$env:USERNAME, \$env:COMPUTERNAME, \$PSVersionTable.PSVersion, [math]::Round((Get-PSDrive C).Free/1GB,1)"
```

正常输出：

```
agvops@DESKTOP-94OA6CK  pwsh 7.6.5  磁盘剩余 97 GB
```

中文不乱码说明 `$PROFILE` 里的 UTF-8 设置生效了。乱码了就重装 profile（第 6 节）。

---

## 2. 连接信息

| 项 | 值 |
| --- | --- |
| 别名 | `agv01` |
| 入口 | `172.19.162.210:22022`（CPE WAN，TCP） |
| 转发到 | `192.168.71.180:22`（上位机 LAN） |
| 账户 | `agvops`（本地管理员） |
| 认证 | **仅公钥**，密码认证已关闭 |
| 私钥 | `C:\Users\szy\.ssh\agv_ops_ed25519` |
| 远程 shell | `pwsh` 7.6.5 |

上位机 host key 指纹（首次连接或怀疑被顶包时核对）：

```
ED25519  SHA256:kZR9F72fdrzs7kIvqEcWMAi8w9aRlosCS7orWCGWRCI
RSA      SHA256:g5FqDG1/jBfePQ/260Xeol07xYukYyi2uWqu+hGRcPM
ECDSA    SHA256:MRYv2tJr8cUNMnhtJeuE8he366X54h46zHS/kdcMw6U
```

`ssh_config` 用的是 `StrictHostKeyChecking accept-new`：首次连接自动记录，
之后如果指纹变了会**拒绝连接**并报警。真换了机器要先删 `known_hosts` 里的旧条目：

```bash
ssh-keygen -R "[172.19.162.210]:22022"
```

---

## 3. 常用操作

### 跑命令

```bash
ssh agv01 "Get-Process | Sort-Object WS -Descending | Select-Object -First 5 ProcessName,@{n='MB';e={[math]::Round(\$_.WS/1MB,1)}}"
```

Bash 里写 PowerShell 要把 `$` 转义成 `\$`，否则会被 Bash 先吃掉。复杂脚本别硬塞进
一行 —— 写成 `.ps1` 传过去跑（见下）。

### 传文件

```bash
# 推
scp 本地文件.ps1 agv01:C:/temp/agv/

# 拉
scp agv01:C:/temp/agv/日志.txt ./evidence/

# 推整个目录
scp -r 本地目录 agv01:C:/temp/agv/
```

远程路径用**正斜杠**（`C:/temp/agv/`），反斜杠会被 scp 当转义符。

### 传了就跑（脚本化操作的标准姿势）

```bash
scp 我的脚本.ps1 agv01:C:/temp/agv/ && \
ssh agv01 "pwsh -ExecutionPolicy Bypass -File C:\temp\agv\我的脚本.ps1"
```

推完最好校验一下哈希，尤其是二进制包：

```bash
ssh agv01 "(Get-FileHash C:\temp\agv\包.zip -Algorithm SHA256).Hash"
sha256sum 包.zip | cut -d' ' -f1 | tr 'a-f' 'A-F'
```

### 常见巡检

```bash
# 磁盘
ssh agv01 "Get-PSDrive -PSProvider FileSystem | Select-Object Name,@{n='FreeGB';e={[math]::Round(\$_.Free/1GB,1)}}"

# 服务状态
ssh agv01 "Get-Service sshd,vncserver | Select-Object Name,Status,StartType"

# 最近的系统错误
ssh agv01 "Get-WinEvent -FilterHashtable @{LogName='System';Level=1,2} -MaxEvents 10 | Select-Object TimeCreated,Id,Message"

# SSH 自身的日志（排查登录失败很有用）
ssh agv01 "Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 20 | Select-Object TimeCreated,Message"

# 开机时长
ssh agv01 "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime"
```

### 完整环境快照

`scripts/01-probe.ps1` 是只读的，随时可跑，用来对比现状与基线：

```bash
scp scripts/01-probe.ps1 agv01:C:/temp/agv/ && \
ssh agv01 "pwsh -ExecutionPolicy Bypass -File C:\temp\agv\01-probe.ps1" > /dev/null && \
ssh agv01 "(Get-ChildItem C:\temp\agv\probe-*.txt | Sort-Object LastWriteTime | Select-Object -Last 1).FullName"
# 然后 scp 拉回 evidence/
```

### 重启服务 / 重启机器

```bash
# 重启 sshd 不会掐断当前连接（已实测），改完配置可以直接重启
ssh agv01 "Restart-Service sshd; (Get-Service sshd).Status"

# 重启机器（会断连，等一两分钟再连）
ssh agv01 "Restart-Computer -Force"
```

---

## 4. 连不上怎么办

按这个顺序切，能快速定位是哪一层坏的。

### 第 1 层：CPE 通不通

```bash
ping 172.19.162.210
```

不通 → CPE 掉线或本机不在企业内网。检查本机 Wi-Fi 是否连着 `172.19.162.x` 网段。

### 第 2 层：端口转发在不在

```bash
ssh -v agv01 2>&1 | head -5
```

看得到 `Connection established` 说明 TCP 通了。连接超时 → CPE 上 22022 那条转发规则
没了或被改了，登 `http://172.19.162.210` 检查。

注意 CPE 的 22 是它自己的 dropbear，能连上 22 不代表转发正常。

### 第 3 层：上位机 sshd 活着吗

TCP 通但 SSH 握手失败 → 上位机的 sshd 挂了。这时候走 **VNC 应急通道**（第 5 节），
进去执行：

```powershell
Get-Service sshd
Start-Service sshd
Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 20
```

### 第 4 层：认证失败

报 `Permission denied (publickey)` 说明网络和 sshd 都正常，纯粹是公钥问题。
最常见的两个原因：

1. **私钥不在或不对** —— 确认 `C:\Users\szy\.ssh\agv_ops_ed25519` 存在，
   且它的公钥与上位机上的一致：

   ```bash
   ssh-keygen -y -f C:/Users/szy/.ssh/agv_ops_ed25519
   # 和 config/agv_ops_ed25519.pub 比对
   ```

2. **authorized_keys 的 ACL 不对** —— 这是 Windows OpenSSH 最经典的坑。
   sshd 会**静默拒绝**任何 SYSTEM 和 Administrators 之外还有写权限的 authorized-keys 文件。
   VNC 进去修：

   ```powershell
   icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F'
   Restart-Service sshd
   ```

   正确的 ACL 应该只有两条：`BUILTIN\Administrators:(F)` 和 `NT AUTHORITY\SYSTEM:(F)`。

---

## 5. 应急通道：VNC

SSH 彻底不通时的后路。RealVNC Server 在上位机上常驻运行，**与 sshd 完全无关**，
sshd 挂了不影响它。

```
地址：172.19.162.210:5900
```

进去后可以用 `agvops` 的密码登录（那个密码就是为这种时刻准备的），或者直接用
已经自动登录的 `HT` 桌面。

物理控制台（车上的触控屏）是最后一道后路。

---

## 6. 维护动作

### 重装 UTF-8 profile（中文乱码时）

```bash
scp scripts/agvops-profile.ps1 agv01:C:/temp/agv/ && \
ssh agv01 "New-Item -ItemType Directory -Path (Split-Path \$PROFILE) -Force | Out-Null; Copy-Item C:\temp\agv\agvops-profile.ps1 \$PROFILE -Force; '已安装'"
```

### 恢复 sshd 配置（加固出问题时）

```bash
ssh agv01 "Get-ChildItem C:\ProgramData\ssh\sshd_config.backup-* | Select-Object Name,LastWriteTime"
ssh agv01 "Copy-Item 'C:\ProgramData\ssh\sshd_config.backup-20270206-210047' 'C:\ProgramData\ssh\sshd_config' -Force; Restart-Service sshd"
```

### 临时开回密码认证（排错用，用完记得关）

```bash
ssh agv01 "(Get-Content C:\ProgramData\ssh\sshd_config) -replace '^PasswordAuthentication no','PasswordAuthentication yes' | Set-Content C:\ProgramData\ssh\sshd_config; Restart-Service sshd"
```

---

## 7. 新增一台车

前提：那台车的 CPE 有企业内网 IP，上位机装了 PowerShell 7。

1. **查 CPE 已占用的转发端口**，挑一个没被用的（1 号车用的 22022，
   建议 2 号车用 22023 依此类推，好记）。

2. **本机启动分发服务**：

   ```bash
   pwsh -ExecutionPolicy Bypass -File scripts/04-serve-payload.ps1 -TargetHost <新CPE的IP>
   ```

   `-TargetHost` 让它算出到那台车该用哪个源地址。核对打印出的箭头指向企业内网地址。

3. **上位机 VNC 里粘它打印的那行命令**，会拉包、校验、跑 bootstrap。
   记下打印的 agvops 密码。

4. **CPE 配转发**：`外部端口/TCP → <上位机LAN IP>:22`

5. **本机 `~/.ssh/config` 加一段**（同时更新 `config/ssh_config.agv` 副本）：

   ```
   Host agv02
       HostName <新CPE的IP>
       Port 22023
   ```

6. **验证** `ssh agv02`，通了再推 03 加固：

   ```bash
   scp scripts/03-harden-sshd.ps1 agv02:C:/temp/agv/ && \
   ssh agv02 "pwsh -ExecutionPolicy Bypass -File C:\temp\agv\03-harden-sshd.ps1 -Force"
   ```

7. **装 UTF-8 profile**（第 6 节）。

顺序不能颠倒：没验证通就加固会把 SSH 锁死（VNC 能救，但白跑一趟）。

---

## 8. 部署车载端

车载端的 CD 不是独立的：**ControlServer 和 OnboardHmi 打在同一个包里**，因为两端在明文期
没有协商也没有降级，版本错配的表现是连接被拒而不是一条说明原因的错误。出包在 ControlServer
仓库的 `release.yml`，本目录只管最后一跳。

完整流程、为什么是这个形状、以及一次性准备（PAT、秘密、站点文件），见
[`../../factory-server/docs/wire-to-gate-cd.md`](../../factory-server/docs/wire-to-gate-cd.md)。

这里只记与车相关的三件事：

**先填站点文件。**一台车一个，`../config/site-<别名>.json`，从 `site-agv01.example.json` 复制。
`wireToGate.onboardInstanceId` **必须跨部署稳定**——服务端把新值当成另一个车载实例。文件缺失或
还留着 `REPLACE_*`，脚本直接拒绝，不猜。

**部署命令，先干跑。**

```bash
pwsh -File remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -WhatIf
```

干跑会把渲染好的配置整份打出来，并且已经做完全部校验：包哈希、占位符残留、TLS 期残留键
（`useTls` / `serverCertificateSha256`——**判据是键在不在，不是值是什么**）、`vehicleSafety`
必须是 http scheme 且 enabled、`onboardBuildCommit` 必须等于包里那个 commit。去掉 `-WhatIf`
才真的动车。

**脚本搬完就停，不启动。**上位机是会动的生产设备，`SQCD.Agv.Wpf` 是交互式 WPF 程序不是服务，
就绪判定要人看着车辆安全投影的返回。客户端正在跑时脚本会拒绝（除非 `-Force`），因为那意味着
车可能在作业途中。启动要到车前，用它自己的桌面会话：

```
C:\8005\OnboardHmi\SQCD.Agv.Wpf.exe
```

上一代留在 `C:\8005\OnboardHmi.previous`，要退回去人工换。

---

## 9. 完全撤销

把一台上位机恢复到没装过这套东西的状态：

```bash
ssh agv01 "
Stop-Service sshd
Set-Service sshd -StartupType Disabled
Remove-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-22' -ErrorAction SilentlyContinue
Remove-Item C:\ProgramData\ssh\administrators_authorized_keys -ErrorAction SilentlyContinue
Remove-LocalUser -Name agvops -ErrorAction SilentlyContinue
Remove-Item C:\temp\agv -Recurse -Force -ErrorAction SilentlyContinue
"
```

跑完 SSH 就断了（本来就是目的）。之后还要手动做：

- 卸载 OpenSSH：`C:\Program Files\OpenSSH\uninstall-sshd.ps1`（需 VNC 进去跑）
- CPE 上删掉那条端口转发规则
- 本机 `ssh-keygen -R "[172.19.162.210]:22022"` 清掉 known_hosts 条目

`HT` 账户、RealVNC、C2000Service、PaceCatView 全程没动过，不需要恢复。
