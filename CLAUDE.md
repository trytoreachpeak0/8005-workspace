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
| `8005-agv-protocol` | **Approval-gated**, read-only by default |

### Read-only

No edits or generated files — source, tests, configuration, scripts,
documentation, handoffs, or evidence. No branches, commits, tags, releases,
issues, pull requests, comments, or pushes. Read-only inspection and fetches
are fine. Run validation that would generate files from a disposable copy, or
with outputs outside the protected repository, and leave its worktree
unchanged.

### Approval-gated

Before any local edit, generated file, branch, commit, push, or remote
tracker/release action in `8005-agv-protocol`, both Zhengyu Shao (the user) and
Kun Wang must explicitly approve the same concrete change and destination
branch. Approvals must be task-specific and present in the current task context
or an explicitly linked approval record. Do not infer approval from old
releases, authorship, map Notes, prior tickets, or approval of a different
change. One approval is not enough. If either is missing, stop at analysis and
report what approval is still required. If the requested scope changes, obtain
both approvals again.

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
`ConvertFrom-Json -AsHashtable`, and UTF-8-without-BOM file defaults. The
control host and the AGV onboard HMI machines reached through
`remote-ops/onboard-hmi/` all run pwsh 7.6.5, so remote scripts follow the
same rule.

One exception, and it does not grow: scripts that execute on a MES factory
target — the offline Windows Server 2016 host documented under
`remote-ops/factory-server/`. It is reached over WinRM, has only Windows
PowerShell 5.1, and no internet access to install pwsh. The scripts that run
there live under `8005---AGV/mes/` and keep `#Requires -Version 5.1`. Never
retrofit an already-released script in either direction.

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
  - `onboard-hmi/` — SSH to the AGV onboard HMI machines: probe, bootstrap, and
    hardening scripts, the control-host SSH config, and the design record. Read
    its `docs/USAGE.md` before touching a machine. Two things stay out of git:
    probe output (`probe-*.txt`), which inventories local accounts, the
    administrators group, autologon config, firewall state, and IP topology;
    and `payload/`, the offline OpenSSH package, which `docs/ASSETS.md`
    describes well enough to re-fetch. The operations private key lives in
    `~/.ssh/`, never here.
  - `factory-server/` — WinRM to the offline Windows Server 2016 host that
    carries SQL Server and the MES ingest deployment, reached over TCP 5985
    from a connected control machine. That host is the one Scripting baseline
    exception: Windows PowerShell 5.1 only, no route to install pwsh.
    Credentials live in `%LOCALAPPDATA%\CodexSecrets\` on the control machine,
    never here.
