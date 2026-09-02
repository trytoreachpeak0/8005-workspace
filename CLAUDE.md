# 8005-workspace

A workspace of independent git repositories, not a monorepo. Each subdirectory
is its own clone with its own remote — stage, commit, and push one repository at
a time, and never assume a change in one is visible to another.

Each repository carries its own `CLAUDE.md` with the rules for working inside
it, but Claude Code loads those only once it reads a file in that directory.
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
| `8005-agv-onboard-hmi` | **Read-only for agents** |
| `slots-simulator` | **Read-only for agents** |
| `8005-agv-protocol` | Writable — **notify Kun Wang after every change** |

### Read-only

No edits or generated files — source, tests, configuration, scripts,
documentation, handoffs, or evidence. No branches, commits, tags, releases,
issues, pull requests, comments, or pushes. Read-only inspection and fetches
are fine. Run validation that would generate files from a disposable copy, or
with outputs outside the protected repository, and leave its worktree
unchanged.

### Notify-after-change

`8005-agv-protocol` is writable. Zhengyu Shao decides its content alone — Kun
Wang's approval is **not** required in advance (changed 2026-09-02; the earlier
dual-approval gate no longer applies).

What replaces it: **every pushed change must be announced to Kun Wang**, because
the protocol is the contract his side builds against and a release invalidates
his gate evidence. Open an issue in `8005-agv-protocol` that `@SocialKKKK`, and
state three things — what changed, which `W2G-IS-*` slices it touches, and
whether his `ONBOARD_HMI_G2` evidence is now void. Do this in the same task as
the push, not later.

Formal releases are unchanged: `docs/release-governance.md` still requires two
distinct product owners in the approval attestation before an immutable tag, and
AI and CI still cannot approve. That governs tagging a `ProtocolRelease`, not
ordinary commits.

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
`8005-mes-ingest/.artifacts/releases/` keep their
`#Requires -Version 5.1` header. They were validated and shipped as 5.1
artifacts. Never retrofit a released script in either direction — not to PS7,
and not back to 5.1.

## 协作与语言

项目由两个人推进：Kun Wang（GitHub `SocialKKKK`）负责 `8005-agv-onboard-hmi` 与
`slots-simulator`；Zhengyu Shao 负责 `8005-agv-control-server`；`8005-agv-protocol`
共同维护。**权威文档是 `8005-agv-program/docs/collaboration-workflow.md`**，各仓 `CLAUDE.md`
里内联了 agent 必须遵守的部分。

注意 `8005-workspace` 这个仓库**只有 Zhengyu Shao 有访问权**，Kun Wang 看不到。任何需要
对方看到的东西不能只写在这里。

协作单位是 `8005-agv-protocol/integration-slices/index.json` 里的 integration slice
（`W2G-IS-00` 到 `W2G-IS-07`），每个切片的 `gates` 就是分工。跨仓库反馈必须带可复现的
门禁证据。protocol 由 Zhengyu Shao 单独决定内容，但**每次推送都要开 issue @`SocialKKKK`
通知**（见上面 Notify-after-change）。发布打 tag 仍需双人签名，AI 和 CI 不能批准。
协议改动要攒批次——补丁发布会作废两边受影响的 G1/G2/G3 证据。

**agent 指令文件用英文**（各仓 `CLAUDE.md`、`.claude/` 下的规则与 skill、
`docs/agents/`）；**人看的东西用中文**（README、文档正文、`docs/defects/`、证据
`SUMMARY.md`、issue 与 PR 的标题和正文、commit message 正文）。中文里保持英文：
commit 的 conventional 前缀、标识符、路径、命令、环境变量、错误码、门禁与切片名、
协议消息名与 schema 字段与 `vectorId`。引用报错和测试输出先贴英文原文再中文解释。
不回溯改旧的。

不知道该做什么时用 **`w2g-next`** skill（`.claude/skills/w2g-next/`）：它读真实状态并
按固定优先级阶梯给出唯一一个下一步。

## CI：不用托管 runner，改用 factory-server 上的 self-hosted runner

