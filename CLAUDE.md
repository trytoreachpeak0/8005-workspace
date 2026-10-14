# 8005-workspace

A workspace of independent git repositories, not a monorepo. Each subdirectory
is its own clone with its own remote — stage, commit, and push one repository at
a time, and never assume a change in one is visible to another.

Each repository carries its own `CLAUDE.md` with the rules for working inside
it, and Claude Code loads those only once it reads a file in that directory —
with one exception, imported on the next line so that it arrives at session
start instead:

@repos/8005-test-lab/CLAUDE.md

That one is imported because `8005-test-lab` is an agent-first tool whose own
`CLAUDE.md` tells a session what to read and in what order, and a reading order
that arrives *after* the session has already read something in that repository
arrives too late to be a reading order. Measured 2026-09-09 in
[#34](https://github.com/trytoreachpeak0/8005-test-lab/issues/34): the five
sessions that worked that map never received it at session start. The other five
repositories keep the on-demand behaviour, which suits them — their rules are
about editing code that is already in front of you.

This file is the authority on write access and applies from the start of every
session. Where a repository restates any of it, this file wins.

## Repository write authority

Identified by remote, not by directory name. These rules apply to each remote
below and to every local clone or worktree whose `origin` resolves to it,
wherever it sits on disk.

| Remote under `github.com/trytoreachpeak0/` | Authority |
| --- | --- |
| `8005-agv-program` | Writable — requirements, cross-subsystem ADRs, decision archive. No code |
| `8005-agv-control-server` | Writable — WIRE_TO_GATE server |
| `8005-mes-ingest` | Writable — MesIngest service and its Watch client |
| `riot-sdk` | Writable — RIoT SDK, C# and Python |
| `8005-agv-onboard-hmi` | Writable **on `w2g/*` branches only** — never `OnboardHmi_MVP` |
| `slots-simulator` | Writable **on `w2g/*` branches only** — never `main` |
| `8005-agv-protocol` | Writable — no announcement duty since 2026-09-08 |
| `8005-test-lab` | Writable — agent-first multi-machine test lab; decisions only until its `wayfinder:map` issue clears |

### Branch-scoped write

`8005-agv-onboard-hmi` and `slots-simulator` were read-only for agents until
2026-09-04. **The development work on both is now ours** — Kun Wang is no longer
expected to carry them. What replaced the old rule is narrower than "writable":

- **Work only on `w2g/*` branches.** Create them, commit to them, push them.
  The local worktree is now ours to edit, which it was not before.
- **Never push to their working branch** — `OnboardHmi_MVP` for the onboard HMI,
  `main` for the simulator. Never force-push anything there, never delete or
  rewrite a branch that is not ours, never tag or release.
- **Changes still arrive as a pull request** into that working branch, and
  **since 2026-09-09 both the agreement and the merge are ours.** The pull request
  is not ceremony: it is still where a change is reviewed, where its evidence is
  recorded, and what the slice board points at. What it is no longer is a gate
  somebody outside this workspace holds.

  This rule moved twice, and the second move is the one to remember. Until
  2026-09-08 a merged PR was "a decision, not a delivery" — Kun Wang clicked
  merge. That day the click moved to us while **his agreement was still
  required**. On 2026-09-09 the user removed that requirement too, on exactly the
  grounds that moved the release signature: he took over Kun Wang's project
  outright, so a rule demanding an approval nobody is there to give does not hold
  a line — it just stalls work, and gets worked around instead of followed.

  Everything else about those branches is unchanged: **never push to
  `OnboardHmi_MVP` or `main` directly** — a change still gets there by opening a
  PR and merging it, never by pushing — never force-push, never delete or rewrite
  a branch that is not ours, never tag or release.
- Issues, pull requests and comments stay allowed, as they have been since
  2026-09-03.

Two consequences worth knowing before they bite:

- **A dirty worktree in either repository aborts an L2 run.**
  `Get-L2PeerPublish` publishes both peers from a throwaway clone of the local
  repository and refuses a dirty source rather than testing uncommitted state
  behind your back. That check used to be free — nothing wrote there. Now it is
  a thing to remember: commit to your `w2g/*` branch before running L2.
- **Their `CLAUDE.md` and `docs/` are still their documents.** Changing how those
  repositories describe themselves is a different act from fixing their code;
  it belongs in a PR he actually asked for, not in passing.

**`ONBOARD_HMI_G2` moved to us on 2026-09-04.** It was deliberately left open when
development transferred — taking over the code does not by itself move a gate —
and the user then decided that it does move. We run that gate and fill in that
column now; the board no longer waits on Kun Wang for it.

**Release signing moved too, on 2026-09-08.** It had not: this paragraph used to
say that taking over both G2 gates was "not a path to signing alone", and that
Kun Wang remained the mandatory second signature. The user then took over his
project outright, which left the rule demanding a signature nobody could give —
and a rule like that does not hold the line, it just gets worked around. So the
rule changed rather than being bypassed: `docs/release-governance.md`, the
attestation JSON Schema and `tools/g1-validate.mjs` (`size===2` → `size===1`)
were all changed together, and `protocol-v0.2.0` was released under the new one.

**Releases carry exactly one approval — and since 2026-09-12 an AI agent may give
it.** The user decided that on 2026-09-12: requiring them to run every release by
hand added a step without adding a decision. An agent approves a release only when
the user has authorized that specific release in the conversation, and the
attestation says so — `approverKind: AI_AGENT` plus `authorizedBy` naming the user —
so it is never read as the user's own signature. **CI still cannot approve.**

### Notify-after-change

`8005-agv-protocol` is writable. Zhengyu Shao decides its content alone — Kun
Wang's approval is **not** required in advance (changed 2026-09-02; the earlier
dual-approval gate no longer applies).

**There is no notify-after-change duty any more, as of 2026-09-08.** Until then
every pushed change had to be announced to Kun Wang in an issue that
`@SocialKKKK`, because the protocol was the contract his side built against and a
release voided his gate evidence. The user took over his project outright, so
neither premise holds: no other side builds against this contract, and there is
no gate evidence of his left to void. Do not open announcement issues, and do not
`@SocialKKKK` anything.

What did not change is why that rule existed. **A protocol push still voids gate
evidence — ours.** Say which `W2G-IS-*` slices a change touches and which evidence
it invalidates, in the commit message and in the slice board. The audience moved;
the accounting did not.

Formal releases need an approval attestation before an immutable tag — **exactly
one approval**: the product owner, or since 2026-09-12 an AI agent the product owner
authorized for that release (two product owners before 2026-09-08). **CI still
cannot approve.** That governs tagging a `ProtocolRelease`, not ordinary commits.

### Scope

Routing a problem to a repository never grants write access to it. These
restrictions override Wayfinder routing, execution authorization in map Notes,
and general requests to fix, document, commit, or push. Only a later explicit
user instruction changing this standing policy may alter the list above.

`w2g-rc-*/` are release-candidate artifact snapshots, not working trees. Read
them for reference; never develop in them.

## Scripting baseline

PowerShell 7 is the shell for every script written in this workspace. Do not
write Windows PowerShell 5.1 compatible code, do not add version probes,
compatibility shims, or 5.1 fallbacks, and do not invoke `powershell.exe` —
call `pwsh`. Every new `.ps1` opens with:

```powershell
#Requires -Version 7
```

