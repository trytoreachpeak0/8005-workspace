# WIRE_TO_GATE 持续部署（CD）

ControlServer 的 CI 已经在 `win11-01` 上跑（`.github/workflows/test.yml`）。这份文档讲的是
它后面那一段：**怎么把两端一起打包送上线，怎么退回去，出事怎么查**。

服务端去厂区服务器，车载端去 AGV 上位机，**同一个包**。

生效日期 2026-09-02。

---

## 1. 三十秒版

```bash
# 一、出包（CI，手动触发，要指定车载端 commit）
gh workflow run release.yml --repo trytoreachpeak0/8005-agv-control-server \
  -f onboard_commit=238b46eb2c9ae90584e4288a782176f66b7de942
```

```bash
# 二、部署服务端（控制端）
pwsh -File remote-ops/factory-server/scripts/15-deploy-control-server.ps1
```

```bash
# 三、部署车载端（控制端）。搬完就停，不启动。
pwsh -File remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1
```

出事了：

```bash
pwsh -File remote-ops/factory-server/scripts/15-deploy-control-server.ps1 -Rollback
```

车载端没有 `-Rollback`，上一代原样留在 `C:\8005\OnboardHmi.previous`，人工换回去。

---

## 2. 为什么是这个形状

```
  8005-agv-control-server (GitHub)
          │  workflow_dispatch，手动，输入车载端 commit
          ▼
  release.yml ── 跑在 win11-01 的 headless runner 上
          │   ├─ actions/checkout 把只读的 onboard 仓库拉成一份 scratch 镜像
          │   └─ New-WireToGateReleaseCandidate.ps1
          │        ├─ 服务端从 HEAD 构建
          │        ├─ 车载端从镜像的一次性克隆构建
          │        └─ 联合 release identity + 依赖/许可证清单 + 秘密扫描门禁
          ▼
  GitHub artifact（一个 zip + sha256 + release-manifest.json）
          │  gh run download
          ▼
  控制端 ──验 SHA-256──┬─▶ scp ─▶ factory01 ─▶ Install-ControlServerRemote.ps1
                       │             停服务 → 换包 → 写配置 → 起服务 → 健康检查
                       │             D:\zhengyushao\ControlServer
                       │
                       └─▶ scp ─▶ agv01 ────▶ 填配置 → 落盘 → 验可达 → **停**
                                     C:\8005\OnboardHmi
```

四个决定值得单独说明，因为它们看起来都有"更省事"的写法：

**一个包装两端。**`docs/RELEASE-CANDIDATE.md` 第 8.1 节写得很直白：明文期的两端之间
**没有协商、没有降级、没有自动探测**，版本错配的表现是连接被拒，而不是一条说明原因的
错误。把两半放进同一个 release identity，"两端同版本"就成了产物的属性，而不是一条要靠
人记住的纪律。代价是每次动车载端也要走 ControlServer 仓库的 workflow——这个代价是划算的。

**车载端从只读仓库的一次性克隆构建。**`8005-agv-onboard-hmi` 对 agent 只读，
`New-WireToGateReleaseCandidate.ps1` 早就是这个形状：clone 到输出目录旁边，构建，从不碰
已有工作树。workflow 里那一步 `actions/checkout` 只是把克隆源换成本机镜像，**目的是不让
token 出现在任何 git 命令行或 runner 的全局 git config 上**——那台 runner 活得比一次作业长。

**runner 不直接部署，必须经控制端中转。**`win11-01` 是 factory-server 的 Hyper-V 客户机，
宿主就在 `192.168.200.1`。让 runner 直连是最短的路，但那等于把一把能进生产服务器的管理员
钥匙放在 CI 上——任何能改那个仓 workflow 的路径最终都能碰到 `AgvAmhs`、`AGV.Web` 和
`SQAGV`。这跟 MesIngest CD 的理由是同一条，见 [mes-ingest-cd.md](mes-ingest-cd.md)。

**车载端搬完就停，不启动。**三条理由，没有一条是"谨慎起见"：

1. 目标是**会动的生产车辆**。`RELEASE-CANDIDATE.md` 第 11 节要求真实车辆动作**逐次授权
   加现场物理安全 GO**，两者都要、每次都要、不可复用；
2. `SQCD.Agv.Wpf` 是**交互式 WPF 程序，不是服务**。没有"停-换-起"这回事，它需要一个有人
   坐在前面的桌面会话；
3. 就绪判定本来就该是人的。第 8 节说干净会话进 `Ready` 的前提是车辆安全投影返回
   `motionState=STOPPED` 且证据未过期——看着那个结果，正是有人在场的意义。

脚本把到这条线之前的事全做完：验包、填现场值、拒掉客户端启动时会拒的配置、放二进制、
设凭据，并且**从车上**证明它被指向的那台服务器真的应答。

---

## 3. 一次性准备

四步，之后每次发布都不用再碰。

### 3.1 给 CI 一个能读车载端仓库的 PAT

`GITHUB_TOKEN` 只对当前仓库有权限，看不见 `8005-agv-onboard-hmi`。需要一个 fine-grained
PAT，**只给那一个仓库的 Contents: Read**，存成 ControlServer 仓库的 secret：

