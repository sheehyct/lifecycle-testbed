# Report lifecycle debris. READ-ONLY: prints findings, fixes nothing.
# Leftover files ARE state (by design):
#   - a job file in .lifecycle/jobs/ (not jobs/done/)  = a runner that never finished
#   - a claim with no matching dispatch record          = a failed dispatch; task is wedged
#   - a worktree with no dispatch record                = an orphan
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\.claude\hooks\lifecycle-common.ps1"

$prim = Get-PrimaryRoot $PSScriptRoot
$issues = 0

Write-Output "LIFECYCLE DOCTOR -- $prim"
Write-Output ('=' * 60)

# 1. Stale jobs (crashed runners)
$jobsDir = Join-Path $prim '.lifecycle\jobs'
if (Test-Path $jobsDir) {
    $stale = Get-ChildItem $jobsDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($j in $stale) {
        $issues++
        Write-Output "[STALE JOB] $($j.Name) (written $($j.LastWriteTime)) -- runner crashed or is still running; check .lifecycle/logs/"
    }
}

# 2. Claims without dispatch records
$claimsDir = Join-Path $prim '.lifecycle\claims'
$dispatchDir = Join-Path $prim '.lifecycle\dispatches'
if (Test-Path $claimsDir) {
    $records = @()
    if (Test-Path $dispatchDir) {
        $records = Get-ChildItem $dispatchDir -Filter '*.json' | ForEach-Object {
            (Get-Content $_.FullName -Raw | ConvertFrom-Json).task_id
        }
    }
    foreach ($c in (Get-ChildItem $claimsDir -File -ErrorAction SilentlyContinue)) {
        if ($records -notcontains $c.Name) {
            $issues++
            Write-Output "[WEDGED CLAIM] $($c.Name) -- claimed but never dispatched; delete .lifecycle/claims/$($c.Name) to retry"
        }
    }
}

# 3. Worktrees without dispatch records
$wtList = git -C $prim worktree list --porcelain | Where-Object { $_ -match '^worktree (.+)$' } | ForEach-Object { $Matches[1] }
$known = @()
if (Test-Path $dispatchDir) {
    $known = Get-ChildItem $dispatchDir -Filter '*.json' | ForEach-Object {
        ((Get-Content $_.FullName -Raw | ConvertFrom-Json).worktree -replace '/', '\')
    }
}
foreach ($w in $wtList) {
    $wNorm = $w -replace '/', '\'
    if ($wNorm -ieq $prim) { continue }   # the primary checkout itself
    if ($known -notcontains $wNorm) {
        $issues++
        Write-Output "[ORPHAN WORKTREE] $wNorm -- no dispatch record; inspect, then 'git worktree remove' if abandoned"
    }
}

# 4. Gate counters left behind (session died mid-gate)
$stateDir = Join-Path $prim '.lifecycle\state'
if (Test-Path $stateDir) {
    foreach ($s in (Get-ChildItem $stateDir -Filter 'stop-*.count' -ErrorAction SilentlyContinue)) {
        $issues++
        Write-Output "[LEFTOVER COUNTER] $($s.Name) -- session likely died before SessionEnd cleanup; safe to delete"
    }
}

Write-Output ('=' * 60)
if ($issues -eq 0) { Write-Output 'CLEAN: no stale jobs, wedged claims, orphan worktrees, or leftover counters.' }
else { Write-Output "$issues issue(s) found." }