Use PS7 features directly where they are the clearest expression: `&&`/`||`,
`??`, `?.`, the ternary operator, `ForEach-Object -Parallel`,
`ConvertFrom-Json -AsHashtable`, and UTF-8-without-BOM file defaults. Every
machine this workspace reaches runs pwsh 7.6.5 — the control host, the AGV
onboard HMI machines under `remote-ops/onboard-hmi/`, and the factory server
under `remote-ops/factory-server/` — so remote scripts follow the same rule.

There is no live exception. The earlier one covered the Windows Server 2016
factory host, on the grounds that it was offline and had only Windows
PowerShell 5.1. Both premises stopped being true: verified 2026-09-01, that
host has pwsh 7.6.5, a registered `PowerShell.7` remoting endpoint, and direct
internet access. New scripts targeting it are PowerShell 7 like everything
else.

What survives is narrower, and it is a freeze rather than an exception: the
already-released MES ingest scripts under
`repos/8005-mes-ingest/.artifacts/releases/` keep their
`#Requires -Version 5.1` header. They were validated and shipped as 5.1
artifacts. Never retrofit a released script in either direction — not to PS7,
and not back to 5.1.

## 协作与语言

项目由两个人推进。**分工在 2026-09-04 变了**：`8005-agv-onboard-hmi` 与
`slots-simulator` 原本由 Kun Wang（GitHub `SocialKKKK`）负责，现在**开发工作在
Zhengyu Shao 这边**——我们在那两个仓开自己的 `w2g/*` 分支改，改完开 PR 进它们的工作分支，
**2026-09-09 起同意与合并都归我方**，不再等 Kun Wang（见上面 Branch-scoped write）。
`8005-agv-control-server` 一直是 Zhengyu Shao 的；`8005-agv-protocol` 共同维护。**权威文档是
`repos/8005-agv-program/docs/collaboration-workflow.md`**，各仓 `CLAUDE.md` 里内联了
agent 必须遵守的部分。

注意 `8005-workspace` 这个仓库**只有 Zhengyu Shao 有访问权**，Kun Wang 看不到。任何需要
对方看到的东西不能只写在这里。

协作单位是 `repos/8005-agv-protocol/integration-slices/index.json` 里的 integration slice
（`W2G-IS-00` 到 `W2G-IS-07`），每个切片的 `gates` 就是分工。跨仓库反馈必须带可复现的
门禁证据。protocol 由 Zhengyu Shao 单独决定内容，**推送后不再需要通知任何人**
（2026-09-08 起，此前每次推送都要开 issue @`SocialKKKK`，见上面 Notify-after-change）。
发布打 tag 同日起**改为单人签名**（此前双人）；**2026-09-12 起 AI 也可以批准**，
前提是用户在对话里授权了那一次发布，attestation 如实记 `approverKind: AI_AGENT` 与
`authorizedBy`；**CI 仍然不能批准**。协议改动仍然要攒批次——发布会作废受影响的 G1/G2/G3
证据，现在作废的是我方自己的。

**agent 指令文件用英文**（各仓 `CLAUDE.md`、`.claude/` 下的规则与 skill、
`docs/agents/`）；**人看的东西用中文**（README、文档正文、`docs/defects/`、证据
`SUMMARY.md`、issue 与 PR 的标题和正文、commit message 正文）。中文里保持英文：
commit 的 conventional 前缀、标识符、路径、命令、环境变量、错误码、门禁与切片名、
协议消息名与 schema 字段与 `vectorId`。引用报错和测试输出先贴英文原文再中文解释。
不回溯改旧的。

## CI：不用托管 runner，改用 factory-server 上的 self-hosted runner

**不要用 GitHub 托管 runner。**2026-09-02 试过五轮，riot-sdk 与 control-server
通过，但 `8005-mes-ingest` 有一整批测试对运行机器有硬假设，托管 runner 满足不
了——断言真实桌面工作区 >= 1280x760、要 Oracle 客户端 thick 模式、断言"取消在
3 秒内返回"这种挂钟行为（托管机上要 46-53 秒）。这不是配置问题，是这套测试的
固有属性：它本来就是为一台特定机器写的。这个判断没有变。

**改用 self-hosted runner**（同日晚些时候的决定，取代了当时"完全不用 CI"的结
论）：runner 跑在 factory-server 的 Hyper-V 客户机 `win11-01` 上（`ssh vm01`），
那台机器同时接替控制端的 `gpt_win11` 成为黄金渲染机。它满足全部机器假设，而且
砍掉了 `Invoke-GoldenRendererValidation.ps1` 那 823 行"因为测试机在别处"才需要
的编排——payload 部署、PowerShell Direct 会话、计划任务注册、证据回捞全部不再
需要。**已于 2026-09-02 落地**：该脚本删除，其中真正有价值的打包发布门禁独立成
`repos/8005-mes-ingest/Invoke-PackagedReleaseGate.ps1`，视觉基线走
`.github/workflows/golden-renderer.yml`（`mode=verify` / `mode=candidates`，只能
手动触发）。

**已落地（2026-09-02）。**win11-01 上跑着**八个** runner，用标签分工。以下是
2026-09-03 从 `gh api repos/<仓>/actions/runners` 实读的结果，不是当初的计划——本表
一度只记了下面前三行，漏掉了 control-server 与 protocol 那两个，而它们一直在跑。
第六个 `win11-01-onboard-hmi` 于 2026-09-18 加上（`8005-agv-onboard-hmi#101`），只跑
`w2g/fp-v2-impl` 这条线；`OnboardHmi_MVP` 不加 CI，因为 MVP 预计几周后会被 v2 替换。
第七个 `win11-01-control-server-2` 于 2026-09-19 加上（`8005-agv-control-server#168`，
调研报告里的方案 d），**只跑服务端的 `test.yml`**：它只带 `cs-test`、不带 `headless`，
所以 `l2.yml` 与 `release.yml` 仍只落在原 runner 上，两个 l2 永远不会同时抢那 4 个
端口槽位，而同一张票的 test 与 l2 能并行。回退办法是把 `test.yml` 的 `runs-on` 改回
`[self-hosted, headless]`。同日 vm01 页面文件由 4 GB 调到 8 GB（已提交上限 16 GiB），
因为实测 test 单独 +4.0 GiB、与 l2 并行时整机峰值 9.42 GiB。
第八个 `win11-01-control-server-desktop` 于 2026-09-19 加上（用户当日批准，
`8005-workspace-v2/ci-research/real-rig-bottleneck.md` 方案 b），**交互式、只跑服务端的
真装置 L2**（`l2.yml` 的 `real-rig` 作业，手动 `-f rig=real`）：真装置要起车载端 WPF 与模拟器窗口，session 0 的服务 runner
起不了。它只带 `cs-desktop`，不带 `headless`／`cs-test`／`golden-renderer`，所以不会领
别的作业；装法是 `remote-ops/factory-server/scripts/18-install-control-server-desktop-runner.ps1`
（`-Remove` 卸掉）。它与 mes-ingest 的桌面作业共用同一个桌面，靠下面第 2 条的互斥体排队：

