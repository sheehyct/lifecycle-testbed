# lifecycle-common.ps1 — shared helpers for the autonomous session lifecycle.
# Dot-source from hooks/scripts. PowerShell 5.1 compatible. No secrets here (invariant 4).

function Invoke-Native {
    # Run a native command with stderr folded into Output WITHOUT tripping
    # ErrorActionPreference=Stop — PS 5.1 turns redirected native stderr into
    # terminating ErrorRecords otherwise (a git CRLF *warning* once killed the
    # runner mid-flight). Returns @{ Output = [string[]]; ExitCode = [int] }.
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Output = @($out); ExitCode = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $eap
    }
}

function Get-PrimaryRoot {
    # Resolve the PRIMARY checkout root from any path inside a worktree or the primary
    # itself. Queue, claims, dispatches, locks, and the event log live in the primary;
    # worktrees only carry their own state/ and active-task.json.
    param([Parameter(Mandatory)][string]$Path)
    $r = Invoke-Native -Exe 'git' -Arguments @('-C', $Path, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if ($r.ExitCode -ne 0 -or -not $r.Output) { throw "Get-PrimaryRoot: '$Path' is not inside a git repository" }
    $common = [string]$r.Output[0]
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
    # Best-effort by design: concurrent runners contend for events.log (Add-Content
    # holds an exclusive handle), so retry with jitter and NEVER throw — audit
    # logging must never kill the component doing the real work.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Component,
        [string]$SessionId = '-',
        [Parameter(Mandatory)][string]$Event,
        [string]$Detail = ''
    )
    try {
        Initialize-LifecycleDirs -Root $Root
        $line = '{0} | {1} | {2} | {3} | {4}' -f (Get-Date -Format o), $Component, $SessionId, $Event, ($Detail -replace "`r?`n", ' / ')
        $path = Join-Path $Root '.lifecycle\logs\events.log'
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Add-Content -Path $path -Value $line -Encoding utf8 -ErrorAction Stop
                return
            } catch {
                Start-Sleep -Milliseconds (20 + (Get-Random -Maximum 80))
            }
        }
    } catch {}
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

function Resolve-CodexExe {
    # Start-Process needs a real Win32 executable, but the npm-installed 'codex'
    # command is a script shim (.cmd/.ps1). Prefer a codex.exe on PATH, else find
    # the native binary inside the shim's npm package.
    $onPath = Get-Command codex -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\.exe$' }
    if ($onPath) { return @($onPath)[0].Source }
    $shim = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shim) {
        $pkgDir = Join-Path (Split-Path $shim.Source -Parent) 'node_modules\@openai\codex'
        if (Test-Path $pkgDir) {
            $exe = Get-ChildItem $pkgDir -Recurse -Filter 'codex.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    throw 'codex.exe not found; is the Codex CLI installed?'
}

function Get-LifecycleConfig {
    # Tracked per-repo config (ticket_prefix, base_branch) written by the installer.
    param([Parameter(Mandatory)][string]$Root)
    $cfgPath = Join-Path $Root 'lifecycle.config.json'
    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $defaults = @{ permission_mode = 'acceptEdits'; max_chain = 5; max_fix_rounds = 2 }
        foreach ($k in $defaults.Keys) {
            if (-not ($cfg.PSObject.Properties.Name -contains $k)) {
                $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k]
            }
        }
        return $cfg
    }
    return [pscustomobject]@{ ticket_prefix = 'task'; base_branch = 'main'; permission_mode = 'acceptEdits'; max_chain = 5; max_fix_rounds = 2 }
}
