# MesIngest 持续部署（CD）

CI 已经在 `win11-01` 上跑（见 `8005-mes-ingest/CLAUDE.md`）。这份文档讲的是它后面
那一段：**怎么把构建产物送上厂区服务器，怎么退回去，出事怎么查**。

生效日期 2026-09-02。

---

## 1. 三十秒版

```bash
# 一、出包（CI，手动触发）
gh workflow run release.yml --repo trytoreachpeak0/8005-mes-ingest

# 二、部署服务器（控制端）
pwsh -File remote-ops/factory-server/scripts/13-deploy-mes-ingest-server.ps1

# 三、部署本机 Watch（控制端）
pwsh -File remote-ops/factory-server/scripts/14-deploy-mes-ingest-watch-local.ps1
```

出事了：

```bash
pwsh -File remote-ops/factory-server/scripts/13-deploy-mes-ingest-server.ps1 -Rollback
```

---

## 2. 为什么是这个形状

```
  8005-mes-ingest (GitHub)
          │  workflow_dispatch，手动
          ▼
  release.yml  ──跑在 win11-01 的 headless runner 上
          │    Publish-MesIngest.ps1 → Test-ReleasePackage.ps1 → zip + sha256
          ▼
  GitHub artifact
          │  gh run download
          ▼
  控制端 ──验 SHA-256──▶ scp ──▶ factory01
                                    │
                                    ├─ Install-MesIngestServer.ps1
                                    │    建库 → 停服务 → 换包 → 写配置 → 起服务 → 健康检查
                                    └─ D:\zhengyushao\MesIngest
```

三个决定值得单独说明，因为它们看起来都有"更省事"的写法：

**runner 不直接部署。**`win11-01` 是 factory-server 的 Hyper-V 客户机，宿主就在
`192.168.200.1`。让 runner 直接 SSH 过去是最短的路，但那等于把一把能进生产服务器的
管理员钥匙放在 CI 上——任何能往那个仓库提 PR 或改 workflow 的路径，最终都能碰到
`AgvAmhs`、`AGV.Web`、RabbitMQ 和 `SQAGV`。中转一道控制端，人始终在路径上，同时
部署本身仍然是一条命令。

**手动触发，不跟推送。**一次部署要停 Windows 服务、换掉整个安装目录。这不是一次
`git push` 该顺带做的事。同样的理由已经写在黄金渲染机的 Validation 阶段上。