**不要用 GitHub 托管 runner。**2026-09-02 试过五轮，riot-sdk 与 control-server
通过，但 `8005-mes-ingest` 有一整批测试对运行机器有硬假设，托管 runner 满足不
了——断言真实桌面工作区 >= 1280x760、要 Oracle 客户端 thick 模式、断言"取消在
3 秒内返回"这种挂钟行为（托管机上要 46-53 秒）。这不是配置问题，是这套测试的
固有属性：它本来就是为一台特定机器写的。这个判断没有变。

**改用 self-hosted runner**（同日晚些时候的决定，取代了当时"完全不用 CI"的结
论）：runner 跑在 factory-server 的 Hyper-V 客户机 `win11-01` 上（`ssh vm01`），
那台机器同时接替控制端的 `gpt_win11` 成为黄金渲染机。它满足全部机器假设，而且
能砍掉 `8005-mes-ingest/Invoke-GoldenRendererValidation.ps1` 那 823 行"因为测试
机在别处"才需要的编排——payload 部署、PowerShell Direct 会话、计划任务注册、证
据回捞全部不再需要。

**已落地（2026-09-02）。**win11-01 上跑着三个 runner，用标签分工：

| runner | 模式 | 标签 | 归属仓 |
| --- | --- | --- | --- |
| `win11-01-riot-sdk` | 服务（session 0） | `headless` | riot-sdk |
| `win11-01-mes-ingest` | 服务（session 0） | `headless` | 8005-mes-ingest |
| `win11-01-mes-ingest-desktop` | 交互式（session 1） | `golden-renderer` | 8005-mes-ingest |

交互式那个由登录触发的计划任务在桌面会话里拉起，依赖客户机的 autologon（用
Sysinternals Autologon 配的，密码进 LSA secret 而不是明文注册表，`DefaultPassword`
键不存在）。**workflow 的 `runs-on` 一定要带 `headless` 或 `golden-renderer`**，
只写 `[self-hosted, win11-01]` 会被两种 runner 里任意一个领走，而其中一个画不了图。

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

1. **挂了 self-hosted runner 的仓库绝不能是 public。**任何人提一个 PR 就能在那
   台机器上执行任意代码，而它经跳板能碰到 factory-server 上的生产服务。
   `8005-agv-protocol` 已于 2026-09-02 从 public 转为 private，正是为此。不要把
   任何仓库改回 public。
2. **`trytoreachpeak0` 是个人账号不是组织，一个 runner 只能绑一个仓库。**要给
   多个仓做 CI，就必须在同一台机器上装多个 runner 实例（不同目录、不同服务名），
   而它们会各自并行领作业。所以**不要指望"一台机器一个 runner"去保证黄金渲染机
   契约的 "Never run two desktop suites in parallel"**——跨仓库的桌面独占
   GitHub 的 `concurrency` 表达不了（它只在单个仓库内生效），那仍然是
   `8005-mes-ingest` 里 desktop mutex 的职责。只给需要金机的 runner 打
   `golden-renderer` 标签，别的 runner 不要带。
3. **黄金渲染机的 Validation 阶段只能 `workflow_dispatch` 手动触发。**它会产生
   候选基线，那必须是用户点头之后的动作，见 `8005-mes-ingest/CLAUDE.md`。

那轮托管 CI 抓到过一个本地发现不了的真 bug（`.gitattributes` 的字节规则在拆分时
丢失，导致查询文件摘要对不上）。**教训是：改动会影响构建的文件后，用干净
checkout 验证一次**——例如临时克隆到别处再跑测试。

## .NET 工具链基线

四个可写 .NET 仓库统一到一套工具链，真相来源是
`8005-agv-program/docs/adr/cross/0056-dotnet-toolchain-baseline.md`：

| 项 | 锁定值 |
| --- | --- |
| SDK | 8.0.424，`rollForward: disable` |
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

This repository tracks only workspace-level files; the seven component clones
and the `w2g-rc-*` build output are gitignored.

