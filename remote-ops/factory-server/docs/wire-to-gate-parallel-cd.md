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
一项留到"到时候再定"**。端口选取的依据是 2026-09-21 对 `factory01` 的实测（证据在
`evidence/deploy/20260921-cs262-parallel-instance/factory01-survey.txt`）：四个端口当时全部
空闲，MVP 占 58005／58007，生产 MesIngest 占 `0.0.0.0:5088`。

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

**Dashboard 预留但不装。** 产品脚本支持它（`-DashboardPackagePath`），本票不传，因为
dashboard 只绑回环、要 `ssh -L` 才看得到，而这台机器的内存是最紧的资源（见第 9 节）。
58109 仍然写进实例定义并纳入端口冲突检查，是为了将来要装时不必重新找一个不冲突的号。

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

还有第二道锁，和车号无关：

- **`riotCreateDispatch.enabled` 必须显式写出来，而且默认只允许 `false`。** 这个开关决定
  这套实例会不会真的向 RIoT 下单，而下单会让车动。产品代码把它和 `JourneyRuntime` 分开正是
  为此——"启用运行时"本身不构成"授权下一张真单"。要把它打开，部署命令得额外带
  `-AllowRiotCreateDispatch`，**而那一次运行仍然要用户单独授权、现场有人盯着**。
- 不下单就没有在途单，没有在途单就不会走到急停那条路（`EmergencyStopSupervisor` 由在途单
  被报 FAILED 驱动）。

### 4.4 地图与通道——运行须知，不在代码里

`agv02`／`agv03` 与 `agv01` 在同一张 RIoT map 上。真要让 v2 驱动车跑起来时：

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

---

## 8. 两处不显然的隔离细节

这两条都是读产品脚本源码才发现的，都会在**第一次升级**时才咬人，所以单独列出来。

**一、传 `-SkipMachineEnvironmentInjection`，不传 `-CopyUserRiotSecretToMachine`。**
机器级的 `CONTROL_SERVER_RIOT_CALL_API_KEY` 是 MVP 安装时设下的**共享资源**（实测存在，
166 字符）。并行实例只读它、不写它——服务自己的注册表 `Environment` 已经带了需要的值。另外
产品脚本在机器级的 key 与用户级的不一致时会直接 throw，覆写它等于这套部署伸手去改生产那套。

`CONTROL_SERVER_ONBOARD_CREDENTIAL`（机器级，64 字符）同样是**读不写**。两套实例、三台车
共用同一个静态共享密钥，这是明文期的既有设计（`RELEASE-CANDIDATE.md` 11.1 节），不是这次
引入的。

**二、`-CertificatePasswordVariable` 必须传一个本实例专用的名字。**
`Update-ControlServerLocal.ps1` 会**删除**它被指向的那个机器级变量（明文期的遗留清理）。留
默认值 `CONTROL_SERVER_ONBOARD_CERTIFICATE_PASSWORD` 的话，**并行实例升级一次就把 MVP 的那个
删了**。这套部署传的是 `CONTROL_SERVER_V2_ONBOARD_CERTIFICATE_PASSWORD`，一个只有它用的名字
（实测目前两个都不存在，所以这段清理对两边都是空操作——但依赖"现在恰好不存在"不是隔离，
名字分开才是）。

安装脚本还会在**动手之前和收工之后各记一次 MVP 服务的指纹**（存在与否、状态、启动类型、
可执行路径、进程 id），对不上就报错。"我没碰它"是一句值得留下证据的话。

---

## 9. 一个必须先澄清的矛盾：`mapId` 是 25 还是 26

两处说法不一致，本票没有权限决定哪个对：

| 出处 | 说法 |
| --- | --- |
| `8005-agv-control-server` 的 `src/ControlServer.Host/appsettings.json`（`fp/v2-impl` 顶端） | `mapId: 25`，`mapIdentity: 老厂前线new`，`dispatchZone: MAP-25-WIRE_TO_GATE`，`allowedDispatchZones: ["MAP-25-WIRE_TO_GATE"]`，`admissionPolicyDeploymentId: MAP-25-WIRE_TO_GATE-20260827` |
| `remote-ops/fleet.md` | agv01 的 `mapId` 25 |
| 工作区 `CLAUDE.md` 隔离表 | "备用车与 `agv01` 同在 RIoT map **26**（2026-09-19 用户更正，此前误记为 25）" |