| runner | 模式 | 标签 | 归属仓 |
| --- | --- | --- | --- |
| `win11-01-riot-sdk` | 服务（session 0） | `dotnet8` `headless` | riot-sdk |
| `win11-01-mes-ingest` | 服务（session 0） | `dotnet8` `headless` | 8005-mes-ingest |
| `win11-01-mes-ingest-desktop` | 交互式（session 1） | `golden-renderer` | 8005-mes-ingest |
| `win11-01-control-server` | 服务（session 0） | `dotnet8` `headless` | 8005-agv-control-server |
| `win11-01-protocol` | 服务（session 0） | `node24` `headless` | 8005-agv-protocol |
| `win11-01-onboard-hmi` | 服务（session 0） | `dotnet8` `headless` | 8005-agv-onboard-hmi |
| `win11-01-control-server-2` | 服务（session 0） | `dotnet8` `cs-test` | 8005-agv-control-server（只跑 `test.yml`） |
| `win11-01-control-server-desktop` | 交互式（session 1） | `dotnet8` `cs-desktop` | 8005-agv-control-server（只跑 `l2.yml` 的 `real-rig` 作业） |

八个都带 `self-hosted` `Windows` `X64` `win11-01`。注意两个交互式 runner 都**不带**
`headless`，`win11-01-mes-ingest-desktop` 是唯一带 `golden-renderer` 的，
`win11-01-control-server-desktop` 是唯一带 `cs-desktop` 的——这一条正是标签分工能成立的原因。

交互式那两个由登录触发的计划任务（`GitHubRunner-<名字>`）在桌面会话里拉起，依赖客户机的 autologon（用
Sysinternals Autologon 配的，密码进 LSA secret 而不是明文注册表，`DefaultPassword`
键不存在）。**workflow 的 `runs-on` 一定要带 `headless`、`golden-renderer`、`cs-test` 或 `cs-desktop`**，
只写 `[self-hosted, win11-01]` 会被两种 runner 里任意一个领走，而其中一个画不了图。

**加了 runner 就回来改这张表。**它漏记了两个 runner 至少一天，而这张表是判断
「某个仓有没有 CI」的唯一依据——第一次挂 L2 到 CI 时，就是照着它得出「control-server
没有 runner」的错误结论，实际上有。

`8005-mes-ingest` 的测试按 `[Collection("WpfDesktop")]` 标记划成两半：`test.yml`
在 headless 上跑其余全部，`desktop-tests.yml` 在交互式 runner 上跑这些。划分由
`Get-WpfDesktopTestFilter.ps1` 扫源码推导，不是手写清单——手写过一次，下一轮就漏
了两个新类。合起来的结果与本地等价：

| | 本地 | CI |
| --- | --- | --- |
| 通过 | 962 | 961（798 + 163） |
| 跳过 | 138 | 138 |
| 失败 | 0 | 1（`8005-mes-ingest#1`，已知） |
| 总计 | 1100 | 1100 |

三条硬约束：

1. **哪些仓库是 public 由用户决定，2026-09-14 起八个组件仓库全部是 public**
   （Repository write authority 表里那八个）；`8005-workspace` 本身仍是 private。
   先改的是 `8005-agv-control-server` 与 `8005-mes-ingest`，同日用户要求其余六个
   一并公开。起因是 artifact 存储配额：私有仓库共用个人账户
   每月 500 MB·月的免费额度，按「大小 × 存放小时数」累计，发布包把它用满后所有
   上传都被拒（`Artifact storage quota has been hit`），删文件也扣不掉当月已累计的
   量；公开仓库的 artifact 不计额度。用户明确接受了代价，并说不用管：任何人都能看到
   代码、完整历史、证据目录里的厂区地址和凭据样值、Actions 日志和发布包；任何人提一个
   PR 就能在 win11-01 上执行代码，而它经跳板能碰到 factory-server 上的生产服务。
   公开前没有做敏感信息清理，也没有关 PR 或加 fork PR 审批。**不要自行把它们改回
   private，也不要自行加这些防护**——要改等用户开口。

   这条原本是「挂了 self-hosted runner 的仓库绝不能是 public」，`8005-agv-protocol`
   正是为此于 2026-09-02 从 public 转为 private。
2. **`trytoreachpeak0` 是个人账号不是组织，一个 runner 只能绑一个仓库。**要给
   多个仓做 CI，就必须在同一台机器上装多个 runner 实例（不同目录、不同服务名），
   而它们会各自并行领作业。所以**不要指望"一台机器一个 runner"去保证黄金渲染机
   契约的 "Never run two desktop suites in parallel"**——跨仓库的桌面独占
   GitHub 的 `concurrency` 表达不了（它只在单个仓库内生效）。

   **它现在由一个机器级命名互斥体承担：`Global\W2G-InteractiveDesktop`，唯一定义
   处是 `repos/8005-mes-ingest/Invoke-WithDesktopLock.ps1`**（2026-09-03 落地）。任何仓库
   的任何脚本，只要在动那台机器的交互式桌面（起 WPF 窗口、抓像素、驱动 UI
   Automation），都必须先拿到同一个名字的互斥体。各仓是独立克隆、没有共享包，所以
   第二个仓要用就自己拷一份 helper——**名字才是契约，代码不是**。

   在那之前这句话只有一半是真的：`golden-renderer.yml` 用的名字是仓库作用域的
   `Global\MesIngestWatchUiTests`（只能把那个脚本与自己串起来），而
   `desktop-tests.yml` **一把锁都没有**，靠的是本仓共用的 `concurrency` 分组。

   **2026-09-19 起第二个仓加进来了，CI 排队、手动仍快速失败。**`8005-agv-control-server`
   的真装置 L2 在交互式 runner `win11-01-control-server-desktop` 上跑，每个场景拿一次锁
   （排队 1800 秒，`scripts/DesktopLock.psm1`）；`8005-mes-ingest` 的 `desktop-tests.yml`
   与 `golden-renderer.yml` 同日改为传 1800 秒超时排队（`8005-mes-ingest#8`，合入
   `b670166a`），作业超时相应加大。脚本默认值仍是 0（exit 3），给在客户机上手动跑的人用。
   CI 作业该排队，不该因为撞上另一个仓的调度就变红。

   只给需要金机的 runner 打 `golden-renderer` 标签，别的 runner 不要带。
3. **黄金渲染机的 Validation 阶段只能 `workflow_dispatch` 手动触发。**它会产生
   候选基线，那必须是用户点头之后的动作，见 `repos/8005-mes-ingest/CLAUDE.md`。

那轮托管 CI 抓到过一个本地发现不了的真 bug（`.gitattributes` 的字节规则在拆分时
丢失，导致查询文件摘要对不上）。**教训是：改动会影响构建的文件后，用干净
checkout 验证一次**——例如临时克隆到别处再跑测试。

### runner 到 GitHub 的网络：现在走代理，但那个 21 秒超时有两个不同的根因

**这一节记着两件事，别把它们搞混——症状一模一样（21 秒 TCP connect 超时），根因完全
不同，而先诊断错了一次的代价是好几个小时。**

1. **端口池耗尽**（2026-09-08 上午定案）：本机出不去，看着像目标被挡。**修法是停掉泄漏
   的服务，不是配代理。**详见下面。
2. **厂区到特定 GitHub IP 真的不通**（2026-09-08 下午）：本机出得去，`api.github.com`
   也通，只有 `github.com` 那个 IP 不通。**修法就是配代理。**见本节末尾。

**先判断是哪一种：查 factory-server 的临时端口占用。**健康时约 1-2%（实测 269/16384），
耗尽时 67%。占用正常就不是第一种，别再去停服务或查 NAT。

```powershell
ssh factory01 "(Get-NetTCPConnection | Where-Object { `$_.LocalPort -ge 49152 }).Count"
```

#### 根因一：端口池耗尽（已修，服务已停）

起因是 release 连续五次失败（`8005-agv-control-server#7`）：构建
每次都成功，五次全栽在与 GitHub 通信那一步，报错都是 21 秒的 TCP connect 超时。

