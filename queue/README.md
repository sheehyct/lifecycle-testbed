# queue/ — autonomous task queue

One markdown file per task. Consumed lowest filename first (use numeric prefixes:
`010-...md`, `020-...md`). `README.md` is never a task.

## Task file format

```markdown
---
id: 010-short-slug
title: One-line human title
base: main
check_command: "powershell -NoProfile -Command <objective check, exit 0 = pass>"
---

## Task

The prompt body the dispatched session receives. Be specific; the session runs
unattended.

## Acceptance

- criterion the Stop gate and the Codex review prompt both see
- another criterion
```

Front-matter fields: `id` (defaults to the filename), `title`, `base` (defaults to
`lifecycle.config.json`'s `base_branch`), `check_command` (optional; run by the Stop gate
in the worktree — non-zero exit blocks the session from stopping).

## Claim / consume semantics

- A task is claimed by atomically creating `.lifecycle/claims/<task-basename>` in the
  PRIMARY checkout (`[IO.File]::Open CreateNew` — exactly one claimant wins a race).
- The SessionEnd runner claims the lowest unclaimed task before dispatching it;
  `dispatch-session.ps1` claims when invoked manually.
- A claimed task file stays in `queue/` while its branch is in flight. After the human
  merges (or rejects) the branch, move the file to `queue/done/` by hand.
- A claim with no matching dispatch record in `.lifecycle/dispatches/` is debris from a
  failed dispatch — `scripts/lifecycle-doctor.ps1` reports these; delete the claim to
  make the task eligible again.
