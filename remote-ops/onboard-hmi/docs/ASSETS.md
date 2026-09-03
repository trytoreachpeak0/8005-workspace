# 资产清单：什么东西落在哪

这套系统的组成部分散落在三个地方：本仓库目录、控制端本机的用户目录、以及上位机上。
只看仓库会漏掉关键的两样（私钥和密码），接手时先读这份。

状态截至 2027-02-06，阶段 1 完成。

---

## 1. 本目录内

```
remote-ops/onboard-hmi/
├── README.md                          架构、决策理由、分阶段进展
├── docs/
│   ├── USAGE.md                       日常怎么用 ← 接手先读这个
│   └── ASSETS.md                      本文件
├── config/
│   ├── ssh_config.agv                 agv 族的 ssh 片段，也是别名注册表（见第 2 节）
│   ├── site.example.json              现场值模板，不属于任何一台车
│   ├── site-agv01.json                1 号车的现场值
│   ├── site-agv02.json                2 号车，通道就绪，值仍是 REPLACE_*
│   ├── site-agv03.json                3 号车，等装 sshd，值仍是 REPLACE_*
│   └── agv_ops_ed25519.pub            运维公钥（公开无妨）
├── scripts/
│   ├── 01-probe.ps1                   只读环境探测，随时可跑
│   ├── 02-bootstrap-sshd.ps1          装 sshd + 建 agvops + 装公钥
│   ├── 03-harden-sshd.ps1             关密码认证
│   ├── 04-serve-payload.ps1           本机侧临时 HTTP 分发（在本机跑）
│   ├── 05-setup-control-host.ps1      控制端重建（换机器时用）
│   ├── 06-deploy-onboard-hmi.ps1      车载端最后一跳（搬完就停，不启动）
│   ├── 07-fix-clock.ps1               校时
│   ├── 08-deploy-slots-simulator.ps1  仓位模拟器
│   ├── 09-switch-io-module.ps1        切 IO 模块
│   └── agvops-profile.ps1             远程 $PROFILE，修 UTF-8 乱码
├── payload/                           ⛔ 不进 git
│   └── OpenSSH-Win64.zip              OpenSSH 10.0.0.0p2 离线包
└── evidence/                          ⛔ 不进 git
    ├── probe-LAB-WIN-01-*.txt         控制端基线
    └── probe-DESKTOP-94OA6CK-*.txt    1 号车基线
```

标 ⛔ 的两个目录只存在于控制端本地，被根 `.gitignore` 挡在版本库外：`evidence/`
含账户、防火墙、IP 拓扑，进了 git 历史就清不掉；`payload/` 是可从上游重新取回的
二进制，遵循本工作区"只留配方不留制品"的惯例（同 `w2g-rc-*`）。克隆出来的副本这两个
目录是空的 —— probe 重新跑 `01-probe.ps1` 即可，离线包按下面的校验值重新下载。

`payload/OpenSSH-Win64.zip` 校验值：

```
SHA256  23F50F3458C4C5D0B12217C6A5DDFDE0137210A30FA870E98B29827F7B43ABA5
大小    5,704,583 bytes
来源    https://github.com/PowerShell/Win32-OpenSSH/releases  (10.0.0.0p2-Preview)
```

---

## 2. 控制端本机，本目录之外

| 路径 | 是什么 | 在仓库里吗 |
| --- | --- | --- |
| `C:\Users\szy\.ssh\agv_ops_ed25519` | **私钥**，无 passphrase | ❌ 故意不放 |
| `C:\Users\szy\.ssh\agv_ops_ed25519.pub` | 公钥 | ✅ `config/` 有副本 |
| `C:\Users\szy\.ssh\config` | 只有一个标记块，里面一行 `Include` | ⚙️ 由装配器生成，不是副本 |
| `C:\Users\szy\.ssh\conf.d\remote-ops-agv.conf` | agv 族的生成产物 | ⚙️ 由 `config/ssh_config.agv` 生成 |
| `C:\Users\szy\.ssh\known_hosts` | 上位机指纹记录 | ❌ 指纹值记在 USAGE.md 第 2 节 |

**私钥为什么不放仓库**：它无 passphrase，进了仓库等于把所有上位机的管理员权限
写进一个可能被同步、备份、共享的目录。它只应该待在控制端本机。

**`config/ssh_config.agv` 不再是「副本」，它是源。**（改于 2026-09-03。）以前它和
`~/.ssh/config` 是两份互抄的东西，谁改了要记得同步另一边；现在方向是单向的：