**编排脚本不进安装包。**`Test-ReleasePackage.ps1` 会递归扫包里所有 `.ps1` 找未经授权的
`DROP DATABASE`，并且只允许两个 canonical `.sql` 路径存在。往包里塞部署脚本会让每次
发布验证直接失败。所以包保持原样，编排脚本走 `remote-ops`，在服务器的包外目录
`D:\zhengyushao\mes-ingest-ops\` 执行。

---

## 3. 一次性准备

这两步只做一次，之后每次发布都不用再碰。

### 3.1 SQL Server 授权

服务器上的 `agvops` 默认**连不上** SQL Server（实测报
`用户 'WIN-0HD72AV4K31\agvops' 登录失败`）。用 Navicat 或 SSMS 以 **sysadmin** 身份连
`WIN-0HD72AV4K31`，把 `scripts/mes-ingest/grant-agvops-sql-access.sql` 整段跑一次。

它给 `agvops` 两项权限，**不给 sysadmin**：

| 权限 | 用途 |
| --- | --- |
| `dbcreator` | 建 `MesIngest` 库 |
| `ALTER ANY LOGIN` | 建 `mesingest` 这个专用应用登录 |

⚠️ **这是一个真实的口子，不是形式主义的警告。**`ALTER ANY LOGIN` 允许改其他 SQL 登录
的密码，`sa` 也在内。也就是说，拿到控制端 `~/.ssh/agv_srv_ed25519` 的人，理论上顺着
这条路能碰到同实例上的 `SQAGV` 生产库。这个取舍是为了让 CD 不必每次找人提权而做的，
脚本末尾有收回的语句。

**现状（2026-10-12 补记）：上面两项之后，`agvops` 已于 2026-09-15 提为 sysadmin**（用用户提供的
`sa` 密码，为读 server-state DMV；`../README.md` 第 5 节），2026-10-11 夜实读
`IS_SRVROLEMEMBER('sysadmin')` 为 1。**用户 2026-10-12 定不收回、如实记录。**所以现在那把私钥
经 `agvops` 能直接读写同实例上的一切，包括 `SQAGV`，不必再绕 `ALTER ANY LOGIN`；本节的两项授权
仍然是首次部署要跑的脚本，但已不是 `agvops` 的权限上限。脚本末尾的收回语句只收回那两项，
收不回 sysadmin（要收回是 `ALTER SERVER ROLE sysadmin DROP MEMBER`，先问用户）。

### 3.2 部署凭证

三个秘密存在控制端，DPAPI 加密，只有当前 Windows 用户能解：

```bash
pwsh -File remote-ops/factory-server/scripts/mes-ingest/Set-MesIngestSecret.ps1 -Import 'C:\MesIngest\service\appsettings.Local.json'
```

| 秘密 | 来源 |
| --- | --- |
| `OraclePassword` | `-Import` 从退役的本机安装里搬过来，不用手敲 |
| `SqlPassword` | 你现场输入，`mesingest` 登录就用这个密码创建 |
| `SharedSecret` | 脚本生成 32 字节随机值，永不显示 |

SQL 密码在输入时就会校验复杂度：**至少 8 位，且大写/小写/数字/符号四类里占三类，
不含登录名**。不合格会当场重问。这条规则是照 Windows 默认策略写的，故意不比它更严——
本地检查不可能是权威的，所以过了不等于服务器一定接受，但没过则一定被拒。

登录是用 `CHECK_POLICY = ON` 创建的，密码不合规时 SQL Server 报：

```
消息 15118，级别 16，状态 1
密码验证失败。该密码不够复杂，不符合操作系统策略要求。
```

改密码用 `-ResetSqlPassword`（不加这个开关，已存在的密码不会被重问）：

```bash
pwsh -File remote-ops/factory-server/scripts/mes-ingest/Set-MesIngestSecret.ps1 -ResetSqlPassword
```

改完直接重跑部署即可。建库和建登录都是幂等的：库已存在就跳过，登录已存在就把密码
`ALTER` 成新值。

存储位置 `%LOCALAPPDATA%\AgvOpsSecrets\mes-ingest-deployment.xml`，和 `agvops` 的应急
密码同一个目录。**不进仓库、不进 CI、不进命令行、不进日志。**

查状态（只报告设没设，不显示值）：

```bash
pwsh -File remote-ops/factory-server/scripts/mes-ingest/Set-MesIngestSecret.ps1 -Show
```

轮换 `SharedSecret` 之后**必须两端一起重新部署**，否则 Watch 认证不过：

```bash
pwsh -File .../Set-MesIngestSecret.ps1 -RotateSharedSecret
pwsh -File .../13-deploy-mes-ingest-server.ps1
pwsh -File .../14-deploy-mes-ingest-watch-local.ps1
```

---

## 4. 部署长什么样

### 服务器（`factory01`）

| 项 | 值 |
| --- | --- |
| 安装根 | `D:\zhengyushao\MesIngest` |
| 上一版 | `D:\zhengyushao\MesIngest.previous`（只留一代） |
| 编排脚本与临时配置 | `D:\zhengyushao\mes-ingest-ops`（ACL 只给 SYSTEM + Administrators） |
| 包落地 | `D:\zhengyushao\mes-ingest-staging` |
| Windows 服务 | `MesIngest`，自动启动，LocalSystem |
| 监听 | `http://0.0.0.0:5088` |
| 数据库 | 本机 `MSSQLSERVER` 实例，库 `MesIngest`，登录 `mesingest`（仅该库 `db_owner`） |
| Oracle | `172.19.1.152:1521/SQMES`，用户 `fwmes`，Thin 模式 |
| Watch | `D:\zhengyushao\MesIngest\watch`，快捷方式在 `C:\Users\Public\Desktop` |
| 防火墙 | 入站规则 `MesIngest Host HTTP`，仅 TCP 5088 |

### 控制端

| 项 | 值 |
| --- | --- |
| Watch 安装根 | `C:\MesIngest-Watch` |
| 上一版 | `C:\MesIngest-Watch.previous` |
| 连接目标 | `http://172.19.205.222:5088` |
| 快捷方式 | 桌面 `MesIngest Watch.lnk`（原来指向已退役的 `C:\MesIngest\watch`，部署时自动改指） |

