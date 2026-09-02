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
| `8005---AGV` | Writable — requirements, MES ingest, agent docs, issue tracker |
| `8005-agv-control-server` | Writable — WIRE_TO_GATE server |
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
`8005---AGV/mes/ingest/csharp/.artifacts/releases/` keep their
`#Requires -Version 5.1` header. They were validated and shipped as 5.1
artifacts. Never retrofit a released script in either direction — not to PS7,
and not back to 5.1.

## 协作与语言

项目由两个人推进：Kun Wang（GitHub `SocialKKKK`）负责 `8005-agv-onboard-hmi` 与
`slots-simulator`；Zhengyu Shao 负责 `8005-agv-control-server`；`8005-agv-protocol`
共同维护。**权威文档是 `8005---AGV/docs/collaboration-workflow.md`**，各仓 `CLAUDE.md`
里内联了 agent 必须遵守的部分。

注意 `8005-workspace` 这个仓库**只有 Zhengyu Shao 有访问权**，Kun Wang 看不到。任何需要
对方看到的东西不能只写在这里。

协作单位是 `8005-agv-protocol/integration-slices/index.json` 里的 integration slice
（`W2G-IS-00` 到 `W2G-IS-07`），每个切片的 `gates` 就是分工。跨仓库反馈必须带可复现的
门禁证据。protocol 由 Zhengyu Shao 单独决定内容，但**每次推送都要开 issue @`SocialKKKK`
通知**（见上面 Notify-after-change）。发布打 tag 仍需双人签名，AI 和 CI 不能批准。
协议改动要攒批次——补丁发布会作废两边受影响的 G1/G2/G3 证据。

写进 GitHub 的东西用中文：README、文档正文、issue 与 PR 的标题和正文、commit message
正文。保持英文：commit 的 conventional 前缀、标识符、路径、命令、环境变量、错误码、
门禁与切片名、协议消息名与 schema 字段与 `vectorId`。引用报错和测试输出先贴英文原文再
中文解释。不回溯改旧的。

## Workspace layout

This repository tracks only workspace-level files; the five component clones
and the `w2g-rc-*` build output are gitignored.

- `repos.md` — the five repositories, their working branches, and who owns each.
- `setup.ps1` — clones whatever is missing on a new machine. Never pulls or
  resets an existing clone.
- `file-naming-convention/` — naming rules for this root, `8005---AGV`, and
  `8005-agv-control-server`. Lowercase kebab-case; the document states the
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
| `ssh vm01` | `win11-01` / `DESKTOP-F9HC40O` | `192.168.200.50` | Windows 11 Pro 26200.9168, activated, pwsh 7.6.5, `agvops` local admin, 6 vCPU, dynamic 4/2/8 GB |

Key-only, via `ProxyJump factory01` — the guest sits on the Internal switch
`AGV-Internal` (`192.168.200.0/24`) with NAT out, so there is no route to it
from the enterprise network and the jump host is the only way in. Its key
(`~/.ssh/agv_vm_ed25519`) is a third key, not the server's and not the
onboard-HMI one. Host config copy: `remote-ops/factory-server/config/ssh_config.vm`.
Operations, troubleshooting, and the antivirus exclusions are in section 8 of
`remote-ops/factory-server/docs/USAGE.md`; the scripts that built it are
`03-configure-hyper-v-host.ps1`, `04-create-win11-vm.ps1`,
`05-bootstrap-guest-sshd.ps1` (runs inside the guest) and `vm-screenshot.ps1`.

The control machine also runs Hyper-V, with `gpt_win11`, `plaintext_onboard_07`,
`rocky_9_minimal` and `windows_server_2022_100`. **Those are not scratch space.**
`gpt_win11` is the golden renderer whose visual baselines are calibrated and
user-approved (`8005---AGV/.claude/rules/watch-ui.md`), and
`plaintext_onboard_07` is the off-machine forensics environment; touching either
outside its own workflow invalidates work that cost the user approval time.

`gpt_win11` has exactly one sanctioned use: the tier 2 and tier 3 golden-renderer
runs defined in `8005---AGV/CLAUDE.md`, each of which the user must authorize
first. That path stays open and follows its own rules (1920x1080 at 100% / 96 DPI,
no RDP or Enhanced Session, never overwrite a baseline before the user reviews
the preview). Everything else is off limits: do not borrow any of the four as
scratch space, do not snapshot or reconfigure them, and do not create new VMs on
the control machine — provision a new guest on the factory server instead.
Reading their configuration to answer a question is fine.
