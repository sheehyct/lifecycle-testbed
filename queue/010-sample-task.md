---
id: 010-sample-task
title: Write a haiku file (lifecycle smoke test)
base: main
check_command: "powershell -NoProfile -Command if (Test-Path 'hello.md') { exit 0 } else { exit 1 }"
---

## Task

Create a file `hello.md` at the repo root containing a haiku about automation, then
commit it with a conventional-commit message.

## Acceptance

- `hello.md` exists at the repo root and contains a haiku (3 lines, 5-7-5-ish)
- The working tree is clean (the file is committed)
- The commit message follows conventional-commit format
