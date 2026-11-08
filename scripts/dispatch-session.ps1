# Dispatch a queued task as an autonomous session (spec Component A).
# Creates the worktree FIRST so the machine-checkable spawn marker
# (.lifecycle/active-task.json) exists before the session starts (invariant 2;
# DEVIATIONS.md Component A entry), then launches a detached `claude -p` inside it.
#
# Spawn semantics (invariant 2, reopened ASL-3): two counted axes, each hard-capped.
#   chain     - position in a run of queued tasks. A human dispatch is chain 0; each
#               auto-dispatched next task is +1. Refused at chain >= max_chain.
#   fix_round - re-dispatch on the SAME task branch to address a NEEDS-CHANGES review.
#               0 for a fresh task; refused at fix_round > max_fix_rounds.
# Inside an automated context the env vars of the ENDING session are authoritative
# floors (max of all signals), so a caller cannot reset a counter by passing a low value.

param(
    [Parameter(Mandatory)][string]$TaskFile,
    [int]$Chain = 0,
    [int]$FixRound = 0,
    [string]$FixFindings = '',
    [switch]$SkipClaim,
    [int]$Depth = -1   # legacy (pre-ASL-3 callers): treated as a chain floor
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\.claude\hooks\lifecycle-common.ps1"

$prim = Get-PrimaryRoot $PSScriptRoot
Initialize-LifecycleDirs -Root $prim
$cfg = Get-LifecycleConfig -Root $prim

$TaskFile = (Resolve-Path $TaskFile).Path   # absolute: the runner re-reads it from another cwd

# ---- Spawn guard (invariant 2), second layer ------------------------------------
$maxChain = [int]$cfg.max_chain
$maxFix   = [int]$cfg.max_fix_rounds
$isFix    = ($FixRound -gt 0)
$newChain = [Math]::Max($Chain, $Depth)
$newFix   = $FixRound
$envChain = $null
if ($env:LIFECYCLE_CHAIN) { $envChain = [int]$env:LIFECYCLE_CHAIN }
elseif ($env:LIFECYCLE_SPAWN_DEPTH) { $envChain = [int]$env:LIFECYCLE_SPAWN_DEPTH }   # pre-ASL-3 session
if ($null -ne $envChain) {
    if ($isFix) {
        $envFix = 0
        if ($env:LIFECYCLE_FIX_ROUND) { $envFix = [int]$env:LIFECYCLE_FIX_ROUND }
        $newFix   = [Math]::Max($newFix, $envFix + 1)
        $newChain = [Math]::Max($newChain, $envChain)
    } else {
        $newChain = [Math]::Max($newChain, $envChain + 1)
    }
}
if ($newChain -ge $maxChain) {
    Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'DISPATCH_REFUSED' -Detail "chain=$newChain reaches max_chain=$maxChain"
    Write-Error "DISPATCH REFUSED: chain position $newChain reaches the cap of $maxChain tasks (invariant 2)."
    exit 1
}
if ($newFix -gt $maxFix) {
    Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'DISPATCH_REFUSED' -Detail "fix_round=$newFix exceeds max_fix_rounds=$maxFix"
    Write-Error "DISPATCH REFUSED: fix round $newFix exceeds the cap of $maxFix (invariant 2)."
    exit 1
}
if ($isFix -and -not $SkipClaim) {
    Write-Error 'A fix round re-uses an already-claimed task; pass -SkipClaim.'
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

if ($isFix) {
    # Fix round: same worktree, same branch, carrying the committed audit.
    if (-not (Test-Path (Join-Path $wt '.lifecycle\active-task.json'))) {
        Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'FIX_NO_WORKTREE' -Detail $wt
        Write-Error "Fix round needs the existing worktree $wt, which is missing."
        exit 1
    }
} else {
    $r = Invoke-Native -Exe 'git' -Arguments @('-C', $prim, 'worktree', 'add', '-b', $branchName, $wt, $base)
    if ($r.ExitCode -ne 0) {
        Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'WORKTREE_FAILED' -Detail "$wt (branch $branchName): $($r.Output -join ' / ')"
        Write-Error "git worktree add failed for $wt (does branch '$branchName' or the path already exist?)"
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path (Join-Path $wt '.lifecycle\state') | Out-Null
[pscustomobject]@{
    task_id       = $taskId
    task_file     = $TaskFile
    title         = $title
    chain         = $newChain
    fix_round     = $newFix
    base          = $base
    check_command = $checkCommand
    acceptance    = $acceptance
    dispatched_at = (Get-Date -Format o)
} | ConvertTo-Json | Set-Content -Path (Join-Path $wt '.lifecycle\active-task.json') -Encoding utf8

[pscustomobject]@{
    task_id       = $taskId
    worktree      = $wt
    branch        = $branchName
    chain         = $newChain
    fix_round     = $newFix
    dispatched_at = (Get-Date -Format o)
} | ConvertTo-Json | Set-Content -Path (Join-Path $prim ('.lifecycle\dispatches\{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $taskId)) -Encoding utf8

# ---- Prompt (no double-quote characters: PS 5.1 native-arg quoting mangles them) -----
# NEVER lead with a slash command: in -p mode an unknown /command aborts the session
# instantly (Unknown command: /session-start) instead of being read as prompt text.
$fixBlock = ''
if ($isFix) {
    $fixBlock = @"

FIX ROUND $newFix of ${maxFix}: an adversarial review of this branch returned NEEDS-CHANGES.
Read the audit at $FixFindings (committed on this branch) BEFORE anything else.
Fix every CRITICAL, HIGH and MEDIUM finding that is correct, with a test that fails without
the fix where one is practical. For a finding you judge wrong, change no code for it and
explain why in your final message. Do not widen scope beyond the findings and the task.
The original task follows for context; its Acceptance criteria still apply.
"@
}
$prompt = @"
You are running AUTONOMOUSLY (chain $newChain, fix round $newFix), dispatched by the session lifecycle.
If this repo has a session-start skill or command, follow its steps first — but adapt its
wait-for-user-direction step: the TASK below IS your direction; proceed without waiting.
$fixBlock

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
if ($isFix) { $sessionLog = Join-Path $wt ".lifecycle\session-output-fix$newFix.log" }

$permArgs = "--permission-mode $($cfg.permission_mode)"
if ($cfg.permission_mode -eq 'bypassPermissions') {
    $permArgs = '--dangerously-skip-permissions'
}

$automated = [int](($newChain -gt 0) -or ($newFix -gt 0) -or ($null -ne $envChain))
$inner = "`$env:LIFECYCLE_CHAIN='$newChain'; `$env:LIFECYCLE_FIX_ROUND='$newFix'; `$env:LIFECYCLE_SPAWN_DEPTH='$automated'; Set-Location '$wt'; Get-Content -Raw '$promptFile' | claude -p $permArgs *> '$sessionLog'"
Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner
)

Write-LifecycleEvent -Root $prim -Component 'dispatch' -Event 'DISPATCHED' -Detail "task=$taskId wt=$wt branch=$branchName chain=$newChain fix_round=$newFix mode=$($cfg.permission_mode)"
Write-Output "Dispatched '$taskId' (chain $newChain, fix round $newFix) in $wt on $branchName (detached claude -p; session output: $sessionLog)"
