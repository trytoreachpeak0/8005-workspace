@AGENTS.md

# Claude Code

The instructions for this workspace are in `AGENTS.md`, imported above so that
every coding agent reads the same text. Write new rules there, not here. This
file holds only what is specific to Claude Code, and keeps `@AGENTS.md` as its
first line. This repository has no CI, so nothing checks that line; keep it.

The two imports below stay here rather than in `AGENTS.md`, because an import is
how Claude Code reads a file at session start; `AGENTS.md` names both files in
words for other agents.

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

The rules both workspaces share — repository write authority, the scripting
baseline, collaboration and language, the CI runners, the agv02/agv03 isolation
for v2 vehicle work and the .NET toolchain baseline — live in
`8005-agv-program` and are imported here, so that `8005-workspace-v2` reads the
same versioned copy (trytoreachpeak0/8005-agv-program#228):

@repos/8005-agv-program/docs/agents/workspace-rules.md

That file is the authority on write access and applies from the start of every
session. Where a repository restates any of it, that file wins. What is
specific to this workspace is in `AGENTS.md`, imported on the first line; what
follows here is specific to Claude Code.

**Start sessions in this workspace's root directory.** Only there is the import
above inside the working directory. From a subdirectory it counts as an
external import and is silently dropped unless external imports were approved
for this repository (not approved on the control machine as of 2026-11-23), and
a worktree of this repository has no `repos/` at all, so the import has no
target; either way the write-authority rules are missing without any error.
