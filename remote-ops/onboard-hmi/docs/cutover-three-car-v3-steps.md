# 切换试跑：三车上 v3 车载端的步骤表（cs#565）

本文是 [control-server#565](https://github.com/trytoreachpeak0/8005-agv-control-server/issues/565)（切换-04）的交付物：三台车
（`agv01`、`agv02`、`agv03`）各自从现状走到「v3 车载端已部署、连上 v2 切换实例、握手 `Ready`、不动车」要做的每一步。
**本文只是准备，写的时候没有 ssh 任何一台车、没有部署、没有碰 `agv01`、MVP 或生产 MesIngest。**执行时由调度排时间，
逐步向用户要授权。

编排以切换方案为准：control-server PR #677 分支上的 `docs/production-cutover-mode-plan.md`（下称「方案」），用户 10-13 已定 D1～D9。
车载端日志簿与发件箱的处理以 program#170 的数据方案为准（program PR #179，`docs/site-procedures/production-cutover-data-plan.md`，下称「数据方案」）第 3 节，回滚的数据部分以它第 4 节为准，本文不另写一套，只把它落成每车的命令。
本文只展开方案第 6 节第 2～16a 步里**与车有关的那一半**；服务端那一半（19 号装定义、换库、归属表、闸门）照方案执行，这里只标出车要卡在哪一步之前或之后。

写作时读到的版本：`8005-workspace@84ba0b4`（`origin/main`）、workspace PR #41 head `e0cd1823`（未合入）、control-server `fp/v2-impl@4d7e0e07`、
onboard-hmi `w2g/fp-v2-impl@5c00a513`、slots-simulator `main@fb5f7c59`。「读到的」指在这些版本上实读的代码与证据；「推的」指没有实测的推论。

## 0. 先说结论

- **三台车走同一套六步**（票面 1～6 条）：只读记录现状 → 停栈后用 `19-archive-onboard-journal.ps1` 查发件箱欠送与 `loadsOnBoard`、都为零才把日志簿整目录改名留存（数据方案第 3 节）→ 部署 v3 车载端 → 新库里为这台车 `bind-io`、
  把它加进充电与等待点的车队范围 → 试跑段不做逐仓核对（模拟 IO）→ 起栈看握手 `Ready`，不开闸、不动车。
- **三台车上场的时点不同**（方案 D4=a、D5=agv02）：
  - `agv02`：S1，切换首装之后马上做。它已经在 v2 上跑了几天，是改动最小的一台。
  - `agv01`：S2 之前做。它从没跑过 v2，步骤最多，**每一步都碰 `agv01`，都要用户授权**。
  - `agv03`：切换一开始就停到 v2 不管的点位、停掉车载端栈，S3 之前再上。
- **有两处方案原文要改**（已报调度，见第 7 节；数据方案第 3.3 节已按同样的结论写）：方案第 6 节第 5 步说 `C:\8005\OnboardHmi` 的备份「含日志簿、发件箱」，实际日志簿与发件箱在
  `C:\Users\HT\AppData\Local\SQCD\8005AGV\onboard-journal.db`，不在安装目录里，要单独备份；`agv02`／`agv03` 的发件箱必须在 v2 换新库**之前**核，
  换库之后再核就只能看着欠送的行被新库当历史吞掉。
- **执行前还缺的东西**列在第 6 节「待填项」：出包的 run id、`agv01` 当前装的版本串、`agv03` 停在哪个点、`agv01` 有没有装仓位模拟器、
  仓位应答脚本 `cs566-sim-respond.ps1` 的源头（它不在任何仓库里，只在 `agv02`／`agv03` 车上）。

## 1. 约定

| 记号 | 含义 |
| --- | --- |
| `<WT>` | 当天为现场新开的 `8005-workspace` worktree，停在 `origin/main` 最新提交（**必须已含 workspace PR #41**）。例如 `F:/8005-wt/cutover-field-8005-workspace`。不要用 `C:\Users\szy\Desktop\8005-workspace` 主目录那份（记忆「现场脚本从专用 worktree 跑」） |
| `<EV>` | 本次证据目录，按方案与票面：`evidence/field/20261013-W3-S0-<车>/`（控制端本地，收工后精简入库） |
| `<RUN>` | 切换包的 release run id（第 2 节 P2） |
| `<D>` | 当天日期 `20261013` |
| 【只读】 | 只读，不改任何东西 |
| 【问用户·agv01】 | 碰 `agv01`（含只读探测），工作区「Ask first」第 2 类，执行前要用户对这一步的授权 |
| 【问用户·动车】 | 会让车动、或让车接上会动它的服务端，「Ask first」第 1 类，逐次授权、现场有人 |
| 【调度】 | 不碰车也不碰生产，调度直接做 |

FieldOps（服务端的现场运维命令行，`ControlServer.FieldOps.exe`）在 factory01 上这样调（与 10-11 两车段证据
`evidence/field/20261011-W2-prep6-two-car/14-fieldops-imports-two-car.txt` 同一形式，`--fleet` 用分号分隔 vehicleKey）：

```powershell
# 在 factory01 上（ssh factory01 后进 pwsh）
$f  = 'D:\zhengyushao\control-server-v2-ops\fieldops-<切换包的提交前 8 位>\ControlServer.FieldOps.exe'
$db = 'C:\ProgramData\8005\ControlServer.V2\data\controlserver.db'
```

**日志簿检查与归档**统一用 `remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1`（本 PR 新增，数据方案第 7 节 G3）：
要求车载端与模拟器都已停；把 `onboard-journal.db` 及 `-wal`／`-shm` 拷到证据目录、在控制端读副本；欠送（`Acknowledged=0` 且 `AbandonedReasonCode` 为空）不为 0
或 `loadsOnBoard` 不为空就拒绝（退出码 1，不改名）；通过后把整个 `8005AGV` 目录改名为 `8005AGV.<Suffix>` 并回读；证据写 `journal-check.json`。
`-CheckOnly` 只查不改名。离线自检 `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1 -SelfTest`（7 条，含两条变异验证过会变红）。
**ssh 那一半没有在车上跑过**，第一次用先带 `-CheckOnly`。

三台车的 vehicleKey 与 agvId（`remote-ops/fleet.md`）：

| 车 | agvId | vehicleKey | RIoT id |
| --- | --- | --- | --- |
| `agv01` | `老厂前线新多仓位1` | `BROKERX-0c20ff0600d644869a6a80c186065d85` | 58 |
| `agv02` | `老厂前线新多仓位2` | `BROKERX-f38975561adf46ccb1d2f23833c7d0e4` | 59 |
| `agv03` | `老厂前线新多仓位3` | `BROKERX-7daca4ee91da498d8026c68b7b941127` | 60 |

## 2. 前置（调度，不碰车）

| # | 做什么 | 命令 | 授权 | 怎么算做成 |
| --- | --- | --- | --- | --- |
| P1 | workspace PR #41（车与线的单一字段 `controlServerLine`）合入 `main`，开 `<WT>` | `git -C C:/Users/szy/Desktop/8005-workspace fetch origin` 后 `git -C C:/Users/szy/Desktop/8005-workspace worktree add <WT> --detach origin/main` | 【调度】 | `<WT>` 下 `remote-ops/onboard-hmi/scripts/VehicleControlServerLine.psm1` 存在；`site-agv01.json` 里是 `"controlServerLine": "mvp"` |
| P2 | **出切换包**：一个包同时给 19 号（服务端）和 06 号（车载端）用。control-server 取方案第 7a 步那次提交（含 cs#564 第二步、cs#44 极性、cs#609 持货 5 分钟、各阶段定义）；车载端取 `w2g/fp-v2-impl` 当时的顶端，必须含 hmi#294 极性（`5c00a513` 或更新） | `git -C C:/Users/szy/Desktop/8005-workspace-v2/repos/8005-agv-onboard-hmi fetch origin`，`git -C ... rev-parse origin/w2g/fp-v2-impl` 取 40 位 SHA，`git -C ... merge-base --is-ancestor 5c00a513f976734b7e301cbc95cfc2360834e19b <SHA>` 必须成功；然后 `gh workflow run release.yml -R trytoreachpeak0/8005-agv-control-server --ref <7a 步的分支> -f onboard_commit=<40 位 SHA> -f onboard_branch=w2g/fp-v2-impl` | 【调度】 | run 成功；下载后 `release-manifest.json` 里 `components.onboardHmi.commit` 等于所选 SHA、`components.controlServer.commit` 等于 7a 步提交、`components.protocol.tag` 是 `protocol-v3.0.0`。run id 记为 `<RUN>` 写进 cs#565 |
| P3 | **`agv01` 的车辆安全凭据**：v2 多车实例要每台车一把自己的投影凭据，DPAPI 存储里现在只有 `agv02`、`agv03` 的 | `pwsh -File <WT>/remote-ops/factory-server/scripts/control-server/Set-ControlServerSecret.ps1 -NewVehicleSafetyCredential agv01` | 【调度】只写控制端本机的 DPAPI 文件，不碰车也不碰服务器；**本票没有执行，由调度安排在 S2 之前** | 输出 `generated OnboardSafetyCredential:BROKERX-0c20ff0600d644869a6a80c186065d85 (agv01)`。脚本从 `site-agv01.json` 的 `expectedVehicleKey` 取 key，已核对与 fleet.md 一致。已存在时它拒绝（`VEHICLE_SAFETY_CREDENTIAL_PRESENT`），不要随手加 `-Rotate` |
| P4 | FieldOps 用切换包同一提交发布到 factory01 的 `D:\zhengyushao\control-server-v2-ops\fieldops-<前 8 位>` | 与 10-11 相同（`evidence/field/20261011-W2-prep6-two-car/02-fieldops-build.txt`） | 【调度】 | 目录里 exe 的哈希与本地发布一致 |
| P5 | **仓位应答脚本入库**：试跑靠 `C:\8005\uia\cs566-sim-respond.ps1 -Mode Load/Unload` 代替人在仓前放货取货（记忆「模拟器 IO 下装卸要跑代现场脚本」）。它不在任何仓库里，只在 `agv02`／`agv03` 车上，`agv01` 没有 | 执行当天从 `agv02` 只读取回：`scp agv02:C:/8005/uia/cs566-sim-respond.ps1 <WT>/remote-ops/onboard-hmi/scripts/agv-sim-respond.ps1`，读一遍、提交进 `8005-workspace`，再推给 `agv01`（A-3d） | 【调度】读 `agv02` 不需授权；推给 `agv01` 属 A-3d | 文件进库、哈希记录 |

## 3. 总览：三车在各阶段做什么

纵向是时间（方案第 6 节的步号），横向是三台车。每格写本车在这一时点的步骤编号，详细内容在第 4 节。

| 时点（方案步号） | `agv01` | `agv02` | `agv03` |
| --- | --- | --- | --- |
| 切换前，MVP 还在跑 | A-1 只读记录现状【问用户·agv01】 | B-1 只读记录现状 | C-1 只读记录现状；C-0 挪到停放点【问用户·动车】 |
| 第 2～3 步：MVP 关闸、等 `agv01` 这趟 `Completed` | A-2a 停栈、`-CheckOnly` 查欠送与在载（对 MVP，MVP 停服之前）【问用户·agv01】 | — | — |
| 第 4～5 步：停 MVP、备份 | A-2b 备份安装目录与机器级变量；日志簿目录检查后改名留存【问用户·agv01】 | — | — |
| 第 6 步：用户在 RIoT 把 `agv01` 搬到 map 26 | （用户本人做） | — | — |
| 第 7 步之前：v2 旧库闸门关、无在途、仍在线 | — | B-2 停栈、检查后日志簿改名留存 | C-2 停栈、检查后日志簿改名留存，之后栈一直停到 S3 |
| 第 8 步：首装 S1（只有 `agv02`） | — | B-3 部署 v3；B-4 `bind-io` 等；B-6 起栈看 `Ready` | — |
| S1 开闸跑（方案第 16 步） | 停着，不在车队表 | 跑 | 停着，不在车队表 |
| 第 16a 步：S1→S2 | A-3 凭据、改线、模拟器、部署 v3；A-4；A-6【问用户·agv01】 | — | — |
| 第 16a 步：S2→S3 | — | — | C-3 部署 v3；C-4；C-6 |
| 第二段：试跑转生产（换新库 B） | 再走一遍 2（检查加改名，后缀 `pre-cutover-production-<日期>`，数据方案第 3.3 节末）、4、5、6，IO 切真模块 | 同左 | 同左 |

**为什么 `agv02`／`agv03` 的发件箱要在换库前核**（B-2、C-2；数据方案第 3.3 节同此）：发件箱里没确认的行，属于它当时连着的那份库。换库之后新库收到这些行不认识，
会回 ack、当历史记下（cs#481，记忆「车改连另一实例前先清发件箱」），车载端就把行删了，原来那份库永远收不到。所以要在旧库还在线时确认欠送为 0；
不是 0，就先起栈让它对旧库送完，再停。

**为什么 `agv03` 要在 S1、S2 期间停到 v2 不管的点位**：v2 判空闲车看的是车队表和旅程占用，不看车载端连没连（方案第 8 节）。S1、S2 的定义里没有 `agv03`，
它不会被派单；但它停在哪里 v2 不知道。它若停在等待点（214～216）、充电位（211、212）或某类任务的固定站（210、217～221）上，
v2 会把别的车派过去撞上它（推的，依据方案第 11 节第 3 条）。10-12 收工时它停在 214「等待点1」、电量 30%（看板 10-12 20:49），正好是 v2 管的点。

## 4. 每车步骤

每一步写：做什么、命令、授权、怎么验证、失败了怎么退回。命令里的 `ssh agvNN '...'` 外层用单引号，`$` 原样传到车上的 pwsh。

### agv02（S1，第一台）

| # | 做什么 | 命令 | 授权 | 怎么验证 | 失败退回 |
| --- | --- | --- | --- | --- | --- |
| B-1 | 记录现状：车载端版本、端口、IO 指向、进程、日志簿目录、时钟、机器级变量名 | 见下方「只读快照命令」，把别名换成 `agv02`，输出存 `<EV>/agv02/01-before.txt` | 【只读】不需问 | 输出里有 `onboardBuildCommit`、`port 58105`、`ioModule 127.0.0.1:1502`（模拟器）、`8005AGV` 目录 | 只读，无需退回 |
| B-2 | **换库前**（方案第 7 步之前，v2 旧库已关闸、无在途、仍在线）：停栈，检查欠送与在载，都为零就把日志簿整目录改名留存（数据方案第 3.3 节） | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv02 -Stop`；`pwsh -File <WT>/remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1 -SshAlias agv02 -Suffix pre-cutover-trial-20261013 -EvidencePath <EV>/agv02/journal` | 不需问（`agv02` 不在 MVP 上；v2 闸门关着） | 输出 `pending=0`、`loadsOnBoard=null` 或 `0`、`ARCHIVED to ...8005AGV.pre-cutover-trial-20261013`；`<EV>/agv02/journal/journal-check.json` 里 `renamed` 为 `true` | 拒绝 `JOURNAL_OUTBOX_PENDING`：旧库还在线，起栈 `10-start-onboard-stack.ps1 -SshAlias agv02` 让它送完，再停栈重跑。`JOURNAL_LOADS_ON_BOARD`：车载端认为车上有货，停下报调度。撤销改名：栈停着时 `ssh agv02 'Rename-Item C:\Users\HT\AppData\Local\SQCD\8005AGV.pre-cutover-trial-20261013 8005AGV'` |
| B-3 | 部署 v3 车载端（方案第 9 步）。前提：S1 定义已由 19 号装上（方案第 8 步），v2 已认识 `agv02` 的投影凭据。先干跑再真跑 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -SshAlias agv02 -OnboardPort 58105 -HealthPort 58107 -RunId <RUN> -KeepCurrentIo -WhatIf`，看完摘要去掉 `-WhatIf` 再跑一次 | 不需问。`-KeepCurrentIo` 让车留在模拟器上（`agv02` 现在是 `127.0.0.1:1502`）。**不要用 `-UseSiteIo`**，那是切真 IO，属「动车」类 | 输出 `OnboardHmi commit:` 等于 P2 的 SHA；`wireToGate endpoint read back: 172.19.205.222:58105`；`ioModule read back: 127.0.0.1:1502`；`vehicle-safety 200`，`vehicleKey` 是 `BROKERX-f389…`、`motionState` 是 `STOPPED`。看到 401 先读车上 `vehicleSafety.endpoint` 的端口（记忆「V2 车载端部署两个端口都要传」） | 放置脚本报错：安装目录没换成功时 06 以非零退出，旧版本仍在 `C:\8005\OnboardHmi` 或 `.previous`。要回到上一版：停栈后 `Rename-Item C:\8005\OnboardHmi OnboardHmi.failed-<D>; Rename-Item C:\8005\OnboardHmi.previous OnboardHmi` |
| B-4 | 新库里为 `agv02` 配置（方案第 10 步，与服务端导入一起做）：仓位模型（整库一次）、`bind-io`、充电策略与名册、等待点的车队范围 | factory01 上：`& $f seed-approved-facts --database $db`（整库一次）；`& $f bind-io --database $db --agv '老厂前线新多仓位2'`；充电策略、名册、等待点按 program#170 第 2 节导入，`--fleet` 写本阶段车队：`BROKERX-f38975561adf46ccb1d2f23833c7d0e4` | 不需问（对 v2 新库，不碰车） | `bind-io` 回 `"outcome":"OK"`、`boundSlots 8`；`& $f status --database $db` 里 `老厂前线新多仓位2` 的 `slotsMissingBinding` 为空；`& $f charging-policy --database $db --fleet <本阶段车队>` 里本车 `commissioned:true`。**试跑段 `status` 显示 `SLOT_CONFIGURATION_NEVER_VERIFIED` 是预期**，10-10、10-11 两轮试跑都是这样（模拟 IO 下不做逐仓核验，见第 5 步） | 导入是版本化的：错了就再导一版正确的，不改库表。换库后要重新激活任务类型站点绑定（记忆「v2 换库要连车载端日志簿一起清」） |
| B-5 | 逐仓核对 | 试跑段不做（方案第 5 节表：模拟 IO 下没有意义）。生产段见第 5 节 | — | — | — |
| B-6 | 起栈，看握手 `Ready`，**不开闸** | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv02` | 起栈本身不动车（闸门关着、v2 不建单）；开闸是方案第 16 步，另行【问用户·动车】 | factory01 上 V2 日志出现 `1103 SessionReadiness ... to "老厂前线新多仓位2" ... "READY"`（形式见 `evidence/field/20261011-W2-prep6-two-car/22-readiness-two-cars.txt`）；按 `evidence/field/20261010-W2-prep/18-precheck-after-onboard-start.txt` 的预检形式读一次：会话 `Readiness=Ready`、无未完成旅程、无故障 | 停在 `RecoveryRequired`：先看时钟（`07-fix-clock.ps1` 那一类问题）和投影 200 与否；`SNAPSHOT_REVISION_CONTENT_CONFLICT` 说明 B-2 没做或做在了起栈之后，停栈重做 B-2 |

### agv01（S2，第二台；每一步都碰 agv01）

`agv01` 今天跑的是现场线 `w2g/field-agv01-6b8a0b0`（顶端 `eec9364`，版本串形如 `0.2.0-safety-mock-travel+<commit>`），不是 `OnboardHmi_MVP`
（记忆「agv01 跑的是现场线不是 MVP 构建」）。它连 MVP 的 58005／58007、接真 IO 模块 `192.168.71.150:502`、车上可能没有仓位模拟器。
下表每一步都是【问用户·agv01】，授权不跨步。

| # | 做什么 | 命令 | 授权 | 怎么验证 | 失败退回 |
| --- | --- | --- | --- | --- | --- |
| A-1 | 记录现状（MVP 还在跑，只读） | 「只读快照命令」换成 `agv01`，存 `<EV>/agv01/01-before.txt` | 【问用户·agv01】只读探测也算 | 记下 `onboardBuildCommit`（回滚时要对上它）、`port 58005`、`ioModule 192.168.71.150:502`、`C:\8005` 下有没有 `SlotsSimulator`、时钟源与偏差、机器级 `CONTROL_SERVER_*` 变量名 | 只读 |
| A-2a | MVP 关闸、`agv01` 这趟 `Completed` 之后（方案第 2 步完成后）、**停 MVP 服务（方案第 4 步）之前**：停栈，只查不改名。有欠送就得趁 MVP 还在线让它送完 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv01 -Stop`（hook `onboard-target-guard.ps1` 会弹确认，正常）；`pwsh -File <WT>/remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1 -SshAlias agv01 -Suffix pre-cutover-trial-20261013 -EvidencePath <EV>/agv01/journal-check -CheckOnly` | 【问用户·agv01】（数据方案第 5 节 R2） | `CHECK OK`、`pending=0`；现场线的日志簿没有 `loadsOnBoard` 字段，读作空；这一项也是方案第 3 步「三处为 0」的第三处 | 拒绝 `JOURNAL_OUTBOX_PENDING`：MVP 还没停，起栈（`10-start-onboard-stack.ps1 -SshAlias agv01 -NoSimulator`，【问用户·agv01】）让它送完，再停栈重查。MVP 已停而仍有欠送：停下报调度，不改名、不部署 |
| A-2b | 备份（方案第 5 步的**修正版**，数据方案第 3.3 节第 5 条）：安装目录整份复制、记机器级变量的名字与值的哈希；日志簿目录用脚本检查后改名留存 | `ssh agv01 'if (Get-Process SQCD* -ErrorAction SilentlyContinue) { throw "client running" }; Copy-Item C:\8005\OnboardHmi C:\8005\OnboardHmi.pre-cutover-trial-20261013 -Recurse; Get-ChildItem C:\8005 \| Select-Object FullName,LastWriteTime; [Environment]::GetEnvironmentVariables("Machine").GetEnumerator() \| Where-Object Key -like "CONTROL_SERVER_*" \| ForEach-Object { "{0} sha256={1}" -f $_.Key, [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$_.Value))) }'`，存 `<EV>/agv01/02-backup.txt`；再 `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1 -SshAlias agv01 -Suffix pre-cutover-trial-20261013 -EvidencePath <EV>/agv01/journal` | 【问用户·agv01】 | `C:\8005\OnboardHmi.pre-cutover-trial-20261013` 存在、文件数等于原目录；脚本输出 `ARCHIVED to ...8005AGV.pre-cutover-trial-20261013`；每个 `CONTROL_SERVER_*` 变量有名字和值的 SHA-256（不记明文） | 复制失败：删掉不完整的副本重来；日志簿改名可随时改回（脚本输出里有撤销命令） |
| A-3a | 凭据：确认 P3 已做（DPAPI 里有 `agv01` 那把） | `pwsh -Command "(Import-Clixml $env:LOCALAPPDATA/AgvOpsSecrets/control-server-deployment.xml).Keys -match 'OnboardSafetyCredential'"` | 【调度】不碰车 | 列出 `OnboardSafetyCredential:BROKERX-0c20ff0600d644869a6a80c186065d85` | 没有就回 P3 |
| A-3b | **改线**：`site-agv01.json` 的 `controlServerLine` 由 `"mvp"` 改为 `"v2"`，在 `8005-workspace` 提交并推送，`<WT>` 拉到这一提交 | 改一行、`git commit -m "chore(remote-ops): agv01 改连 v2 切换实例（cs#565）"`、推送 | 【问用户·agv01】（方案第 9 步：改这个字段就是让 agv01 换线） | `<WT>` 里 `Read-VehicleControlServerLine` 对 `agv01` 返回 `v2`。不改的话 06 会以 `V2_PORTS_FOR_MVP_VEHICLE` 拒绝，这是 PR #41 的安全方向 | 改回 `"mvp"` 再提交（第 6 节回滚第 3 步） |
| A-3c | 19 号换装 S2 定义（方案第 16a 步，闸门关），让 v2 认识 `agv01` 与它的投影凭据。**建议放在 06 之前**，这样 06 部署后的投影探针能直接读到 200；方案 16a 原文是先部署车载端再换装定义，那样探针会是 401（06 只打警告不失败），要在 19 之后从车上补读一次 | 照方案第 16a 步与 `wire-to-gate-parallel-cd.md` 第 14 节 | 方案第 16a 步已标【执行前问用户】 | `EFFECTIVE_CONFIGURATION` 车队是 `agv02`、`agv01` 两行 | 照方案 |
| A-3d | 装仓位模拟器（A-1 读到没有时）与仓位应答脚本 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/08-deploy-slots-simulator.ps1 -SshAlias agv01 -SourceRepository C:/Users/szy/Desktop/8005-workspace-v2/repos/slots-simulator`；`ssh agv01 'New-Item -ItemType Directory -Force C:\8005\uia'`；`scp <WT>/remote-ops/onboard-hmi/scripts/agv-sim-respond.ps1 agv01:C:/8005/uia/cs566-sim-respond.ps1` | 【问用户·agv01】 | 08 输出 `Source commit fb5f7c593742bf98bc3957b8729a38aad5321f28`（与 `agv03` 10-11 装的同一提交）和 `Installed to C:\8005\SlotsSimulator`；`C:\8005\uia\cs566-sim-respond.ps1` 哈希等于 P5 入库那份 | 删 `C:\8005\SlotsSimulator` 即撤销（不影响 MVP 车载端） |
| A-3e | 部署 v3 车载端。`agv01` 现在接真模块，06 不带开关会按站点文件渲染真模块（「真模块→站点值」那一行），**不切换 IO**；随后 A-3f 再切模拟器 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -SshAlias agv01 -OnboardPort 58105 -HealthPort 58107 -RunId <RUN> -WhatIf`，看完去掉 `-WhatIf` | 【问用户·agv01】 | 同 B-3：commit、`58105`、`vehicle-safety 200` 且 `vehicleKey` 是 `BROKERX-0c20…`；`IO target: REAL MODULE 192.168.71.150:502, from the site file; before: REAL MODULE ...`。**06 只放置不启动，所以这时车不会接上真 IO** | 06 会把旧版挪到 `C:\8005\OnboardHmi.previous`；A-2b 另有 `.mvp-field-20261013`，回滚用后者（第 6 节） |
| A-3f | IO 切到模拟器，**必须在起栈之前** | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/09-switch-io-module.ps1 -SshAlias agv01 -Simulator` | 【问用户·agv01】 | 输出 `Onboard IO target is now 127.0.0.1:1502`（形式见 `evidence/field/20261011-W2-prep6-two-car/10-agv03-io-to-simulator.txt`） | 备份在 `C:\8005\OnboardHmi\appsettings.json.bak-<时间>`；没切成就**不要起栈** |
| A-4 | 新库里为 `agv01` 配置：`bind-io`；充电、等待点的 `--fleet` 加上 `agv01`；S2 归属表照方案第 12～14 步 | `& $f bind-io --database $db --agv '老厂前线新多仓位1'`；`--fleet 'BROKERX-f38975561adf46ccb1d2f23833c7d0e4;BROKERX-0c20ff0600d644869a6a80c186065d85'` | 不碰车 | 同 B-4，看 `老厂前线新多仓位1`；`import-waiting-points` 的 `coverage.sufficient` 为 `true`（两台车至少要两个可分配等待点） | 同 B-4 |
| A-5 | 逐仓核对 | 试跑段不做 | — | — | — |
| A-6 | 起栈，看握手 `Ready`，不开闸 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv01` | 【问用户·agv01】 | 同 B-6，看 `老厂前线新多仓位1` 的 `READY`；车载屏上 IO 显示来自模拟器 | 停栈（`-Stop`），回第 6 节回滚，或留在 S1 不加车 |

试跑段 `agv01` 还要两样脚本支持，**本票不改，已报调度**：`16-enter-sublot-uia.ps1` 在 PR #41 之后按站点字段放行 `agv01`；
`17-capture-hmi-screen.ps1`、`18-read-hmi-screen-state.ps1` 仍然拒绝 `agv01`（方案第 6 节末尾，审查 M2），试跑要不要读 `agv01` 的屏，要单独决定。

### agv03（S1、S2 停着，S3 上）

`agv03` 10-11 已在 v2 上跑过两车实验，车载端是 v2 线、连 58105、IO 在模拟器。

| # | 做什么 | 命令 | 授权 | 怎么验证 | 失败退回 |
| --- | --- | --- | --- | --- | --- |
| C-1 | 记录现状 | 「只读快照命令」换成 `agv03`，存 `<EV>/agv03/01-before.txt` | 【只读】 | 同 B-1 | — |
| C-2 | **换库前**（与 B-2 同时，C-0 挪完之后）：停栈，检查后日志簿改名留存；之后栈一直停到 S3 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv03 -Stop`；`pwsh -File <WT>/remote-ops/onboard-hmi/scripts/19-archive-onboard-journal.ps1 -SshAlias agv03 -Suffix pre-cutover-trial-20261013 -EvidencePath <EV>/agv03/journal` | 不需问 | 同 B-2 | `JOURNAL_OUTBOX_PENDING`：`agv03` 不在旧库当前车队表里，未必送得出去。按数据方案第 6 节 U6 等用户定（建议是行内容已在证据副本里，改名留存、不再送）；脚本没有绕过开关，用户定了再手动改名。其余同 B-2 |
| C-0 | 挪到停放点（v2 不管的点，见第 7 节待填项 F2），挪完再做 C-2 | 由用户或现场在 RIoT 上下发移动；`agv03` 电量低时先充电（10-12 收工时 30%） | 【问用户·动车】移动是动车 | RIoT 读回 `agv03` 在 map 26、站点等于选定的点、`MT_FINISHED` | 停不到位就停在原处，报调度；**不要在 v2 的等待点、充电位或任务固定站上开 S1 的闸** |
| C-3 | 部署 v3 车载端 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -SshAlias agv03 -OnboardPort 58105 -HealthPort 58107 -RunId <RUN> -KeepCurrentIo -WhatIf`，再去掉 `-WhatIf` | 不需问 | 同 B-3，`vehicleKey` 是 `BROKERX-7dac…`、`ioModule read back: 127.0.0.1:1502` | 同 B-3 |
| C-4 | `bind-io`；`--fleet` 三车；S3 合并归属表照方案第 12～14 步 | `& $f bind-io --database $db --agv '老厂前线新多仓位3'`；`--fleet` 三个 key 分号分隔 | 不碰车 | 同 B-4；等待点 `coverage.sufficient` 为 `true`（三车需三个等待点，map 26 现有 214～216 三个） | 同 B-4 |
| C-5 | 逐仓核对 | 试跑段不做 | — | — | — |
| C-6 | 起栈，看 `Ready`，不开闸 | `10-start-onboard-stack.ps1 -SshAlias agv03` | 起栈不动车；从停放点开出来是 S3 开闸，另行【问用户·动车】 | 同 B-6 | 同 B-6 |

### 共用命令

**只读快照命令**（以 `agv02` 为例；本地单引号，`$` 原样传给车上 pwsh）：

```powershell
ssh agv02 '$c = Get-Content -Raw C:\8005\OnboardHmi\appsettings.json | ConvertFrom-Json; "time " + (Get-Date -Format o); Get-ChildItem C:\8005 | Select-Object Name,LastWriteTime; "wireToGate " + ($c.wireToGate | Select-Object host,port,onboardInstanceId,onboardBuildCommit,recoveryResumeEnabled | ConvertTo-Json -Compress); "ioModule " + $c.ioModule.host + ":" + $c.ioModule.port; "vehicleSafety " + $c.vehicleSafety.endpoint; Get-Process SQCD* -ErrorAction SilentlyContinue | Select-Object Name,Id,SessionId; Get-ChildItem C:\Users\HT\AppData\Local\SQCD -Force | Select-Object Name,LastWriteTime; Get-ChildItem C:\Users\HT\AppData\Local\SQCD\8005AGV -Filter "onboard-journal.db*" | Select-Object Name,Length,LastWriteTime; w32tm /query /status | Select-String "Source|Last Successful"; [Environment]::GetEnvironmentVariables("Machine").Keys | Where-Object { $_ -like "CONTROL_SERVER_*" }'
```

时钟源若不是 `172.19.205.222`、或偏差大于几秒，先跑 `07-fix-clock.ps1`（fleet.md 第 2 条：断电会复发，投影 5 秒窗口会让会话出不了 `RecoveryRequired`）。

**日志簿检查**用第 1 节的 `19-archive-onboard-journal.ps1`。它查的三项与数据方案第 3.2 节的三条查询相同，另把发件箱分组、`pendingResults` 条数、
日志簿纪元与已应用快照的修订号写进 `journal-check.json`。四张表 `WireToGateDurableOutbox`、`WireToGateRecoveryState`、`WireToGateAppliedJourneySnapshots`、
`WireToGateJournalMetadata` 在现场线 `eec9364` 与 `w2g/fp-v2-impl` 上同名同形（读到的），所以 `agv01` 也用它。

## 5. 生产段（试跑转生产）每车要补的

方案第 17～22 步。v2 换新库 B，三车**再走一遍** 2（`19-archive-onboard-journal.ps1 -Suffix pre-cutover-production-<日期>`，在方案第 17 步关闸之后、第 18 步换库之前）、4（新库里 `bind-io` 等）、6（`Ready`），另加两件：

1. **IO 切回真模块**：`pwsh -File <WT>/remote-ops/onboard-hmi/scripts/09-switch-io-module.ps1 -SshAlias <车> -RealModule`。【问用户·动车】，每台车单独授权、现场有人（方案第 20 步）。
2. **逐仓核对**（票面第 5 条，`REQ-0263`）：在真 IO 下逐仓开锁、放物、关门，现场填一份核对记录，`& $f verify --database $db --record <记录.json>` 写进库，
   `& $f status --database $db` 里该车 `slotsMissingVerification` 为空、`ready:true`。**不能拿旧库或试跑库的记录导进来**，那正是票面定义的失败。
   证据进 `evidence/field/<日期>-W3-S0-<车>/`。核对时开锁属于动车类，【问用户·动车】。逐仓核对的具体操作单不在本票范围，C-05 与调度对齐后另写。

## 6. 回滚

### 6.1 单步失败

见每一步的「失败退回」列。原则：日志簿目录、安装目录都是改名留存，不删；FieldOps 导入错了导下一版，不改库表。

### 6.2 `agv01` 换回 MVP 现场线（方案第 7 节回滚第 2、3 步与数据方案第 4 节第 2 条的展开）

全部【问用户·agv01】。前提：v2 已关闸、`agv01` 无在途（方案回滚第 1 步）。

| # | 做什么 | 命令 | 怎么验证 |
| --- | --- | --- | --- |
| R1 | 停 `agv01` 的栈 | `pwsh -File <WT>/remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1 -SshAlias agv01 -Stop` | 没有 `SQCD*` 进程 |
| R2 | v3 那份日志簿改名留存（它属于 v2 的库，是试跑证据） | `ssh agv01 'Rename-Item C:\Users\HT\AppData\Local\SQCD\8005AGV 8005AGV.v2-trial-20261013; Rename-Item C:\Users\HT\AppData\Local\SQCD\8005AGV.pre-cutover-trial-20261013 8005AGV'` | `8005AGV` 的 `onboard-journal.db` 修改时间等于 A-2b 时记录的 |
| R3 | 安装目录换回 | `ssh agv01 'Rename-Item C:\8005\OnboardHmi OnboardHmi.v2-trial-20261013; Rename-Item C:\8005\OnboardHmi.pre-cutover-trial-20261013 OnboardHmi; (Get-Content -Raw C:\8005\OnboardHmi\appsettings.json \| ConvertFrom-Json).wireToGate \| Select-Object host,port,onboardBuildCommit'` | `onboardBuildCommit` 等于 A-1 记录的版本；`port 58005`；`ioModule` 是 `192.168.71.150:502`（这份配置本来就连 MVP、接真模块，不重新渲染） |
| R4 | 机器级变量对回 | 读 `CONTROL_SERVER_*` 名字与值的 SHA-256（A-2b 那条命令的后半） | 与 A-2b 记录逐项相同。06 写过三项：`CONTROL_SERVER_ONBOARD_CREDENTIAL`、`CONTROL_SERVER_OPERATOR_ID`（与 MVP 共用的同一个值，推的：两者都取自同一个 DPAPI 存储键）、`CONTROL_SERVER_ONBOARD_SAFETY_CREDENTIAL`（只有 v2 模板读，MVP 模板不读）。前两项不一致就照方案回滚要用户处理，不要猜值 |
| R5 | 站点字段改回 | `site-agv01.json` 的 `controlServerLine` 改回 `"mvp"`，提交推送（方案回滚第 3 步） | `Read-VehicleControlServerLine` 对 `agv01` 返回 `mvp` |
| R6 | RIoT 搬回 map 25、MVP 换回并启动 | 方案回滚第 4～6 步（用户本人在 RIoT 操作；MVP 由调度按方案） | 方案回滚第 7 步：MVP 健康、`agv01` 握手 |
| R7 | 起 `agv01` 的栈（MVP 线，真 IO） | `10-start-onboard-stack.ps1 -SshAlias agv01 -NoSimulator` | 方案回滚第 7 步 |

**备份坏了的退路**（只在 R3 读到的版本对不上时用）：现场线构建能从源码重出。现场线 `origin/w2g/field-agv01-6b8a0b0` 的顶端 `eec9364`
（A-1 读到的版本若不是它，用读到的那个），用 MVP 线的 release 出包：
`gh workflow run release.yml -R trytoreachpeak0/8005-agv-control-server --ref ControlServer_MVP -f onboard_commit=<A-1 读到的 40 位 SHA> -f onboard_branch=w2g/field-agv01-6b8a0b0`，
再 `06-deploy-onboard-hmi.ps1 -SshAlias agv01 -OnboardPort 58005 -HealthPort 58007 -RunId <那次 run>`（R5 之后，站点字段已是 `mvp`）。
这条路**没有实测过**：现场线构建当初是本地出的，`ControlServer_MVP` 的 release 能不能出同一份、MVP 端那半要不要跟着换，执行前要调度先读一遍；
所以 A-2b 的整份复制是主路，这条只是备份坏掉时的退路。

### 6.3 `agv02`／`agv03` 回到切换前

两车切换前就连着 v2 并行实例，车载端也已经是 v2 线，所以**车载端版本不用换回**。要换的只有日志簿：它绑着切换期间的那份库。
v2 按方案回滚第 8 步「离开切换」时会换成空库，所以车这一侧是：停栈（`10-start-onboard-stack.ps1 -SshAlias <车> -Stop`）→ `19-archive-onboard-journal.ps1 -Suffix v2-trial-<D>`
（此时切换库还在线，欠送就先起栈送完） → v2 起服后再起栈。
切换前那份 `8005AGV.pre-cutover-trial-<D>` 属于切换前的旧库，旧库不回来就不要把它改回去，否则同样会撞 `SNAPSHOT_REVISION_CONTENT_CONFLICT`。

## 7. 待填项与执行前要定的事

| # | 项 | 现状 | 谁定 |
| --- | --- | --- | --- |
| F1 | `<RUN>`：切换包的 release run id | 要等方案第 7a 步的提交 | 调度（P2） |
| F2 | `agv03` 在 S1、S2 期间的停放点 | 推不出：要在 RIoT map 26 上选一个不是 210～221、不在 `agv02` 去 217 与 N 区通道上的点，方案第 11 节没有给 `agv03` 的建议 | 用户（现场看地图） |
| F3 | `agv01` 当前车载端版本串 | 记忆里是 09-20 的 `eec9364`，之后可能再部署过 | A-1 实读 |
| F4 | `agv01` 有没有 `C:\8005\SlotsSimulator` | 不知道 | A-1 实读，决定 A-3d 做不做 |
| F5 | 仓位应答脚本 `cs566-sim-respond.ps1` 的源头 | 不在任何仓库里，只在 `agv02`／`agv03` 车上 | 调度（P5） |
| F6 | `agv01` 的时钟 | 09-21 修过，断电会复发 | A-1 实读，必要时 `07-fix-clock.ps1` |
| F7 | 17、18 号读屏脚本对 `agv01` 的拒绝怎么处理 | 方案审查 M2 已提，未定 | 调度／用户 |
| F8 | `agv01` 的 `onboardInstanceId` | **不改**，沿用 `620ee2ce-cf8a-4429-8a0b-0c4098bcba7e`：规则是跨部署稳定，v2 新库从没见过它，不冲突 | 已定（本文） |

### 需授权步骤清单

- 【问用户·agv01】：A-1、A-2a、A-2b、A-3b、A-3d、A-3e、A-3f、A-6；回滚 R1～R7。
- 【问用户·动车】：C-0（`agv03` 挪到停放点）；各阶段开闸（方案第 16 步）；生产段 IO 切真模块与逐仓核对。
- 方案里已标、本文照引的：A-3c（19 号换装 S2 定义）。
- 不需问：`agv02`、`agv03` 的只读快照、停栈、日志簿检查与改名（`19-archive-onboard-journal.ps1`）、部署（模拟 IO、闸门关）、FieldOps 导入、起栈看 `Ready`。

### 对方案的两处修正（已报调度）

1. 方案第 6 节第 5 步与第 7 节备份表说 `C:\8005\OnboardHmi` 整份另存「含日志簿、发件箱」。读到的：日志簿与发件箱在
   `C:\Users\HT\AppData\Local\SQCD\8005AGV\onboard-journal.db`（`journalPath` 默认值，现场线与 v2 线相同），日志也在那个目录下。
   只备份安装目录的话，回滚时 `agv01` 的日志簿已经被 v2 那份覆盖。本文 A-2b、R2 已单独处理。
2. 方案第 9 步写「先确认发件箱无欠送再清日志簿与发件箱」放在换库之后。对 `agv02`／`agv03`，换库后再确认已经晚了（理由见第 3 节），本文挪到 B-2、C-2，换库之前做。