**根因不在 CI，也不在代理，在 factory-server 上的一个连接泄漏。**`AgvAmhs` 向本机
RabbitMQ 开 AMQP 连接（对端 5672）却不关闭，跑六天攒到 10330 条，占掉那台主机 16384 个
临时端口（49152-65535）里的 64%。而 **WinNAT 每为客户机转换一条出站连接，就要从同一个
端口池里借一个外部端口**——借不到时 SYN 被静默丢弃，客户机那头看到的就是 21 秒超时。
CI 只是碰巧最先撞上：它过 NAT，比主机自己更早分不到端口。

定死它的是这组同一时刻的 A/B：

| 观测 | 停 AgvAmhs 前 | 停 AgvAmhs 后 |
| --- | --- | --- |
| 客户机 → `192.168.200.1`（**不过 NAT**） | 92/92 100% | 177/177 100% |
| 客户机 → `172.19.162.241`（**过 NAT**） | 72/92 **78%** | 177/177 **100%** |
| factory01 → 同一目标（同一时刻） | 198/198 100% | 159/159 100% |
| ICMP（两边） | 100% | 100% |
| 主机临时端口占用 | 10968 / 16384（67%） | 152 / 16384（1%） |

`AgvAmhs` 与 `RabbitMQ` 已于 2026-09-08 **停止并设为 Disabled，不要恢复**。`AgvAmhs`
是同事写的玩具程序，误留在这台服务器上一直没关，**从来不属于生产栈**——所以泄漏不用
修，关掉就是终局。脚本是 `remote-ops/factory-server/scripts/17-disable-amhs-stack.ps1`，
`-Revert` 留着只是退路。`RabbitMQ` 是跟着它一起停的；`AGVWebApi`、`MesIngest`、
`8005 AGV ControlServer`、SQL Server 都没动，停完一切正常，说明没有别的东西在用那个
消息队列。

修好之后代理一度不需要了，客户机切回了 `-Mode Direct`。**那个状态只维持了几个小时**，
见下面的根因二。唯一定义处是
`remote-ops/factory-server/scripts/09-configure-guest-proxy.ps1`，`-Mode Proxy` 留作后备，
**改完必须重启 runner 服务才生效**。

五条别再重走的弯路：

1. **被 NAT 误导过一次，写在这里免得再来。**当时测出 `github.com` 直连 0/8、过代理
   12/12，据此得出「github.com 被厂区网挡了，必须过代理」，还照此改了配置。**那是
   假象**——端口池修好后同一个测量是 12/12、中位 400 ms，比过代理还快。**目标看起来
   「被挡」的时候，先确认本地出得去。**（同一天下午那个结论又变成真的了，见根因二。
   所以这条的用法不是「被挡都是假象」，而是**「先确认本地出得去」这个动作本身**——两次
   的分歧点正在这里。）
2. **换代理节点不是解药。**把 Clash 节点从日本切到美国后，github.com 过代理由 2/10
   失败变成 10/10 成功，紧接着第五次 release 仍以完全相同的方式失败。代理的上游从来
   不是问题。
3. **21 秒是 Windows 的 TCP connect 超时**，不是 GitHub 的超时。三种互不相干的客户端
   （Node 的 upload-artifact、.NET 的 runner、git/curl）同一症状，说明问题在网络不在
   客户端库。GitHub 报的 `ECONNRESET`/`ETIMEDOUT` 是二手信息。
4. **只测到传输层的探测在这里什么都证明不了。**TCP connect 通、TLS 握手超时是常态——
   connect 包小，TLS 那几个大包正好撞上端口分配失败。**要用真实请求加 45 秒超时**：
   同一批端点 4 秒超时测出 36% 成功、45 秒测出 100%。**判定成功的标准是 release 连续
   两次实跑出可下载的 artifact，不是「探测通了」。**
5. **runner 不读 `.proxy` / `.noproxy` 文件。**这个版本只认环境变量
   （`http_proxy`/`https_proxy`/`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`），程序集里连
   `.proxy` 这个字面量都没有。`10-install-github-runner.ps1` 曾经写这两个文件，已经
   删掉——一个看着像配置、实际什么都不做的文件，第一次出事就要吃掉一小时。

还有两条与本次无关但值得知道：**.NET 的 `NO_PROXY` 不做后缀匹配**（`github.com` 豁免
不了 `api.github.com`），而 curl、Node 的 toolkit 和 runner 会做；**厂区到公网的 DF ping
在 1000 字节以上不通**（972 通、1000 静默丢，两台机器一致，没有 ICMP「需要分片」回来），
排查时会看着像 MTU 问题，但把客户机 MTU 降到 1000 试过，当时 github.com 直连仍是 0/8，
已还原 1500。

**artifact 上传的重试留着。**`CreateArtifact`/`FinalizeArtifact` 是这条链上仅剩的单次
调用（checkout 自己 fetch 三次，restore 有自己的重试），而 upload-artifact 不提供任何
重试开关，`run:` 步骤又没法重新调用一个 action，所以在 `release.yml` 里把三次尝试写开，
中间隔 30 秒，后两次带 `overwrite`。根因修掉之后它一次都没触发过，但它救过一次真失败，
成本是零，留着。`test.yml` 与 `l2.yml` 传的是诊断材料不是交付物，那两处用
`continue-on-error`：判定在上一步，别让一次网络抖动把绿的跑成红的。

**验收证据。**Proxy+bypass 配置下 `34145513351`、`34146036477`（前者第一次上传失败、
靠重试救回）；停掉 AgvAmhs 之后 `34175549786` 一把过；切成全直连之后 `34176439971` 与
`34176609797` 连续两次一把过，三个重试步骤全部 skipped。`34146036477` 的包下载回控制端
校验过 SHA-256，manifest 里两端 commit 齐全。

#### 根因二：厂区到 `github.com` 那个 IP 真的不通（现行状态：Proxy）

同日下午，protocol 的 g1（run `34209440540`）挂在 `actions/checkout`，报错与上面一模
一样：`Failed to connect to github.com:443 after 21069 ms`。**但这次是真的被挡**，
区分它与根因一的是这组数据：

| 观测 | 结果 |
| --- | --- |
| factory01 临时端口占用 | **269 / 16384（1.6%）**，健康——**这一条排除了根因一** |
| `AgvAmhs` / `RabbitMQ` | 仍是 Stopped / Disabled，没被恢复 |
| factory01 → `www.baidu.com`、`www.microsoft.com` | 4/4 ✓ 本机出得去 |
| factory01 → `api.github.com`（`20.205.243.168`） | **4/4 ✓** |
| factory01 → `github.com`（`20.205.243.166`） | **0/8 ✗** |
| vm01 → `github.com` 直连 | **0/6 ✗** |
| vm01 → `codeload.github.com` 直连 | **3/6**——时通时不通 |
| DNS | 解析正常，返回真实 GitHub IP，无污染 |
| vm01 → 上述全部**过代理** | **6/6 ✓**，中位 700–1400 ms |

两个 IP 只差最后一位、一个通一个不通，而本机出得去、DNS 干净、端口池健康——**这排除了
配置侧的每一种解释，剩下的就是厂区出口对特定 IP 的封锁**。国内连 GitHub 时通时不通是
常态，`codeload` 那个 3/6 就是它的样子。

**所以客户机切回了 `-Mode Proxy`（默认 bypass 列表，未改）**，CI 与控制端笔记本又绑在
一起了。验收：同一个 run `34209440540` 重跑，40 秒一把过（失败那次跑了 2m5s）。

