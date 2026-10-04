# 并行期：v2 在 factory01 上的第二套部署

约 2026-10-08 起，`factory01` 上同时跑两套 ControlServer：

- **MVP 那一套**（`ControlServer_MVP`／`protocol-v0.3.0`）继续驱动 `agv01`，服务真实客户，
  取真实需求。它由 [wire-to-gate-cd.md](wire-to-gate-cd.md) 管，本文档**不碰它一个字节**。
- **v2 这一套**（`fp/v2-impl`／`protocol-v2.0.0`）驱动 `agv02`／`agv03`，**只吃注入的测试
  需求**，直到约 10-15 切换那天才接真实需求、同时停掉 MVP。

本文档讲第二套：装在哪、占哪些端口、怎么起、怎么退，以及它凭什么不会碰到第一套。

**机制已就绪，第一次真实安装尚未发生。** 见最后一节。

生效日期 2026-09-21（control-server#262）。

---

## 1. 三十秒版

```bash
# 干跑：把要做的事全算一遍，在碰服务器之前停下
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <control-server 的干净 checkout> -WhatIf
```

```bash
# 真装（需要用户单独授权那一次）
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <同上>
```

```bash
# 退回上一代
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <同上> -Rollback
```

```bash
# 升级或回滚前先关派车闸门（需要用户单独授权那一次；加 -WhatIf 是只读的预演）
pwsh -File remote-ops/factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1 `
  -State Closed -ControlServerRepository <同上>
```

```bash
# 整套拿掉（默认保留数据；首次安装半路失败时也用它）
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <同上> -Uninstall
```

**真装之前先看第 11 节**：装完服务就处在 `-Intake` 状态（接真实数据、做真实决策、不动车）；
而且出厂的实例定义**故意过不了校验**——两个 map 26 的值还是 `REPLACE_*` 占位，第一步要从现场取回（第 9 节）。

MVP 那一套用的是 `15-deploy-control-server.ps1`，**两条命令永远不会互相走错**：MVP 的脚本
不认识并行实例，并行的脚本在读到 MVP 的服务名、安装目录、端口或车号时**直接拒绝**，见第 6 节。

---

## 2. 为什么是"第二套"而不是"同一套脚本加几个参数"

产品安装脚本（`Install-ControlServerLocal.ps1`、`Update-ControlServerLocal.ps1`）本来就把
服务名、安装根、数据根、备份根、端口、绑定地址全部做成了参数——它们的注释写明这是为了
"能在隔离实例上完整演练升级路径"。**所以产品脚本一行未改**，第二套只是用不同的参数调它们。

变的是**编排层**。原本可以给 `15-deploy-control-server.ps1` 加几个参数了事，没有这么做，
理由只有一条：**那几个参数正好是决定一次失误会不会落在生产部署上的参数**。分成两条命令
之后，MVP 的命令装不了并行实例，并行的命令装不到 MVP 头上——后半句还额外由配置校验兜着。

```
  8005-agv-control-server 的 release.yml（手动触发，传车载端 commit 与分支 w2g/fp-v2-impl）
          ▼
  GitHub artifact（一个 zip + sha256 + release-manifest.json）
          │  gh run download
          ▼
  控制端 ──验 SHA-256──┬─▶ 校验实例定义（拒绝才停在这里，机器还没被碰）
                       ├─▶ 本地 publish FakeMesIngest（self-contained）
                       └─▶ scp ─▶ factory01 ─▶ Install-ParallelInstanceLocal.ps1
                                     ├─ 记录 MVP 服务指纹（事前）
                                     ├─ 调产品脚本，全套隔离参数
                                     ├─ 把 v2 专属配置叠加进 appsettings.Production.json
                                     ├─ 部署 FakeMesIngest，注册计划任务
                                     ├─ 防火墙（规则名带 V2）
                                     └─ 再记一次 MVP 指纹，不一致就报错
```

**runner 仍然不部署。** `win11-01` 是 `factory01` 的 Hyper-V 客户机，宿主就在
`192.168.200.1`，让 runner 直连是最短的路，但那等于把一把能进生产服务器的管理员钥匙放在
CI 上——任何能改那个仓 workflow 的路径最终都能碰到 `AgvAmhs`、`AGV.Web` 和 `SQAGV`。理由
与 MVP 那套、与 [mes-ingest-cd.md](mes-ingest-cd.md) 完全相同。

**编排脚本不进安装包。** `scripts/parallel/` 不在打包脚本的文件清单里（它只收四个具名的
产品脚本），所以包内容不变，发布验证不受影响。

---

## 3. 布局：端口、目录、服务名，全部定死

下表就是 `8005-agv-control-server` 的 `scripts/parallel/instance-factory01-v2.json`，**没有
一项留到"到时候再定"**。依据是 2026-09-21 对 `factory01` 的两次只读探测，证据在
`8005-agv-control-server` 的 `evidence/deploy/20260921-cs262-parallel-instance/`：

- `factory01-survey.txt`（08:56）：四个端口全部空闲，MVP 占 58005／58007，生产 MesIngest 占
  `0.0.0.0:5088`；
- `factory01-survey-paths.txt`（10:20，审查后补）：下表 V2 那一列的八个目录、服务名、计划任务名、
  两条防火墙规则**全部不存在**；四个端口仍空闲，且当时没有任何连接把它们当作本地端口占用。

第一次探测只看了端口没看目录，所以「目录不冲突」那一半当时并没有证据，第二次补上了。

| 项 | MVP（不要碰） | v2 并行实例 |
| --- | --- | --- |
| Windows 服务名 | `8005 AGV ControlServer` | `8005 AGV ControlServer V2` |
| 安装根 | `C:\Program Files\8005 AGV\ControlServer` | `C:\Program Files\8005 AGV\ControlServer.V2` |
| 数据根（SQLite + 日志） | `C:\ProgramData\8005\ControlServer` | `C:\ProgramData\8005\ControlServer.V2` |
| 升级备份根 | `C:\ProgramData\8005\ControlServer-backups` | `C:\ProgramData\8005\ControlServer.V2-backups` |
| 当前包 | `D:\zhengyushao\ControlServer` | `D:\zhengyushao\ControlServer.V2` |
| 上一代 | `…\ControlServer.previous` | `…\ControlServer.V2.previous` |
| 运维目录（结果 JSON、日志、种子） | `D:\zhengyushao\control-server-ops` | `D:\zhengyushao\control-server-v2-ops` |
| 暂存目录 | `D:\zhengyushao\control-server-staging` | `D:\zhengyushao\control-server-v2-staging` |
| 车载 NDJSON | `tcp://172.19.205.222:58005` | `tcp://172.19.205.222:58105` |
| 健康 + 车辆安全投影 | `http://172.19.205.222:58007` | `http://172.19.205.222:58107` |
| Dashboard | 58009（当前未安装） | **58109，预留，本票不装**（见下） |
| MES 需求来源 | `http://127.0.0.1:5088` 生产 MesIngest | `http://127.0.0.1:58188` FakeMesIngest |
| 防火墙规则名 | `8005 AGV ControlServer 5800x` | `8005 AGV ControlServer V2 5810x` |
| 驱动的车 | `agv01` | `agv02`（或 `agv03`） |

端口号用 `+100` 的偏移（`580xx` → `581xx`），是为了让运维在 `netstat` 里一眼分得清哪个是
哪个，而不是记住四个互不相干的数字。

**Dashboard：本部署不装，也不支持装。** 产品安装脚本能装它（`-DashboardPackagePath`），但它的
三个 dashboard 参数默认值——安装目录 `ControlServer.Dashboard`、计划任务名、端口 58009——**全是
MVP 的身份**，而端口那一项没有「已存在就拒绝」的兜底。本部署一个都不传，所以不会装；要装的话
得先把这三样都写进实例定义并显式传给产品脚本，那是另一次改动。实例定义里的 `dashboardPort`
（58109）目前**没有任何代码使用**，只是纳入了端口冲突检查，留着是为了那次改动不必再找一个
不冲突的号。另一个不装的理由是内存（见第 11 节）。

**两条与端口有关、容易误解的事实**：

- 四个端口（58105／58107／58109／58188）和 MVP 的 58005／58007 一样，都落在 Windows 的临时端口
  范围（49152–65535）内。上面「探测时空闲」**不保证下个月启动时仍空闲**——Windows 可能把它们分给
  某条出站连接。这是继承自 MVP 的风险，不是本票新造的，但监听端口从两个变成了四个。症状与排查见
  第 12 节。
- 实例定义里的端口与绑定地址**只在首次安装时生效**。升级沿用已装的 `appsettings.Production.json`
  （`Update-ControlServerLocal.ps1` 的既有行为），所以改了定义里的端口再升级，端口不会变；要换
  端口得卸载再装。`-WhatIf` 会打印定义里的端口，同时会提醒这一点。

**绑具体网卡 IP，不要 `0.0.0.0`。** 后者会连带把服务暴露到 Hyper-V 的 `AGV-Internal`
（`192.168.200.0/24`），而 CI runner 就住在那个网段上。这个坑 MVP 首跑时踩过一次；现在它
是一条会拒绝部署的检查，不只是一句叮嘱。

---

## 4. 四样共享资源，逐条

工作区 `CLAUDE.md` 的隔离表列了四样，下面是每一样在这套部署里的具体做法。

### 4.1 MES 需求——不接生产 MesIngest，全程吃注入的

两版默认都从 `127.0.0.1:5088` 取需求，**而一条需求被谁认领了，在另一边看来就是不存在**。
所以 v2 在整个并行期都只读 `tools/ControlServer.FakeMesIngest` 这个替身，真实需求要到约
10-15 切换当天才转给 v2、同时停掉 MVP。

怎么常驻见第 5 节。配置上由两道拦着：

- `mesIngest.baseUrl` 必须是**回环**地址，且**端口不能是 5088**；
- `fakeMesIngest.port` 必须与 `baseUrl` 里的端口一致（防止改了一处忘了另一处）。

### 4.2 端口与数据库——换端口、换库目录

见第 3 节的表。校验会拒绝：取 58005／58007／58009／5088 中任何一个、四个端口之间互相
撞车、安装根或数据根与 MVP 的路径相等**或互相嵌套**（嵌套也要拒：装在生产数据根**里面**
会在卸载时跟着被删，装在**外面**会把生产文件卷进这套实例的 ACL 收紧）。

数据库是各自的 SQLite，在各自的数据根下，安装期各自迁移。**两套都不碰 `SQAGV`。**

