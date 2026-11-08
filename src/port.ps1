function Get-Port {
    param([string]$Value)
    try {
        $n = [int]$Value
        if ($n -lt 1 -or $n -gt 65535) { return 8080 }
        return $n
    } catch {
        return 8080
    }
}