**这次没有把 bypass 列表清空，是有实测依据的**：`objects`、`pipelines`、
`results-receiver`、`broker`、`blob.core.windows.net`、`api.nuget.org` 直连都是 5/5，
脚本内置的 `$mustBeDirect` 验证也要求它们直连可达。只有 `github.com`、
`codeload.github.com`、`api.github.com` 走代理——那正是脚本 Proxy 模式的默认设计。

**一个测量陷阱，我踩了一次：**第一轮诊断里 `objects.githubusercontent.com` 测出 0/4，
差点据此把它从 bypass 里挪走。那是假阴性——**那些主机对 HEAD 请求返回 4xx，而我的探测
把非 2xx 当成了失败**。脚本注释早就写着「status code is irrelevant, an answer is the
point」。判定连通要看**有没有回应**，不是回应是不是 200。

**CD 断线时的备用路是 `repos/8005-agv-control-server/scripts/Build-LocalRc.ps1`**，在
控制端本地产出与 workflow 等价的一套东西（zip + `.sha256` + `release-manifest.json` +
`SHA256SUMS.txt`），`15-deploy-control-server.ps1 -PackagePath` 直接能吃。它替代的只是
`gh run download`，别的一步没改。

## CD：MesIngest 部署到 factory-server，控制端中转

**已落地（2026-09-02）**，端到端验证过。权威文档是
`remote-ops/factory-server/docs/mes-ingest-cd.md`。

```
release.yml (workflow_dispatch, headless runner) → zip + sha256 → GitHub artifact
   → 控制端 gh run download → 验哈希 → scp → factory01 → Install-MesIngestServer.ps1
```

| 位置 | 内容 |
| --- | --- |
| `D:\zhengyushao\MesIngest` | 服务器安装根，Windows 服务 `MesIngest`，绑 `0.0.0.0:5088` |
| `D:\zhengyushao\MesIngest.previous` | 只留一代，`-Rollback` 换回去 |
| `C:\MesIngest-Watch` | 控制端只装 Watch，连 `172.19.205.222:5088` |
| 数据库 | 服务器本机 `MSSQLSERVER` 的 `MesIngest` 库，登录 `mesingest` 仅该库 `db_owner` |

四条不显然的约束：

1. **runner 不直接部署，必须经控制端中转。**`win11-01` 是 factory-server 的客户机，
   宿主就在 `192.168.200.1`，让 runner 直连是最短的路，但那等于把一把能进生产服务器
   的管理员钥匙放在 CI 上——任何能改那个仓 workflow 的路径最终都能碰到 `AgvAmhs`、
   `AGV.Web` 和 `SQAGV`。
2. **部署编排脚本不能进安装包。**`Test-ReleasePackage.ps1` 递归扫包内所有 `.ps1` 找
   未授权的 `DROP DATABASE`，并且只允许两个 canonical `.sql` 路径。往包里塞脚本会让
   每次发布验证直接失败。脚本走包外的 `D:\zhengyushao\mes-ingest-ops\`。
3. **`agvops` 在 SQL Server 上是 sysadmin。**最初 CD 只给了 `dbcreator` + `ALTER ANY LOGIN`
   （`scripts/mes-ingest/grant-agvops-sql-access.sql`），2026-09-15 为了读内存、等待、计划缓存这类
   server-state DMV，用用户提供的 `sa` 密码执行 `ALTER SERVER ROLE sysadmin ADD MEMBER` 提成了
   sysadmin（`remote-ops/factory-server/README.md` 第 5 节有记录，`sa` 本身未改）；2026-10-11 夜
   vm01 内存调研时实读 `IS_SRVROLEMEMBER('sysadmin')` 返回 1（`8005-workspace-v2/ci-research/memory-budget.md`）。
   **2026-10-12 用户定：不收回，如实记录。**代价按实写：控制端那把 SSH 私钥
   （`~/.ssh/agv_srv_ed25519`）经 `agvops` 能直接读写同实例上的一切，包括 `SQAGV` 生产库，
   不再需要绕道 `ALTER ANY LOGIN`。所以「不碰 `SQAGV`」「CD 不碰生产库」现在只靠脚本与会话自律，
   没有数据库权限这一层兜底。`grant-agvops-sql-access.sql` 末尾的收回语句只收回那两项，
   **收不回 sysadmin**；真要收回是 `ALTER SERVER ROLE sysadmin DROP MEMBER`，要先问用户。
4. **Host 绑非 localhost，于是所有请求都要 Bearer**（`MesIngest.Host/Program.cs:182`
   的中间件不区分来源）。服务器上那个走回环的 Watch 同样要带 SharedSecret，健康检查
   也要。三个秘密存控制端 `%LOCALAPPDATA%\AgvOpsSecrets\mes-ingest-deployment.xml`，
   DPAPI 加密。

**CD 不跑打包发布门禁，不删库，不碰 `SQAGV`。**`Invoke-PackagedReleaseGate.ps1` 属于
切 RC 的流程；唯一会删库的入口仍是 `pack/cutover/Invoke-EmptyDatabaseCutover.ps1`。

首次实跑打出来两个自己的 bug，都值得记住：**`-replace` 的左侧是正则**，`'\'` 是非法
模式而不是一个反斜杠；**失败要尽早**——密码复杂度原本等到下载 207 MB、建完库才被
SQL Server 以 15118 拒绝，现在在输入时就检查。

## CD：WIRE_TO_GATE 两端，一个包，控制端中转

**服务端已落地（2026-09-03），车载端待现场值。**权威文档是
`remote-ops/factory-server/docs/wire-to-gate-cd.md`。

```
8005-agv-control-server 的 release.yml (workflow_dispatch，输入车载端 commit)
  → New-WireToGateReleaseCandidate.ps1 → zip + sha256 → GitHub artifact
  → 控制端 gh run download → 验哈希 ─┬─→ scp → factory01 → ControlServer
                                     └─→ scp → agv0N    → OnboardHmi（搬完就停）
```

`agv0N` 是三台车里的某一台，**别名是区分它们的唯一依据**，车队登记册见
`remote-ops/fleet.md`。目前只有 `agv01` 部署过车载端。

| 位置 | 内容 |
| --- | --- |
| `C:\Program Files\8005 AGV\ControlServer` | 服务安装根，Windows 服务 `8005 AGV ControlServer` |
| `D:\zhengyushao\ControlServer` | 当前包，`.previous` 留一代，`-Rollback` 换回去 |
| 绑定 | `tcp://172.19.205.222:58005`、`http://172.19.205.222:58007` |
| `C:\8005\OnboardHmi` | 车上安装根，`.previous` 留一代 |

**两端打进一个包**，因为明文期的两端没有协商也没有降级（`RELEASE-CANDIDATE.md`
8.1），版本错配的表现是连接被拒而不是一条说明原因的错误。车载端仓库只读的约束不受
影响：workflow 把它 checkout 成 scratch 镜像，`New-WireToGateReleaseCandidate.ps1`
再从镜像的一次性克隆构建，从不写那个仓库。

**部署搬完就停，启动是单独一步。**上位机是会动的生产设备，`SQCD.Agv.Wpf` 是交互式 WPF
程序不是服务，就绪判定要人看着车辆安全投影的返回。这不是谨慎，是第 11 节要求的
逐次授权加现场安全 GO。车载端部署还需要 `remote-ops/onboard-hmi/config/site-<别名>.json`
里的现场值（规则服务器 IP、IO 模块 IP、稳定 UUID），**没填之前脚本直接拒绝，不猜**。

