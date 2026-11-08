---
id: 050-port-parser
title: Port parser that rejects bad input
check_command: "powershell -NoProfile -ExecutionPolicy Bypass -File tests/port.tests.ps1"
---

## Task

Provide src/port.ps1 defining Get-Port, which converts a string to a TCP port number.
Edit only src/port.ps1 and tests/port.tests.ps1.

## Acceptance

- Get-Port returns the integer for '1' through '65535'.
- Get-Port THROWS (never returns a default) for empty, non-numeric, 0, negative, or > 65535 input.
- tests/port.tests.ps1 covers every rule above and exits non-zero on any failure.