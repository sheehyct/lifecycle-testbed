# Stop hook: completion gate for AUTONOMOUS sessions (spec Component B).
# exit 0 = allow stop; exit 2 + stderr = force the session to continue.
# Interactive sessions (no .lifecycle/active-task.json in cwd) are never gated.
# No built-in loop guard exists (DEVIATIONS.md, Component B entry) — the continuation
# cap is a counter file keyed by session_id, cleaned by the SessionEnd hook.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lifecycle-common.ps1"

if ($env:SKIP_STOP_GATE -eq '1') { exit 0 }   # escape hatch for debugging

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch { exit 0 }

$cwd = $payload.cwd
if (-not $cwd -or -not (Test-Path $cwd)) { exit 0 }

$taskPath = Join-Path $cwd '.lifecycle\active-task.json'
if (-not (Test-Path $taskPath)) { exit 0 }    # not an autonomous session: no gate
$task = Get-Content $taskPath -Raw | ConvertFrom-Json

$sid = $payload.session_id
$stateDir = Join-Path $cwd '.lifecycle\state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$counterPath = Join-Path $stateDir "stop-$sid.count"
$outcomePath = Join-Path $stateDir "outcome-$sid.txt"

$count = 0
if (Test-Path $counterPath) { $count = [int]((Get-Content $counterPath -Raw).Trim()) }

# Cap reached: allow the stop, but record that the gate gave up — the runner
# suppresses next-task dispatch and flags it in the notification.
if ($count -ge 3) {
    Set-Content -Path $outcomePath -Value 'GATE-CAP-EXCEEDED: 3 forced continuations did not produce a passing close' -Encoding utf8
    exit 0
}

function Block {
    param([string]$Reason)
    Set-Content -Path $counterPath -Value ($count + 1) -Encoding utf8
    [Console]::Error.Write($Reason)
    exit 2
}

$msg = $payload.last_assistant_message
if (-not $msg) { $msg = '' }

# Check 1: explicit machine-checkable outcome marker in the final message.
if ($msg -notmatch 'TASK COMPLETE|BLOCKED:') {
    Block ("End your final message with 'TASK COMPLETE -- <one-line summary>' when the " +
           "acceptance criteria are met, or 'BLOCKED: <what is missing>' if you cannot " +
           "proceed. If BLOCKED on a missing credential, name it; do not fabricate or " +
           "stub around it (invariant 4).")
}

# BLOCKED sessions may stop (invariant 4 path). Preserve the reason for the runner.
if ($msg -match 'BLOCKED:\s*(.+)') {
    Set-Content -Path $outcomePath -Value ('BLOCKED: ' + $Matches[1].Trim()) -Encoding utf8
    Remove-Item $counterPath -Force -ErrorAction SilentlyContinue
    exit 0
}

# Check 2: clean working tree.
$dirty = git -C $cwd status --porcelain
if ($dirty) {
    Block ("Working tree has uncommitted changes:`n" + ($dirty | Out-String) +
           "Commit them (conventional message) or declare BLOCKED with a reason.")
}

# Check 3: optional per-task objective check (from the task's front-matter).
if ($task.check_command) {
    $out = ''
    $code = 0
    try {
        Push-Location $cwd
        $out = Invoke-Expression $task.check_command 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $out = $_.Exception.Message
        $code = 1
    } finally {
        Pop-Location
    }
    if ($code -ne 0) {
        $tail = (($out -split "`n") | Select-Object -Last 25) -join "`n"
        Block ("check_command failed (exit $code):`n$tail`nFix the failure, commit, then " +
               "close with 'TASK COMPLETE -- ...'.")
    }
}

# All checks pass: record the outcome for the SessionEnd runner (SessionEnd stdin
# does not carry last_assistant_message) and allow the stop.
$completeLine = ($msg -split "`n") | Where-Object { $_ -match 'TASK COMPLETE' } | Select-Object -First 1
if (-not $completeLine) { $completeLine = 'TASK COMPLETE' }
Set-Content -Path $outcomePath -Value $completeLine.Trim() -Encoding utf8
Remove-Item $counterPath -Force -ErrorAction SilentlyContinue
exit 0