```
remote-ops/*/config/ssh_config.<族>   ← 唯一的源，改这里
        ↓  pwsh remote-ops/control-host/Build-SshConfig.ps1
~/.ssh/conf.d/remote-ops-<族>.conf    ← 生成物，不要手改
~/.ssh/config                          ← 只有一个标记块 + 一行 Include
```

**不要再直接编辑 `~/.ssh/config` 里的这些块。**改片段、跑装配器，它会校验命名唯一性并
拒绝重名。`05-setup-control-host.ps1` 现在调用装配器，不再整文件覆盖——它以前那样做会
把 `factory01` 和 `vm01` 一起抹掉。细节见
[`../../control-host/README.md`](../../control-host/README.md)。

---

## 3. 故意不落盘的东西

| 是什么 | 在哪 | 为什么不落盘 |
| --- | --- | --- |
| `agvops` 的密码 | **用户手里**（bootstrap 时打印一次） | 落盘就等于把应急后路的凭据也交出去了 |
| `HT` 的密码 | 不存在，该账户是空密码 | 既有状况，本方案没动它 |

**agvops 密码丢了怎么办**：日常不需要它（走公钥）。真需要重置，VNC 进去用 HT
（空密码，直接进桌面）开管理员 PowerShell：

```powershell
Set-LocalUser -Name agvops -Password (Read-Host -AsSecureString)
```

---

## 4. 上位机上落了什么

1 号车 `DESKTOP-94OA6CK`（`192.168.71.180`）当前状态：

| 位置 | 内容 | 撤销方式 |
| --- | --- | --- |
| `C:\Program Files\OpenSSH\` | OpenSSH 10.0.0.0p2 程序本体 | `uninstall-sshd.ps1` |
| 服务 `sshd` | Automatic，运行中，监听 22 | `Stop-Service` + `Set-Service -StartupType Disabled` |
| `C:\ProgramData\ssh\sshd_config` | 已加固：仅公钥认证 | 恢复同目录的 `sshd_config.backup-20270206-210047` |
| `C:\ProgramData\ssh\administrators_authorized_keys` | 运维公钥，ACL 锁定 | 删除该文件 |
| 注册表 `HKLM:\SOFTWARE\OpenSSH\DefaultShell` | 指向 `pwsh.exe` | 删除该值即回退到 cmd.exe |
| 本地账户 `agvops` | 管理员组，密码永不过期 | `Remove-LocalUser agvops` |
| 防火墙规则 `OpenSSH-Server-In-TCP-22` | 入站放行 | `Remove-NetFirewallRule` |
| `C:\Users\agvops\Documents\PowerShell\Microsoft.PowerShell_profile.ps1` | UTF-8 设置 | 删除该文件 |
| `C:\temp\agv\` | 脚本与离线包的落地副本 | 整个目录可删 |

**没有动过的东西**（不需要恢复）：`HT` 账户及其桌面、RealVNC Server、
`C2000Service`（IO 模块）、`PaceCatView`（雷达）、任何现有网络配置。

完整撤销命令见 [USAGE.md](USAGE.md) 第 8 节。

---

## 5. 上位机之外的配置

**CPE（北京节点通 CPE2458，`172.19.162.210`）** 上加了一条端口转发：

```
公用端口 22022  TCP  ->  192.168.71.180:22
```

这条规则在 CPE 的管理页（`http://172.19.162.210`）里，**不在任何脚本或备份中**。
CPE 恢复出厂或换设备后必须手动重建，否则 SSH 直接不通。

CPE 上原有的转发（本方案没碰）：`80, 443, 502, 2222, 5001, 5002, 5003, 5010,
5900, 8001, 8005, 8008, 8009`。其中 5900 是 RealVNC，是应急通道，**千万别删**。

---

## 6. 换控制端机器怎么办

私钥不在仓库里，所以换机器不是拷贝目录就能了事。两种情况：

**能拿到旧机器**：把 `C:\Users\szy\.ssh\agv_ops_ed25519` 和 `.pub` 拷到新机器的
同名目录，然后跑：

```powershell
pwsh -ExecutionPolicy Bypass -File scripts\05-setup-control-host.ps1
```

**拿不到旧私钥**：只能生成新密钥，然后把新公钥分发到每一台车。分发得走 VNC
（因为旧密钥没了，SSH 进不去）：

```powershell
pwsh -ExecutionPolicy Bypass -File scripts\05-setup-control-host.ps1 -GenerateNewKey
```

脚本会打印新公钥和一段安装命令，VNC 进每台车粘一次。这就是为什么**私钥值得单独备份**
到一个安全的地方（密码管理器、加密 U 盘），而不是只存在一台笔记本上。
