# Component repositories

All eight are cloned under `repos/` in this workspace and tracked on their own
remotes. This repository never contains their content — `setup.ps1` restores
them. Write authority is defined in `CLAUDE.md`; the "Owner" column below is
why, not a second policy.

The `Directory` column names the directory inside `repos/`, so
`8005-agv-protocol` is at `repos/8005-agv-protocol` from the workspace root.
They were moved there on 2026-09-04; before that they sat directly in the root.
The move kept them siblings of one another, so relative paths **between**
repositories are unchanged.

| Directory | Remote (`github.com/trytoreachpeak0/`) | Working branch | Owner | Agent access |
| --- | --- | --- | --- | --- |
| `8005-agv-program` | `8005-agv-program` | `main` | mine | writable |
| `8005-agv-control-server` | `8005-agv-control-server` | `ControlServer_MVP` | mine | writable |
| `8005-mes-ingest` | `8005-mes-ingest` | `main` | mine | writable |
| `riot-sdk` | `riot-sdk` | `main` | mine | writable |
| `8005-agv-onboard-hmi` | `8005-agv-onboard-hmi` | `OnboardHmi_MVP` | colleague | `w2g/*` branches only |
| `slots-simulator` | `slots-simulator` | `main` | colleague | `w2g/*` branches only |
| `8005-agv-protocol` | `8005-agv-protocol` | `main` | mine | writable — the announcement duty ended 2026-09-08 |
| `8005-test-lab` | `8005-test-lab` | `main` | mine | writable — the multi-machine test lab, created 2026-09-04; decisions only until its wayfinder map clears |

The naming conventions in `file-naming-convention/` govern this workspace root
and four repositories by name — `8005-agv-program`, `8005-agv-control-server`,
`8005-mes-ingest`, `riot-sdk`. That list is the document's own scope statement,
so it did not grow when `8005-test-lab` and `8005-agv-protocol` joined the
"mine" column; widening it is a decision, not a formality. Everything else keeps
its own habits.

"Owner" and "Agent access" stopped agreeing on 2026-09-04. The two repositories
owned by the colleague are still his — he accepts or declines what lands in them
— but the development work on both moved here. We commit on `w2g/*` branches and
deliver by pull request; their working branches (`OnboardHmi_MVP`, `main`) stay
untouched by us. `CLAUDE.md` has the exact rule.

`8005-agv-protocol` moved from "shared" to "mine" on 2026-09-08, when the user
took over the colleague's project. Content decisions were already his alone
since 2026-09-02; what ended that day is the duty to announce every push, and
the two-owner release signature. See `CLAUDE.md`.

## 2026-09-02 的拆分

`8005---AGV` 拆成了三个仓库并改名：

- **`8005-agv-program`**（原 `8005---AGV`，GitHub 上做了重命名，旧 URL 自动重定向）
  —— 需求基线、商务协议、跨子系统 ADR、`CONTEXT.md`、`.scratch/` 决策档案。**不含代码。**
- **`8005-mes-ingest`** —— 原 `mes/ingest/csharp/`，提到仓库根。带 `ADR-mes-*`、金机
  流程文档和 `.claude/rules/watch-ui.md`。
- **`riot-sdk`** —— 原 `rcs/riot-sdk/`，提到仓库根。C# 与 Python 两套实现都在里面，
  所以名字不带 `-dotnet`，也不带 `8005-` 前缀（它是 RCS 厂商的接口，不是本项目专有）。

同时从历史里清掉了 `.artifacts/`（占历史的 90%）和 92 个 Codex 检查点 ref：
**914 MB → 52 MB，557 个提交一个没少。**

**历史被重写了，全部 commit hash 变更。**任何 `8005---AGV` 的旧克隆都要重新克隆。
拆分前的完整 mirror 备份在控制端 `C:\Users\szy\8005-restructure-backup\`。