实例定义现在填的是 **25**，与 `appsettings.json` 保持一致。选 25 而不是 26 的理由：改成 26
就得连带编造一整套 `MAP-26-WIRE_TO_GATE` 的 `dispatchZone`、`allowedDispatchZones` 和
`admissionPolicyDeploymentId`，而那几个值我没有出处——凭空造一组标识符比留下一个已知的矛盾
更糟。

校验里加了一条：**`routeGraph.mapId` 与 `journeyRuntime.mapId` 必须相等**，所以改的时候不会
只改一处。

**第一次真装之前必须澄清这一项**，办法是从 `factory01` 直接查 RIoT（控制端到 RIoT 走 Clash
TUN，探测结果不可信；`factory01` 那边直连可达，`CONTROL_SERVER_RIOT_CALL_API_KEY` 在 User 和
Machine 两个作用域都有）。它决定路网引擎会去拉哪张图——填错的话引擎会持有一张与实际调度不同
的图，而它照样跑得好好的。

---

## 10. 回滚

```bash
pwsh -File remote-ops/factory-server/scripts/19-deploy-control-server-parallel.ps1 `
  -ControlServerRepository <干净 checkout> -Rollback
```

形状与 MVP 那套相同：上一代原样留在 `D:\zhengyushao\ControlServer.V2.previous`，回滚是把两个
目录**对调**（不是复制），所以"回滚一次回滚"就是再跑一遍同一条命令。回滚之后会**重新叠加一次
配置**——升级会保留现有的 `appsettings.Production.json`，但回滚到一个比某个叠加键更早的代际
时，不重叠就会丢掉那个键。

**回滚不碰 MVP**，一个字节都不碰；收工前同样比对 MVP 指纹。

**车载端不会跟着回滚。** 两端不协商版本，版本错配的表现是连接被拒而不是一条说明原因的错误
（`RELEASE-CANDIDATE.md` 8.1 节）。所以 `agv02`／`agv03` 上的车载端要一起退回去，否则它们只会
停止连接。

彻底卸载用产品脚本 `Uninstall-ControlServerLocal.ps1`，它要求把服务名、安装根、数据根**显式
写出来**，而且生产那几个名字要额外带 `-AllowProductionService`——所以卸并行实例不可能误删
生产那套。

---

## 11. 第一次真实安装：还没做，要单独申请

**本文档描述的机制已经就绪并验证过，但 `factory01` 上至今没有装过第二套。**

用户 2026-09-20 解除的是"v2 实例不在 `factory01` 上跑"这条**位置限制**，不是**某一次具体安装
操作的授权**。这两者的区别在本仓是有先例的：车载端部署脚本把包搬上去就停，启动是单独一步，
因为上位机是会动的生产设备。

申请第一次安装时要一并报上去的东西：

| 项 | 内容 |
| --- | --- |
| 装什么 | 一次 `release.yml` 产出的 v2 联合包（服务端 + 车载端），服务端半边装到 `factory01`；外加一个从同一 commit 构建的 FakeMesIngest |
| 装到哪 | 第 3 节的表，全部是 MVP 之外的新路径与新端口 |
| 预计多久 | 产品脚本装一次约几分钟（含服务启动与健康检查）；加上 scp 一个百 MB 级的包，按半小时准备 |
| 会不会动车 | **不会。** `riotCreateDispatch.enabled = false`，不下单就不会有在途单，也就走不到急停。让车动是另一次、要单独授权的操作 |
| 会不会抢真实需求 | **不会。** `MesIngest:baseUrl` 指向本机回环的 FakeMesIngest，目录初始为空 |
| 怎么确认没影响 MVP | 安装脚本事前事后各记一次 MVP 服务指纹（状态、启动类型、可执行路径、pid），不一致就报错并中止；另外可在安装前后各跑一次第 12 节的只读巡检 |
| 出问题怎么退 | `-Rollback`；首次安装没有上一代，所以首次的退路是 `Uninstall-ControlServerLocal.ps1` 显式点名卸掉 V2 那套 |
| **风险：内存** | 这台机器物理 31.5 GiB、空闲 5.6 GiB，已提交 29.6 / 36.3 GiB，余量 6.7 GiB。MVP 的 `ControlServer.Host` 吃 876 MB 工作集。第二套按同量级估，加 FakeMesIngest 预计再吃 1～1.5 GiB。**装得下，但余量会明显变薄**，同机还跑着 SQL Server（7.7 GiB）、`AGV.Web`、生产 MesIngest |
| **待澄清** | `mapId` 是 25 还是 26，见第 9 节。建议在申请时一并定下来 |

---

## 12. 出事了

先做一次只读巡检（这几条都不碰 MVP 的进程、目录、配置和数据库）：

```bash
# 临时端口池——2026-09-08 一个泄漏连接的服务把它占到 64%，CI 停摆 4 小时 14 分
ssh factory01 "(Get-NetTCPConnection | Where-Object { `$_.LocalPort -ge 49152 }).Count"
```

健康时约 1～2%（2026-09-21 实测 261 / 16384）。

```bash
# 两套服务各自的状态
ssh factory01 "Get-Service '8005 AGV ControlServer','8005 AGV ControlServer V2' | Format-Table Name,Status,StartType"
# 替身的计划任务
ssh factory01 "Get-ScheduledTask -TaskName '8005 AGV ControlServer V2 FakeMesIngest' | Format-Table TaskName,State"
```

| 症状 | 先看 |
| --- | --- |
| 部署在校验那一步就停了 | 它会把**每一条**拒绝理由都列出来，照着改实例定义。机器还没被碰 |
| v2 实例起得来但不受理任何需求 | 先看替身活着没（`http://127.0.0.1:58188/control/v1/health` 的 `demandCount`）。目录空是**正常默认**，要灌需求见第 5 节 |
| 替身日志里有 `SEED FAILED` | 种子文件里那条需求缺必填字段，或 `area` 填成了前缀而不是区号 |
| 替身的计划任务显示 Ready 而不是 Running | 连续失败 3 次后不再重启。看 `D:\zhengyushao\control-server-v2-ops\logs\fake-mes-ingest.log` |
| 路网引擎像是没在跑 | 查 `appsettings.Production.json` 里 `RouteGraph.enabled` **和** `JourneyRuntime.enabled` 是不是都为真——只开前者，引擎一次都不会跑 |
| 车上连不上 v2 实例 | 先查 `Find-NetRoute` 是不是 Clash；再查防火墙里有没有 `8005 AGV ControlServer V2 58105` 那两条 |
| 部署报 "MVP service changed" | **立刻停下**。这条断言就是为了不让任何东西悄悄碰生产那套。把前后两次指纹发出来再判断 |

诊断日志和结果 JSON 在 `D:\zhengyushao\control-server-v2-ops\results\`，一次安装一对。

---

## 13. 这套部署不做什么

- **不碰 MVP** 的进程、安装目录、配置与数据库。事前事后各比对一次服务指纹。
- **不碰生产 MesIngest，不碰 `SQAGV`。**
- **不碰 `agv01`。** 配置层面拒绝，不是靠纪律。
- **不写任何机器级环境变量。** 只读那两个共享的。
- **不让 runner 直接部署。** 必须经控制端中转。
- **不启用 `riotCreateDispatch`。** 要开得显式带 `-AllowRiotCreateDispatch`，而那一次运行
  仍然要用户单独授权、现场有人盯着。
- **不启动车载端。** `agv02`／`agv03` 上的车载端部署与启动是另一条路
  （`remote-ops/onboard-hmi/scripts/`），规矩没变：搬完就停，启动要有人走到车前。
- **不跑门禁。** `G1`／`G2`／`G3`／`RC` 属于切发布候选的流程，不在部署路径上。
- **不装 Dashboard。** 端口预留，见第 3 节。
