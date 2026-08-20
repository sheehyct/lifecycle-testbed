# Dispatch a queued task as an autonomous session (spec Component A).
# Creates the worktree FIRST so the machine-checkable depth marker
# (.lifecycle/active-task.json) exists before the session starts (invariant 2;
# DEVIATIONS.md Component A entry), then launches `claude --bg` from inside it.
#
# Depth semantics: a human-dispatched session is depth 0; its SessionEnd runner may
# dispatch ONE follow-up at depth 1; a depth-1 session's runner is refused here and
# in the runner itself. Two independent layers, both machine-checkable.

param(
    [Parameter(Mandatory)][string]$TaskFile,
    [int]$Depth = 0,
    [switch]$SkipClaim
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\.claude\hooks\lifecycle-common.ps1"

$prim = Get-PrimaryRoot $PSScriptRoot
Initialize-LifecycleDirs -Root $prim
$cfg = Get-LifecycleConfig -Root $prim

# ---- Spawn guard (invariant 2), second layer ------------------------------------
$newDepth = $Depth
if ($env:LIFECYCLE_SPAWN_DEPTH) {
    # Called from inside an automated context: the child is one deeper than the caller,
    # whatever the caller passed.
    $newDepth = [Math]::Max($Depth, ([int]$env:LIFECYCLE_SPAWN_DEPTH) + 1)
}
if ($newDepth -ge 2) {
    Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'DISPATCH_REFUSED' -Detail "depth=$newDepth exceeds limit 1"
    Write-Error "DISPATCH REFUSED: spawn depth $newDepth would exceed the limit of 1 (invariant 2)."
    exit 1
}

# ---- Invariant 1 hygiene: no protection-bypassing token should ride along --------
foreach ($t in @('GH_TOKEN', 'GITHUB_TOKEN')) {
    if (Test-Path "env:$t") {
        Write-Warning "$t is set; the dispatched session inherits it. Invariant 1 relies on the ruleset having NO bypass actors."
        Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'TOKEN_WARNING' -Detail $t
    }
}

# ---- Parse task front-matter ------------------------------------------------------
$taskRaw = Get-Content $TaskFile -Raw
if ($taskRaw -notmatch '(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$') {
    Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'TASK_MALFORMED' -Detail $TaskFile
    Write-Error "Task file has no front-matter block: $TaskFile"
    exit 1
}
$fmBlock = $Matches[1]
$body    = $Matches[2].Trim()

$fm = @{}
foreach ($line in ($fmBlock -split "`n")) {
    if ($line -match '^\s*([A-Za-z_]+)\s*:\s*(.*)$') {
        $fm[$Matches[1]] = $Matches[2].Trim().Trim('"')
    }
}
$taskId = $fm['id']
if (-not $taskId) { $taskId = [IO.Path]::GetFileNameWithoutExtension($TaskFile) }
$title = $fm['title']
if (-not $title) { $title = $taskId }
$base = $fm['base']
if (-not $base) { $base = $cfg.base_branch }
$checkCommand = $fm['check_command']

$acceptance = ''
if ($body -match '(?s)##\s*Acceptance\s*\r?\n(.*?)(\r?\n##|$)') { $acceptance = $Matches[1].Trim() }

# ---- Claim (manual invocation claims here; the runner claims before calling) ------
if (-not $SkipClaim) {
    $claim = Join-Path $prim ".lifecycle\claims\$([IO.Path]::GetFileNameWithoutExtension($TaskFile))"
    if (-not (New-AtomicClaim -Path $claim)) {
        Write-Error "Task already claimed: $TaskFile (delete the marker in .lifecycle/claims/ to re-dispatch)"
        exit 1
    }
}

# ---- Worktree FIRST (so the depth marker exists pre-launch) ------------------------
$repoName = Split-Path $prim -Leaf
$wtParent = Join-Path (Split-Path $prim -Parent) "$repoName-wt"
if (-not (Test-Path $wtParent)) { New-Item -ItemType Directory -Force -Path $wtParent | Out-Null }
$wt = Join-Path $wtParent $taskId
$branchName = "task/$taskId"

$r = Invoke-Native -Exe 'git' -Arguments @('-C', $prim, 'worktree', 'add', '-b', $branchName, $wt, $base)
if ($r.ExitCode -ne 0) {
    Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'WORKTREE_FAILED' -Detail "$wt (branch $branchName): $($r.Output -join ' / ')"
    Write-Error "git worktree add failed for $wt (does branch '$branchName' or the path already exist?)"
    exit 1
}

New-Item -ItemType Directory -Force -Path (Join-Path $wt '.lifecycle\state') | Out-Null
[pscustomobject]@{
    task_id       = $taskId
    task_file     = $TaskFile
    title         = $title
    depth         = $newDepth
    base          = $base
    check_command = $checkCommand
    acceptance    = $acceptance
    dispatched_at = (Get-Date -Format o)
} | ConvertTo-Json | Set-Content -Path (Join-Path $wt '.lifecycle\active-task.json') -Encoding utf8

[pscustomobject]@{
    task_id       = $taskId
    worktree      = $wt
    branch        = $branchName
    depth         = $newDepth
    dispatched_at = (Get-Date -Format o)
} | ConvertTo-Json | Set-Content -Path (Join-Path $prim ('.lifecycle\dispatches\{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $taskId)) -Encoding utf8

# ---- Prompt (no double-quote characters: PS 5.1 native-arg quoting mangles them) -----
# NEVER lead with a slash command: in -p mode an unknown /command aborts the session
# instantly (Unknown command: /session-start) instead of being read as prompt text.
$prompt = @"
You are running AUTONOMOUSLY (spawn depth $newDepth), dispatched by the session lifecycle.
If this repo has a session-start skill or command, follow its steps first — but adapt its
wait-for-user-direction step: the TASK below IS your direction; proceed without waiting.

TASK: $title

$body

Rules:
- Work ONLY in this worktree, on branch $branchName. Never push to $base.
- Commit with conventional-commit messages as you complete work.
- If a credential or resource is missing, do not fabricate or stub around it (invariant 4).
- End your FINAL message with 'TASK COMPLETE -- <one-line summary>' once the Acceptance
  criteria are met, or 'BLOCKED: <what is missing>' if you cannot proceed.
"@

# ---- Launch (detached claude -p) -------------------------------------------------------
# NOT --bg: a --bg session in a fresh worktree blocks forever on the workspace-trust
# dialog (found in E2E verification: prompt delivered, 0 tokens processed). Per
# `claude --help`, the trust dialog is SKIPPED in non-interactive mode (-p with
# stdout redirected => not a TTY). -p fires SessionStart/Stop/SessionEnd hooks
# normally and exits when the session completes, which triggers the SessionEnd
# hook -> detached runner. Prompt goes via stdin (argument quoting mangles it).
#
# permission_mode from lifecycle.config.json: an unattended session cannot answer
# permission prompts. acceptEdits default; bypassPermissions only where the repo
# is disposable AND the structural gates (ruleset, read-only codex, depth guard,
# worktree isolation) are in place.
$promptFile = Join-Path $wt '.lifecycle\dispatch-prompt.txt'
Set-Content -Path $promptFile -Value $prompt -Encoding utf8
$sessionLog = Join-Path $wt '.lifecycle\session-output.log'

$permArgs = "--permission-mode $($cfg.permission_mode)"
if ($cfg.permission_mode -eq 'bypassPermissions') {
    $permArgs = '--dangerously-skip-permissions'
}

$inner = "`$env:LIFECYCLE_SPAWN_DEPTH='$newDepth'; Set-Location '$wt'; Get-Content -Raw '$promptFile' | claude -p $permArgs *> '$sessionLog'"
Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner
)

Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'DISPATCHED' -Detail "task=$taskId wt=$wt branch=$branchName depth=$newDepth mode=$($cfg.permission_mode)"
Write-Output "Dispatched '$taskId' (depth $newDepth) in $wt on $branchName (detached claude -p; session output: $sessionLog)"
