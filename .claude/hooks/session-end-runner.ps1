# Detached session-end runner (spec Component C). Launched by session-end.ps1; owns
# everything too slow for the 60-second SessionEnd budget: git context, the Codex
# review, the findings file, the ntfy notification, the spawn guard, and next-task
# dispatch. Codex runs in its default read-only sandbox and THIS script writes the
# findings file from its captured output (invariant 3). The ntfy topic comes only
# from .env (invariant 4). The spawn guard is machine-checkable state, not a prompt
# rule (invariant 2).

param([Parameter(Mandatory)][string]$JobFile)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lifecycle-common.ps1"

$job  = Get-Content $JobFile -Raw | ConvertFrom-Json
$sid  = [string]$job.session_id
$sid8 = $sid.Substring(0, [Math]::Min(8, $sid.Length))
$wt   = $job.cwd
$prim = Get-PrimaryRoot $wt
Initialize-LifecycleDirs -Root $prim

$runnerLog = Join-Path $prim ('.lifecycle\logs\runner-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $sid8)
function Log {
    param([string]$Msg)
    Add-Content -Path $runnerLog -Value ('{0} {1}' -f (Get-Date -Format o), $Msg) -Encoding utf8
}
function LogEvent {
    param([string]$EventName, [string]$Detail = '')
    Write-LifecycleEvent -Root $prim -Component 'runner' -SessionId $sid -Event $EventName -Detail $Detail
}

$lockPath = $null
try {
    LogEvent 'RUNNER_START' "job=$JobFile wt=$wt"
    $cfg    = Get-LifecycleConfig -Root $prim
    $prefix = $cfg.ticket_prefix
    $base   = $cfg.base_branch

    # ---- 1. Git + task context --------------------------------------------------
    $branch = (git -C $wt branch --show-current | Out-String).Trim()
    $task = $null
    $taskPath = Join-Path $wt '.lifecycle\active-task.json'
    if (Test-Path $taskPath) {
        $task = Get-Content $taskPath -Raw | ConvertFrom-Json
        if ($task.base) { $base = $task.base }
    }

    $outcome = '(no outcome marker -- interactive session or stop gate inactive)'
    $outcomePath = Join-Path $wt ".lifecycle\state\outcome-$sid.txt"
    if (Test-Path $outcomePath) { $outcome = (Get-Content $outcomePath -Raw).Trim() }

    $ahead = 0
    if ($branch -and $branch -ne $base) { $ahead = [int]((git -C $wt rev-list --count "$base..HEAD" | Out-String).Trim()) }
    $dirty = [bool](git -C $wt status --porcelain)
    $diffstat = '(no diff)'
    if ($branch -and $branch -ne $base) {
        $ds = git -C $wt diff --stat "$base...HEAD" | Select-Object -Last 1
        if ($ds) { $diffstat = $ds.Trim() }
    } elseif ($dirty) {
        $ds = git -C $wt diff --stat | Select-Object -Last 1
        if ($ds) { $diffstat = $ds.Trim() }
    }
    Log "context: branch=$branch base=$base ahead=$ahead dirty=$dirty outcome=$outcome"

    # ---- 2. Codex review (skip when there is nothing to review) ------------------
    $verdict = 'SKIPPED'
    $findingsRel = '-'
    if ($ahead -gt 0 -or $dirty) {
        # Per-branch lock: two sessions ending near-simultaneously on the SAME branch
        # must not run duplicate reviews (verification 5). Different branches never collide.
        $slug = ($branch -replace '[^A-Za-z0-9]', '-')
        $lockCandidate = Join-Path $prim ".lifecycle\locks\review-$slug.lock"
        if (Test-Path $lockCandidate) {
            $age = (Get-Date) - (Get-Item $lockCandidate).LastWriteTime
            if ($age.TotalMinutes -gt 30) {
                Remove-Item $lockCandidate -Force
                Log 'stale review lock (>30 min) removed'
            }
        }
        if (-not (New-AtomicClaim -Path $lockCandidate)) {
            $verdict = 'DUPLICATE-SKIPPED'
            Log "review lock held for branch '$branch'; skipping duplicate review"
        } else {
            $lockPath = $lockCandidate

            # Findings file: next N over existing audits, but ALWAYS suffixed with the
            # session id — two runners on different branches can compute the same N
            # concurrently, and same-named files on sibling branches are an add/add
            # merge conflict. sid8 makes the name unique by construction.
            $reviewDir = Join-Path $wt 'docs\reviews'
            if (-not (Test-Path $reviewDir)) { New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null }
            $n = 1
            Get-ChildItem $reviewDir -Filter "$prefix*-codex-audit.md" -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -match ('^' + [regex]::Escape($prefix) + '(\d+)(?:-[A-Za-z0-9]+)?-codex-audit\.md$')) {
                    $v = [int]$Matches[1]
                    if ($v -ge $n) { $n = $v + 1 }
                }
            }
            $findingsName = "$prefix$n-$sid8-codex-audit.md"
            $findingsPath = Join-Path $reviewDir $findingsName

            $title = 'untitled'
            if ($task -and $task.title) { $title = $task.title }
            $acceptance = '(none declared)'
            if ($task -and $task.acceptance) { $acceptance = $task.acceptance }

            $diffScope = "Run 'git diff $base...HEAD' and 'git log $base..HEAD --oneline' to see the changes under review."
            if ($branch -eq $base -or $ahead -eq 0) { $diffScope = "Run 'git status' and 'git diff' to see the uncommitted changes under review." }
            $reviewPrompt = @"
You are performing an ADVERSARIAL code review of an autonomous coding session's work.
Repository root: the current working directory. Branch '$branch', base '$base'.
$diffScope Read any file you need for context.

Task the session was given: $title
Acceptance criteria the session claimed to meet:
$acceptance

Session outcome claim: $outcome

Hunt for: acceptance criteria not actually met, invariant violations, race conditions,
silent failure paths, and anything the diff claims but does not do. Do NOT assume the
work is correct.

End your review with a line 'VERDICT: APPROVE' or 'VERDICT: APPROVE-WITH-NITS' or
'VERDICT: NEEDS-CHANGES' or 'VERDICT: BLOCK', and list findings as
[CRITICAL|HIGH|MEDIUM|LOW] -- file:line -- description.
"@

            $raw = Join-Path $prim ".lifecycle\tmp\$sid-review-raw.md"
            $errFile = Join-Path $prim ".lifecycle\tmp\$sid-codex-stderr.txt"
            $outFile = Join-Path $prim ".lifecycle\tmp\$sid-codex-stdout.txt"

            # `codex exec review` rejects a custom prompt combined with --base, and the
            # acceptance-criteria context IS the review's value — so use `codex exec`
            # with an EXPLICIT read-only sandbox (invariant 3; DEVIATIONS.md C.2 entry)
            # and a prompt that diffs the range itself. -o makes the Codex CLI (not the
            # model) emit the final message to a file we then wrap. The prompt goes via
            # STDIN ('-'): argument-string quoting mangles multi-line prompts.
            $codexArgs = @('exec', '-', '-s', 'read-only', '--ephemeral', '--skip-git-repo-check', '-o', $raw)

            $codexExe = Resolve-CodexExe   # npm 'codex' is a script shim; we need the real .exe
            Log "codex: $codexExe $($codexArgs -join ' ') (prompt via stdin)"
            LogEvent 'CODEX_START' "branch=$branch base=$base out=$findingsName"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $codexExe
            $psi.Arguments = (($codexArgs | ForEach-Object {
                if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
            }) -join ' ')
            $psi.WorkingDirectory = $wt
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Write($reviewPrompt)
            $proc.StandardInput.Close()
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()   # async: avoids full-buffer deadlock
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $finished = $proc.WaitForExit(1200000)   # 20 minutes
            if (-not $finished) {
                Invoke-Native -Exe 'taskkill' -Arguments @('/PID', "$($proc.Id)", '/T', '/F') | Out-Null
                $verdict = 'REVIEW-FAILED'
                Log 'codex timed out after 20 minutes; process tree killed'
                LogEvent 'CODEX_TIMEOUT'
            } else {
                Set-Content -Path $outFile -Value $stdoutTask.Result -Encoding utf8
                Set-Content -Path $errFile -Value $stderrTask.Result -Encoding utf8
                if ($proc.ExitCode -ne 0) {
                    $verdict = 'REVIEW-FAILED'
                    $stderrTail = (($stderrTask.Result -split "`n") | Select-Object -Last 10) -join ' / '
                    Log "codex exit $($proc.ExitCode): $stderrTail"
                    LogEvent 'CODEX_FAILED' "exit=$($proc.ExitCode)"
                } else {
                    LogEvent 'CODEX_DONE'
                }
            }

            $rawContent = '(codex produced no output)'
            if (Test-Path $raw) { $rawContent = Get-Content $raw -Raw -Encoding utf8 }
            if ($verdict -ne 'REVIEW-FAILED') {
                if ($rawContent -match 'VERDICT:\s*(APPROVE-WITH-NITS|APPROVE|NEEDS-CHANGES|BLOCK)') {
                    $verdict = $Matches[1]
                } else {
                    $verdict = 'UNSPECIFIED'
                }
            }

            # The RUNNER composes the findings file (invariant 3): template wrapper
            # around the verbatim Codex output.
            $today = Get-Date -Format 'yyyy-MM-dd'
            $reviewedRange = "$base..HEAD on $branch"
            if ($ahead -eq 0) { $reviewedRange = "uncommitted working tree @ $branch" }
            $findings = @"
# External Audit -- autonomous SessionEnd runner via Codex CLI (verbatim source, read CRITICALLY)

> External review captured $today (session $sid8 post-session, autonomous).
> **Do NOT assume this is correct.** The critical synthesis -- agree, dispute, act --
> belongs in docs/HANDOFF.md, written by the next session.

---

## 1. Metadata

- **Session:** $sid (task: $title)
- **Reviewed:** $reviewedRange
- **Reviewer:** codex exec (-s read-only, --ephemeral), wrapped by session-end-runner.ps1
- **Runner verdict parse:** $verdict
- **Session outcome claim:** $outcome

## 2. Verbatim audit

$rawContent
"@
            Set-Content -Path $findingsPath -Value $findings -Encoding utf8
            $findingsRel = "docs/reviews/$findingsName"
            Log "findings written: $findingsRel verdict=$verdict"
            LogEvent 'FINDINGS_WRITTEN' "$findingsRel verdict=$verdict"

            # Flip the current-request pointer, if this repo uses one (best-effort).
            $rr = Join-Path $wt 'docs\reviews\REVIEW_REQUEST.md'
            if (Test-Path $rr) {
                $content = Get-Content $rr -Raw
                if ($content -match '- Status: REQUESTED') {
                    $content = $content -replace '- Status: REQUESTED', "- Status: RETURNED (audit: $findingsRel, $today)"
                    Set-Content -Path $rr -Value $content -Encoding utf8
                }
            }

            # Commit the findings on the session branch; push the BRANCH only. The
            # base branch is protected server-side (invariant 1) and we never try it.
            $r = Invoke-Native -Exe 'git' -Arguments @('-C', $wt, 'add', '--', 'docs/reviews')
            $r.Output | ForEach-Object { Log "git add: $_" }
            $r = Invoke-Native -Exe 'git' -Arguments @('-C', $wt, 'commit', '-m', "chore(review): codex audit $findingsName (session $sid8)")
            $r.Output | ForEach-Object { Log "git commit: $_" }
            $r = Invoke-Native -Exe 'git' -Arguments @('-C', $wt, 'remote', 'get-url', 'origin')
            $originUrl = ''
            if ($r.ExitCode -eq 0 -and $r.Output) { $originUrl = ([string]$r.Output[0]).Trim() }
            if ($originUrl -and $branch -and $branch -ne $base) {
                $r = Invoke-Native -Exe 'git' -Arguments @('-C', $wt, 'push', '-u', 'origin', $branch)
                $r.Output | ForEach-Object { Log "git push: $_" }
                if ($r.ExitCode -ne 0) { LogEvent 'PUSH_FAILED' $branch } else { LogEvent 'PUSHED' $branch }
            } elseif ($originUrl) {
                Log "on base branch '$base'; not pushing (base is protected; findings stay local)"
            } else {
                Log 'no origin remote; findings stay local'
            }
        }
    } else {
        Log 'nothing to review (0 commits ahead, clean tree)'
    }

    # ---- 3. Notify (best-effort; topic from .env ONLY -- invariant 4) -------------
    $ntfy = Read-DotEnvValue -Root $prim -Key 'NTFY_TOPIC_URL'
    $repoWeb = ''
    $originUrl2 = ''
    $r = Invoke-Native -Exe 'git' -Arguments @('-C', $wt, 'remote', 'get-url', 'origin')
    if ($r.ExitCode -eq 0 -and $r.Output) { $originUrl2 = ([string]$r.Output[0]).Trim() }
    if ($originUrl2 -match 'github\.com[:/]([^/]+)/([^/\s]+?)(\.git)?$') {
        $repoWeb = 'https://github.com/{0}/{1}' -f $Matches[1], $Matches[2]
    }
    $click = $repoWeb
    if ($repoWeb -and $branch -and $branch -ne $base) {
        $click = '{0}/compare/{1}...{2}?expand=1' -f $repoWeb, $base, $branch
    }
    $repoName = Split-Path $prim -Leaf
    $body = @(
        "outcome: $outcome",
        "review: $verdict ($findingsRel)",
        "diff: $diffstat"
    ) -join "`n"
    if ($ntfy) {
        try {
            $headers = @{ Title = "$repoName [$branch] $verdict" }
            if ($click) { $headers['Click'] = $click }
            Invoke-RestMethod -Method Post -Uri $ntfy -Headers $headers -Body $body -TimeoutSec 15 | Out-Null
            LogEvent 'NTFY_SENT'
        } catch {
            Log "ntfy failed: $($_.Exception.Message)"
            LogEvent 'NTFY_FAILED' $_.Exception.Message
        }
    } else {
        Log 'NTFY_TOPIC_URL not set in .env; skipping notification'
        LogEvent 'NTFY_SKIPPED'
    }

    # ---- 4. Spawn guard + next-task dispatch (invariant 2: depth <= 1) ------------
    # Fail-safe: take the MAX of every depth signal; any signal >= 1 suppresses.
    $depth = [int]$job.spawn_depth_env
    if ($task -and ($null -ne $task.depth)) { $depth = [Math]::Max([int]$task.depth, $depth) }

    if ($depth -ge 1) {
        Log "SPAWN SUPPRESSED: depth=$depth (invariant 2: spawn depth <= 1)"
        LogEvent 'SPAWN_SUPPRESSED' "depth=$depth"
    } elseif (@('BLOCK', 'NEEDS-CHANGES', 'REVIEW-FAILED') -contains $verdict -or $outcome -match 'BLOCKED|GATE-CAP') {
        Log "next-task dispatch suppressed: verdict=$verdict outcome=$outcome"
        LogEvent 'DISPATCH_SUPPRESSED' "verdict=$verdict"
    } else {
        $next = $null
        $queueDir = Join-Path $prim 'queue'
        if (Test-Path $queueDir) {
            $candidates = Get-ChildItem $queueDir -Filter '*.md' |
                Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name
            foreach ($c in $candidates) {
                $claim = Join-Path $prim ".lifecycle\claims\$($c.BaseName)"
                if (New-AtomicClaim -Path $claim) { $next = $c; break }
            }
        }
        if ($next) {
            Log "dispatching next task: $($next.Name)"
            LogEvent 'DISPATCH_NEXT' $next.Name
            try {
                & (Join-Path $prim 'scripts\dispatch-session.ps1') -TaskFile $next.FullName -Depth 1 -SkipClaim 2>&1 |
                    ForEach-Object { Log "dispatch: $_" }
            } catch {
                Remove-Item (Join-Path $prim ".lifecycle\claims\$($next.BaseName)") -Force -ErrorAction SilentlyContinue
                Log "dispatch failed: $($_.Exception.Message)"
                LogEvent 'DISPATCH_FAILED' $_.Exception.Message
            }
        } else {
            Log 'queue empty or fully claimed; ending quietly'
        }
    }

    Move-Item $JobFile (Join-Path $prim '.lifecycle\jobs\done\') -Force
    LogEvent 'RUNNER_COMPLETE'
} catch {
    try {
        Log ("RUNNER_ERROR: " + $_.Exception.Message + "`n" + $_.ScriptStackTrace)
        LogEvent 'RUNNER_ERROR' $_.Exception.Message
    } catch {}
} finally {
    if ($lockPath -and (Test-Path $lockPath)) {
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
    }
}