启动这一步 2026-09-04 之前只有一条路——走到车前双击。现在是
`remote-ops/onboard-hmi/scripts/10-start-onboard-stack.ps1`：模拟器先、客户端后，
用交互会话里的计划任务拉起（sshd 给的是 session 0，在那里起窗口等于起在没人看的桌面上），
起完即注销任务、不留残留。**改掉的是「必须站在哪栋楼里」，不是那道授权**——逐次授权现在由
「有人刻意敲这条命令」表达，**没有任何东西会替你敲**：部署不会、登录触发不会。第 8 节那条
没变，就绪判定仍然是人的。`-SimulatorOnly` 只起模拟器，不起任何会让车动的东西。

**注意车上的 `wireToGate.recoveryResumeEnabled` 出厂是 `false`**，恢复入口因此不会出现，
与会话是不是 `RecoveryRequired` 无关。要让操作员能在 HMI 上发起恢复，两端都得开：车载端这个
开关，加服务端的恢复管理员凭据。

首跑打出来三个坑，都值得记住：

1. **`curl.exe` 不是每台 Windows 都有。**它随 Windows 10 1803 / Server 2019 内置，
   厂区服务器是 **Server 2016，没有**。`Install-ControlServerLocal.ps1` 和
   `Update-ControlServerLocal.ps1` 内部有四处硬依赖它，部署就挂在那里。已改用 PS7
   自带的客户端（`8005-agv-control-server` 的 `1c67367`）。注意 `Get-ReadyCheck`
   那处**故意不带 `--fail`**——它必须读到 `not-ready` 响应的 body——所以不能与另外
   三处一并处理，用 `-SkipHttpErrorCheck` 还原。
2. **多仓库 checkout 要各占一个子目录。**镜像放在 `$GITHUB_WORKSPACE` 根就等于放进
   了 ControlServer 的工作树，RC 脚本的「仓库必须干净」检查立刻失败。
3. **默认绑具体网卡 IP 而不是 `0.0.0.0`。**后者会连带把服务暴露到 Hyper-V 的
   `AGV-Internal`，而 CI runner 就住在那个网段上。

**绝不要取消 self-hosted runner 上正在跑的 job。**2026-09-03 实测：取消一个 job 会
把 runner 的 broker 长轮询连接一起取消，退避重试（日志里的
`Back off 9.921 seconds before next retry. 4 attempt left.`）耗尽之后会话就卡住，
不再领任何新作业。它没有自愈——直到 GitHub 主动推了一条 `RunnerRefreshConfigMessage`
触发会话重启才恢复，**中间空转了 4 小时 14 分**。这些仓库每个只有一个 runner，一个
会话卡死就是整个仓库的 CI 停摆。

那次的动机是「两个分支推同一个 commit，test 跑了两遍，取消一个省点机时」。省下的是
2 分钟，代价是 4 小时。宁可让重复作业跑完。

**这件事有一个自动版本，2026-09-03 已经堵上。**`cancel-in-progress: true` 会在同一分支
连推两次时自动取消正在跑的作业，与手动取消同一条路径。当时
`8005-agv-control-server` 与 `riot-sdk` 的 `test.yml`、`8005-agv-protocol` 的 `g1.yml`
三个 workflow 都是 `true`（`8005-mes-ingest` 的六个早就是 `false`），现已统一改为
`false`。**新写 workflow 时不要再设成 `true`。**注意改为 `false` 后仍会取消**排队中**的
作业——第三个到达时中间那个被顶掉——那不碰 runner 会话，是安全的。

**这条曾被误记为「控制端笔记本一睡，CI 就停摆到它醒」，那个归因是错的**，不要据此去
改 `NO_PROXY` 或电源设置。控制端设了永不睡眠（睡眠超时 AC/DC 都是 0），实测 7 天内
零 `Kernel-Power` 42/107 事件，win11-01 同样没睡过。runner 日志里那段时间的报错是
`TaskCanceledException` 与 `SocketException(995)`——本地取消，不是代理拒绝也不是断网。

`NO_PROXY` 的事实部分仍然成立、也仍未改：`pipelines.actions.githubusercontent.com`
等五个域名实测都能直连，但都不在机器级 `NO_PROXY` 里，所以 runner 的流量确实绕行
控制端 `172.19.162.241:7890` 的 Clash 代理。这与 Lab VMs 一节「这些域名直连」的记载
不符——能直连是事实，配置从未体现。用户 2026-09-03 决定暂不改动。

**CD 不跑门禁，不启用 `JourneyRuntime`，不碰 `SQAGV`。**门禁属于切 RC 的流程；
产品安装脚本以 `JourneyRuntime.enabled=false` 部署，不建单不动车。

## 全产品（v2）的完整测试与实车运行：用 agv02／agv03 隔离做，不干扰 MVP

**用户 2026-09-14 定，今后都照此执行。**生产跑的是 MVP 线（`ControlServer_MVP`／`OnboardHmi_MVP`，
`protocol-v0.3.0`）：factory01 上的 `8005 AGV ControlServer` 服务只管 `agv01`，正在服务客户。
全产品 v2 线（`fp/v2-impl`／`w2g/fp-v2-impl`，`protocol-v1.0.0`）的完整测试、实车运行与现场演练
（例如批次 2 票 19 的 W1 空载急停演练）**不等生产切到 v2**，在备用车上、用独立的 v2 服务端实例做。

**允许（不必再逐项问）：**

- 访问 `agv02`、`agv03`：SSH 上位机，在上面部署与启动 v2 车载端，修它们的时钟，填
  `remote-ops/onboard-hmi/config/site-agv02.json`／`site-agv03.json` 的现场值。
- 在生产位置之外运行 v2 服务端实例，并让它经 RIoT 只为 `agv02`／`agv03` 建单、发订单命令与急停命令。

**四样共享资源必须隔离：**

