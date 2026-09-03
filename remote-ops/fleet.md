# 车队登记册

8005 项目就 **3 台车**，不多不少。每台车是「**AGV 车辆本体** + 装在它上面的**上位机**」
两件东西，本文件是这两者**一一对应关系的唯一真相来源**。

一台车有五个身份坐标，散落在三个系统里。**给出任意一个，这张表都能反查其余四个**：

| 坐标 | 属于谁 | 长什么样 | 恒定？ |
| --- | --- | --- | --- |
| SSH 别名 | 上位机（本运维通道） | `agv01` | 我们自己起的，改了就全乱 |
| CPE 地址 | 车（企业内网入口） | `172.19.162.210` | **会变**，换设备/改配置就变 |
| RIoT `deviceKey` | 车（RIoT 平台） | `BROKERX-0c20ff06…` | **恒定**，全局唯一 |
| RIoT `id` | 车（RIoT 平台） | `58` | **恒定**，该实例内的自增主键 |
| `deviceName` / `agvId` | 车（RIoT 平台 = 现场位号） | `老厂前线新多仓位1` | 人可改，且 RIoT 不保证唯一 |

**只有 `deviceKey` 和 `id` 是真正恒定的**，任何长期引用都该落在这两个上。`deviceName`
可以重名——`DispatchableVehicleLookup.ResolveDeviceKey` 撞到重名会抛
`vehicle-name-ambiguous` 而不是随便挑一个。

**跨领域的东西这里只放指针，不放副本**——上位机代码、部署流程各有自己的真相来源，
抄进来就会腐烂。见最后一节。

---

## 三条先读的硬约束

**1. 三台车是同一个镜像克隆的，克隆后没做任何个性化。SSH 别名是从控制端区分它们的
唯一依据。**

COMPUTERNAME 三台都是 `DESKTOP-94OA6CK`，MachineGuid 三台都是
`6910ff68-24ae-4fcb-8e16-b6bbd5924490`，SMBIOS UUID 与 InstallDate 也相同，「以太网 5」
的 IP 三台都是 `192.168.71.180`（各在自己 CPE 的 NAT 后面，所以不冲突）。

**任何从机器本身推导身份的做法都会把三台车当成一台。**`onboardInstanceId`、`agvId`、
`expectedVehicleKey` 必须人工给定，不能生成、不能复制、不能从 MachineGuid 派生——服务端
把重复的身份当成同一台车，两台车共用一个 Guid 等于服务端只看得见一台。

**2. 镜像自带一个时钟故障，每台新车上线必修，且要在任何东西读它的时间戳之前修。**

现象一致：时钟快 158 天（读到 2027-02），时间源 `Local CMOS Clock`，配置的 NTP 是
`172.19.206.222`——那台机器跑 RIoT、123 端口不应答，且它与真实服务器 `172.19.205.222`
只差第三段一个数字，所以这个配置错误能活过复核。

这是安全相关故障不是外观问题：车载安全门禁用 5 秒窗口比较服务端 `observedAt` 与本机时钟
（`VehicleSafetySignal.IsFresh`），时钟偏这么多会让每次投影都显得过期，干净会话永远出不了
`RecoveryRequired` / `DEPARTURE_SAFETY_NOT_READY`。

修：[onboard-hmi/scripts/07-fix-clock.ps1](onboard-hmi/scripts/07-fix-clock.ps1)，在车上跑。
w32time 自己拒绝这么大的修正，所以先 `Set-Date` 粗跳、再交给 NTP 细调。

**3. 通道通 ≠ 已部署。**三台车的 SSH 通道都就绪，但只有 agv01 装了车载端。

---

## 一一对应表

数据取自 RIoT `GET /api/device/v1/devices`，核对于 2026-09-03。

| 上位机 | CPE 地址 | RIoT `id` | RIoT `deviceKey` | `deviceName` / `agvId` | 序列号 |
| --- | --- | --- | --- | --- | --- |
| `agv01` | `172.19.162.210` | **58** | `BROKERX-0c20ff0600d644869a6a80c186065d85` | `老厂前线新多仓位1` | `313712` |
| `agv02` | `172.19.162.179` | **59** | `BROKERX-f38975561adf46ccb1d2f23833c7d0e4` | `老厂前线新多仓位2` | `313710` |
| `agv03` | `172.19.162.70` | **60** | `BROKERX-7daca4ee91da498d8026c68b7b941127` | `老厂前线新多仓位3` | `313711` |

**对应关系的物理依据是 CPE 地址**：车辆本体在 RIoT 上登记的 `hostPort`（`<CPE>:5001`）
与它车上那台上位机的 SSH 入口（`<同一个 CPE>:22022`）是同一台 CPE 的 WAN 地址——一台车
一台 CPE，车和上位机都在它后面。要重新核对这张表，就是把 RIoT 的 `hostPort` 的 IP 段与
`ssh_config.agv` 的 `HostName` 对齐。