```bash
gh secret set ONBOARD_HMI_TOKEN --repo trytoreachpeak0/8005-agv-control-server
```

⚠️ 这把 token 让 CI 能读 Kun Wang 的仓库。只给读，不给写；权限范围只勾那一个仓库，别用
classic token 的全账号 `repo` scope。

### 3.2 部署凭证

四个秘密存在控制端，DPAPI 加密，只有当前 Windows 用户能解：

```bash
pwsh -File remote-ops/factory-server/scripts/control-server/Set-ControlServerSecret.ps1 -Import
```

| 秘密 | 环境变量 | 来源 |
| --- | --- | --- |
| `RiotCallApiKey` | `CONTROL_SERVER_RIOT_CALL_API_KEY` | `-Import` 从本机环境变量搬 |
| `OnboardCredential` | `CONTROL_SERVER_ONBOARD_CREDENTIAL` | 你现场输入，**两端共用同一个值** |
| `MesIngestSharedSecret` | `CONTROL_SERVER_MES_INGEST_SHARED_SECRET` | `-Import` 从 MesIngest 的 store 搬 |
| `OperatorId` | `CONTROL_SERVER_OPERATOR_ID` | `-Import` 从本机环境变量搬 |

`-Show` 只报告哪些存在、多少字符，永远不打印值。

⚠️ `OnboardCredential` 是**明文过网的静态共享密钥**。第 11.1 节说得很清楚：链路明文之后，
在网络上抓一次包即可永久冒充该车载端，不轮换、不挑战应答、重放没有时间窗。这是 2026-08-31
在知情前提下接受的取舍，前提是受控的工厂内网——不是这套脚本能改善的东西。

### 3.3 每台车的站点文件

车载端配置模板有 6 个 `REPLACE_*` 现场值。它们不是秘密（`vehicleKey` 早就明文写在
ControlServer 的 `appsettings.json` 里），所以进 git，一台车一个文件：

```bash
cp remote-ops/onboard-hmi/config/site-agv01.example.json \
   remote-ops/onboard-hmi/config/site-agv01.json
```

填这些：

| 键 | 说明 |
| --- | --- |
| `wireToGate.onboardInstanceId` | **必须跨部署稳定**。服务端把新值当成另一个车载实例 |
| `vehicleSafety.expectedVehicleKey` | 现场登记的 RIoT `vehicleKey` |
| `ruleGateway.host` | 规则服务器 IP |
| `ioModule.host` | 八仓 IO 模块 IP |
| `agvId` / `onboardInstanceId` | 顶层标识 |

`REPLACE_CONTROL_SERVER_IP` 和 `REPLACE_CONTROL_SERVER_HOST` 不在站点文件里——它们由部署
脚本按 `-ControlServerHost` / `-HealthPort` 算出来，两端不会填岔。

站点文件缺失或还留着占位符，脚本**直接拒绝**，不猜。

### 3.4 控制端到服务器的路由

`172.19.205.222` 的绕行路由 MesIngest CD 已经装过了。确认一次：

```powershell
Find-NetRoute -RemoteIPAddress 172.19.205.222 | Select-Object -First 1 InterfaceAlias
```

显示 `Clash` 就跑 `scripts/01-control-host-route.ps1`。部署脚本自己也会检查这条并告警，
但它只能告警，不能替你判断结果的真假。

---

## 4. 一次完整发布

```bash
# 1. 确认要发的车载端 commit
git -C 8005-agv-onboard-hmi log --oneline -1 OnboardHmi_MVP
```

```bash
# 2. 出包
gh workflow run release.yml --repo trytoreachpeak0/8005-agv-control-server \
  -f onboard_commit=<40 位 hash>
```

```bash
# 3. 先干跑一次，看它打算做什么
pwsh -File remote-ops/factory-server/scripts/15-deploy-control-server.ps1 -WhatIf
```

```bash
# 4. 部署服务端
pwsh -File remote-ops/factory-server/scripts/15-deploy-control-server.ps1
```

服务端跑完会打印两个端点和车载端该用的 commit。**先服务端后车载端**：车载端落地时会从车上
探一次投影端点，服务端不在就只能拿到一条 `UNREACHABLE` 告警。

```bash
# 5. 车载端也先干跑，它会把渲染好的配置整份打出来
pwsh -File remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -WhatIf
```

```bash
# 6. 部署车载端
pwsh -File remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1
```

```bash
# 7. 人到车前，确认车的状态，然后启动
ssh agv01 "Start-Process 'C:\8005\OnboardHmi\SQCD.Agv.Wpf.exe'"   # ← 不要这样做
```

最后这条**故意划掉**。`SQCD.Agv.Wpf` 要交互式桌面会话，SSH 起的进程在 session 0 里看不见
窗口；更要紧的是启动它意味着一台会动的车进入待命。到车前去，用它自己的桌面。

---

## 5. 服务器上的布局

