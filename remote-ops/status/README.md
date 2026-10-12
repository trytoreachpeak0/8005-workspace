# 运行状态 journal

一条命令，看清 WIRE_TO_GATE 两端此刻真实在干什么，并把这次观测追加成 journal 的一行。

```powershell
pwsh remote-ops/status/Get-WireToGateStatus.ps1
```

默认看的是 agv01 和 MVP 服务（`-BaseUrl` 默认 `http://172.19.205.222:58007`）。看 v2 的车必须显式指向 v2 实例，
否则会在发出任何请求之前拒绝（[workspace#32](https://github.com/trytoreachpeak0/8005-workspace/issues/32)）：

```powershell
pwsh remote-ops/status/Get-WireToGateStatus.ps1 -SiteAlias agv02 -BaseUrl http://172.19.205.222:58107 -ServiceName '8005 AGV ControlServer V2'
```

离线自检：`pwsh -File remote-ops/status/Test-GetWireToGateStatus.ps1`。

```
2026-09-03 11:41:57  老厂前线新多仓位1  (agv01)
  [ok]   server-service-running     Running, pid 16240
  [ok]   server-live                HTTP 200
  [FAIL] server-ready               HTTP 503 RECOVERY_HANDSHAKE_REQUIRED
  [FAIL] onboard-process-running    SQCD.Agv.Wpf not running
  [FAIL] session-present            no session for '老厂前线新多仓位1'
  [?]    session-ready              no session yet
  [ok]   vehicle-safety-stopped     STOPPED, key matches, no reasons, evidence 1498 ms old
  [ok]   clock-onboard-vs-server    onboard is 116 ms ahead of server (window 5000 ms)
  MVP: not complete
```

**只读。**它不启动任何东西、不停任何东西，也不往两台目标机写任何文件。

## 这个 journal 不是那个 journal

同名但完全是两回事，不要混：

| | 车载恢复日志 | 这里的状态 journal |
| --- | --- | --- |
| 谁写 | 车载端产品自己（`SqliteWireToGateJournal`） | 控制端这个脚本 |
| 在哪 | 车上 `%LOCALAPPDATA%\SQCD\8005AGV\onboard-journal.db` | 控制端 `%LOCALAPPDATA%\AgvOpsStatus\` |
| 依据 | ADR 0006，产品恢复所必需的因果状态 | 无，纯观测 |
| 删了会怎样 | **不允许删**，未结日志删了就丢了物理副作用的解释 | 丢历史，不影响任何东西 |

形状上它像的是 `MesIngest.Watch` 的 `WatchConnectionEventJournal`：按天一个 JSON Lines
文件，一行一次完整观测，只追加不改写。**一条过去的观测在它记录的状态变化之后仍然成立**，
所以永远不回头改行。

## 九条判据

`mvpComplete` 是九条全部 PASS。`UNKNOWN` 不算通过——连不上时是"不知道"，不是"失败"，
这个区别在排错时很重要。

| 判据 | 在问什么 | 不过时先看 |
| --- | --- | --- |
| `server-service-running` | 厂区服务器上的 Windows 服务在不在跑 | `ssh factory01`，`Get-Service '8005 AGV ControlServer'` |
| `server-live` | 服务进程有没有在应答 HTTP | 服务器防火墙那两条规则；`Find-NetRoute` 是不是走了 Clash |
| `server-ready` | 有没有任何一台车完成了恢复握手 | 正常状态就是 `RECOVERY_HANDSHAKE_REQUIRED`，直到车载端起来 |
| `onboard-process-running` | 车上 `SQCD.Agv.Wpf` 进程在不在 | **这是人在车前的动作**，见下 |
| `session-present` | 服务端见没见过这台车 | 车载端起来了但没这条，查两端版本与绑定地址 |
| `session-ready` | 这台车的会话是不是 `Ready` | `reasonCode`：`DEPARTURE_SAFETY_NOT_READY` 是闸门在正常工作，只有 `HANDSHAKE_INCOMPLETE` 才去查五步握手 |
| `io-target-reachable` | 车载端配的 IO 目标在不在 | 只在指向模拟器（`127.0.0.1`）时判，见下 |
| `vehicle-safety-stopped` | 安全闸门四项：`vehicleKey` 匹配、`STOPPED`、无 `reasonCodes`、证据够新 | RIoT 是否可读；`UNKNOWN` / `MOVING` 是闸门在工作不是 bug |
| `clock-onboard-vs-server` | 车和服务器的时钟差在不在 5 秒窗口内 | `remote-ops/onboard-hmi/scripts/07-fix-clock.ps1` |

`vehicle-safety-stopped` 是 RC 文档第 8 节要求在**启动车载端之前**验的那四项，用车载端同一把凭据
只读调用。它是最可能把干净会话卡在 `RecoveryRequired` 的一条，而从车上看不出原因。凭据从
`%LOCALAPPDATA%\AgvOpsSecrets\control-server-deployment.xml` 取，秘密不落盘也不打印；
没有秘密库时这条降级成 `UNKNOWN`，`-SkipVehicleSafety` 可以整条关掉。

证据年龄按**车载端的时钟**算，因为应用 `maximumEvidenceAgeMs` 的是车。拿控制端时钟算会得到
负数——控制端慢几秒。

`io-target-reachable` 读车上 `appsettings.json` 的 `ioModule.host` 来决定判什么：指向
`127.0.0.1` 就是模拟器模式，要求模拟器进程在跑且 1502 在监听；指向真实 Modbus 模块时这条
不判（`UNKNOWN`），因为车上没有对应的本地进程可查。模拟器没起来的症状是车载端连不上 IO，
看着像接线故障而不是少了个进程——这条就是为了不让人往那个方向查。

`agvId` 从 `remote-ops/onboard-hmi/config/site-<别名>.json` 读，不硬编码——
`/api/runtime/sessions` 按这个值索引，每台车不一样。没有站点文件时脚本直接拒绝，不猜。

## 关于时钟这条

判的是**两台厂区机器之间**的偏差，不是任何一台相对控制端的偏差。控制端不参与产品的任何
比较：2026-09-03 实测它比两台厂区机器慢 3.2 秒，这对产品没有任何含义。

每台机器相对控制端的偏差仍然记录，但只当上界读，不当测量值：远程时间戳是在 ssh 认证加
pwsh 冷启动**之后**取的，不是在往返正中间，系统性地偏大 1 到 3 秒。两个数相减时这部分
大都抵消，所以差值可信而单值不可信。

车上的时钟曾经快 158 天。安全闸门拿本机时钟比服务端的 `observedAt`，窗口 5 秒，偏成那样
的话干净会话永远进不了 `Ready`，而现场看到的表现是握手 bug。**新车上线前先对表。**

## 持续盯着

```powershell
pwsh remote-ops/status/Get-WireToGateStatus.ps1 -Watch -IntervalSeconds 30
```

首轮打全表，之后只在**有判据翻转时**再打全表，其余时候一行摘要。每一轮都进 journal——
journal 的价值就是那些翻转的时刻。

拿去做别的处理：

```powershell
pwsh remote-ops/status/Get-WireToGateStatus.ps1 -Quiet -PassThru
```

## journal 文件

默认 `%LOCALAPPDATA%\AgvOpsStatus\w2g-status-<yyyyMMdd>.jsonl`，一行约 1.7 KB。
**不进 git**，理由和 `probe-*.txt` 一样：里面是现场机器身份和实时状态。

翻历史，比如找出车载端进程是什么时候起来的：

```powershell
Get-Content "$env:LOCALAPPDATA\AgvOpsStatus\w2g-status-20260903.jsonl" |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.onboard.processId } |
    Select-Object -First 1 observedAt, @{n='pid'; e={$_.onboard.processId}}
```

需要清理时自己删旧文件。脚本不做保留策略——按 60 秒轮询一天约 2.5 MB，还不值得一套机制。

## 现在离 MVP 还差什么

截至 2026-09-03，九条里过了四条。剩下的挂在**人在车前的两个动作**上，顺序不能反：

1. 先启动桌面上的「8005 仓位模拟器」，等它把 1502 听起来
2. 再启动「8005 AGV 车载端」

两个都是 WPF 程序，SSH 起的进程在 session 0 里没有窗口，所以只能在车的桌面会话里做。顺序
要求来自 IO 连接：车载端启动时就去连 Modbus，模拟器还没监听的话它连不上。

`io-target-reachable` 和 `onboard-process-running` 变绿之后，`session-present` →
`session-ready` → `server-ready` 会顺次跟上。`-Watch` 就是为这一刻准备的：人在车前操作，
这边看着判据一条条翻。

判读标准的权威版本在 `remote-ops/factory-server/docs/wire-to-gate-cd.md` 第 7 节。