`8005---AGV` was split and renamed on 2026-09-02 — it is now `8005-agv-program`
(requirements and decisions, no code), plus `8005-mes-ingest` and `riot-sdk`.
Its history was rewritten to purge `.artifacts/`, so every commit hash changed
and any old clone must be re-cloned. The pre-split mirror sits outside the
workspace at `C:\Users\szy\8005-restructure-backup`. See `repos.md`.

- `repos.md` — the seven repositories, their working branches, and who owns each.
  It also records the 2026-09-02 split of `8005---AGV`.
- `setup.ps1` — clones whatever is missing on a new machine. Never pulls or
  resets an existing clone.
- `file-naming-convention/` — naming rules for this root and the four
  repositories owned here. Lowercase kebab-case; the document states the
  exceptions. It does not govern the three repositories owned by other people.
- `releases/<id>/` — the recipe to rebuild and verify a release candidate:
  manifest, hashes, operator's manual, build scripts. Never the binaries.
- `remote-ops/` — every channel for reaching a machine in the plant. Writable;
  reaching a machine through it never grants write access to the repository
  whose code runs there. Two channels, one subdirectory each:
  - `onboard-hmi/` — SSH (`ssh agv01`, one alias per car) to the AGV onboard HMI
    machines: probe, bootstrap, and hardening scripts, the control-host SSH
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
| `ssh vm01` | `win11-01` / `DESKTOP-F9HC40O` | `192.168.200.50` | Windows 11 Pro 26200.9168, activated, `agvops` local admin, 20 vCPU, 8 GB static, 1920x1080. pwsh 7.6.5, .NET SDK 8.0.424, git 2.55.0.5 |

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
environment gate; the 8 GB is static because dynamic memory had been assigning
it 2.5 GB, which starves a restore/build/test cycle. Reproduce both with
`remote-ops/factory-server/scripts/06-configure-golden-renderer-vm.ps1`.

**The guest cannot reach `github.com` over HTTPS**, and neither can the factory
server itself — verified 2026-09-02, `github.com:443` does not complete a TCP
handshake from either. What does work: `github.com:22` (so git over SSH),
`api.github.com`, `pipelines.actions.githubusercontent.com`,
`results-receiver.actions.githubusercontent.com` and NuGet, all direct. A runner
therefore registers and reports fine, but must check out over SSH rather than
HTTPS. One-off installer downloads are staged from the control machine with
`scp`, or routed through the control machine's proxy at `172.19.162.241:7890`
when it is running — that address is the control machine's Wi-Fi interface and
is DHCP-assigned, so never write it into anything that must keep working.

Do not use `192.168.200.1` to mean the control machine from inside the guest:
the control machine has an interface with that same address, and it is also the
guest's own default gateway on the factory server.

Operations, troubleshooting, and the antivirus exclusions are in section 8 of
`remote-ops/factory-server/docs/USAGE.md`; the scripts that built it are
`03-configure-hyper-v-host.ps1`, `04-create-win11-vm.ps1`,
`05-bootstrap-guest-sshd.ps1` (runs inside the guest) and `vm-screenshot.ps1`.

The control machine also runs Hyper-V, with `gpt_win11`, `plaintext_onboard_07`,
`rocky_9_minimal` and `windows_server_2022_100`. **Those are not scratch space.**
`gpt_win11` is the golden renderer whose visual baselines are calibrated and
user-approved (`8005-mes-ingest/.claude/rules/watch-ui.md`), and
`plaintext_onboard_07` is the off-machine forensics environment; touching either
outside its own workflow invalidates work that cost the user approval time.

`gpt_win11` has exactly one sanctioned use: the tier 2 and tier 3 golden-renderer
runs defined in `8005-mes-ingest/CLAUDE.md`, each of which the user must authorize
first. That path stays open and follows its own rules (1920x1080 at 100% / 96 DPI,
no RDP or Enhanced Session, never overwrite a baseline before the user reviews
the preview). Everything else is off limits: do not borrow any of the four as
scratch space, do not snapshot or reconfigure them, and do not create new VMs on
the control machine — provision a new guest on the factory server instead.
Reading their configuration to answer a question is fine.