| 资源 | 冲突 | 隔离做法 |
| --- | --- | --- |
| MES 需求 | 两版默认都从工厂服务器本机 `127.0.0.1:5088` 的生产 MesIngest 取需求，v2 会抢走真实需求 | v2 实例不接生产 MesIngest，用 `8005-agv-control-server` 的 `tools/ControlServer.FakeMesIngest` 注入测试需求。**这一条在并行期继续有效，用户 2026-09-20 明确定过**：约 10-08 起 v2 与 MVP 在 factory01 上并行时，v2 仍然只吃注入的测试需求；真实需求要到约 10-15 切换当天才转给 v2，**同时停掉 MVP**。理由是取走就是取走了——任何时刻只允许一个实例认领真实需求，「抢」这件事从根上不存在。要在并行期就吃一部分真实需求，唯一安全的做法是在 MesIngest 那一侧按站点或任务类型分流，那是一个要开发的机制，得单开票。**2026-10-09 用户放宽（客户要求 10-10 起用 v2 跑 STAGING_TO_WIRE）**：v2 可以读生产 MesIngest，**但只允许 `STAGING_TO_WIRE` 一种任务类型**，MVP 继续只做 `WIRE_TO_GATE`。依据是读代码得到的两条事实：MVP（含 agv01 现场线）在受理前写死只做 `WIRE_TO_GATE`；MesIngest 只读、没有认领语义，两边看到的是同一份目录——所以分流靠的是「两边任务类型不相交」，不是「认领后对方看不见」（上面那句理由按代码并不成立）。v2 的 `allowedWorkTypes` 一旦含 `WIRE_TO_GATE` 就会和 MVP 抢同一批料，部署脚本的「生产来源模式」负责拒绝这种配置（control-server 对应票）。整体割接（停 MVP、v2 接全部任务类型）仍按原计划，在 v3 发布、W2、program#61 之后 |
| 端口与数据库 | 两版默认都监听 `58005`／`58007`，库都在 `%ProgramData%/8005/ControlServer` | v2 实例换端口、换库目录，不用 `C:\Program Files\8005 AGV\ControlServer` 与 `D:\zhengyushao\ControlServer`。**「不在 factory01 上跑」这条已由用户 2026-09-20 解除**：约 10-08 起的并行期，v2 实例就跑在 factory01 上（那一天之前的日常开发测试仍然不要占 factory01，没必要）。**解除的只是这一条**，同表其余三条一字未改、仍然全部有效。绑定要绑具体网卡 IP，不要 `0.0.0.0`——后者会把服务连带暴露到 Hyper-V 的 `AGV-Internal`，而 CI runner 就住在那个网段上 |
| RIoT | 两版连同一个 RIoT（`172.19.206.222:8888`），RIoT 上有 25 台可调度车 | `JourneyRuntime.agvId`／`vehicleKey` 只能是 `agv02` 或 `agv03`（见 `remote-ops/fleet.md`）；绝不对 `agv01` 或其他车建单、发订单命令或急停 |
| 地图与通道 | MVP 与 `agv01` 在 RIoT map 25（`老厂前线new`），v2 与备用车在 map 26（`老厂前线new_wk`）。2026-09-21 用户更正：09-19 那次「同在 map 26」是误记 | 选 `agv01` 不经过的路段、`agv01` 空闲的时段，避开演示与生产高峰 |

**不碰，要碰先问：**`agv01`；factory01 上 MVP 服务的进程、安装目录、配置与数据库；生产 MesIngest；
`ControlServer_MVP`、`OnboardHmi_MVP` 分支。

**仍然逐次授权：**任何会让车动、或会发出急停的运行，每一次都要用户在对话里单独授权，现场有人盯着、
物理急停可按；急停演练车必须空载。授权不跨次，上面「允许」那一栏不替代它。

**急停之后怎么释放，要事先写进演练方案。**在途单被报 FAILED 触发的急停目前没有自动解除路径
（`8005-agv-control-server/docs/emergency-stop-field-fallback.md`）；v2 实例仍在运行、故障仍在时去 RIoT
手动解锁，会被判为外部解除并立即重触发。

2026-09-14 18:28 从控制端探测：`agv02`、`agv03` 的 CPE 上 RIoT 用的 5001 端口通，上位机 SSH 的 22022
不通（上位机大概率没开机）；两台都还没部署车载端。

## .NET 工具链基线

四个可写 .NET 仓库统一到一套工具链，真相来源是
`repos/8005-agv-program/docs/adr/cross/0056-dotnet-toolchain-baseline.md`：

| 项 | 锁定值 |
| --- | --- |
| SDK | 8.0.426，`rollForward: disable` |
| 运行时目标 | `net8.0`（`8005-mes-ingest` 的 WPF 侧另有 `net8.0-windows`，那是合理的） |
| 测试栈 | xunit.v3 3.2.2 + Microsoft.NET.Test.Sdk 18.8.1 + xunit.runner.visualstudio 3.1.5 |

**禁用 xunit v2、NUnit、MSTest 与 coverlet.collector。**基线不靠读文档维持，靠
四层机制：`global.json` 锁 SDK、`Directory.Packages.props` 集中版本（配
`CentralPackageVersionOverrideEnabled=false`，内联 `Version=` 触发 NU1008）、
`Directory.Build.props` 统一目标框架与 `LangVersion`、`Directory.Build.targets`
的禁用包守卫在构建期报错。

工作区根的 `check-toolchain.ps1` 扫全部七个仓报告偏离，可写仓有偏离则退出码 1。
`8005-agv-onboard-hmi` 与 `slots-simulator` 属于 Kun Wang，**只报告不修改**，也不
影响退出码。

**不要单独升某一个仓的版本。**改 ADR 和各仓的 props 文件，一起动。

## Workspace layout

This repository tracks only workspace-level files; the eight component clones
and the `w2g-rc-*` build output are gitignored.

**The eight clones live under `repos/`** (moved there on 2026-09-04 to keep the
root readable — previously they sat directly in it). They stay siblings of each
other, so every cross-repository relative path is unchanged; what moved by one
level is the path from the workspace root, e.g. `repos/8005-agv-protocol/integration-slices/index.json`.
Everything else — `remote-ops/`, `releases/`, `file-naming-convention/`, the
`w2g-rc-*` snapshot — stayed where it was.

`8005---AGV` was split and renamed on 2026-09-02 — it is now `8005-agv-program`
(requirements and decisions, no code), plus `8005-mes-ingest` and `riot-sdk`.
Its history was rewritten to purge `.artifacts/`, so every commit hash changed
and any old clone must be re-cloned. The pre-split mirror sits outside the
workspace at `C:\Users\szy\8005-restructure-backup`. See `repos.md`.

- `repos/` — the eight component clones, one directory per repository. Not
  tracked here; each is its own clone on its own remote.
- `repos.md` — the eight repositories, their working branches, and who owns each.
  It also records the 2026-09-02 split of `8005---AGV`.
- `setup.ps1` — clones whatever is missing into `repos/` on a new machine. Never
  pulls or resets an existing clone.
- `file-naming-convention/` — naming rules for this root and the four
  repositories owned here. Lowercase kebab-case; the document states the
  exceptions. It does not govern the three repositories owned by other people.
- `releases/<id>/` — the recipe to rebuild and verify a release candidate:
  manifest, hashes, operator's manual, build scripts. Never the binaries.