---

## 5. 关于绑定与鉴权

Host 绑 `0.0.0.0:5088`，因为控制端的 Watch 要连它。代价是**所有请求都要带 Bearer**——
`MesIngest.Host/Program.cs:182` 那道中间件对整条管道生效，不区分来源，本机回环也一样。
所以：

- 服务器上那个 Watch 虽然走 `127.0.0.1`，配置里同样有 `SharedSecret`；
- 部署脚本的健康检查也带 `Authorization: Bearer`，不带会拿到 401 而不是契约；
- 手工 `curl` 调试时忘了带头，看到的 401 是设计如此，不是服务坏了。

防火墙那条规则**今天不影响任何东西**：`em4` 属 Private profile，而 Private 是关的。
加它是为了哪天某个 profile 被打开时，服务不会毫无征兆地从网络上消失。

---

## 6. 回滚

```bash
pwsh -File remote-ops/factory-server/scripts/13-deploy-mes-ingest-server.ps1 -Rollback
```

`MesIngest.previous` 换回 `MesIngest`，失败的那份留在 `MesIngest.rollback-failed`，服务
重启。**只回滚程序，不回滚数据库。**数据库回退是另一件事，有停机和备份前置，走
`pack/UPGRADE.md` 和 `scripts/cutover/`——那里是产品中唯一会删库的入口。

只保留一代 previous 是有意的。留两代之后，"哪个是上一版"就成了一个要在压力下回答的
问题。

---

## 7. 排错

**部署卡在健康检查。**服务起来了但 `/api/v2/contract` 五分钟没应答。空库首次启动要
建 schema v29，慢是正常的，但五分钟到了还没好通常是别的原因。Host 作为服务运行时写
**Windows 应用程序事件日志**：

```bash
ssh factory01 "Get-WinEvent -LogName Application -MaxEvents 30 | Where-Object { \$_.Message -match 'MesIngest' } | Select-Object TimeCreated,LevelDisplayName,Message | Format-List"
```

配置被拒绝会表现为启动异常而不是 500——Host 见到已退役的配置键会直接拒绝启动，这是
ADR-mes-0017 要求的行为。

**`SourceDirty=True` 被拒。**包是从脏工作树构建的，追不回是哪个提交。CI checkout 天然
干净，出现这个说明有人在本地 `Publish-MesIngest.ps1` 之后手动传了包。

**Watch 连不上。**先确认路由没被 Clash TUN 劫持——`14-deploy-...` 脚本开头会自己检查
并拒绝继续，手工确认用：

```powershell
Find-NetRoute -RemoteIPAddress 172.19.205.222 | Select-Object -First 1 InterfaceAlias
```

出现 `Clash` 就是假的。装绕行路由：`scripts/01-control-host-route.ps1`。

**契约版本不匹配。**Watch 要求版本和能力集合精确匹配，不匹配就拒绝解释业务数据。两端
用同一个 artifact 部署即可避免；跨版本部署了就把两边都重新跑一遍。

---

## 8. 边界

- **CD 不跑打包发布门禁。**`Invoke-PackagedReleaseGate.ps1` 要在金机的交互式会话里跑，
  几十分钟，并且会产出需要人判断的图像。它属于切 RC 的流程，不属于每次部署。
- **CD 不删数据库。**产品里唯一会删库的入口是 `scripts/cutover/Invoke-EmptyDatabaseCutover.ps1`，
  它要求停机、备份和人工确认精确目标。部署脚本只会 `CREATE DATABASE`，而且只在库不存在时。
- **CD 不动 `SQAGV`。**一行都不碰。
- **历史不迁移。**按 ADR-mes-0017 这是空库整体替换。控制端上那两个库
  （`MesIngest_V2` 18.9 GB、`MesIngest_V2_29` 3.5 GB）已于 2026-09-02 按用户要求
  DROP，没有备份。服务器上的历史从第一个成功的 `MesTaskUnionRound` 重新开始。
- **控制端 `C:\MesIngest` 保留未删。**服务已停止并禁用，但目录还在，Oracle 凭证就是从
  它里面搬出来的。服务器跑稳之后手动删。
