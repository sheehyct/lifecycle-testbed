. "$PSScriptRoot\..\src\port.ps1"
if ((Get-Port '443') -ne 443) { Write-Output 'FAIL 443'; exit 1 }
Write-Output 'PASS'
exit 0