三台车在 RIoT 上都是 `deviceType=1`（AGV）、`model=300ul`、`series=oasis`。RIoT 记录建于
agv01 `2026-07-31`、agv02 `2026-09-03 19:06`、agv03 `19:16`。

**三个反直觉的地方，按序号猜必错：**

1. **序列号与车号不同序**——`313712` / `313710` / `313711` 分别是 1 / 2 / 3 号车。
2. **`physicsId` 三台完全相同（`14682111`）**，和上位机的 MachineGuid 一样，不能用来
   区分车辆。RIoT 侧唯一可靠的区分依据是 `deviceKey` 与 `id`。
3. **RIoT 上有 25 台可调度车、42 台设备**，名字里带「老厂前线」「多仓位」的不止我们这三台。
   按名字模糊匹配会撞到别的车，例如 `172.19.162.248` 是「老厂电镀AGV」而不是我们的车。

## 上位机通道

| 别名 | 入口 | MAC | ED25519 host key | 通道 | 车载端 |
| --- | --- | --- | --- | --- | --- |
| `agv01` | `172.19.162.210:22022` | `68-ED-A4-9B-B5-5A` | `SHA256:kZR9F72fdrzs7kIvqEcWMAi8w9aRlosCS7orWCGWRCI` | 就绪 | **已部署** |
| `agv02` | `172.19.162.179:22022` | `68-ED-A4-9B-B5-CE` | `SHA256:7irq9yWgCqEkMIKZF7v5wvGasUFx+Dmd3g1vnIflduY` | 就绪 | 未部署 |
| `agv03` | `172.19.162.70:22022` | `68-ED-A4-9B-B5-D2` | `SHA256:/q4BBoyU4/DqU8DP9jhmn1kuuOd2hfKoHJu6vhHddNQ` | 就绪 | 未部署 |

「通道就绪」= sshd 已装、已加固（密码认证关闭，实测强制走密码返回
`Permission denied (publickey)`）、已校时、UTF-8 profile 已装。三台配置一致。
「车载端」列实测于 2026-09-03（`C:\8005\OnboardHmi`：agv01 有 478 个文件，另两台不存在）。

每台车都在自己的 KonNaD CPE2458 后面做 NAT，`22022 → 192.168.71.180:22`。
**外部 22 不可用**——CPE 自己的 dropbear 占着。三台车用同一个外部端口号是故意的：CPE 是
三台独立设备、地址各不相同，没必要让端口号也递增。

别名定义在 [onboard-hmi/config/ssh_config.agv](onboard-hmi/config/ssh_config.agv)，
那个文件同时是 `agv` 族的别名注册表。**不要直接改 `~/.ssh/config`**，改片段后重跑
`control-host/Build-SshConfig.ps1`。私钥 `~/.ssh/agv_ops_ed25519` 在控制端本机，不在仓库里。

---

## agv01 —— 老厂前线新多仓位1

| 项 | 值 |
| --- | --- |
| 现场值文件 | [onboard-hmi/config/site-agv01.json](onboard-hmi/config/site-agv01.json) —— **已填齐** |
| `onboardInstanceId` | `OBU-LAOCHANG-XDCW-01` / `620ee2ce-cf8a-4429-8a0b-0c4098bcba7e` |
| IO 模块 | `192.168.71.150`，实测 Modbus 502 开放 |
| 车载端 | 已部署在 `C:\8005\OnboardHmi` |

这台车也是 ControlServer `JourneyRuntime` 里唯一登记的车（`mapId` 25、闸口
`gateStationRiotId` 210、`dispatchZone` `MAP-25-WIRE_TO_GATE`）。

同机还有 `C2000Service.exe`（IO 模块连接工具，监听 8000/9786）与 `PaceCatView`（雷达），
平时都不开，与车载端部署无冲突。`HT` 账户是本地管理员且**空密码**，RealVNC Server 在跑
（5900 已被 CPE 转发）——这两条是接手时的既有状态，运维通道没有动过它们。

## agv02 —— 老厂前线新多仓位2

| 项 | 值 |
| --- | --- |
| 现场值文件 | [onboard-hmi/config/site-agv02.json](onboard-hmi/config/site-agv02.json) |
| `agvId` / `expectedVehicleKey` | **已确定**（照上面的对应表填，来源是 RIoT） |
| `onboardInstanceId` | **待定**，要新生成一个 Guid |
| IO 模块 | **待定**。同网段见过 `192.168.71.50`，很可能是它，但要实测 502 通了再填 |
| 车载端 | 未部署 |

**已知隐患：**「以太网 6」被配了 `192.168.71.221`，与「以太网 5」的 `192.168.71.180`
同网段。该口当前 `Disconnected`（触控屏自带的第二个网口，未接线），所以暂时无害；一旦接线
就是双网卡同网段、出向路由不确定。agv01 的同一个口是 `169.254.x` 没被配过，**所以这是
agv02 单独被人改的**。未处理，接线前要先决定拆掉哪一个。