| 位置 | 内容 |
| --- | --- |
| `C:\Program Files\8005 AGV\ControlServer` | 服务安装根，Windows 服务 `8005 AGV ControlServer` |
| `C:\ProgramData\8005\ControlServer` | 数据根，SQLite 与日志 |
| `C:\ProgramData\8005\ControlServer-backups` | 产品脚本自己的升级备份，一次一目录 |
| `D:\zhengyushao\ControlServer` | 当前部署的包（含 `scripts/`、`onboard-hmi/`、清单） |
| `D:\zhengyushao\ControlServer.previous` | 只留一代，`-Rollback` 换回去 |
| `D:\zhengyushao\control-server-ops\results` | 每次安装的结果 JSON 与诊断日志 |

绑定：`tcp://172.19.205.222:58005`（车载 NDJSON）和 `http://172.19.205.222:58007`
（健康 + 车辆安全投影）。

**默认绑具体网卡 IP 而不是 `0.0.0.0`**，因为 `0.0.0.0` 会连带把服务暴露到 Hyper-V 的
`AGV-Internal`（`192.168.200.0/24`），而 CI runner 就住在那个网段上。CI 没有理由够得到
ControlServer。

车上：`C:\8005\OnboardHmi`，上一代在 `C:\8005\OnboardHmi.previous`。

---

## 6. 四个不显然的约束

**1. 安装编排脚本不进包，也不重写产品脚本。**包里自带
`scripts\Install-ControlServerLocal.ps1` 和 `Update-ControlServerLocal.ps1`，备份、ACL、
生命周期检查、失败回滚全在里面。`Install-ControlServerRemote.ps1` 只做它们不做的事：验哈希、
把秘密放到它们读取的作用域、注入 MesIngest token、开防火墙、留一代旧包。首装还是升级由机器
状态决定，不由调用方指定——所以控制端永远是同一条命令。

**2. MesIngest 的 Bearer token 是产品脚本不管的那一个。**MesIngest 在服务器上绑
`0.0.0.0:5088`，它的中间件不区分来源，**走回环也要 Bearer**。而
`Install-ControlServerLocal.ps1` 只注入 RIoT key 和车载凭据。所以远程编排脚本在安装后往服务
的注册表 `Environment` 里补一条并重启。现在补而不是等到需要时补，是为了让以后启用
`JourneyRuntime` 是一次配置变更，而不是一次重新部署。

**3. RIoT key 从 User 作用域读，车载凭据从 Machine 作用域读。**这是
`Install-ControlServerLocal.ps1` 的既有行为（缺任何一个就 throw），两处读的都是注册表而不是
进程环境块，所以远程脚本在同一会话里先写后调子进程是成立的。别改成命令行传参——那会让密钥
进入进程命令行。

**4. 服务器上没有 `curl.exe`。**Windows Server 2016 不带，它是从 Server 2019 才内置的。
第 4.4 节要求"用带 `--noproxy` 的 curl 读 body 判定可达"，服务器这边用 PowerShell 7 的
`Invoke-WebRequest -NoProxy` 达到同样效果。控制端和车上同理。

---

## 7. 出事了

| 症状 | 先看 |
| --- | --- |
| workflow 在 checkout onboard 镜像时失败 | `ONBOARD_HMI_TOKEN` 过期或权限不够（3.1） |
| workflow 在扫描门禁失败 | 秘密扫描或许可证解析。日志里有具体规则和文件，**不会打印匹配到的值** |
| `gh run download` 找不到 artifact | artifact 保留 30 天；重新跑一次 release |
| 包哈希对不上 | 控制端和服务器各验一次。scp 被截断就是这么抓出来的 |
| 服务起来了但控制端连不上 | 先查 `Find-NetRoute` 是不是 Clash；再查服务器防火墙那两条规则 |
| 车上报 `vehicle-safety UNREACHABLE` | 服务端没部署，或绑的地址车上够不着 |
| 车载端启动即抛 `WIRE_TO_GATE配置键...已移除` | 配置里有残留的 `useTls` / `serverCertificateSha256`。**判据是键在不在，不是值是什么**——删键，别改成 `false` |
| 车载端停在 `RecoveryRequired` | 先看 `GET /api/runtime/sessions` 的 `reasonCode`。`DEPARTURE_SAFETY_NOT_READY` 表示恢复报告收到了但车辆停稳事实不满足，**这是闸门在工作**；只有 `HANDSHAKE_INCOMPLETE` 才去查五步握手 |

诊断日志和结果 JSON 在服务器 `D:\zhengyushao\control-server-ops\results\`，一次安装一对。

---

## 8. CD 不做什么

- **不跑门禁。**`G1`/`G2`/`G3`/`RC` 属于切发布候选的流程，不在部署路径上。CD 送的是产物，
  不是资格。
- **不启用 `JourneyRuntime`。**产品安装脚本以 `enabled=false` 部署——不建单、不动车。启用它
  是一次单独的、需要现场事实和授权的配置变更。
- **不碰 `SQAGV`，不碰 MesIngest 的库。**ControlServer 用自己的 SQLite，安装期迁移。
- **不启动车载端。**见第 2 节。
- **不管两端版本一致以外的兼容性。**协议改版会作废两边的 G1/G2/G3 证据，那是另一条流程。
