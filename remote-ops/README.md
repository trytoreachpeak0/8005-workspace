# 远程运维通道

进厂区机器的两条通道。动任何一台机器之前，先读它所在子目录的文档。

| 目录 | 目标机 | 协议 | 目标机 PowerShell | 先读 |
| --- | --- | --- | --- | --- |
| `onboard-hmi/` | AGV 车载上位机 | SSH（`ssh agv01`） | pwsh 7.6.5 | `onboard-hmi/docs/USAGE.md` |
| `factory-server/` | 厂区服务器 `WIN-0HD72AV4K31`（SQL Server + AGV 服务栈 + MES ingest 目标机 + **Hyper-V 宿主**） | SSH（`ssh factory01`） | pwsh 7.6.5 | `factory-server/docs/USAGE.md` |

两条通道现在都走 SSH、仅公钥认证、远程 shell 都是 pwsh 7.6.5，操作习惯一致。

**跨两条通道的部署流程有两份文档**，都在 `factory-server/docs/` 下，因为出包那一侧在那边：

| 文档 | 讲什么 |
| --- | --- |
| `factory-server/docs/mes-ingest-cd.md` | MesIngest 部署到厂区服务器 |
| `factory-server/docs/wire-to-gate-cd.md` | WIRE_TO_GATE 两端。**服务端去厂区服务器，车载端去上位机，同一个包** |

WIRE_TO_GATE 那份跨了这里的两个子目录：服务端脚本是 `factory-server/scripts/15-*`，车载端是
`onboard-hmi/scripts/06-*`，每台车的现场值在 `onboard-hmi/config/site-<别名>.json`。

**想知道两端此刻在干什么，用 `status/`**：

```powershell
pwsh remote-ops/status/Get-WireToGateStatus.ps1
```

一次运行同时读服务端 HTTP、两台机器的 SSH，给出七条判据的 PASS/FAIL 和一句 MVP 结论，
并把这次观测追加成 journal 的一行。只读，不启动也不停任何东西。用法和每条判据不过时先看
哪里在 `status/README.md`。

`factory-server/` 早先走的是 WinRM 5985 加 `codex-ops`/`codex-admin` 双账户，
已于 2026-09-01 整个拆除——双账户模型从未真正生效、文档里的防火墙加固不成立、
且它需要关闭远程 UAC 令牌过滤。原委见 `factory-server/README.md` 决策一。

厂区服务器 2026-09-01 起还装了 **Hyper-V**，跑实验虚拟机。虚拟机相关的操作、限制和
装机的坑在 `factory-server/docs/USAGE.md` 第 8 节。两条硬规矩：**不要在 `em4` 上建
External 虚拟交换机**（那是唯一插了线的网卡，也是 SSH 通道本身），**pwsh 7 里调
Hyper-V 模块要加 `-SkipEditionCheck`**，否则拿到的是绑不上参数的 `Deserialized.*`
对象。

## 两条通道共同的约束

- **能连上机器不等于能改代码。** 通过这里够到一台机器，不会获得那台机器上运行的
  代码所属仓库的写权限。写权限只看根 `CLAUDE.md`。
- **凭据不进仓库。** 两把运维私钥都在控制端 `~/.ssh/`（上位机
  `agv_ops_ed25519`，服务器 `agv_srv_ed25519`，**互不通用**）；应急用的账户密码
  在控制端 `%LOCALAPPDATA%\AgvOpsSecrets\` 的 DPAPI 文件里。都不在这里，也不要
  复制进来。
- **探测输出不进 git。** `probe-*.txt` 已 gitignore，内容是本机账户、管理员组、
  自动登录配置、防火墙状态和 IP 拓扑。
- **通用脚本只有一份。** `01-probe.ps1`、`02-bootstrap-sshd.ps1`、
  `03-harden-sshd.ps1`、`agvops-profile.ps1` 都在 `onboard-hmi/scripts/` 下，
  两条通道共用，不要复制第二份。各子目录的 `scripts/` 只放该目标机特有的东西。

## 控制端本机的坑：Clash TUN

控制端跑着 Clash for Windows 的 TUN 模式，它在 `Clash` 适配器上装了
`128.0.0.0/1` 路由。**任何不落在 Wi-Fi 直连网段 `172.19.162.0/24` 里的目标，
ping 和端口探测都会返回假的"成功"**——TUN 自己应答 ICMP，也自己先完成 TCP 握手。

厂区服务器 `172.19.205.222` 属于这种情况，已用
`factory-server/scripts/01-control-host-route.ps1` 加明细路由绕开，重启后仍在。
新增其它网段的目标机时，同一个脚本换 `-Prefix` 参数即可。

排错前先确认这条：

```powershell
Find-NetRoute -RemoteIPAddress <目标IP> | Select-Object -First 1 IPAddress,InterfaceAlias
```

`InterfaceAlias` 显示 `Clash` 就说明探测结果不可信。

**明细路由只解决路由层，HTTP 客户端是另一条路径。**`Invoke-WebRequest` 和
`Invoke-RestMethod` 默认用系统代理设置，那跟路由表无关——即使 `Find-NetRoute` 显示
直连，请求仍然交给控制端的 Clash 代理转发。表现是错误被伪装：2026-09-03 拿一个
不存在的端口测厂区服务器，回来的是代理的 `HTTP 502`，看着像"服务在但坏了"，加
`-NoProxy` 之后才是真相——`connection refused`，请求根本没到那台机器。

**探厂区机器的 HTTP 一律带 `-NoProxy`。**判据是"目标在明细路由覆盖的网段里"，此时
代理只会添乱。`curl.exe` 对应的是 `--noproxy '*'`。

## 脚本语言

本工作区的脚本一律 PowerShell 7，见根 `CLAUDE.md` 的 Scripting baseline。
**这里不再有例外**：控制端、车载上位机、厂区服务器都是 pwsh 7.6.5。
早先给厂区服务器开的 5.1 例外已经作废，那台机器现在装了 pwsh 7.6.5 也能上外网。
只有 `8005---AGV/mes/ingest/csharp/.artifacts/releases/` 下**已发布**的 MES ingest
脚本保持 `#Requires -Version 5.1` 冻结不动。
