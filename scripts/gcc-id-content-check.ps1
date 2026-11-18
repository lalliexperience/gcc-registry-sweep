# Content-check the logon re-seeded identity keys (post-boot verification).
# Existence is EXPECTED (logon re-seed); POISON is any .us authority / old tenant id in values.
param([string]$TenantId = '')
$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$o = "$env:TEMP\gcc-idcheck-$stamp.log"
function Log($m) { $m | Out-File $o -Append -Encoding ascii }
$script:fail = 0
function Fail($m) { $script:fail++; Log ('ERROR ' + $m) }
$pat = 'microsoftonline\.us|office365\.us|login\.windows\.net'
if ($TenantId) { $pat = [regex]::Escape($TenantId) + '|' + $pat }
Log "=== GCC ID-CONTENT-CHECK $stamp ==="
foreach ($rk in @('HKCU\Software\Microsoft\Office\16.0\Common\Identity','HKCU\Software\Microsoft\IdentityCRL')) {
  $q = (& reg query $rk /s 2>&1 | Out-String)
  if ($q -match 'ERROR:') { Log ('KEY-ABSENT ' + $rk); continue }
  $lines = ($q -split "`r?`n") | Where-Object { $_.Trim() }
  Log ('KEY ' + $rk + ' lines=' + $lines.Count)
  foreach ($l in $lines) {
    if ($l -match $pat) { Log ('  POISON-LINE ' + $l.Trim()) }
  }
  $poison = ($lines | Where-Object { $_ -match $pat }).Count
  if ($poison -gt 0) { Fail ('KEY-POISONED hits=' + $poison + ' ' + $rk) } else { Log ('KEY-CLEAN ' + $rk) }
  # dump compact value list for the record
  foreach ($l in $lines) { if ($l -match '^\s+HKEY_|REG_') { Log ('  DUMP ' + $l.Trim()) } }
}
Log ('SUMMARY failures=' + $script:fail)
if ($script:fail -eq 0) { Log 'ID-CHECK-CLEAN' } else { Log 'ID-CHECK-POISONED - wipe keys again before sign-in' }
Get-Content $o