### 4.3 RIoT——车号在配置层面按 `deviceKey` 成对判定

两版连同一个 RIoT（`172.19.206.222:8888`），上面有 25 台可调度车。`JourneyRuntime` 只登记
一台车（`agvId` + `vehicleKey` 是单值不是列表）。

**判定方式是成对匹配，不是单字段白名单**，依据是 `remote-ops/fleet.md`：

| 别名 | `agvId`（RIoT `deviceName`） | `vehicleKey`（RIoT `deviceKey`） |
| --- | --- | --- |
| `agv02` | `老厂前线新多仓位2` | `BROKERX-f38975561adf46ccb1d2f23833c7d0e4` |
| `agv03` | `老厂前线新多仓位3` | `BROKERX-7daca4ee91da498d8026c68b7b941127` |

为什么要成对：`deviceName` 是人可改的，RIoT 也**不保证它唯一**，只查名字会放过一个被改过
名的车；只查 key 会放过一份人读起来指向另一台车的配置。而两者都查不到的那个状态——**改了
一半**——恰恰是最容易出现的（把 `agvId` 从 2 号改成 3 号，忘了改 key）。

白名单**硬编码在 `ParallelInstance.psm1` 里**，不从被校验的那份配置读。从配置读的白名单不
是白名单：改车的人同一次按键就把名单一起改了。

**多车名册 `Fleet` 整节拒绝。** `JourneyRuntimeOptions` 另有一个真在用的名册，服务端校验器只要求
它包含主车，不限制还包含谁，而上面这对检查从来不看名册里面。所以实例定义里出现 `fleet`（任何
大小写）直接拒绝——并行实例只驱动一台车。背景与「为什么不能只按名字拒绝」见第 6 节。

还有第二道锁，和车号无关：

- **`riotCreateDispatch.enabled` 必须显式写出来，而且默认只允许 `false`。** 这个开关决定
  这套实例会不会真的向 RIoT 下单，而下单会让车动。产品代码把它和 `JourneyRuntime` 分开正是
  为此——"启用运行时"本身不构成"授权下一张真单"。要把它打开，部署命令得额外带
  `-AllowRiotCreateDispatch`，**而那一次运行仍然要用户单独授权、现场有人盯着**。
- 不下单就没有在途单，没有在途单就不会走到急停那条路（`EmergencyStopSupervisor` 由在途单
  被报 FAILED 驱动）。

### 4.4 地图与通道——运行须知，不在代码里

`agv02`／`agv03` 与 `agv01` 在同一片现场通道里跑。（地图编号：MVP 与 `agv01` 在 RIoT map 25
（`老厂前线new`），v2 与备用车在 map 26（`老厂前线new_wk`）。这是用户 2026-09-21 的更正，工作区
`CLAUDE.md` 隔离表已随 `5e33113` 改过来，此前那里误记为「同在 map 26」。配置怎么写见第 9 节；这里只管
现场，而现场的通道不管地图编号是几都是共用的。）真要让 v2 驱动车跑起来时：

- 选 `agv01` **不经过的路段**；
- 选 `agv01` **空闲的时段**，避开演示与生产高峰；
- 避开 05:30 CST 前后（`8005-mes-ingest` 的夜间黄金渲染校验要占 `win11-01` 的桌面，虽然那是
  另一台机器，但同一个时间窗里没人看着这边）。

这一条按票面要求只写进运行须知，不在代码里做——路段和时段是现场判断，编码成规则只会在
现场变化时挡住正确的操作。

---

## 5. FakeMesIngest 怎么在一台生产服务器上连续跑一周

这是本票最需要说清楚的一件事，因为 **`ControlServer.FakeMesIngest` 今天是个开发期工具，
它的三个性质都不适合无人值守常驻**：

1. **它不是 Windows 服务。** 它是个控制台 ASP.NET Core 程序，没有 `UseWindowsService`。用
   `sc.exe` 注册成服务的话，服务控制管理器等不到它汇报"已启动"，会把它杀掉。
2. **它的需求目录在内存里。** 进程一重启目录就空了。而**"目录是空的"和"今天确实没活"在外
   部看起来一模一样**——没有报错、没有告警、看板上看不出区别。这和票面点名的那个 RouteGraph
   问题是同一种形状的失效。
3. **它默认拒绝在非回环地址上监听**（这一条是**优点**，必须保持）。

**结论：它不适合"就这么放那儿跑"，但适合"包一层"。** 我没有去改这个工具，包了一层，理由
是改它等于让一个测试替身长出生产特性，而需要的那三件事在外面做得到：

```
计划任务 "8005 AGV ControlServer V2 FakeMesIngest"
  ├─ 触发器：开机启动
  ├─ 账户：SYSTEM，最高权限，无时间限制
  ├─ 失败重启：3 次，每次间隔 1 分钟
  ├─ MultipleInstances: IgnoreNew（手动再点一次不会起第二个）
  └─ 动作：pwsh -File Start-FakeMesIngestResident.ps1
             ├─ 起替身（回环，显式传 listenAddress，不靠默认值）
             ├─ 轮询 /control/v1/health 直到 200（用 Invoke-WebRequest，不用 curl.exe）
             ├─ POST /control/v1/reset，拿到本轮的 runId
             ├─ 按种子文件逐条 PUT 需求
             ├─ 把目录读回来数一遍，和种子文件对不上就在日志里警告
             └─ Wait-Process —— 脚本活多久 = 替身活多久
```

**"脚本活多久 = 替身活多久"是这个方案成立的关键**，不是顺手写的。计划任务的重启策略作用
在它自己启动的那个进程上，也就是这个包装脚本。如果替身死了而包装脚本还活着，任务在 Windows
看来"仍在运行"，永远不会重启，机器上就只剩一个空壳。实测确认过：杀掉替身，包装脚本 2 秒内
退出，退出码非 0，端口释放（证据第三节）。

**种子文件是权威状态。** `D:\zhengyushao\control-server-v2-ops\fake-mes-ingest-seed.json`，
安装时创建成空目录（`{"demands": []}`）——**空是刻意的**，一个自带需求的替身会让"没有任何
需求被受理"这条断言无法成立。要灌测试需求就往这个文件里加，然后重启那个计划任务：

```bash
ssh factory01 "Stop-ScheduledTask -TaskName '8005 AGV ControlServer V2 FakeMesIngest'; Start-ScheduledTask -TaskName '8005 AGV ControlServer V2 FakeMesIngest'"
```

每次启动都先 `reset` 再照种子灌一遍，所以**重启之后目录一定回到种子文件描述的样子**，这
正是对上面第 2 条缺陷的解法。一条需求至少要给 `demandId`、`sublot`、`area`、`eqp`、
`package`；`area` 要填站点名里解析得出的区号（`N1-3_N1-7` 拆成 `N1-3` 与 `N1-7`，填 `N1` 会
判 `AREA_STATION_NOT_FOUND`）。

### 怎么停

