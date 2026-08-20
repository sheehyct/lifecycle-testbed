---
id: 020-chain-task
title: Write a verification quote file (chain smoke test)
base: main
check_command: "powershell -NoProfile -Command if (Test-Path 'quotes.md') { exit 0 } else { exit 1 }"
---

## Task

Create a file `quotes.md` at the repo root containing one short original aphorism about
verifying automated systems, then commit it with a conventional-commit message.

## Acceptance

- `quotes.md` exists at the repo root with one aphorism about verification
- The working tree is clean (the file is committed)
- The commit message follows conventional-commit format
