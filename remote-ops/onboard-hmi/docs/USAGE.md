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

### 读车载端应用日志（中文）

车载端日志在 `C:\Users\HT\AppData\Local\SQCD\8005AGV\logs\agv-yyyyMMdd.log`，由 `FileAppLogger`
写成**无 BOM 的 UTF-8**，每行 `时间戳<Tab>等级<Tab>类别<Tab>来源<Tab>消息`，类别是 REQ-0272 的七个面之一。

这个位置是 `%LOCALAPPDATA%\SQCD\8005AGV\logs`（与日志簿同处），**只在车载端以 `HT` 账号运行时**
才落在上面那条路径；换了运行账号，路径跟着那个账号的 `%LOCALAPPDATA%` 变。车载端自己清理超过 30 天的
`agv-yyyyMMdd.log`，同目录别的文件不碰。为了在
[`../../fleet.md`](../../fleet.md) 硬约束 2 那种 RTC 断电后的时钟前跳下不误删，它有两道闸：

- 清理时认定的「现在」不超过「开机时目录里最新一份日志那天的零点＋本次运行时长」（运行时长取单调时钟，不受墙钟
  跳变影响），所以重启后头一两天会比 30 天多留一点。
- 从要删的最新一份到今天，相邻两份日志相隔超过 7 天就一份不删，只在当天日志里记一行 `LocalFault` 警告。按周断续
  使用的备用车照常清理；停机一周以上后，超过 30 天的旧日志会多留到重新连续为止，这是有意的。

两道都挡不住的情况：时钟错着跨过一次重启、而且只快了不到 7 天，这时会删掉按真实时间 23～30 天的日志。真实日期
接近 RTC 落点（约 2027-02）时跳变会落在这个范围，那段时间开机后先确认已校时（`scripts/07-fix-clock.ps1`）。

