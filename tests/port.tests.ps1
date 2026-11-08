# Tests for Get-Port (src/port.ps1).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests/port.tests.ps1
# Exits 0 only if every assertion passes; exits 1 on any failure.

# A failure to load the module under test must fail the run, not be skipped.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\src\port.ps1"

# Fail fast if the file loaded but did not define Get-Port; otherwise the
# 65535-call sweep below would crawl through command-not-found lookups.
if (-not (Get-Command Get-Port -CommandType Function -ErrorAction SilentlyContinue)) {
    Write-Output 'FAIL: src/port.ps1 does not define function Get-Port'
    exit 1
}

$script:failures = New-Object System.Collections.Generic.List[string]
$script:checks = 0

function Assert-Port([string]$Value, [int]$Expected) {
    $script:checks++
    try {
        $r = Get-Port $Value
    } catch {
        $script:failures.Add("VALID '$Value': threw $($_.Exception.GetType().Name): $($_.Exception.Message)")
        return
    }
    if ($r -isnot [int]) {
        $type = if ($null -eq $r) { 'null' } else { $r.GetType().FullName }
        $script:failures.Add("VALID '$Value': returned type $type, expected System.Int32")
    } elseif ($r -ne $Expected) {
        $script:failures.Add("VALID '$Value': returned $r, expected $Expected")
    }
}

# Rejection must be a thrown ArgumentException. Any other exception type
# (e.g. CommandNotFoundException if Get-Port failed to load) is a failure, so
# these checks cannot pass vacuously; returning any value is a failure too.
function Assert-Rejects($Value, [string]$Label) {
    $script:checks++
    try {
        $r = Get-Port $Value
        $script:failures.Add("REJECT $Label : returned '$r' instead of throwing")
    } catch [System.ArgumentException] {
        # expected
    } catch {
        $script:failures.Add("REJECT $Label : threw $($_.Exception.GetType().FullName), expected ArgumentException")
    }
}

# --- Rule 1: returns the integer for '1' through '65535' -------------------
Assert-Port '1' 1
Assert-Port '443' 443
Assert-Port '8080' 8080
Assert-Port '65535' 65535

# Exhaustive sweep of the whole valid range; only the first few misses are
# listed so a total regression does not flood the output.
$sweepMisses = 0
foreach ($i in 1..65535) {
    $s = [string]$i
    try { $r = Get-Port $s } catch { $r = $null }
    if ($r -isnot [int] -or $r -ne $i) {
        $sweepMisses++
        if ($sweepMisses -le 5) { $script:failures.Add("SWEEP '$s': got '$r'") }
    }
}
$script:checks++
if ($sweepMisses -gt 5) { $script:failures.Add("SWEEP: $sweepMisses of 65535 valid inputs failed in total") }

# --- Rule 2: THROWS (never returns a default) ------------------------------
# empty
Assert-Rejects ''    "empty ''"
Assert-Rejects $null 'null'
Assert-Rejects ' '   "whitespace-only ' '"

# non-numeric (anything other than plain ASCII decimal digits)
Assert-Rejects 'abc'      "non-numeric 'abc'"
Assert-Rejects '80abc'    "non-numeric '80abc'"
Assert-Rejects '4.5'      "decimal '4.5'"
Assert-Rejects '0x1BB'    "hex '0x1BB' ([int] cast would give 443)"
Assert-Rejects '1e3'      "exponent '1e3' ([int] cast would give 1000)"
Assert-Rejects '+80'      "signed '+80'"
Assert-Rejects '1,000'    "thousands separator '1,000'"
Assert-Rejects ' 443'     "leading space ' 443'"
Assert-Rejects '443 '     "trailing space '443 '"
Assert-Rejects "443`n"    "trailing newline '443\n'"
Assert-Rejects "443`0"    "trailing NUL '443\0' (.NET Framework TryParse accepts it)"
Assert-Rejects ([string][char]0x0664 + [char]0x0664 + [char]0x0663) "Arabic-Indic digits (regex \d matches them)"

# zero
Assert-Rejects '0'  "zero '0'"
Assert-Rejects '00' "zero '00'"

# negative
Assert-Rejects '-1'     "negative '-1'"
Assert-Rejects '-443'   "negative '-443'"
Assert-Rejects '-65535' "negative '-65535'"

# greater than 65535
Assert-Rejects '65536'                "above range '65536'"
Assert-Rejects '99999'                "above range '99999'"
Assert-Rejects '2147483648'           "Int32 overflow '2147483648'"
Assert-Rejects '99999999999999999999' "Int64 overflow '99999999999999999999'"

# --- Result ----------------------------------------------------------------
if ($script:failures.Count -gt 0) {
    $script:failures | ForEach-Object { Write-Output "FAIL $_" }
    Write-Output "FAILED: $($script:failures.Count) failure(s) across $script:checks checks"
    exit 1
}
Write-Output "PASS: $script:checks checks (incl. full 1..65535 sweep)"
exit 0