## agv03 —— 老厂前线新多仓位3

| 项 | 值 |
| --- | --- |
| 现场值文件 | [onboard-hmi/config/site-agv03.json](onboard-hmi/config/site-agv03.json) |
| `agvId` / `expectedVehicleKey` | **已确定**（照上面的对应表填，来源是 RIoT） |
| `onboardInstanceId` | **待定**，要新生成一个 Guid |
| IO 模块 | **待定**，同上，要实测 |
| 车载端 | 未部署 |

时钟已于 2026-09-03 修好：上线时读到 2027-02-09、快 158.1 天，修后偏移 `+0.0001s`，
源 `172.19.205.222,0x9`。

---

## 部署一台车还缺什么

`06-deploy-onboard-hmi.ps1` 见到 `REPLACE_*` 会**直接拒绝而不是猜一个值**。四个值里
**两个现在已经确定了**（上面的对应表就是来源），另两个仍要人工给：

| 值 | 状态 | 约束 |
| --- | --- | --- |
| `agvId` | **已知** | 就是这台车的 RIoT `deviceName`。示例值 `AGV-8005-01` 被客户端当作占位符，Production 下启动即抛 `InvalidDataException` |
| `vehicleSafety.expectedVehicleKey` | **已知** | 就是这台车的 RIoT `deviceKey`，还须与 ControlServer 登记的一致 |
| `onboardInstanceId` | **待定** | D 形式 Guid（`8-4-4-4-12`），跨部署稳定。`pwsh -c '[guid]::NewGuid().ToString()'`。**不要复制别的车的** |
| `ioModule.host` | **待定** | 实测 502 通过之后再填 |

另外 ControlServer 的 `JourneyRuntime` 目前只登记了 agv01 一台车（`agvId` +
`vehicleKey` 是单值不是列表），要跑另外两台车得先解决那一侧。

`ruleGateway.host` 保留 `127.0.0.1` 即可——规则服务器只在 `wireToGate.enabled=false`
时才连（`App.xaml.cs:41` 用 `DisabledRuleGateway` 顶掉它），而 Production 强制它为 `true`。
配置校验仍要求它不是占位值。

**车载端部署搬完就停，不启动。**上位机是会动的生产设备，`SQCD.Agv.Wpf` 是交互式 WPF 程序
不是服务，就绪判定要人看着车辆安全投影的返回。

---

## 指针：这些东西的真相在别处

| 你要找 | 去哪 |
| --- | --- |
| 日常运维怎么操作、怎么排错 | [onboard-hmi/docs/USAGE.md](onboard-hmi/docs/USAGE.md) |
| 为什么这么设计、GUI 有什么做不到 | [onboard-hmi/README.md](onboard-hmi/README.md) |
| 哪个文件/凭据/配置落在哪 | [onboard-hmi/docs/ASSETS.md](onboard-hmi/docs/ASSETS.md) |
| 两端的部署与发布流程 | [factory-server/docs/wire-to-gate-cd.md](factory-server/docs/wire-to-gate-cd.md) |
| 上位机代码 | 仓库 `8005-agv-onboard-hmi`（Kun Wang 所有，**agent 只读**） |
| 此刻两端真实在干什么 | `pwsh remote-ops/status/Get-WireToGateStatus.ps1 -SiteAlias <别名>`（默认 `agv01`） |
| 别名命名规则、装配器 | [control-host/README.md](control-host/README.md) |

## 怎么重新核对这张表

RIoT 在 `http://172.19.206.222:8888`。**控制端到它走 Clash TUN**（`Find-NetRoute` 会显示
`Clash`，NextHop `198.18.0.1`），探测和请求结果都不可信——**从厂区服务器查**，那边直连
可达，且 `CONTROL_SERVER_RIOT_CALL_API_KEY` 在 User 和 Machine 两个作用域都有。

认证是 `Authorization: Bearer <key>`。三个只读接口：

| 接口 | 给什么 |
| --- | --- |
| `GET /api/device/v1/devices?pageNum=1&pageSize=50` | 完整 `Device对象`：`id`、`deviceKey`、`deviceName`、`hostPort`、`deviceSerialNo` |
| `GET /api/task/vehicles/getAllVehicleSimpleInfo` | 可调度车的 `deviceKey` + `deviceName` |
| `GET /api/task/vehicles/getAllVehicleKeys` | 只有 key 的列表 |

**车上不跑 RIoT**——RIoT 是 ControlServer 侧调的平台 API，车辆本体作为设备注册在上面。
`vehicleKey`（协议与部署配置里的叫法）和 `deviceKey`（RIoT 里的叫法）是同一个东西。
