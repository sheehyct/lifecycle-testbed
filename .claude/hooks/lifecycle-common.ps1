# lifecycle-common.ps1 — shared helpers for the autonomous session lifecycle.
# Dot-source from hooks/scripts. PowerShell 5.1 compatible. No secrets here (invariant 4).

function Get-PrimaryRoot {
    # Resolve the PRIMARY checkout root from any path inside a worktree or the primary
    # itself. Queue, claims, dispatches, locks, and the event log live in the primary;
    # worktrees only carry their own state/ and active-task.json.
    param([Parameter(Mandatory)][string]$Path)
    $common = git -C $Path rev-parse --path-format=absolute --git-common-dir 2>$null
    if (-not $common) { throw "Get-PrimaryRoot: '$Path' is not inside a git repository" }
    return (Split-Path ($common -replace '/', '\') -Parent)
}

function Initialize-LifecycleDirs {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($d in 'jobs', 'jobs\done', 'state', 'claims', 'dispatches', 'logs', 'tmp', 'locks') {
        $p = Join-Path $Root ".lifecycle\$d"
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    }
}

function Write-LifecycleEvent {
    # Append-only audit line: ISO8601 | component | session | EVENT | detail
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Component,
        [string]$SessionId = '-',
        [Parameter(Mandatory)][string]$Event,
        [string]$Detail = ''
    )
    Initialize-LifecycleDirs -Root $Root
    $line = '{0} | {1} | {2} | {3} | {4}' -f (Get-Date -Format o), $Component, $SessionId, $Event, ($Detail -replace "`r?`n", ' / ')
    Add-Content -Path (Join-Path $Root '.lifecycle\logs\events.log') -Value $line -Encoding utf8
}

function Read-DotEnvValue {
    # Credentials come ONLY from a human-populated .env (invariant 4).
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Key)
    $envFile = Join-Path $Root '.env'
    if (-not (Test-Path $envFile)) { return $null }
    $line = Get-Content $envFile | Where-Object { $_ -match "^\s*$Key=" } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    $value = $line.Split('=', 2)[1].Trim()
    if ($value -eq '') { return $null }
    return $value
}

function New-AtomicClaim {
    # CreateNew semantics: exactly one caller wins a race for the marker file.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
        $fs.Close()
        return $true
    } catch {
        return $false
    }
}

function Get-LifecycleConfig {
    # Tracked per-repo config (ticket_prefix, base_branch) written by the installer.
    param([Parameter(Mandatory)][string]$Root)
    $cfgPath = Join-Path $Root 'lifecycle.config.json'
    if (Test-Path $cfgPath) { return (Get-Content $cfgPath -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{ ticket_prefix = 'task'; base_branch = 'main' }
}
