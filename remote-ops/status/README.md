# 运行状态 journal

一条命令，看清 WIRE_TO_GATE 两端此刻真实在干什么，并把这次观测追加成 journal 的一行。

```powershell
pwsh remote-ops/status/Get-WireToGateStatus.ps1
```

```
2026-09-03 11:41:57  老厂前线新多仓位1  (agv01)
  [ok]   server-service-running     Running, pid 16240
  [ok]   server-live                HTTP 200
  [FAIL] server-ready               HTTP 503 RECOVERY_HANDSHAKE_REQUIRED
  [FAIL] onboard-process-running    SQCD.Agv.Wpf not running
  [FAIL] session-present            no session for '老厂前线新多仓位1'
  [?]    session-ready              no session yet
  [ok]   clock-onboard-vs-server    onboard is 157 ms ahead of server (window 5000 ms)
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

## 七条判据

`mvpComplete` 是七条全部 PASS。`UNKNOWN` 不算通过——连不上时是"不知道"，不是"失败"，
这个区别在排错时很重要。

| 判据 | 在问什么 | 不过时先看 |
| --- | --- | --- |
| `server-service-running` | 厂区服务器上的 Windows 服务在不在跑 | `ssh factory01`，`Get-Service '8005 AGV ControlServer'` |
| `server-live` | 服务进程有没有在应答 HTTP | 服务器防火墙那两条规则；`Find-NetRoute` 是不是走了 Clash |
| `server-ready` | 有没有任何一台车完成了恢复握手 | 正常状态就是 `RECOVERY_HANDSHAKE_REQUIRED`，直到车载端起来 |
| `onboard-process-running` | 车上 `SQCD.Agv.Wpf` 进程在不在 | **这是人在车前的动作**，见下 |
| `session-present` | 服务端见没见过这台车 | 车载端起来了但没这条，查两端版本与绑定地址 |
| `session-ready` | 这台车的会话是不是 `Ready` | `reasonCode`：`DEPARTURE_SAFETY_NOT_READY` 是闸门在正常工作，只有 `HANDSHAKE_INCOMPLETE` 才去查五步握手 |
| `clock-onboard-vs-server` | 车和服务器的时钟差在不在 5 秒窗口内 | `remote-ops/onboard-hmi/scripts/07-fix-clock.ps1` |

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

截至 2026-09-03，七条里过了三条。剩下四条全部挂在同一个动作上：**得有人到车前，用桌面
快捷方式启动车载端**。SSH 起的进程在 session 0 里没有窗口，而且启动它意味着一台会动的车
进入待命，所以这一步不能远程做。

`onboard-process-running` 一旦变绿，`session-present` → `session-ready` → `server-ready`
会顺次跟上。`-Watch` 就是为这一刻准备的：人在车前操作，这边看着判据一条条翻。

判读标准的权威版本在 `remote-ops/factory-server/docs/wire-to-gate-cd.md` 第 7 节。