```bash
# 停掉（不卸载）
ssh factory01 "Stop-ScheduledTask -TaskName '8005 AGV ControlServer V2 FakeMesIngest'"
# 彻底移除
ssh factory01 "Unregister-ScheduledTask -TaskName '8005 AGV ControlServer V2 FakeMesIngest' -Confirm:`$false"
```

停掉它之后 v2 实例读不到契约，会 fail-closed——不受理任何需求，不会去找别的需求来源。

### 会不会占端口撞上别人

不会。它绑 `127.0.0.1:58188`，2026-09-21 实测该端口在 `factory01` 上空闲，而且它**拒绝在
非回环地址上监听**（实测：传 `0.0.0.0` 时退出码 2，stderr 说明原因）。唯一的调用方是同机的
v2 实例。

### 三条这个方案的已知限制，写在这里免得以后当成故障

- **`-RestartCount 3` 意味着连续失败 3 次之后任务就不再重启了**（这是照搬 dashboard 的设置，
  不是本票新定的）。连续三次失败通常意味着环境问题，自动重启也修不好；日志在
  `D:\zhengyushao\control-server-v2-ops\logs\fake-mes-ingest.log`。
- **它是 self-contained 发布的，不随发布包走。** 版本对齐靠"从同一个 commit 构建"：
  `Publish-FakeMesIngest.ps1` 要求仓库干净并把 commit 记进 manifest。契约发现是逐字段比对
  的，两边不同源就会 `CONTRACT_VERSION_MISMATCH`，目录根本不会被读。
- **它不校验 Bearer token。** 凭据不是这个替身要证明的东西。所以别拿它去验 MesIngest 的认证
  行为。

---

## 6. 配置未表态就拒绝部署

调度 2026-09-20 定：`RouteGraph.Enabled` 的**代码默认值不改**（保持关闭），改的是部署——
**部署脚本读不到显式的 `RouteGraph` 配置就拒绝部署，不要静默用默认值**。

理由不是洁癖。途中追加在引擎关闭时**完全不工作，而且不工作的样子和"今天车比较忙"一模
一样**——没有报错、没有告警、看板上看不出区别。一个"继承了默认值所以关着"的环境，出问题
时根本没法查：你看不出这是设计如此还是有人忘了配。

所以实例定义里 `routeGraph` 必须有一个**明确表态**：

- `routeGraph` 必须是个对象。**空对象 `{}` 不算表态**——它看起来"配过了"，其实什么也没说。
- `routeGraph.enabled` 必须是 **JSON 布尔**。写成字符串 `"false"` 会被拒（.NET 配置能把它
  绑成布尔，正因如此它才危险：一处手误不会有任何东西报错）。
- `enabled` 为真时，`mapId` 必须是正整数，`runtimeRefreshPeriod`／`runtimeStateMaxAge`／
  `designStateTtl` 三个都必须写出来，而且后两个都要**大于**刷新周期（和产品自己的
  `RouteGraphOptionsValidator` 同构，放在部署期是为了在服务被停掉之前就报，而不是停完起不来）。

同一条规矩还管着另外两处：`riotCreateDispatch.enabled` 和 `journeyRuntime.enabled` 都必须
显式写出来，都必须是 JSON 布尔。

### 每一节只认白名单里的键，精确到大小写

实例定义的每一节（顶层、`mesIngest`、`fakeMesIngest`、`routeGraph`、`riotCreateDispatch`、
`journeyRuntime`）都有一份允许的键名清单，**清单之外的键一律拒绝，而不是原样透传**。

这一条是审查找到的洞逼出来的，而修的过程中又发现了第二个洞：

- **审查找到的**：`JourneyRuntimeOptions` 上有一个真在用的多车名册 `Fleet`，服务端自己的
  校验器只要求名册**包含**主车那一对，不限制**还能包含谁**。而之前的车号检查只读 `agvId`／
  `vehicleKey`，叠加又把 `journeyRuntime` 的全部键原样抄进配置——往定义里加一个 `fleet` 数组
  混进 agv01，校验全绿、叠加照抄、服务端也放行。今天不出事，是因为包里和定义里都恰好没有
  这一节；而批次 7 的多车工作正朝着用上它的方向走。
- **修的时候发现的**：读实例定义用的 `ConvertFrom-Json -AsHashtable` **区分大小写**，而 .NET
  配置**不区分**。所以只拒绝 `fleet` 不够——写成 `Fleet` 就绕过去了；更糟的是同时写
  `"agvId": "…仓位2"` 和 `"AgvId": "…仓位1"`，按名字读的检查只看得见前一个，配置系统却把两者
  当成同一个设置。**任何「按名字去读已知键」的检查都只能看见它想到的键**，拒绝它没想到的键
  才能把剩下的口子一起堵上。

所以现在是三种拒绝，各自说明怎么修：名册（整节拒绝，并行实例只驱动一台车）、已知键的大小写
变体（删掉重复的那个）、别的未知键（拼错了，或者产品新加的选项还没登记进白名单）。

`Fleet` 是**刻意**不进白名单的那一个。自测里有一条守卫：把白名单里 `journeyRuntime`／
`routeGraph`／`riotCreateDispatch` 的每个键拿去和对应 C# 选项类的属性逐个比对，C# 那边改名
的话这里会红，而不是让一个配置键悄悄绑不到任何东西上；同时断言 `Fleet` 在 C# 里存在、在白名单
里不存在。

还有一条组合检查：**`routeGraph.enabled` 为真而 `journeyRuntime.enabled` 为假会被拒**。路网
引擎只在 `JourneyRuntimeWorker` 的一轮迭代里刷新，运行时关着的话引擎一次都不会跑——那份配置
读起来是"引擎开着"，实际什么都不量。

### 反向验证

`scripts/parallel/Invoke-ReverseCheck.ps1`，在**真实文件**上做（不是内存副本），14 项全绿。
每个用例输出三样东西：blob 哈希改前改后（证明注入落到了文件上）、拒绝时列出的**全部**理由
（所以"是哪一项让它红的"是读出来的）、从字节备份还原后哈希回到基准。

证据在 `8005-agv-control-server` 的
`evidence/deploy/20260921-cs262-parallel-instance/`，`SUMMARY.md` 里有逐条的用例表。

顺带一提：这一轮反向验证抓出了我自己写的一个真 bug——`Assert-ParallelInstanceDefinition`
在定义**合法**时会抛 PowerShell 内部错误（空数组返回被 unwrap 成 `$null`，`.Count` 失败），
而部署脚本用的正是它。**合法的定义会装不上。** 当时的自测只测了被包装的那个函数，包装层
自己的失败模式没人看——只有在真实文件上跑"不注入、只重排格式"那条用例才暴露出来。

---

## 7. 配置叠加：为什么必须有这一层

产品安装脚本生成的 `appsettings.Production.json` 只写固定的几个键：`Health`、
`ConnectionStrings`、`OnboardTransport`、`OnboardSafetyProjection`、
`JourneyRuntime.enabled`、`Serilog`。别的一概不写。

**而 .NET 配置是逐键合并，不是整节替换。** 安装脚本写下
`JourneyRuntime = { enabled = false }` 只覆盖了 `enabled` 这一个键，`agvId`、`vehicleKey`
和其余所有键**仍然来自包里的 `appsettings.json`**——而那里写的是：

```json
"agvId": "老厂前线新多仓位1",
"vehicleKey": "BROKERX-0c20ff0600d644869a6a80c186065d85",
```

**那是 agv01，生产那台车。** 所以没有这层叠加，一个安装目录、端口、服务名全都干干净净隔离
开的实例，会指向生产车辆。

叠加由 `Install-ParallelInstanceLocal.ps1` 在产品脚本跑完之后做：读回那份 JSON，把
`MesIngest`、`JourneyRuntime`、`RouteGraph`、`RiotCreateDispatch` 四节合并上去，写回，重启
服务，**再读一遍并断言车辆身份与 MesIngest 来源确实是这套实例自己的**。合并丢了任何一个键
都会在这里报错，而不是留下一个"起得来、健康检查也过、开着真实需求驱动错车"的服务。

**2026-10-03 起（control-server#454）叠加的还有清桩出口要的两节**：`VehicleFaultRecovery`（Host 恢复与清桩入口的开关、
凭据变量名）和 `FieldOperatorRoles`（现场人员名单路径、车载端入口声明），回读核对也从三个键扩到叠加写的每一个值。在那之前
这两节只能装完手工合入，而首装会整份重写 `appsettings.Production.json`、重建服务的注册表 `Environment`，手工合入的东西被
静默冲掉，服务端只告警 2271/2272、充不上照旧 `ORDER_HANG`、车载端也不出清桩入口。详见第 7.1 节。

### 7.1 清桩出口的两节配置与恢复凭据

实例定义里必须显式写这两节，缺了就拒绝（出厂是第一阶段：入口关、未声明车载端入口）：

```json
"vehicleFaultRecovery": { "enabled": false },
"fieldOperatorRoles": {
  "path": "D:\\zhengyushao\\control-server-v2-ops\\field-operator-roles.json",
  "onboardClearanceEntryDeclared": false
}
```

- `fieldOperatorRoles.path` 必须在运维目录里：每次装包都会替换安装目录。文件不存在时安装脚本建一个空名单
  `{"operators":[]}`（服务端读作「没人有权限」，安全方向），已有的绝不覆盖。名单怎么填见 control-server#411 的模板。
- **凭据变量名不由定义给。**叠加固定写 `CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL`，定义里写
  `credentialEnvironmentVariable` 会被拒——免得并行实例指到 MVP 的变量。
- **凭据的值**存在控制端的 DPAPI 秘密存储里，键名 `V2FaultRecoveryCredential`，用
  `control-server/Set-ControlServerSecret.ps1` 录入，**与 MVP 的值分开**。这个键是**可选的**：录入时直接回车就跳过，MVP 操作员
  只来补 MVP 的键时不会被逼着编一个 v2 值——编出来的值会让下面「缺键就拒」那道检查形同虚设。已录入的要换，用
  `-Replace V2FaultRecoveryCredential`（回车保留原值）。`19-deploy` 有这个键就把它作为
  `faultRecoveryCredential` 放进 `deploy-config.json`；服务器端安装脚本把它写进**并行实例服务自己的**注册表 `Environment`，
  不写机器级、不进仓库。
- **控制端：**定义里 `vehicleFaultRecovery.enabled = true` 而秘密存储里**没有这个键**，`19-deploy` 在下载之前就拒绝——只看控制端
  存储，不看服务器上已有的那一条。
- **服务器端**取值顺序：`deploy-config.json` 里有就用它，没有就沿用服务里已有的那一条（在产品脚本运行**之前**读，因为首装会重建
  `Environment`）。**回滚没有 `deploy-config.json`，只沿用已有的。**入口开着而两处都没有，在停任何东西之前拒绝——服务端自己也会
  因为缺凭据拒绝启动，但那时旧服务已经停了。经 `19-deploy` 安装或升级时控制端那道检查在前，服务器端这一道主要管回滚和手工运行。
- 收工时安装脚本打一行 `CLEARANCE_EXIT_READINESS ...`：按服务端 `StationClearanceExit` 的规则，读生效配置、`Environment` 里的
  变量名（不读值）和名单文件。两节缺失、或入口开着却没有凭据，报 `CLEARANCE_EXIT_BROKEN`，安装算失败；出口不可用（第一阶段
  名单为空就是这样），打 `CLEARANCE_EXIT_UNAVAILABLE` 警告并列原因码，不算失败。它读的是服务将读的文件，不是运行中进程的
  判定——服务端没有对外暴露这个状态，只有自己日志里的 2271/2272。

---

## 8. 三处不显然的隔离细节

前两条是读产品脚本源码才发现的，都会在**第一次升级**时才咬人；第三条是审查发现的，**两套
部署时间窗一重叠就会咬人**。

**一、传 `-SkipMachineEnvironmentInjection`，不传 `-CopyUserRiotSecretToMachine`。**
机器级的 `CONTROL_SERVER_RIOT_CALL_API_KEY` 是 MVP 安装时设下的**共享资源**（实测存在，
166 字符）。并行实例只读它、不写它——服务自己的注册表 `Environment` 已经带了需要的值。另外
产品脚本在机器级的 key 与用户级的不一致时会直接 throw，覆写它等于这套部署伸手去改生产那套。

**用户级**的同名变量则两套都会写：产品安装脚本从用户级读 key，所以每次安装（不论哪一套）都
先把它写进用户级。今天两套用同一把 RIoT 密钥，写的是同一个值，所以无害；**哪天两套要用不同的
密钥，这里就会互相覆盖**，届时要改成装完还原。安装日志里那一句已经改成照实说「写进了用户级、
与 MVP 共用」，不再暗示用户级是本实例独占的。

`CONTROL_SERVER_ONBOARD_CREDENTIAL`（机器级，64 字符）同样是**读不写**。两套实例、三台车
共用同一个静态共享密钥，这是明文期的既有设计（`RELEASE-CANDIDATE.md` 11.1 节），不是这次
引入的。

**二、`-CertificatePasswordVariable` 必须传一个本实例专用的名字。**
`Update-ControlServerLocal.ps1` 会**删除**它被指向的那个机器级变量（明文期的遗留清理）。留
默认值 `CONTROL_SERVER_ONBOARD_CERTIFICATE_PASSWORD` 的话，**并行实例升级一次就把 MVP 的那个
删了**。这套部署传的是 `CONTROL_SERVER_V2_ONBOARD_CERTIFICATE_PASSWORD`，一个只有它用的名字
（实测目前两个都不存在，所以这段清理对两边都是空操作——但依赖"现在恰好不存在"不是隔离，
名字分开才是）。

**三、暂存目录的清理只认本实例自己的前缀。**
两套的包目录都在 `D:\zhengyushao` 下（`ControlServer` 与 `ControlServer.V2`）。安装脚本收工时
会清掉解包用的暂存目录，原来的写法是在包目录的**父目录**里删所有 `*.incoming-*`——这个通配符
不带实例前缀，所以 MVP 的 `ControlServer.incoming-<时间>` 和 V2 的 `ControlServer.V2.incoming-<时间>`
**互相都在对方的命中范围内**。两套部署时间窗重叠时，先收工的那条会把另一条正在解包的目录整个
删掉。

**而且这个 bug 是从 MVP 的脚本抄过来的**，在复制那一刻就存在了。两边一起改成
`"<包目录名>.incoming-*"`；自测里用临时目录重现了一遍：旧通配符两个都命中（证明夹具确实重现了
这个 bug），新通配符从两边各自只命中自己的。四个孪生脚本（MVP 的 `15-deploy-control-server.ps1`
与 `Install-ControlServerRemote.ps1`，并行的 `19-deploy-control-server-parallel.ps1` 与
`Install-ParallelInstanceLocal.ps1`）的头注释里都互相点了名：**改一边碰到机器层面的东西时，去看
另一边**。

安装脚本还会在**动手之前和收工之后各记一次 MVP 服务的指纹**（存在与否、状态、启动类型、
可执行路径、进程 id），对不上就报错。"我没碰它"是一句值得留下证据的话。**但指纹只比服务、不看
磁盘**——上面那个暂存目录的 bug 它就抓不到。磁盘这一侧靠的是路径校验与前缀化的清理。

---

## 9. 地图：v2 跑 map 26，出厂定义故意装不上

**用户 2026-09-21 答复：「MVP 是跑在 25 上面的，v2 是跑在 26 上的」。** 所以此前记录的「`appsettings.json`
写 25、工作区 `CLAUDE.md` 写 26」，是两条线用两张不同的图：`appsettings.json` 写的是 MVP 那条线的 25。
工作区 `CLAUDE.md` 那一行说「备用车与 `agv01` 同在 map 26」，其中 `agv01` 那半句是误记，已随 `5e33113` 更正。

实例定义现在这样写：

| 键 | 出厂值 | 出处 |
| --- | --- | --- |
| `routeGraph.mapId`、`journeyRuntime.mapId` | 26 | 用户答复 |
| `journeyRuntime.mapIdentity` | `老厂前线new_wk` | 真机证据 `evidence/field/2026-09-19-B6-map-name-baseline-check/real-riot/fields.json`（实读过） |
| `journeyRuntime.dispatchZone`／`allowedDispatchZones` | `REPLACE_WITH_MAP26_DISPATCH_ZONE` | **待现场取回**：形式可推（`MAP-26-WIRE_TO_GATE`），没人确认现场真这么叫 |
| `journeyRuntime.admissionPolicyDeploymentId` | `REPLACE_WITH_MAP26_ADMISSION_POLICY_DEPLOYMENT_ID` | **待现场取回**：无出处，尾巴那个日期是一次现场标定的产物 |
| 站点清单 `task-type-stations.settings.json`（在发布包里，不在定义里） | 一整份绑在 25 上 | **要出一份 26 版** |

`tests/` 里出现过 `MAP-26-*`，但那是测试自己编的假数据（同一文件里还有 `MAP-26-DIE-ATTACH` 这种我们
不做的作业类型），不能当出处。`src/` 里没有任何硬编码的 25，全部来自配置。

**两条检查把「在那之前不要装」从文档搬进了校验**（control-server#262 复审 M3）：

- 定义里任何字符串值还带 `REPLACE_`，拒绝。**所以出厂定义现在过不了校验，这是刻意的**——自测里有一条
  断言：出厂文件必须**恰好**因这三个占位被拒，不多不少。这和车载端部署拒绝没填完的站点文件是同一个做法。
- map 25、`老厂前线new`、任何 `MAP-25-*` 标识符，一律拒绝。以前文档里写着「按原样装会指向 MVP 那张图、
  校验拦不住」，那句话靠的是读文档的人；现在不靠了。

上一轮我选择让定义「暂时保持 25」、在文档里提醒。那个选择的问题是：25 对校验来说是一个合法的正整数，
**批准的人看到「校验全绿」会以为配置没问题，而那正是配置有问题、校验看不见的一种。**占位值反过来：校验
一定红，红的理由直接告诉你还差哪两个值。

**真装第一步怎么取值**：从 `factory01` 直查 RIoT（控制端到 RIoT 走 Clash TUN，探测结果不可信；
`factory01` 那边直连可达，`CONTROL_SERVER_RIOT_CALL_API_KEY` 在 User 与 Machine 两个作用域都有）。
`dispatchZone` 与准入策略部署号取回现场真实值，站点清单出一份 26 版。

校验里还有一条「`routeGraph.mapId` 与 `journeyRuntime.mapId` 必须相等」，改的时候不会只改一处。

---

## 10. 回滚与卸载

### 回滚：退回上一代

```bash
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <干净 checkout> -Rollback
```

形状与 MVP 那套相同：上一代原样留在 `D:\zhengyushao\ControlServer.V2.previous`，回滚是把两个
目录**对调**（不是复制），所以「回滚一次回滚」就是再跑一遍同一条命令。回滚之后会**重新叠加一次
配置**——升级会保留现有的 `appsettings.Production.json`，但回滚到一个比某个叠加键更早的代际
时，不重叠就会丢掉那个键。

**升级与回滚都会先把旅程运行时关掉（control-server#454）。**服务在的时候，两者都走产品的
`Update-ControlServerLocal.ps1`，而它的预检要求已装配置里 `JourneyRuntime.enabled` 为 false：它会用保留下来的配置拉起还没验证的
新版本做启动、存活检查、重启，运行时开着就会在这次检查里取需求、建单。并行实例装完即 `-Intake`（`enabled = true`），所以在这之前，
首装之后的每一次升级和回滚都会被这道预检拒掉（在停服务之前，机器没被动过）。现在的顺序是：

1. **派车闸门开着就拒绝**（`UPGRADE_REFUSED_DISPATCH_OPEN`）。已装配置里 `RiotCreateDispatch.enabled` 为真时车可能在途，停服务等于
   中途停掉运行时对它的故障监看。服务器端安装脚本在最开头查一次（记录定义、回滚对调目录、解包之前），停服务前再查一次。要升级
   或回滚，**先用 `20-set-control-server-parallel-dispatch-gate.ps1 -State Closed` 关闸门**（见下面「关、开派车闸门」）；
   脚本跑不了时才手工关，**按这个顺序**（拒绝消息里照抄了这几步）：
   1. 停止往 FakeMesIngest 注入新需求，等 `agv02`／`agv03` 的最后一张单都 `Completed`；
   2. 在 factory01 上编辑 **V2 的** `C:\Program Files\8005 AGV\ControlServer.V2\appsettings.Production.json`，把
      `RiotCreateDispatch.enabled` 改成 false。**不是 MVP 的 `C:\Program Files\8005 AGV\ControlServer\appsettings.Production.json`**——
      两者只差一个 `.V2`，改错了就是动了生产那套、而这套的闸门还开着。用能保持 UTF-8 的编辑器改；用记事本「另存为」可能换掉编码，
      把中文 `agvId` 存坏；
   3. 重启服务 **「8005 AGV ControlServer V2」**，不是 MVP 的「8005 AGV ControlServer」。

   只改了文件、没重启也会被拒（`CONFIGURATION_CHANGED_SINCE_START`）：开头检查比较已装配置的修改时间和服务进程的启动时间，文件更新
   就说明运行中的进程还按旧配置跑、闸门可能还开着。只有 Running 和 Stopped 两种状态才判断：服务正在启停（StartPending、StopPending、
   ContinuePending、PausePending）、Paused 或状态读不到时直接拒绝（`SERVICE_NOT_SETTLED`），提示稍后再试，不比时间——过渡状态下进程
   可能还没读完配置。服务是 Running 却读不到进程启动时间（`SERVICE_START_TIME_UNKNOWN`）或读不到文件修改时间时也拒绝。服务是
   Stopped 时不比时间。
2. 先停服务，再把文件里的开关置为 false，然后调升级脚本。升级的检查、备份、失败回退都停在 false。
3. 升级成功后叠加把定义里的值写回去，**包括派车闸门**：`RiotCreateDispatch.enabled` 恢复成实例定义里的值。出厂定义是 false，所以照常
   关着；定义里是 true（部署时带 `-AllowRiotCreateDispatch`）的话，升级成功后闸门会重新打开。手工关闸门只为放行这一次升级，不改定义。

所有拒绝——派车闸门、配置缺失或读不出、配置改后未重启、缺凭据、回滚没有 `<包目录>.previous\controlserver`——都在记录定义、回滚对调
目录、解包之前，拒绝消息里的「Nothing was stopped or changed」是真的。回滚还像安装一样检查产品脚本有没有写出结果文件。

升级失败时开关留在 false（安全方向），输出 `JOURNEY_RUNTIME_LEFT_DISABLED`，写明文件里的值和服务状态，实例此时不受理任何需求。
失败后服务的状态取决于升级脚本在哪一步失败：在它自己的预检里失败，服务停在我们停下的状态；预检之后再失败，升级脚本自己的回退会用
**旧二进制加 false** 把服务拉起来。**恢复办法是重新部署当前在跑的那个 commit（或修好的新包），不要用 `-Rollback` 来恢复开关**：
安装模式失败时代际对调还没发生，这时再跑 `-Rollback`，装上的是 `.previous`，也就是更早一代，车载端版本可能对不上。

回滚还会沿用服务里已有的恢复凭据（第 7.1 节）。

**车载端不会跟着回滚。** 两端不协商版本，版本错配的表现是连接被拒而不是一条说明原因的错误
（`RELEASE-CANDIDATE.md` 8.1 节）。`agv02`／`agv03` 上的车载端要一起退回去。

**首次安装没有上一代**，所以首次安装失败时的退路不是回滚，是下面的卸载。

### 关、开派车闸门（control-server#472）

```bash
# 先预演：只读，不复制、不停服务、不写文件；服务器上已有脚本时，打印旅程检查此刻的结论
pwsh -File remote-ops/factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1 `
  -State Closed -ControlServerRepository <干净 checkout> -WhatIf
```

