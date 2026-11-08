function Get-Port {
    <#
    .SYNOPSIS
    Converts a string to a TCP port number (1-65535).

    .DESCRIPTION
    Accepts only plain ASCII decimal digits. Anything else -- empty, whitespace,
    signs, hex, exponents, decimals, separators, or a value outside 1-65535 --
    throws a System.ArgumentException. There is no default port.
    #>
    [OutputType([int])]
    param([string]$Value)

    # Shape check first. The [int] cast is too lenient ('' -> 0, '0x1BB' -> 443,
    # '1e3' -> 1000, '4.5' -> 4, ' 443 ' -> 443). [0-9] rather than \d, which also
    # matches non-ASCII digits. \A..\z rather than ^..$, since $ allows a trailing
    # newline. This also rejects the trailing NUL that .NET Framework's TryParse allows.
    if ($Value -notmatch '\A[0-9]+\z') {
        throw [System.ArgumentException]::new(
            "Invalid port '$Value': expected a decimal integer from 1 to 65535.", 'Value')
    }

    # Digits only, so TryParse fails only on Int32 overflow (> 65535 anyway).
    $n = 0
    $parsed = [int]::TryParse($Value, [System.Globalization.NumberStyles]::None,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)
    if (-not $parsed -or $n -lt 1 -or $n -gt 65535) {
        throw [System.ArgumentException]::new(
            "Invalid port '$Value': must be between 1 and 65535.", 'Value')
    }
    return $n
}
