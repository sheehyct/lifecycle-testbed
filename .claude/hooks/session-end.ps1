# SessionEnd hook. HARD CONSTRAINT: the total SessionEnd hook budget is 60 seconds
# (DEVIATIONS.md, Component C entry), so this script only records a job file and
# launches the DETACHED runner, then exits. All slow work (Codex review, ntfy,
# spawn-guard dispatch) happens in session-end-runner.ps1.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lifecycle-common.ps1"

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch {
    exit 0   # no/garbled stdin: nothing to do; never obstruct session close
}

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = $payload.cwd }
if (-not $root -or -not (Test-Path $root)) { exit 0 }

$sid = $payload.session_id
if (-not $sid) { $sid = 'unknown-' + (Get-Date -Format yyyyMMddHHmmss) }

try {
    # Jobs are centralized in the primary checkout so lifecycle-doctor can find
    # crashed runners in one place; fall back to the session root outside a repo.
    $jobRoot = $root
    try { $jobRoot = Get-PrimaryRoot $root } catch {}
    Initialize-LifecycleDirs -Root $jobRoot

    $depthEnv = 0
    if ($env:LIFECYCLE_SPAWN_DEPTH) { $depthEnv = [int]$env:LIFECYCLE_SPAWN_DEPTH }

    $job = [pscustomobject]@{
        session_id      = $sid
        transcript_path = $payload.transcript_path
        cwd             = $root
        reason          = $payload.reason
        ended_at        = (Get-Date -Format o)
        spawn_depth_env = $depthEnv    # captured NOW; the detached runner gets a copy of this env
    }
    $jobPath = Join-Path $jobRoot ".lifecycle\jobs\$sid.json"
    $job | ConvertTo-Json | Set-Content -Path $jobPath -Encoding utf8

    # The Stop-gate continuation counter is per-session state; the session is over.
    Remove-Item (Join-Path $root ".lifecycle\state\stop-$sid.count") -Force -ErrorAction SilentlyContinue

    Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "$PSScriptRoot\session-end-runner.ps1",
        '-JobFile', $jobPath
    )

    Write-LifecycleEvent -Root $jobRoot -Component 'session-end-hook' -SessionId $sid `
        -Event 'RUNNER_LAUNCHED' -Detail "reason=$($payload.reason) job=$jobPath"
} catch {
    # Never obstruct session close; leave a trace if possible.
    try {
        Write-LifecycleEvent -Root $root -Component 'session-end-hook' -SessionId $sid `
            -Event 'HOOK_ERROR' -Detail $_.Exception.Message
    } catch {}
}
exit 0
