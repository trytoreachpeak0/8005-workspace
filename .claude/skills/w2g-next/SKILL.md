---
name: w2g-next
description: >
  Work out the single next action on the WIRE_TO_GATE project and say what it is.
  Reads the real state — slice board, gate evidence, open defects, working tree —
  and applies a fixed priority ladder instead of guessing. Use whenever the user
  is unsure what to work on or how the workflow advances: "现在该做什么",
  "下一步做什么", "接下来干嘛", "我不知道该做什么了", "工作流怎么推进",
  "what should I do next", "/w2g-next". Also use before starting a work session
  on 8005-agv-control-server, 8005-agv-protocol, or a slice, to confirm the
  chosen task is actually the frontier.
---

# What to do next on WIRE_TO_GATE

Answer with **one** next action, not a menu. The point of this skill is that the
project's state already determines the answer; your job is to read the state
honestly and apply the ladder.

Deliver the answer in Chinese. Keep identifiers, paths, commands, gate names and
`vectorId` values in English.

## 1. Gather state

Run these before deciding anything. Do not skip a source because you think you
know its answer — a stale assumption is what this skill exists to prevent.

```bash
# Where the working tree stands, in every writable repo
git -C repos/8005-agv-control-server status --short
git -C repos/8005-agv-protocol status --short

# The progress board: the issue labelled wayfinder:map
gh issue list -R trytoreachpeak0/8005-agv-protocol --label wayfinder:map --json number,title
gh issue view <that number> -R trytoreachpeak0/8005-agv-protocol

# Open work, both sides
gh issue list -R trytoreachpeak0/8005-agv-control-server --state open
gh issue list -R trytoreachpeak0/8005-agv-protocol --state open

# Slice order and dependencies
cat repos/8005-agv-protocol/integration-slices/index.json

# Unfixed defects
ls repos/8005-agv-control-server/docs/defects/

# Most recent gate evidence
ls -t repos/8005-agv-control-server/evidence/g2 | head -3
ls -t repos/8005-agv-control-server/evidence/g3 | head -3
ls -t repos/8005-agv-control-server/evidence/rc | head -3
```

Paths are relative to the workspace root `C:\Users\szy\Desktop\8005-workspace`;
the seven component clones live under `repos/` there.

## 2. Apply the ladder

**First match wins. Stop there.** Do not present later rungs as alternatives —
that turns a decision back into a question.

1. **Uncommitted product-code changes in a writable repo.**
   Finish what is already open before starting anything new: run the repo's
   default test command, then commit. An abandoned half-change is the most
   expensive thing on this list.

2. **An open issue assigned to the user in a repository they own.**
   Lowest issue number first. It was already triaged as the thing to do.

3. **An unfixed defect in `docs/defects/` that blocks a slice.**
   A defect with no linked fix evidence blocks every slice whose gates it
   touches. Fix it before advancing the frontier.

4. **The frontier slice: lowest `sequence` whose `prerequisites` are all
   satisfied and whose `CONTROL_SERVER_G2` is not green.**
   This is the normal answer. Advance it — implement, then run
   `CONTROL_SERVER_G2` for that slice.

5. **Our G2 is green everywhere but the other side's `ONBOARD_HMI_G2` is not.**
   This is not our work. Two things are worth doing, in this order: post the
   current status on the board issue so Kun Wang sees where he is blocking, then
   pick up work that does not depend on him — a later slice that is parallel by
   `prerequisites`, technical debt, or the control-server UI.

6. **Both sides' G2 are green on a slice and `G3` has not run.**
   Propose scheduling G3. It needs both people present and is the most expensive
   resource on the project — say so, and name the exact runner and evidence
   directory.

7. **All eight slices are green across all four gates.**
   Cut a release candidate: `.\scripts\New-WireToGateReleaseCandidate.ps1`.

8. **Nothing above matches.**
   Report the state you found and ask. Do not invent work.

## 3. Say it in a fixed shape

Four parts, nothing else:

- **做什么** — one sentence, the action.
- **为什么是它** — which rung fired, and the evidence that put it there.
- **怎么开始** — the exact first command or file.
- **什么时候算完成** — the gate, test, or artifact that closes it.

## Honesty rules

- **`ONBOARD_HMI_G2` status is usually unknown to us.** Kun Wang's repository is
  read-only and often carries no pass/fail evidence. When the board says `❓`,
  say it is unknown and that confirming it means asking him — never assume green
  and never assume red.
- **Green in old evidence may be void.** A protocol release invalidates the
  affected G1/G2/G3 evidence on both sides. If the protocol moved after an
  evidence directory was written, treat that gate as not green and say why.
- **Never propose entering a gate on your own initiative.** Name it, say what it
  costs and what it proves, then ask.
- If two rungs look equally live, the lower number wins. Say that you made the
  call and why.

## What this skill does not do

It picks the next action; it does not do the work. Once the user agrees, drop
out of this skill and work normally under the repository's own `CLAUDE.md`.