**版本分界（onboard-hmi#312）**：含该票的车载端之前，日志写在程序目录 `C:\8005\OnboardHmi\logs\`。
部署脚本每次把程序目录整个改名成 `.previous`、再删掉上一代 `.previous`，所以那里的日志会随部署消失，
这正是改位置的原因。升级时旧日志**不迁移**：升级那次部署把旧包连同旧日志改名到
`C:\8005\OnboardHmi.previous\logs\`，下一次部署就删掉，要留就在那之前拷走。文件本身是好的（hmi#292：2026-10-11 从 agv02 原样取回 `agv-20261010.log`、
`agv-20261011.log`，2135 行全部带中文，严格 UTF-8 解码通过，`EF BF BD` 计数为 0）。
看到中文变成一串 `�`（U+FFFD）而英文正常，是**读取链路**上的编码错配，不是日志坏了。

推荐读法：先原样拷回本机，再按 UTF-8 读。字节不经过任何控制台，不会被转码。

```bash
scp agv02:C:/Users/HT/AppData/Local/SQCD/8005AGV/logs/agv-20261010.log ./evidence/
```

```powershell
Get-Content ./evidence/agv-20261010.log -Encoding utf8 | Select-String 'RECOVERY'
```

一定要隔着 SSH 直接看时，只用 `ssh agvNN "<命令>"` 让远端默认 shell 执行，它会加载 `agvops`
的 UTF-8 profile（第 6 节）：

```bash
ssh agv02 "Get-Content C:\Users\HT\AppData\Local\SQCD\8005AGV\logs\agv-20261010.log -Tail 50"
```

会出 `�` 的读法，别用：

- 远端绕开 profile：`pwsh -NoProfile ...`、`powershell.exe ...`、`cmd /c type ...`。SSH 会话的
  控制台代码页是 936（GBK），没有 profile 把它改成 65001，中文就以 GBK 字节发回来，本机按
  UTF-8 解码时每个汉字都变成 `�`，ASCII 部分不受影响——正是 hmi#292 现场看到的样子。
  （本机已验证「GBK 字节按 UTF-8 解码」得到的正是这个形状，反方向错配得到的是错字而不是 `�`；
  现场当时具体用了哪条命令没有记录，「绕开 profile」是按这个形状推断的。带 profile 的会话实测
  `[Console]::OutputEncoding.CodePage` 为 65001。）
- 本机用 pwsh 接 `ssh` 的输出（`$x = ssh agv02 "..."`）：本机控制台默认也是 936，pwsh 会把
  原生命令的 UTF-8 输出按 GBK 解码，得到一堆错字。要这么接，先在本机执行
  `[Console]::OutputEncoding = [Text.Encoding]::UTF8`。

判断一份日志到底坏没坏，只看拷回来的原始字节（`EF BF BD` 出现几次），不看屏幕上的字。

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

1. **查这台 CPE 已占用的转发端口。** 默认用 **22022**，1、2 号车都是它——每台 CPE 是
   独立设备、有自己的地址，外部端口本来就不会互相撞，统一一个数比按车递增好记。
   外部 22 不能用：CPE 自己的 dropbear 占着。
   只有当这台 CPE 的 22022 已被别的用途占了，才另挑一个，并在片段的注释里写明原因。

2. **本机启动分发服务**，**要管理员权限**（`HttpListener` 绑非回环地址需要，脚本还会临时
   开一条入站防火墙规则，退出时自己删掉）：

   ```bash
   pwsh -ExecutionPolicy Bypass -File scripts/04-serve-payload.ps1 -TargetHost <新CPE的IP>
   ```

   `-TargetHost` 让它算出到那台车该用哪个源地址。核对打印出的箭头指向企业内网地址——
   控制端有 Hyper-V 交换机和 Clash 隧道的地址排在真实地址前面，挑错了上位机够不着。

   **必须在主检出里跑，不能在 git worktree 里跑。**`payload/` 是 gitignore 的，只存在于
   当初把包放进去的那个检出；worktree 有 `scripts/` 但没有 `payload/`。脚本会在缺包时
   直接拒绝（2026-09-03 加的守卫）——在那之前它不会停，只会打出一条文件名和哈希都是空的
   命令，粘到上位机上以一个不指向真正原因的方式失败。

3. **上位机 VNC 里粘它打印的那行命令**，会拉包、校验、跑 bootstrap。
   记下打印的 agvops 密码。

4. **CPE 配转发**：`外部端口/TCP → <上位机LAN IP>:22`

5. **改 `config/ssh_config.agv`，然后重跑装配器。**不要直接编辑 `~/.ssh/config`——
   那份文件由 `remote-ops/control-host/Build-SshConfig.ps1` 生成，手改会在下次装配时
   被覆盖，而且绕过了命名唯一性校验。

   **项目就 3 台车，`agv01`–`agv03` 的块都已经填好了**（地址见
   [`../../fleet.md`](../../fleet.md)），本节因此是流程记录，不是待办。真要再接一台，
   照着复制一块，别名必须是 `agv` + 两位数字：

   ```
   Host agv0N
       HostName <新CPE的IP>
       Port 22022
   ```

   机器还没上线就先把 `HostName` 写成 `REPLACE_...` 占住名字，装配时会跳过它。然后：

   ```bash
   pwsh ../../control-host/Build-SshConfig.ps1
   ```

   它会校验全部通道的命名（重名直接非零退出），把片段装到 `~/.ssh/conf.d/`，并且**不碰**
   `factory01`、`vm01` 那些别的通道的别名。规则见
   [`../../control-host/README.md`](../../control-host/README.md)。

   连之前先确认解析对了，这一步不发起连接：

   ```bash
   ssh -G <别名> | grep -E '^(hostname|port|user|identityfile) '
   ```

6. **验证** `ssh <别名>`，通了再推 03 加固：

   ```bash
   scp scripts/03-harden-sshd.ps1 <别名>:C:/temp/agv/ && \
   ssh <别名> "pwsh -ExecutionPolicy Bypass -File C:\temp\agv\03-harden-sshd.ps1 -Force"
   ```

7. **装 UTF-8 profile**（第 6 节）。

8. **校时**（`scripts/07-fix-clock.ps1`）。镜像自带时钟快 158 天且 NTP 配错，三台车都
   中了，**要在任何东西读这台机器的时间戳之前修**。原因见
   [`../../fleet.md`](../../fleet.md) 的硬约束 2。

   **这台机器每次断电都会重新跳回 2027，所以这一步在 2026-09-21 之前只管一个开机周期。**
   那天 agv01 两次断电后又读到 2027-02-05（快 137 天），而 09-03 配的 NTP 一直还在、厂区
   服务器也一直在应答——`w32tm /stripchart` 明明测得出这 11873082 秒的偏差，机器就是不改。
   原因是 w32time 自己的两个上限 `MaxPosPhaseCorrection` / `MaxNegPhaseCorrection` 出厂是
   54000 秒（15 小时），超过就判定"对端或本机不可信"，于是拒绝纠正并退回
   `Local CMOS Clock`。09-03 那次之所以看起来修好了，是因为 `Set-Date` 是人工粗调、绕过了
   这个上限，而后续维持交给了一个根本不被允许纠正的 NTP。

   脚本已于 2026-09-21 改过（[workspace#5](https://github.com/trytoreachpeak0/8005-workspace/issues/5)），
   现在做四件事：指 NTP、把两个上限放开到 `0xFFFFFFFF`、resync、注册开机触发的计划任务
   `W2G-ClockResyncAtStartup`（SYSTEM 身份，开机后延迟 30 秒，失败每 30 秒重试共 10 次）。
   放开上限的代价是这台机器从此接受任意大的时间跳变；在一台已知会跳、又没有别的时间源的
   车载机上这笔账是划算的，它现在的状态是停在错误时间上不动，没有比这更糟的。改完之后
   **机器自己就能把任意大的偏差纠回来，断电不再需要人上车校时**，`-ReferenceTime` 因此
   变成可选参数，只在 resync 拉不回来时当兜底。

   ```bash
   scp remote-ops/onboard-hmi/scripts/07-fix-clock.ps1 <别名>:C:/temp/agv/ && \
   ssh <别名> "pwsh -ExecutionPolicy Bypass -File C:\temp\agv\07-fix-clock.ps1 -WhatIf"
   ```

   干跑只打印要做什么，去掉 `-WhatIf` 才真的动机器。**在一台时钟看起来已经正常的车上也要
   跑**——放开上限和装计划任务，图的就是下一次断电。验收标准是"把时钟改成一个明显错误的值、
   重启，它自己回得来"，不是"现在读数对"。

   **这把一个持续的错误缩成了一个开机窗口，没有消灭它。**开机后时钟错的时间大约是 35 秒
   （计划任务延迟 30 秒起 + resync 几秒），CPE 链路慢时按 30 秒一次重试，最坏到 5 分钟。
   这个窗口在本目录这套工具下咬不到车载端：`SQCD.Agv.Wpf` 不是服务，**没有任何东西会在开机时
   替你把它拉起来**——10 号脚本是人从 SSH 敲的，拉起用的计划任务跑完即注销（第 8 节）；这台
   机器开机直进桌面也不是自动登录，而是 `HT` 账户没有密码（见
   [`../README.md`](../README.md) 决策五）。**但厂家镜像里如果留了启动项，那就另说**，而这
   一条本目录的记录里没有答案。人在车上时顺手查一次，一条命令：

   ```powershell
   Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User
   ```

   查出来有车载端的启动项，就意味着上面那 35 秒里车载端可能已经带着坏时钟连上去了，症状会是
   一个与车辆无关的 `DEPARTURE_SAFETY_NOT_READY`。真正堵住这个窗口的是车载端自己在启动时比一次
   时间差、不对就拒绝启动（workspace#5 的建议 2，属于 `8005-agv-onboard-hmi`，要单开票）。

   **根子在硬件，上面这些只是兜底。**落点 18 天里几乎没动（09-03 读 2027-02-08，09-21 读
   2027-02-05），如果 RTC 在断电期间正常走，落点应该跟着往前推 18 天。它没有，说明主板的
   RTC 停了、上电时固件恢复了一个陈旧的保存值，典型原因是 CMOS 电池没电——那要人到车上换。
   三台车同一批同一个镜像，agv02、agv03 大概率一样，顺手一起查。

9. **填 `config/site-<别名>.json`**——照 `site.example.json` 建一个，里面全是
   `REPLACE_*`。这一步跟部署走，不跟通道走，细节在第 8 节。注意 `onboardInstanceId`
   和 `expectedVehicleKey` **不能抄别的车的**：服务端靠它们区分车辆，抄了等于两台车
   在服务端是同一台。

10. **在 [`../../fleet.md`](../../fleet.md) 里加一行**，否则下一个人不知道这台车存在。

顺序不能颠倒：没验证通就加固会把 SSH 锁死（VNC 能救，但白跑一趟）。

---

## 8. 部署车载端

车载端的 CD 不是独立的：**ControlServer 和 OnboardHmi 打在同一个包里**，因为两端在明文期
没有协商也没有降级，版本错配的表现是连接被拒而不是一条说明原因的错误。出包在 ControlServer
仓库的 `release.yml`，本目录只管最后一跳。

完整流程、为什么是这个形状、以及一次性准备（PAT、秘密、站点文件），见
[`../../factory-server/docs/wire-to-gate-cd.md`](../../factory-server/docs/wire-to-gate-cd.md)。

这里只记与车相关的三件事：

**先填站点文件。**一台车一个，`../config/site-<别名>.json`，从 `site.example.json` 复制。
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

**IO 指向：部署不再悄悄把模拟器换成真模块**（[workspace#28](https://github.com/trytoreachpeak0/8005-workspace/issues/28)，
2026-10-12）。测试车（agv02/agv03）平时用车上的仓位模拟器做 IO（`127.0.0.1:1502`，由 `09-switch-io-module.ps1 -Simulator`
切过去）。以前 `06` 每次都按站点文件把 `ioModule` 渲染回真模块（`192.168.71.150:502`），之后要模拟器全靠人记得再跑一次 `09`；
忘了就起栈，车就接上了真 IO——而切到真 IO 属于要先问用户的「动车」一类。现在 `06` 在 `-WhatIf` 闸门之前只读一次车上已装配置的
`ioModule.host`/`port`，按下表决定：

| 车上已装配置的 IO | 不带开关 | `-KeepCurrentIo` | `-UseSiteIo` |
| --- | --- | --- | --- |
| 模拟器（回环地址） | **拒绝**（`IO_SIMULATOR_TO_REAL_REFUSED`），提示二选一 | 保留原 host:port | 改用站点里的真模块，打 Warning |
| 真模块（如 agv01） | 站点值，与以前逐字相同 | 保留原 host:port | 站点值 |
| 没有（首次部署） | 站点值，与以前相同 | **拒绝**（`IO_KEEP_NO_INSTALLED_CONFIG`），不回落到站点值 | 站点值 |
| 读不出或缺字段 | 当作可能是模拟器，拒绝 | **拒绝**（`IO_KEEP_UNREADABLE`） | 站点值，打 Warning |
| 未知 IO（既不是回环，也不等于站点 host） | **拒绝**（`IO_UNKNOWN_TO_REAL_REFUSED`） | 保留原 host:port | 站点值，打 Warning |
| 安装目录没有配置，但 `.previous` 里有 | **拒绝**（`IO_PREVIOUS_INSTALL_ONLY`），先到车上确认 | **拒绝**（同左） | 站点值，打 Warning |

「读不出或缺字段」不带开关也拒绝，是调度 2026-10-12 认可的取舍：配置坏了的车本来就该有人看一眼再部署。
「只有 `.previous`」是放置脚本在「把旧目录挪成 `.previous`」和「把新目录挪成安装目录」两步之间断掉留下的样子，
它不是首次部署；脚本不猜车原来该用哪种 IO，要人到车上看清楚，恢复或删掉 `.previous` 再部署。

- **`-UseSiteIo` 会让车接上真 IO。**部署前要用户对这一次授权，并且现场有人；摘要行里也写着这句话。
- 两个开关互斥，同时给会在连车之前就拒绝。
- **只保留 `host` 和 `port`。**这正是 `09` 改的那两项。`unitId`、DO/DI 起始地址、通道数、超时和八个仓位的映射
  都跟新包的模板走：它们是这个包版本的接线定义，模拟器和真模块共用同一套；保留下来等于把旧包的映射冻在车上。
- 判定规则分三类：host 是回环地址（`127.x`、`::1`、`localhost`）算模拟器；与站点文件的 `ioModule.host` 相同才算真模块；
  其余一律算「未知 IO」，例如 `localhost.`、把端口写进 host 的 `127.0.0.1:1502`、本机主机名、另一个模块地址。
  这样一种没人列过的写法只会落到「拒绝」那一侧，不会被当成真模块放行。
- 不论带不带开关，部署摘要都会打一行 `IO target: ...`，写明这次的指向、来源和车上原来的指向；放置之后还会在车上
  回读 `ioModule`，与预期不符就报错。

测试车照常部署的写法：

```bash
pwsh -File remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -SshAlias agv02 -KeepCurrentIo -WhatIf
```

离线自检（不连车）：`pwsh -File remote-ops/onboard-hmi/scripts/Test-DeployOnboardHmi.ps1`。

**`06` 搬完就停，不启动**——启动是单独一步，见下。上一代留在 `C:\8005\OnboardHmi.previous`，
要退回去人工换。

### 启动与停止：`10-start-onboard-stack.ps1`

**这条规则 2026-09-04 改过。**在那之前启动只有一条路：走到车前，在它自己的桌面上双击
`C:\8005\OnboardHmi\SQCD.Agv.Wpf.exe`。现在有脚本了：

```bash
pwsh -File remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv01
pwsh -File remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv01 -Stop
```

**改掉的是「必须站在哪栋楼里」，不是那道授权。**`RELEASE-CANDIDATE.md` 第 11 节要求的逐次
授权仍然成立，只是现在由「有人刻意敲这条命令」来表达——**没有任何东西会替你敲它**：部署不会、
登录触发不会、也不留下任何比这一次运行活得更久的计划任务。第 8 节那条也没变：干净会话只有在
车辆安全投影返回 `motionState=STOPPED` 且证据新鲜时才到 `Ready`，**那个判定仍然是人的**。

脚本替人做对了两件容易做错的事：

- **顺序。**模拟器必须先在 1502 上监听，客户端才能开 Modbus 连接。反过来起，客户端启动时的 IO
  快照就失败，会话再也离不开 `RecoveryRequired`——而那看起来像服务端的问题。
- **等待。**两半各自确认起来了（模拟器看端口，客户端看进程）再往下走，失败因此报在真正失败的
  那一半上。

`SQCD.Agv.Wpf` 是交互式 WPF 程序不是服务，sshd 给的是 session 0，在那里起窗口等于起在没人看的
桌面上。脚本改用**交互会话里的计划任务**把它拉起来（和 win11-01 上那个 golden-renderer runner
同一手法），进程因此落在 session 1。这依赖上位机的自动登录；没有 Active 的 console 会话时脚本
直接报错，而不是留下一个永远不触发的任务。

客户端正在跑时脚本拒绝启动（除非 `-Force`），因为那意味着车可能在作业途中。**模拟器在跑不拦**
——那是正常中间态，会原样留着。`-SimulatorOnly` 只起模拟器，不起任何会让车动的东西。

### 无人现场窗口的两个开关：`14` 与 `15`

两个都是出厂关、部署会渲染回关、**客户端停着时**才动，开一次、`-Revert` 关一次，都不启动任何东西：

| 脚本 | 开的是什么 | 不开的后果 |
| --- | --- | --- |
| `14-set-recovery-window.ps1` | 恢复入口（两端凭据 + `wireToGate.recoveryResumeEnabled`） | 真 `UNKNOWN` 进不了恢复 |
| `15-set-automation-face.ps1` | 车载端自动化面 `127.0.0.1:58007`（`automation.enabled` + `automation.productionReviewReference`） | `FieldOperator.psm1` 的 `Remote` 模式连不上，无人窗口一个动作都做不了 |

```bash
pwsh -File remote-ops/onboard-hmi/scripts/15-set-automation-face.ps1 -ReviewReference '<放行记录的 URL>'
pwsh -File remote-ops/onboard-hmi/scripts/15-set-automation-face.ps1 -Revert
```

`15` 的出处必填、没有默认值：Production 下客户端要求它是非占位符，而默认值等于谁跑脚本谁就拿到一次放行。
agv01 的放行记录是 [8005-agv-program#44 的这条留言](https://github.com/trytoreachpeak0/8005-agv-program/issues/44#issuecomment-5632670629)，**只覆盖 agv01**。
它逐个叶子比对改前改后，除这两个字段外有任何变化就还原备份并失败；备份留在 `C:\8005\appsettings-backup-automation-face-*.json`。
**窗口内重新部署之后两个都要重跑**——部署不报错，面与恢复入口只是无声消失。

### 看屏上显示什么：`17-capture-hmi-screen.ps1`

只读取一次车载端屏：全屏截图、每个车载端窗口单独的图、UI Automation 控件树与可见文字（JSON）。
**只接受 `agv02`／`agv03`**，`agv01` 在参数校验时就被拒绝。不点、不输入、不改焦点、不起停任何
进程，所以不需要逐次授权；但它要进 `HT` 的桌面会话，现场票作业中途用之前先跟调度打招呼。
条码自动录入（`16`）在跑时它拒绝启动（`DESKTOP_BUSY`），两个交互工具不同时进桌面。

```bash
pwsh -File remote-ops/onboard-hmi/scripts/17-capture-hmi-screen.ps1 -SshAlias agv02 -EvidenceDirectory evidence/field/<目录>
pwsh -File remote-ops/onboard-hmi/scripts/17-capture-hmi-screen.ps1 -SelfTest
```

输出落在 `-EvidenceDirectory`，文件名带车号和**控制端**时刻（车上时钟不可信）：
`agv02-<时刻>-screen.png`、`-window-<n>.png`、`-uia.json`（车端记录，`visibleTexts` 是屏上文字）、
`-run.json`（控制端记录：预检、结果码、车端脚本是否跑起来、清理，以及车上还剩的取屏任务与进程——
脚本不停任何进程，只列出来；能保证的是控制端不挂住）。终端最后会打印可见文字的前 30 条。

结果码与退出码、为什么这样做、锁屏和熄屏时能看到什么，见 [hmi-screen-capture.md](hmi-screen-capture.md)。
两条要记住：锁屏时全屏图只有锁屏画面，车载端界面看 `-window-<n>.png` 与 UIA 文字（结果码 `DESKTOP_LOCKED`）；截图入库前看一眼，
脚本只涂黑了密码框，屏上若有别的敏感内容要自己处理。

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