- `remote-ops/` — every channel for reaching a machine in the plant. Writable;
  reaching a machine through it never grants write access to the repository
  whose code runs there. Two channels, one subdirectory each:
  - `fleet.md` — the fleet register. **The project has exactly three cars**, and
    each car is an AGV plus the onboard HMI machine bolted to it. This file is
    the single source of truth for **how those two halves map onto each other**,
    across five identity coordinates: the SSH alias (`agv01`/`agv02`/`agv03`),
    the CPE address, the RIoT `deviceKey`, the RIoT `id`, and the
    `deviceName`/`agvId`. Given any one of them, read the table there to get the
    other four; **only `deviceKey` and `id` are durable**, so long-lived
    references belong on those. Read it before touching a car or writing
    anything that names one. Two load-bearing facts: the three HMI machines are
    clones of one image with nothing re-personalized (same COMPUTERNAME, same
    MachineGuid, same LAN address), and on the RIoT side the three cars share a
    `physicsId` and their serial numbers do not run in car order — so **never
    derive a car's identity from the machine itself or from a serial**.
  - `onboard-hmi/` — SSH to the AGV onboard HMI machines: probe, bootstrap, and
    hardening scripts, the control-host SSH
    config, and the design record. Read its `docs/USAGE.md` before touching a
    machine. Two things stay out of git:
    probe output (`probe-*.txt`), which inventories local accounts, the
    administrators group, autologon config, firewall state, and IP topology;
    and `payload/`, the offline OpenSSH package, which `docs/ASSETS.md`
    describes well enough to re-fetch. The operations private key lives in
    `~/.ssh/`, never here.
  - `factory-server/` — SSH (`ssh factory01`) to the Windows Server 2016 host
    `WIN-0HD72AV4K31` at `172.19.205.222`, which carries SQL Server, the
    running AGV service stack, the MES ingest deployment target, and — since
    2026-09-01 — the Hyper-V role hosting lab VMs. Read its `docs/USAGE.md`
    before touching the machine — production services run on it. Two rules
    there are load-bearing: never build an External virtual switch on `em4`
    (it carries the only cabled link and this SSH channel itself), and never
    touch the `SQAGV` database (it is not this workspace's to manage).
    Key-only authentication; the private key lives in `~/.ssh/`, never here (a
    different key from the onboard-HMI one). The WinRM channel that preceded it
    was torn down on 2026-09-01 — see that subdirectory's README for what was
    removed and why; do not rebuild it. Two things stay out of git:
    `probe-*.txt`, and the console-rescue password for the `agvops` account,
    which lives in `%LOCALAPPDATA%\AgvOpsSecrets\` on the control machine.
    The lab guests on this host are reached from the control machine with
    `ssh vm01` (and one alias per further guest), which jumps through
    `factory01` — see **Lab VMs** below.

  Before trusting ANY ping or port probe from the control host, check that it is
  not going through the Clash TUN adapter, which answers ICMP itself and
  completes TCP handshakes locally — nonexistent hosts appear reachable and
  every port appears open:

  ```powershell
  Find-NetRoute -RemoteIPAddress <target> | Select-Object -First 1 InterfaceAlias
  ```

  `Clash` means the result is fiction. `remote-ops/factory-server/scripts/01-control-host-route.ps1`
  installs the bypass route (pass `-Prefix` for a new subnet, `-Remove` to undo).

## Lab VMs

Experiments run on the factory server's Hyper-V, never on the control machine's
own Hyper-V. As of 2026-09-02 there is one guest:

| Alias | Guest | Address | Notes |
| --- | --- | --- | --- |
| `ssh vm01` | `win11-01` / `DESKTOP-F9HC40O` | `192.168.200.50` | Windows 11 Pro 26200.9168, activated, `agvops` local admin, 20 vCPU, 10.5 GB static (8 GB until 2026-10-11), 1920x1080. pwsh 7.6.5, .NET SDK 8.0.426, git 2.55.0.5 |

Key-only, via `ProxyJump factory01` — the guest sits on the Internal switch
`AGV-Internal` (`192.168.200.0/24`) with NAT out, so there is no route to it
from the enterprise network and the jump host is the only way in. Its key
(`~/.ssh/agv_vm_ed25519`) is a third key, not the server's and not the
onboard-HMI one. Host config copy: `remote-ops/factory-server/config/ssh_config.vm`.

`win11-01` carries two roles as of 2026-09-02: the self-hosted GitHub Actions
runner, and the golden WPF renderer that replaces the control machine's
`gpt_win11`. Its specification is not scratch configuration — 1920x1080 comes
from `Set-VMVideo -ResolutionType Single`, without which a guest with no
vmconnect session attached reports 1024x768 and fails the renderer's
environment gate; the memory is static because dynamic memory had been assigning
it 2.5 GB, which starves a restore/build/test cycle. It went from 8 GB to 10.5 GB
on 2026-10-11 (user-approved): an l2 plus a test round had pushed the guest to
11.65 GiB committed and 0.4 GB available, paging. The 2.5 GB came out of factory01
only by freeing it -- SQL Server's max server memory 8192 -> 6144 MB and an idle
RDP session logged off -- and the host keeps at least 4 GB available with the v2
instance running. Measurements, what else could be freed and the 14 GB the guest
would really want: `8005-workspace-v2/ci-research/memory-budget.md`. Do not grow it
further out of factory01's free memory; that floor is the user's. Reproduce both with
`remote-ops/factory-server/scripts/06-configure-golden-renderer-vm.ps1`.

**The guest reaches `github.com` through the control machine's Clash proxy**
(`172.19.162.241:7890`), and everything else in the CI path directly. It briefly
did reach `github.com` directly — 12/12 at a median 400 ms on the morning of
2026-09-08 — but by that afternoon that IP (`20.205.243.166`) was unreachable
from the plant while `api.github.com` (`20.205.243.168`) still answered, so the
guest went back to `-Mode Proxy`. **The CI path therefore depends on the control
machine again**: Clash must be running with LAN connections allowed. See the
"runner 到 GitHub 的网络" section above — it carries the two distinct root causes
behind the identical 21-second timeout, and which measurement tells them apart.

**Everything here uses git over HTTPS. Nothing uses git over SSH** — all eight
clones, the workspace repository, `gh`'s `git_protocol` and every
`actions/checkout` are HTTPS, and there is no `url.*.insteadOf` rewrite on any
of the three machines. `github.com:22` happens to be reachable; that is a fact
about the network, not a path anything takes. Keep it that way: an SSH checkout
would need a deploy key per repository, and it buys nothing now.

This paragraph said the opposite until 2026-09-08, and the correction is worth
keeping. It recorded `github.com:443` as unreachable from both machines and told
you to check out over SSH. **The measurement was real; the conclusion was
wrong.** What was actually failing is WinNAT on the factory server, starved of
ephemeral ports by a connection leak in `AgvAmhs` — see the CI section above.
Stopping that service made `github.com` directly reachable from both machines in
the same instant, and the proxy came out of the CI path entirely.

One-off installer downloads can still be staged from the control machine with
`scp` when that is more convenient than a direct download. The control machine's
proxy at `172.19.162.241:7890` is no longer in the CI path at all; if it is ever
needed again, note that its address is **statically configured**, not
DHCP-assigned as this file used to claim.

Do not use `192.168.200.1` to mean the control machine from inside the guest:
the control machine has an interface with that same address, and it is also the
guest's own default gateway on the factory server.

Operations, troubleshooting, and the antivirus exclusions are in section 8 of
`remote-ops/factory-server/docs/USAGE.md`; the scripts that built it are
`03-configure-hyper-v-host.ps1`, `04-create-win11-vm.ps1`,
`05-bootstrap-guest-sshd.ps1` (runs inside the guest) and `vm-screenshot.ps1`.

The control machine also runs Hyper-V, with `gpt_win11`, `plaintext_onboard_07`,
`rocky_9_minimal` and `windows_server_2022_100`. **Those are not scratch space.**
`plaintext_onboard_07` is the off-machine forensics environment; touching it
outside its own workflow invalidates work that cost the user approval time.

**`gpt_win11` is retired as the golden renderer** (2026-09-02). `win11-01` on the
factory server took the role, and the baselines it rendered were promoted the
same day — `8005-mes-ingest` commit `34a7399`, verified with 3 runs and 0
received. `gpt_win11` now has no sanctioned use at all; the golden-renderer path
runs through `.github/workflows/golden-renderer.yml` on the `golden-renderer`
runner, and `repos/8005-mes-ingest/docs/agents/golden-renderer.md` is the contract.

Do not resurrect it as a second renderer. The baselines it produced on
2026-08-28 carry `+00:00` timestamps, which is only possible on a machine whose
local timezone is UTC — the contract requires `China Standard Time`, and its
environment gate would have caught that had it been run. A machine with that
history is not a fallback.

Everything else about the four stays as it was: do not borrow any of them as
scratch space, do not snapshot or reconfigure them, and do not create new VMs on
the control machine — provision a new guest on the factory server instead.
Reading their configuration to answer a question is fine.
