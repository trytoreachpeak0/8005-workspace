# ws#20 本机复现：条码自动录入期间仓位模拟器是否被带走（2026-10-11 18:49–18:53）

## 结论

**没有复现。**21 次录入（新代码验证 1 次＋旧版 10 次＋新版 10 次交替），模拟器 pid 24260、车载端 pid 13940 从头到尾不变。隐藏控制台之后，录入进程仍然找到了车载端窗口「8005 多仓位AGV车载端」，**这一点已实证**。现场 18:03:47 模拟器退出的触发源仍未查明。

## 条件

| 项 | 值 |
| --- | --- |
| 机器 | 控制端本机，交互桌面（远程桌面会话 `rdp-tcp#0`），不是车 |
| slots-simulator | `fb5f7c59`（与现场同） |
| 车载端 | `eced7c16`（与 agv02 同），默认 `appsettings.json`：`wireToGate.enabled=false`、IO 指向 `127.0.0.1:1502` |
| 启动方式 | 模拟器与车载端各用一次性 Interactive 计划任务（与 `10-start-onboard-stack.ps1` 同）；录入任务用 `16-enter-sublot-uia.ps1` 的 `New-LaunchScript` 真实生成的启动段 |
| 互斥 | 整轮持有 `Global\W2G-InteractiveDesktop`；构建与复现都经 `Invoke-HeavyLocal.ps1 -Ticket ws#20`，持有者「ws#20 封锁」 |
| 车 | 未碰 agv02／agv03，未动车 |

与车上的偏差（都写在 `repro.ps1` 开头）：启动段只认 `console` 会话，本机是 RDP，复现时放宽为 `console|rdp-tcp#N`；工作目录在 scratch；循环 20 次在车端参数后追加 `-WaitSeconds 3`（现场那次在任务启动 3 秒内就被结束，等待时长不影响）。

## 结果（`runs.jsonl`、`log.txt`）

| 项 | 结果 |
| --- | --- |
| 验证（新代码、参数不改） | 任务 `0x41301`；`window`＝车载端主窗口；`outcome=INPUT_NOT_OPEN`（本机无服务端，会话不就绪，条码框禁用，符合预期） |
| 旧版 ×10、新版 ×10 | 全部 `0x41301`、全部找到车载端窗口、全部 `INPUT_NOT_OPEN`；模拟器与车载端全部存活 |
| `lastRunTime` | 21 次都落在启动调用之后 1～5 秒，读到的都是本次启动。现场 `18:03:03`（早于启动约 45 秒）在本机没有重现 |

## 局限

- 探针 `entryWindowVisible` 对新旧两版都报 `no-main-window`（两次为空），分不出「旧版有可见控制台、新版没有」：控制台窗口可能由 Windows Terminal／conhost 托管，不挂在 pwsh 进程上。所以「隐藏后不再有可见窗口」**没有得到实证**，只实证了「隐藏后 UIA 仍可用」。
- 本机是 RDP 会话、无服务端、条码框始终禁用，与车上（console 会话、真实会话就绪）不同；现场那次的触发条件未知，21 次不复现不能排除它。