```bash
# 真关（需要用户单独授权那一次）；升级成功后要重新开，就把 Closed 换成 Open
pwsh -File remote-ops/factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1 `
  -State Closed -ControlServerRepository <同上>
```

**真跑会停、启一个在线服务，只在用户为那一次授权之后运行**，通常就是紧接着一次已授权的 v2 升级或回滚之前。它不碰 MVP 的服务、
文件和数据库。控制端只做两件事：把 control-server 仓里的 `Set-ParallelDispatchGateLocal.ps1` 与它用的两个模块，复制到
`opsRoot\dispatch-gate\<commit>` 这个**按 commit 区分的子目录**，再 ssh 过去执行它，并告诉它定义在 `opsRoot\installed-instance.json`。
`-ControlServerRepository` 必须是干净的 checkout，否则直接拒绝，这样子目录名就能说明里面装的是哪个版本。

为什么不直接放进 `opsRoot`：`19-deploy-control-server-parallel.ps1` 把安装脚本、卸载脚本和这两个模块当成**一个整体**放在 `opsRoot`
里。要是 20 号用一个较新的 checkout 把模块覆盖进去，之后再跑 19 号的 `-Uninstall`，就成了旧卸载脚本配新模块；部署时清理秘密文件用的
也是服务器上那份模块。放进单独的子目录，20 号就永远不会改动 19 号部署的东西，19 号也不用为闸门做任何改动。代价是每用一个新 commit
跑一次，就多留一个小目录；它们随 `opsRoot` 一起删（`-Uninstall -RemoveData`）。

服务器端的步骤与拒绝（逻辑在 `ParallelHost.psm1` 的 `Invoke-ParallelDispatchGateChange`，自测在 `Test-ParallelInstance.ps1`）：

1. **只认 v2。** 服务名和路径都取自安装时记录的 `installed-instance.json`，经 `Get-ParallelInstanceLayout` 算出，定义先过安装时的
   同一道断言：MVP 的服务名、目录、端口一律拒绝。服务名是 MVP 的、或配置／数据库路径落在生产路径里，再拒一次（`GATE_REFUSED_PRODUCTION`）。
   没有 V2 服务就拒绝（`GATE_SERVICE_MISSING`）。
2. **安装脚本开头那几道检查原样复用**（`Get-ParallelPreInstallRefusal`）：配置缺失或读不出、服务在启停中、Running 却读不到进程
   启动时间、配置在进程启动之后被改过，都拒绝。闸门开着这一条在这里不算拒绝，因为关的就是它。
3. 已经是要的状态：什么都不碰，直接说明。
4. **读 v2 自己的 SQLite 库判断有没有车在跑单**，只读打开（`Mode=ReadOnly`），库路径取自已装配置的 `ConnectionStrings:ControlServer`，
   必须落在 v2 的数据目录里。不用看板接口，是因为实读过：`/api/dashboard/*` 每个接口都只返回在途旅程的一部分（等待中的、有阻塞原因的、
   装货阶段的），一辆正常行驶、没有阻塞原因的车在接口上看不见。
   - **关**：有任何一个旅程不是 `Completed`（`Blocked` 也算在途），就拒绝（`GATE_CLOSE_REFUSED_IN_FLIGHT`），提示先停注入、等车跑完。
   - **开**：只拒绝「单已经发给 RIoT、或可能已经发出」的旅程（`GATE_OPEN_REFUSED_ORDER_SENT`）。闸门关着时服务端建不了单
     （返回 `CreateDispatchDisabled`，什么也不写），这时存在的旅程都在等这道闸门；要是因为它们就拒绝开闸，就永远开不了，只能改库。
     「没发过」的判法照搬服务端自己的定义（`WireToGateStore.IsNeverSentAsync`）：`PENDING_RECONCILIATION` 且没有建单尝试、没有单号；
     或 `RESULT_UNKNOWN` 但只是因为建单前的查询都没回音。旅程的单包括它行上记的取货段、送门段，以及同一辆车在这个旅程创建之后
     建的所有单（后续停靠、重建、充电段的单不记在旅程行上）。
   - 库读不出、表缺失、时间读不出，**一律拒绝**（`GATE_STATE_UNREADABLE`）。
5. **停服务，再读一次**。这一次才作数：服务停了就不会再建单，读完到写之间不可能再冒出新单。这一次被拒，脚本会按原样把服务拉起来，
   拒绝消息以 `AFTER_STOP` 开头，写明「配置没改、服务停过一次」，并照实说服务拉起后是不是回到了 Running（没回到就点名它现在的状态）。
   服务本来就是 Stopped 的，脚本不碰它，拒绝消息也就没有 `AFTER_STOP` 前缀。
6. **写开关**：找节不区分大小写，写成 UTF-8 无 BOM；回读开关必须是写进去的布尔值，**其余每个值必须与写之前一模一样**，这一条就是
   中文 `agvId` 没被存坏的证明。写失败就把原文件逐字节放回、核对、拉起服务，报 `GATE_WRITE_FAILED`，闸门保持原状。
7. **启动服务**，要求它是 Running，且进程启动时间晚于文件修改时间（都按 UTC 比），否则报 `GATE_RESTART_UNVERIFIED`。服务本来是
   Stopped 的，就只写文件、不启动，下次启动时读到。

前后各取一次 MVP 服务的指纹，有任何变化就报错。

**已知限制。** 用这个脚本关的闸门，开的时候不会被挡：关的时候要求没有在途旅程，之后接的旅程都建不了单。要是闸门是绕过脚本、
在旅程跑到一半时手工关的，那个旅程已经发出过的单会挡住开闸。这是判不清时一律拒绝的结果，而且**不会自己解除**：闸门关着，那个旅程
就永远走不到 `Completed`。拒绝消息里写了出路，就是下面的手工开闸。

#### 手工开闸（只在脚本因 `GATE_OPEN_REFUSED_ORDER_SENT` 拒绝、且查清之后）

1. 到 RIoT 上确认拒绝消息里点名的车**没有在跑的单**。这一步是开闸前唯一能替代脚本判断的东西，不能跳过。
2. 在 factory01 上编辑 **V2 的** `C:\Program Files\8005 AGV\ControlServer.V2ppsettings.Production.json`，把
   `RiotCreateDispatch.enabled` 改成 true。**不是 MVP 的 `C:\Program Files\8005 AGV\ControlServerppsettings.Production.json`**；
   用能保持 UTF-8 的编辑器改，不要用记事本「另存为」，免得把中文 `agvId` 存坏。
3. 只重启服务 **「8005 AGV ControlServer V2」**，不碰 MVP 的「8005 AGV ControlServer」。

这三步同样是改动在线服务，要用户为那一次授权。开闸后，在等闸门的旅程会立刻建单，车会动。

### 卸载：一项一项拿掉

```bash
# 先干跑。它只读服务器、不写服务器，列出每一项要删和要留的，什么也不删
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <干净 checkout> -Uninstall -WhatIf
```

```bash
# 真卸载（默认保留数据）
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <干净 checkout> -Uninstall
```

产品卸载脚本 `Uninstall-ControlServerLocal.ps1` 只管服务、安装根和（可选）数据根。并行部署留下的其余
东西由 `Uninstall-ParallelInstanceLocal.ps1` 按下表逐项处理。**这张表是从 `Get-ParallelInstanceLayout`
推出来的，安装脚本的每一个路径和名字也从这同一个函数取**——自测会扫安装脚本，找任何绕开它直接读路径或
名字的写法（并先证明这个扫描能扫出故意埋进去的两处），所以「装了、但卸载不知道」的东西要么不存在，要么
会在自测里红。

| 项 | 默认 | 说明 |
| --- | --- | --- |
| 服务 `8005 AGV ControlServer V2` + 安装根 | 删 | 调产品卸载脚本。**第一个做，失败即中止全部**，见下 |
| 计划任务 `8005 AGV ControlServer V2 FakeMesIngest` | 删 | 连同它拉起、还占着端口的替身进程（只杀路径在 V2 替身目录下的） |
| 防火墙 `8005 AGV ControlServer V2 58105`／`58107` | 删 | MVP 那两条名字不同，不会被碰 |
| 机器级 `CONTROL_SERVER_V2_ONBOARD_CERTIFICATE_PASSWORD` | 删 | 本实例专用名字；脚本拒绝删 MVP 那个名字 |
| 替身目录 `…\ControlServer.V2.FakeMesIngest` | 删 | |
| 包 `D:\zhengyushao\ControlServer.V2` 与 `.previous` | 删 | |
| 残留的暂存目录 `ControlServer.V2.incoming-*`／`ControlServer.V2.rollback-*` | 删 | 进程被强杀时会留下；通配符带本实例前缀 |
| 暂存 `D:\zhengyushao\control-server-v2-staging` | 删 | |
| 数据根 `C:\ProgramData\8005\ControlServer.V2`（SQLite） | **留** | 带 `-RemoveData` 才删 |
| 升级备份 `…\ControlServer.V2-backups` | **留** | 同上 |
| 运维目录 `D:\zhengyushao\control-server-v2-ops`（结果、日志、种子、安装时的定义） | **留** | 同上。种子文件被校验要求必须放在这里面 |
| 用户级 `CONTROL_SERVER_RIOT_CALL_API_KEY` | **永远不删** | MVP 每次安装都读它，删了会让下一次 MVP 部署挂掉 |

#### 它按哪一份定义卸载

**安装时记下的那一份。** 安装脚本在动手之前就把它用的定义拷成运维目录里的 `installed-instance.json`
（首次安装半路失败时也有），卸载默认读它，找不到才退回 `instance.json`。控制端的 `-Uninstall`
**不往服务器拷任何东西**，干跑和真跑都一样，直接调服务器上上次安装留下的卸载脚本。

这是复审 M2 修的：第一版在询问 `-WhatIf` **之前**就把脚本和 `instance.json` 拷上服务器——`-Uninstall -WhatIf`
会写服务器（这张票上第二个「干跑开关失效」，第一个是那个粘连的 `return`），而且会**在卸载之前把安装时那份
定义覆盖成控制端现在这份**。定义在安装和卸载之间改过的话，卸载就会按新路径删、漏掉旧路径。

#### 什么情况下它会停——这一段是 S1 修出来的

复审找到过这张票最严重的一个缺陷：把定义里的路径写成正斜杠（`C:/Program Files/8005 AGV/ControlServer`）、
或者 `packageRoot` 写成 `D:\zhengyushao\ControlServer.previous`，**校验会通过，卸载的删除清单里会出现 MVP 的
安装根、生产 SQLite 所在的数据根、MVP 回滚要用的上一代包和生产 MesIngest 目录**。复审在自己机器上用假目录
实测过，`<根>\.\Prod`、`<根>\x\..\Prod` 这种写法 `Remove-Item` 真的会删掉 `Prod`。三个根因叠在一起：

1. **路径只做了字符串比较**，正斜杠、`.`、`..`、8.3 短名、`\\?\`、UNC 全被判成「不是生产路径」；
2. **生产路径清单不全**——漏掉的五个目录，就列在这张票自己的探测证据里；
3. **更强的护栏被更弱的盖过了。** 产品卸载脚本会先把路径规范化再比对，能认出正斜杠写法并抛
   `Refusing to uninstall the production deployment`。但第一版卸载脚本把这个异常当成普通失败捕获、继续往下，
   **接下来的目录循环照删不误**。内层那道护栏认出了危险、拒绝了；外层把拒绝当成一个可以跳过的错误，然后自己
   动手删了。两道护栏组合起来，比只有内层那一道更弱。

现在的做法，每一条都对着一个根因：

- **路径只认一种写法，再用白名单判归属。** 盘符开头、全反斜杠、没有空段、没有 `.`／`..`、没有 `~`、不是 UNC
  或 `\\?\`、每段不以点或空格结尾（Windows 会悄悄去掉它们，`ControlServer.` 就是 `ControlServer`），最后
  `GetFullPath` 还得原样交回。然后必须**直接**位于三个已知根目录之一下面，**目录名里带 `V2` 标记**。
  **白名单是第一道，生产清单降为第二道**（清单已按探测证据补全，且对任何读不懂的写法按「是生产路径」处理）。
  失效方向对了：白名单漏一个目录，后果是删不掉；黑名单漏一个目录，后果是删错了。
- **服务那一步只要失败，整个卸载立即中止**，计划任务、防火墙、目录一样都不碰。产品卸载脚本的拒绝是整个卸载
  里最重要的一条信号。
- **每删一个目录之前都重新过一遍白名单和生产清单**，包括 `.previous` 这种派生路径和残留暂存目录的每一个匹配。
  任何一个过不去，目录阶段就停在那里。

S1 的聚焦复审又找出这两条里的两个漏洞，都已补上（control-server#262，第三轮）：

- **「服务那一步失败」原来只认抛异常。** 复审用假的产品卸载脚本试了 `exit 1`、`Continue` 下的 `Write-Error`、
  原生命令非零退出，这几种都**不会**让卸载中止，接着删了 8 个 V2 目录（删不到 MVP，因为逐目录复检还在）。
  当时安全只是因为真实的产品卸载脚本恰好每种失败都抛异常。现在改成**要求正面确认成功**：退出码为 0、产品脚本
  在它最后一步写的结果文件确实是这一次新写的、内容是 `PASS` 且服务名对得上、服务确实已经不在了——缺一样就当
  失败、整体中止。没有改成「识别更多种失败」，是因为实测过那条路走不通：`Continue` 下 `Write-Error` 之后 `$?`
  仍是 True；而收集错误流会把产品脚本**故意静默**的错误（`Get-Service -ErrorAction SilentlyContinue`）也收进来，
  每一次正常卸载都会被判失败。
- **所有路径检查都只看字符串，没核过链接。** 名叫 `ControlServer.V2`、实际是指向 MVP 安装根的 junction，字符串
  检查全部放行。本机实测（pwsh 7.6.6）`Remove-Item -Recurse -Force` 碰到 junction 只删链接、不顺着删进目标，
  不管 junction 在目录里面、隔两层、还是目录本身就是 junction。但这是某个命令今天的行为，不是本部署的代码
  保证的，所以现在**要删的路径本身是 junction 或符号链接就拒绝**，目录阶段停在那里；自测把实测行为钉住，哪天
  pwsh 改了行为自测就会红。目录符号链接没测：创建它要管理员权限，本机会话没有。

安装脚本自己的四处删除（替身目录、旧暂存目录、上一代包、收尾的暂存清理）原来只靠脚本开头那一次校验，现在和
卸载一样走同一个删目录函数 `Remove-ParallelInstanceDirectory`，每次删前重新检查那个具体路径。

第三轮短审之后又收紧了四处（control-server#262）：

- **装着密钥的配置文件只认一个路径。** 安装脚本原来在收尾时删掉调用方给的任何路径，不查是不是文件、在不在运维目录下。
  现在只认 `<运维目录>\deploy-config.json`（控制端本来就只传这个），必须是普通文件，开工前就校验；删的时候路径从布局
  取，不从参数取。
- **从拷上服务器那一刻起，每一条退出路径都清掉它。** 这个文件里是 RIoT 调用密钥、MesIngest 共享密钥和（有的话）V2 恢复凭据的明文。原来只有
  主流程的 `finally` 会删它，而定义校验、配置路径校验、管理员检查都在主流程之前，任何一个失败，文件就带着密钥留在
  服务器上。现在分两段兜住：
  - 安装脚本从第一个检查之前就开一个外层 `try/finally`，从里面任何地方退出都会去删。已经算出布局时，只删布局里的
    那个路径；定义被拒、还没有布局时，只删安装脚本自己目录下名叫 `deploy-config.json` 的普通文件。
  - 安装脚本的 `finally` 管不到的情况，由控制端兜：从开始拷配置那一刻起，控制端在自己的 `finally` 里经 ssh 调用服务器上
    同一个删除函数再查一遍。这一步是在 factory01 上执行删除，所以只删一个文件：路径和目录都在控制端由布局算出，
    服务器端函数只接受 `<运维目录>\deploy-config.json`，不接受别的路径。
  - 删不掉就打印 `SECRET_FILE_LEFT_BEHIND: <路径> …` 并写明原因，**不会静默**。安装本身成功、却留下了文件时，这一条
    会变成报错，因为留下密钥的安装不算成功。

  逐条退出路径由谁兜：

  | 退出路径 | 谁来删 |
  | --- | --- |
  | 管理员检查、读取或校验定义、生成布局、配置路径被拒、建结果目录、记录 MVP 指纹、`Copy-Item` 记录定义、主流程中途抛出 | 安装脚本外层 `finally`（配置路径被拒时不删，报 `SECRET_FILE_LEFT_BEHIND`） |
  | 参数绑定失败、导入模块失败（都在外层 `try` 之前） | 控制端补查 |
  | 安装进程被杀、ssh 断线把它一起带走（`finally` 根本不会执行） | 控制端补查 |
  | scp 成功但 ssh 起不来、scp 拷到一半 | 控制端补查 |
  | 控制端补查时 ssh 也连不上 | **没人删**，控制端打印 `SECRET_FILE_LEFT_BEHIND`，要人手工删 |

  最后一行是兜不住的那一种。它的后果有限：这个文件所在的运维目录，控制端建它时就把权限收成只有 SYSTEM 和
  Administrators 能读，而管理员本来就能拿到这台机器上的一切，所以留下它不会让更多人读到秘密，只是违背了「用完就删」
  的承诺。（不要把这写成「两个秘密本来就在别处」：RIoT 密钥写进的是执行安装那个账户的用户级环境变量，MesIngest
  共享密钥要到安装后段才写进本服务注册表的 `Environment` 值，早退出时这次安装还没把它写到任何别处。）
- **两条自测扫描是防回归护栏，不是证明。** 一条挡住卸载脚本直接调用产品脚本的常见写法，一条挡住四个文件（两个脚本、
  两个模块，同一个扫描函数、同一套规则）里常见的删除写法；复审找到的每一种绕法都写成了合成代码，扫描必须认得出来。
  但黑名单永远补不完，已知挡不住的有：别名和函数定义（`Set-Alias`、`Set-Item function:`）、.NET、COM 与 CIM 的进程
  和删除接口（`[Diagnostics.Process]::Start`、`Invoke-CimMethod`、VB 的 `DeleteDirectory`、FSO 的 `DeleteFolder`）、
  挪走、清空或改权限、计划任务，以及写在扫描不读的模块里的定义。复审第四轮定下不再追这些。
  **真正保证不删错东西的是构造**：删前逐次复检的路径白名单与生产清单、拒删链接、服务一步的正面确认与失败即中止、
  配置文件只删那一个固定路径。
- **产品卸载脚本的结果文件名带 GUID**，别的进程猜不到，也就没法抢先写一个假的 `PASS`。
- **「正面确认」依赖的前提也有一道防回归检查。** 有一种失败正面确认认不出来：产品脚本报错后继续跑、删掉服务、最后
  照样写 `PASS`。今天这不会发生，因为产品脚本开头就设了 `$ErrorActionPreference = 'Stop'`，而且只在末尾写一次
  `PASS`。自测只认得四种违反写法（第一句不是设 `Stop`、`PASS` 不是恰好一次、`PASS` 不在最后三句、有 `trap`），
  认不出之后再改回 `Continue`、`$PSDefaultParameterValues`、try/catch 吞掉错误、把 `PASS` 拆开拼接。**产品卸载脚本
  一改，就要有人重读一遍，不能只看这项检查是不是绿的。**
  这项检查在卸载时也会对**实际要调用的那一份**产品脚本再做一次：运行时优先用已装包或上一代包自带的那份，而不是仓库
  里自测读的那份，所以只在仓库里检查不够。不过就中止（`Get-ParallelProductUninstallerPath`）。
- **`sc.exe delete` 返回 1072 不会造成误报。** 复审担心 1072（服务已被标记为待删除）让退出码非 0，从而把一次成功的
  卸载判成失败。实测不会（`review8-sc1072-probe`）：产品脚本在 `sc.exe` 之后还会跑一次 `netstat.exe`，调用方拿到的是
  最后一个原生命令的退出码 0。这依赖两条命令的先后；哪天顺序变了，1072 就会被判为失败、卸载中止，方向安全，重跑即可。

地图标识符的规则也收紧了一点：`map` 和 `25` 之间的分隔符可以省略，所以最自然的笔误 `MAP25` 也会被拒。有意不处理的：
没有左边界（`xMAP-25` 也会被拒，多拒是安全方向），`MAP.25`、`MAP/25`、`MAP-025` 不认。

另外，车号、配置键、路径根目录这几处白名单改成了逐字符比较：PowerShell 默认的相等比较会跳过零宽字符，`-eq` 还不区分
大小写，所以末尾多一个零宽空格的车名、或全小写的车号 key，原来都会被当成允许的那一个。

删除的顺序和这两条停止条件写在模块函数 `Invoke-ParallelRemovalSequence` 里，动作由卸载脚本注入。这样自测
可以**不需要一台机器**就证明：「产品卸载脚本以 production 拒绝」之后没有任何别的动作发生；通配符匹配到 MVP
的暂存目录时，它不会被删、后面的目录也不会被删。自测还在副本里逐一拆掉这些护栏，确认每拆一道，都恰好是对应
的那几条用例变红（证据 `review2-mutation.txt`，第三轮加上新护栏后重跑为 `review3-mutation.txt`）。其中一条值得记住：**只拆掉白名单的 `V2` 标记检查，
「通配符匹配到 MVP 暂存目录」那条就红了**——因为 `ControlServer.incoming-…` 和生产路径 `ControlServer` 名字不同、
也不嵌套，**只靠生产清单会放行删除**。白名单不是锦上添花，它在承重。

另外三道护栏照旧：定义先整份校验（复审给的那份复现定义，现在在第一步就被拒，卸载脚本什么清单都不打）；
MVP 服务指纹事前事后比对；非服务类的单项失败会记下、继续，最后列一张「删了哪些、哪些没删掉」的完整清单。

#### 手工运行要注意

服务器端卸载脚本的 `ConfirmImpact` 是 `High`，手工运行会弹确认。**经非交互的 ssh 运行时，这个确认会把会话
挂住**——带 `-Confirm:$false`（控制端的 `-Uninstall` 就是这么传的），或者先用 `-WhatIf` 看清单。

卸载的代码路径与回滚一样，**没有在真机上跑过**，因为两者都要先装一次。

---

## 11. 第一次真实安装：还没做，要单独申请

**本文档描述的机制已经就绪并验证过，但 `factory01` 上至今没有装过第二套。**

用户 2026-09-20 解除的是「v2 实例不在 `factory01` 上跑」这条**位置限制**，不是**某一次具体安装
操作的授权**。这两者的区别在本仓是有先例的：车载端部署脚本把包搬上去就停，启动是单独一步，
因为上位机是会动的生产设备。

### 装完是什么状态——请批准的人先看这一条

**这一次安装装完，服务就处在 `-Intake` 状态：接真实数据、做真实决策、不动车。** 具体是：

- `JourneyRuntime.enabled = true`：运行时在跑，每 2 秒一轮，读需求目录、做受理与调度判断，
  路网引擎按周期拉 RIoT；
- `RiotCreateDispatch.enabled = false`：**不向 RIoT 下单**。审查从代码核过，这个闸门关着时两条
  建单路径都直接返回 `CreateDispatchDisabled`；不下单就没有在途单，没有在途单就走不到急停；
- 需求只来自本机回环的 FakeMesIngest，目录初始为空；
- 清桩出口按出厂定义是第一阶段：Host 恢复入口关、名单为空、未声明车载端入口，收工时会打
  `CLEARANCE_EXIT_UNAVAILABLE` 警告——这是预期，不是失败（第 7.1 节）。

**这和 MVP 那条线不一样，不要按 MVP 的习惯理解。** MVP 是「装」和「开运行时」两条命令、两次决定
（装完是全关，开运行时要另跑 `Set-JourneyRuntime.ps1 -Intake`）；并行实例是**装完即 Intake**，
少了中间那个决策点。这样设计是因为本票的目的就是给后面两张票（量路网引擎开销、验硬件极性常量）
提供一个在跑的环境，而路网引擎只在运行时开着时才刷新。**如果批准的人希望装完是全关的**，把实例
定义里 `journeyRuntime.enabled` 与 `routeGraph.enabled` 都改成 `false` 再装即可（两者必须同时
改，只关前者会被校验拒绝），之后单独再开。

### 申请材料

| 项 | 内容 |
| --- | --- |
| 装什么 | 一次 `release.yml` 产出的 v2 联合包（服务端 + 车载端），服务端半边装到 `factory01`；外加一个从同一 commit 构建的 FakeMesIngest |
| 装到哪 | 第 3 节的表，全部是 MVP 之外的新路径与新端口。2026-09-21 只读探测：八个目录、服务名、任务名、两条防火墙规则**全部不存在**，四个端口空闲且没有被出站连接占着 |
| 装完的状态 | **`-Intake`**，见上一小节 |
| **第一步：地图取值** | **装之前**从 factory01 直查 RIoT，取回 `dispatchZone` 与 `admissionPolicyDeploymentId` 的 map 26 真实值填进定义，并出一份 26 版站点清单，见第 9 节。`mapId`（26）与 `mapIdentity`（`老厂前线new_wk`）已有出处、已写好。**出厂定义在这两个值填好之前过不了校验，部署命令会在碰服务器之前拒绝**——这是刻意的 |
| **第二步：列出另外两个根的子目录** | **装之前**列出 `C:\Program Files\8005 AGV` 与 `C:\ProgramData\8005` 下的全部子目录，确认没有「名字带 `v2` 字样、却不属于本实例」的目录。原因：路径白名单认的是「直接位于这三个根之一下、名字带 `V2` 标记」，如果那里本来就有一个别人的 `…v2…` 目录，白名单挡不住它，只能靠生产清单兜。第三个根 `D:\zhengyushao` 的子目录已在 2026-09-21 探测里列过（`factory01-survey-paths.txt`）；这两个没有列过，因为**看它们就是读 MVP 的安装目录**，属于要先问用户的一类。和第一步取值放在一起，请用户一并授权（control-server#262 S1 复审疑问 1） |
| 预计多久 | 取值与改定义不计；产品脚本装一次约几分钟（含服务启动与健康检查），加上 scp 一个百 MB 级的包，按半小时准备 |
| 会不会动车 | **不会**，`riotCreateDispatch.enabled = false` |
| 会不会抢真实需求 | **不会**，`MesIngest:baseUrl` 指向本机回环的 FakeMesIngest |
| 怎么确认没影响 MVP | 安装脚本事前事后各记一次 MVP 服务指纹（状态、启动类型、可执行路径、pid），不一致就报错；安装前后各跑一次第 12 节的只读巡检。注意指纹只比服务、不比磁盘——磁盘这一侧靠路径校验与前缀化的暂存清理（第 8 节） |
| **风险：内存** | 物理 31.5 GiB、空闲 5.6 GiB，已提交 29.6／36.3 GiB，余量 6.7 GiB。MVP 的 `ControlServer.Host` 吃 876 MB。第二套加 FakeMesIngest 预计再吃 1～1.5 GiB。装得下，但余量会明显变薄——同机还跑着 SQL Server（7.7 GiB）、`AGV.Web`、生产 MesIngest |

### 装到一半失败怎么办——比「回滚」更手工

安装脚本里**没有跨步骤的自动回滚**。产品安装脚本自己失败时会自我回滚；但它**成功之后**，本脚本
做的那些事——配置叠加、写 MesIngest token、部署替身、注册计划任务、开防火墙、代际对调——任何
一步失败，都会留下一个半装的实例，而首次安装此时没有 `.previous` 可以换回去。

脚本在这种情况下会明确打出「没有完成、可能半装」，并把 MVP 指纹的前后值打出来。然后：

1. **先看 MVP**：指纹前后是否一致；再用第 12 节的巡检确认 58005／58007 仍在应答。
2. 用 `-Uninstall -WhatIf` 看半装实例留下了哪些东西，再 `-Uninstall` 拿掉（默认保留数据根与运维
   目录，失败现场的结果 JSON 与日志就在 `control-server-v2-ops\results\`）。卸载按安装脚本**动手前**
   记下的 `installed-instance.json` 来删，所以半装的实例也有它；包目录此时还不存在，产品卸载脚本
   从运维目录里控制端送去的那份取（第 10 节）。卸载里服务那一步一旦失败会整体中止，此时照日志处理
   服务，**不要**手工去删目录——手工删正是 S1 那个缺陷的形状。
3. 修好原因再重装。首次安装的产品脚本在安装根已存在时会拒绝，所以一定要先卸载干净。

---

## 12. 出事了

先做一次只读巡检（这几条都不碰 MVP 的进程、目录、配置和数据库）：

```bash
# 临时端口池——2026-09-08 一个泄漏连接的服务把它占到 64%，CI 停摆 4 小时 14 分
ssh factory01 "(Get-NetTCPConnection | Where-Object { `$_.LocalPort -ge 49152 }).Count"
```

健康时约 1～2%（2026-09-21 实测 261／16384）。

```bash
# 两套服务各自的状态
ssh factory01 "Get-Service '8005 AGV ControlServer','8005 AGV ControlServer V2' | Format-Table Name,Status,StartType"
# 替身的计划任务
ssh factory01 "Get-ScheduledTask -TaskName '8005 AGV ControlServer V2 FakeMesIngest' | Format-Table TaskName,State"
```

| 症状 | 先看 |
| --- | --- |
| 部署在校验那一步就停了 | 它会把**每一条**拒绝理由都列出来，照着改实例定义。机器还没被碰 |
| 校验报「is still the placeholder」 | 出厂定义就是这样，刻意的。两个 map 26 的值要先从现场取回填进去，见第 9 节 |
| 校验说路径「is not in canonical form」或「does not carry the instance marker」 | 路径写成了正斜杠、带 `.`／`..`、不在三个根目录下、或名字里没有 `V2` 标记。照第 10 节「什么情况下它会停」改成唯一接受的那种写法 |
| 卸载报服务那一步失败、然后抛「Uninstall ABORTED」 | 这是设计：服务那一步一失败，其余一样都不碰。尤其当原因是产品卸载脚本以 production 拒绝时，说明定义里的某个路径指向了生产——**先查定义，不要手工删目录**。如果原因是「returned without writing its result file」或「exit code N」，说明产品卸载脚本中途停了，它的输出就打在这句报错上面 |
| 安装一开始就报「-DeploymentConfigPath is '…'; the only accepted path is '…'」 | 传给服务器端安装脚本的配置文件路径不是 `<运维目录>\deploy-config.json`。正常经控制端的 `19-deploy` 不会出现；手工运行时照报错里给的路径传 |
| 输出里有 `SECRET_FILE_LEFT_BEHIND` | 服务器上那份装着明文密钥的 `deploy-config.json` 没被删掉，这一行写着路径和原因。**先手工删掉它**，再看原因：多半是路径不是 `<运维目录>\deploy-config.json`，或者 ssh 在安装中途断了、控制端的补查也没连上 |
| 删除时报「it is a junction or symbolic link」 | 要删的那个目录其实是一个链接。**先查它指向哪里**（`Get-Item <路径> \| Select-Object Target`），不要手工删——如果它指向 MVP 的目录，删错一步就是 S1 的形状 |
| 校验报「is not a key this deployment knows」 | 实例定义里有白名单之外的键（拼错，或者产品新加的选项还没登记）。未知键一律拒绝而不是透传，见第 6 节 |
| **V2 起不来，日志报 bind 失败／地址已被占用** | **先查那个端口有没有被临时连接占着**：`Get-NetTCPConnection -LocalPort <端口>`。58105／58107／58109／58188 都落在临时端口范围（49152–65535）内，Windows 可能把它们分给某条出站连接——MVP 的 58005／58007 有同样的风险，只是一直没撞上。2026-09-21 探测时四个都空闲，**那不保证下个月启动时仍空闲** |
| v2 实例起得来但不受理任何需求 | 先看替身活着没（`http://127.0.0.1:58188/control/v1/health` 的 `demandCount`）。目录空是**正常默认**，要灌需求见第 5 节 |
| 替身日志里有 `SEED FAILED` | 种子文件里那条需求缺必填字段，或 `area` 填成了前缀而不是区号 |
| 替身的计划任务显示 Ready 而不是 Running | 连续失败 3 次后不再重启。看 `D:\zhengyushao\control-server-v2-ops\logs\fake-mes-ingest.log` |
| 路网引擎像是没在跑 | 查 `appsettings.Production.json` 里 `RouteGraph.enabled` **和** `JourneyRuntime.enabled` 是不是都为真——只开前者，引擎一次都不会跑 |
| 改了实例定义里的端口，装完端口没变 | **升级路径沿用已装的 `appsettings.Production.json`**（`Update-ControlServerLocal.ps1` 的既有行为），定义里的端口与绑定地址只在**首次安装**时生效。要换端口得卸载再装。`-WhatIf` 会打印新端口，同时会提醒这一点 |
| 车上连不上 v2 实例 | 先查 `Find-NetRoute` 是不是 Clash；再查防火墙里有没有 `8005 AGV ControlServer V2 58105` 那两条 |
| 输出里有 `CLEARANCE_EXIT_UNAVAILABLE` | 清桩出口不可用，后面列着原因码。第一阶段（入口关、名单为空）就是这样，**是预期**。不是第一阶段时：`FIELD_OPERATOR_ROSTER_EMPTY` 填名单（每台车的操作员号各一条，必须写 `operatorId`），`STATION_CLEARANCE_ENTRY_NOT_OFFERED`／`CHARGING_RECOVERY_ENTRY_NOT_OFFERED` 看定义里的 `vehicleFaultRecovery.enabled` 与凭据（第 7.1 节） |
| 安装报 `CLEARANCE_EXIT_BROKEN` | 生效配置里缺了那两节，或入口开着而服务 `Environment` 里没有 `CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL`。后者先跑 `Set-ControlServerSecret.ps1` 录入 `V2FaultRecoveryCredential` 再重装 |
| 部署一开始就报「'V2FaultRecoveryCredential' is missing」 | 定义里开了恢复入口，但控制端秘密存储里没有这个键（第 7.1 节）。机器还没被碰；用 `Set-ControlServerSecret.ps1` 录入后重跑 |
| 服务器端报「there is no value for CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL」 | 定义里开了恢复入口，`deploy-config.json` 里没有凭据、服务里也没有（多见于回滚或手工运行）。机器还没被动过 |
| 升级或回滚一开始就报 `UPGRADE_REFUSED_DISPATCH_OPEN` | 已装配置的派车闸门开着，车可能在途。经用户授权后用 `20-set-control-server-parallel-dispatch-gate.ps1 -State Closed` 关（第 10 节「关、开派车闸门」）；脚本跑不了时才照第 10 节的三步手工关：先停注入新需求、等 `agv02`／`agv03` 都 `Completed`；再改 **`C:\Program Files\8005 AGV\ControlServer.V2\appsettings.Production.json`**（不是 MVP 的 `...\ControlServer\`，不要用记事本另存为）；再重启 **「8005 AGV ControlServer V2」**（不是「8005 AGV ControlServer」）。机器还没被动过 |
| 一开始就报 `CONFIGURATION_CHANGED_SINCE_START` | V2 的已装配置在服务进程启动之后被改过，进程还按旧配置跑。多半是关闸门时改了文件、忘了重启。重启「8005 AGV ControlServer V2」再跑。机器还没被动过 |
| 一开始就报 `SERVICE_NOT_SETTLED` | V2 服务正在启动或停止（或处于 Paused、状态读不到）。等它稳定在 Running 或 Stopped 再跑。机器还没被动过 |
| 一开始就报 `SERVICE_START_TIME_UNKNOWN` 或 `CONFIGURATION_WRITE_TIME_UNKNOWN` | V2 服务是 Running，却读不到它的进程启动时间（进程在吗？），或读不到已装配置的修改时间。查明再跑。机器还没被动过 |
| 回滚一开始就报「No previous generation to roll back to」 | `D:\zhengyushao\ControlServer.V2.previous\controlserver` 不存在，没有可退的上一代。首次安装后的第一次升级之前就是这样。机器还没被动过 |
| 一开始就报 `INSTALLED_CONFIGURATION_MISSING` 或 `INSTALLED_CONFIGURATION_UNREADABLE` | 服务在，但安装目录里的 `appsettings.Production.json` 不在或读不出来。任何一次安装或回滚都不会留下这种状态，**先查明原因**（被手工删了？备份根下最近一次升级的备份里有没有？），弄清之前不要重跑，更不要用 `-Rollback` 试——以前这里会先对调包目录再失败。机器还没被动过 |
| 部署报「has no 'vehicleFaultRecovery' section」 | `-ControlServerRepository` 指向的 checkout 早于 control-server#454。换一个包含它的 checkout |
| 升级或回滚失败，输出里有 `JOURNEY_RUNTIME_LEFT_DISABLED` | 设计如此：升级前关掉的运行时开关留在 false，实例不派车。升级脚本在自己的预检里失败（比如包清单不对、输出路径已存在）时服务停着；预检之后失败时它的回退用旧二进制加 false 把服务拉起来。按失败原因处理后，**重新部署当前在跑的那个 commit（或修好的新包）**，成功后叠加会写回定义里的值。**不要用 `-Rollback` 来恢复开关**：安装失败时代际对调还没发生，`-Rollback` 会装上更早一代，车载端可能对不上（第 10 节） |
| 部署报 "MVP service changed" | **立刻停下**。这条断言就是为了不让任何东西悄悄碰生产那套。把前后两次指纹发出来再判断 |

诊断日志和结果 JSON 在 `D:\zhengyushao\control-server-v2-ops\results\`，一次安装一对。

### 真装时要盯的三件事——推理过、没实测过

这三条是审查提出的疑问，代码里看不出确定答案，也没有在本机实跑的办法。**不是已知故障，是已知
盲点**，真装时第一次遇到就记下结果：

1. **替身重启之后，服务端怎么看待目录。** 先说实测到的：`historyEpoch` 是种子里写死的常量，
   **不会变**；`catalogRevision` 在种子文件不变时每次重灌都回到同一个值——本机实跑两次启动的
   ETag 都是 `W/"catalog-h8f14e45f…-r3"`。所以「种子不变、替身重启」在服务端看来目录身份完全
   相同，这一种没有问题。

   有问题的是两种情况，代码里看不出服务端的确定反应：
   - **改了种子文件再重启**：需求条数相同时，得到的是**同一个 epoch、同一个 revision、不同的
     需求内容**，而 ETag 只由 epoch 与 revision 推导（`FakeMesIngest/README.md`）。服务端若以
     ETag 判断「目录没变」，会看不到这次换内容。
   - **运行中用控制面临时加过需求、之后替身重启**：revision 从较高的值**回落**，同一个
     `demandId` 在回落后的目录里再次出现——会不会被判 `CandidateChanged` 空转或被**重复受理**。

   目录为空时两种都不会触发。**第一次往种子文件里加需求、以及第一次修改种子文件时，都要盯住。**
   稳妥的做法是改种子之前先把 `historyEpoch` 换一个新值（替身支持 `--FakeMesIngest:Seed:HistoryEpoch=`），
   让「换了一本目录」在身份上看得出来——这一步本票没做成自动的，因为它会改变替身的启动参数，
   等第一次真实观察结果出来再定。
2. **计划任务那一层一次都没实跑过。** 本机实测证明的是「替身死了，包装脚本跟着退出、退出码非 0」
   ——这一条是方案成立的关键，已验证。但「Windows 看到非 0 退出后真的会按 `-RestartCount 3` 重启」
   和「`-AtStartup` 触发器真的会在开机时以 SYSTEM 拉起」是推理。真装后找一个 MVP 空闲的时段，
   手动结束替身进程一次，看任务是否在一分钟内把它拉回来。
3. **首次安装半路失败的退路**比回滚更手工，已在第 11 节写细。

---

## 13. 这套部署不做什么

- **不碰 MVP** 的进程、安装目录、配置与数据库。事前事后各比对一次服务指纹；暂存目录的清理
  限定在本实例自己的前缀下（第 8 节）。
- **不碰生产 MesIngest，不碰 `SQAGV`。**
- **不碰 `agv01`。** 配置层面拒绝，不是靠纪律；车辆名册（`Fleet`）整节拒绝，见第 6 节。
- **不写 MVP 用的机器级环境变量。** 它只读机器级的 `CONTROL_SERVER_RIOT_CALL_API_KEY` 与
  `CONTROL_SERVER_ONBOARD_CREDENTIAL`，不写。它**会动**的机器级变量只有一个，是它自己专用的
  `CONTROL_SERVER_V2_ONBOARD_CERTIFICATE_PASSWORD`：升级时产品脚本会删它（目前本来就不存在），
  卸载时本脚本会删它。**用户级**的 `CONTROL_SERVER_RIOT_CALL_API_KEY` 它会写，而 MVP 每次安装也写
  同一个变量——今天两套是同一把密钥所以无害，见第 8 节。
- **不让 runner 直接部署。** 必须经控制端中转。
- **不启用 `riotCreateDispatch`。** 要开得显式带 `-AllowRiotCreateDispatch`，而那一次运行
  仍然要用户单独授权、现场有人盯着。
- **不启动车载端。** `agv02`／`agv03` 上的车载端部署与启动是另一条路
  （`remote-ops/onboard-hmi/scripts/`），规矩没变：搬完就停，启动要有人走到车前。
- **不跑门禁。** `G1`／`G2`／`G3`／`RC` 属于切发布候选的流程，不在部署路径上。
- **不装 Dashboard，也不支持装。** 见第 3 节。
