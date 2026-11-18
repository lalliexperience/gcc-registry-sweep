# Post-boot cleanup + INDEPENDENT verification pass for the gcc-one-pass v5.1 follow-up.
# v5.2 (2026-11-17): param-ized (-Alias) — no per-user clone step; optional -Domain and
# -TenantId enable the live OCS map probe and GUID-based file scanning.
# Dispatch: run AS the target user via per-user scheduled task (Interactive + Highest):
#   powershell -NoProfile -ExecutionPolicy Bypass -File gcc-postboot-verify.ps1 `
#     -Alias <sam> [-Domain <cutover-domain>] [-TenantId <old-tenant-GUID>]
# Handles the one failed wipe from the one-pass run (BrokerPlugin Settings dir, was file-locked
# while user session was live) + re-deletes the Outlook Settings\Accounts anchor value that
# survived its delete, then re-verifies EVERYTHING from a fresh session.
param([string]$Alias = '', [string]$Domain = '', [string]$TenantId = '')
if (-not $Alias) { Write-Output 'PARAM-MISSING: -Alias <sam> (the WORKING user, never the elevation twin)'; exit 2 }
$ErrorActionPreference = 'Continue'
$u = "C:\Users\$Alias\AppData"
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$o = "$u\Local\Temp\gcc-postboot-$stamp.log"
function Log($m) { $m | Out-File $o -Append -Encoding ascii }
$script:fail = 0
function Fail($m) { $script:fail++; Log ('ERROR ' + $m) }
Log "=== GCC POST-BOOT VERIFY+FIX $stamp user=$Alias ==="
# 0) kill the settings.dat lock holder
taskkill /f /im backgroundTaskHost.exe 2>&1 | Out-Null
Start-Sleep -Seconds 2
# 1) broker Settings leftover wipe (backup first)
$bs = "$u\Local\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\Settings"
if (Test-Path $bs) {
  $bk = "C:\Users\$Alias\M365ScrubBackup\postboot-$stamp"
  New-Item $bk -ItemType Directory -Force | Out-Null
  robocopy $bs "$bk\BrokerSettings" /E /R:1 /W:1 | Out-Null
  Remove-Item $bs -Recurse -Force -ErrorAction 0
  if (Test-Path $bs) { Fail ('BROKER-SETTINGS-STILL-EXISTS ' + $bs) } else { Log ('BROKER-SETTINGS-WIPED (backup postboot-' + $stamp + '\BrokerSettings)') }
} else { Log 'BROKER-SETTINGS-ABSENT' }
# 2) Outlook anchor value re-delete (failed in one-pass run: remain=True)
$osk = 'HKCU\Software\Microsoft\Office\Outlook\Settings'
$pre = (& reg query $osk /v Accounts 2>&1 | Out-String)
if ($pre -match 'Accounts') {
  & reg export $osk "$env:TEMP\reg-outlook-settings-$stamp.reg" /y > $null 2>&1
  $delout = (& reg delete $osk /v Accounts /f 2>&1 | Out-String)
  Log ('ANCHOR-REDEL-RAW ' + $delout.Trim())
  if ((& reg query $osk /v Accounts 2>&1 | Out-String) -match 'ERROR:') { Log 'ANCHOR-DELETED-NOW remain=False' }
  else { Fail 'ANCHOR-STILL-EXISTS-after-redelete' }
} else { Log 'ANCHOR-ALREADY-GONE' }
# 3) full independent re-verify
Log '--- RE-VERIFY ---'
foreach ($p in @('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Mru','HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Substrate','HKCU\Software\Microsoft\Office\16.0\Common\Identity','HKCU\Software\Microsoft\IdentityCRL','HKCU\Software\Microsoft\OneDrive\Accounts\Business1')) {
  if ((& reg query $p 2>&1 | Out-String) -match 'ERROR:') { Log ('REGOK-ABSENT ' + $p) } else { Fail ('REG-STILL-EXISTS ' + $p) }
}
foreach ($d in @("$u\Local\Microsoft\IdentityCache","$u\Local\Microsoft\TokenBroker","$u\Local\Microsoft\OneAuth","$u\Local\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy","$u\Local\Packages\MSTeams_8wekyb3d8bbwe","$u\Local\Microsoft\Teams")) {
  if (Test-Path $d) {
    $fsCmd = 'findstr /m /s /i /c:"microsoftonline.us" /c:"office365.us"'
    if ($TenantId) { $fsCmd += ' /c:"' + $TenantId + '"' }
    $hits = (Invoke-Expression ("$fsCmd `"$d\*`"")) 2>&1 | Where-Object { $_ -is [string] -and $_ -match '^[A-Z]:\\' }
    Log ('DIR-VERIFY ' + $d + ' matches=' + @($hits).Count)
    foreach ($h in $hits) { Log ('  HIT ' + $h) }
  } else { Log ('DIR-VERIFY ' + $d + ' ABSENT') }
}
foreach ($rk in @('HKLM\SOFTWARE\Microsoft\Office\DmsClient\C2RReleaseData','HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\DmsClient\C2RReleaseData','HKLM\SOFTWARE\Microsoft\Office\DmsClient\C2RTargetAudience','HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\DmsClient\C2RTargetAudience')) {
  $q = (& reg query $rk 2>&1 | Out-String)
  if ($q -match 'ERROR:') { Log ('DMS-ABSENT ' + $rk) }
  elseif (($TenantId -and $q -match $TenantId) -or $q -match 'microsoftonline\.us|office365\.us') { Fail ('DMS-STILL-POISONED ' + $rk) }
  else { Log ('DMS-CLEAN ' + $rk) }
}
# 4) OCS federation-provider live map probe (should say Global = commercial)
if ($Domain) {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 "https://odc.officeapps.live.com/odc/v2.1/federationProvider?domain=$Domain"
    Log ('OCS-PROBE ' + ($r.Content -replace '\s+',' ').Substring(0, [Math]::Min(300, $r.Content.Length)))
  } catch { Log ('OCS-PROBE-FAILED ' + $_.Exception.Message) }
} else { Log 'OCS-PROBE-SKIPPED (pass -Domain <cutover-domain> to enable)' }
# 5) fresh-boot dsregcmd
$s = dsregcmd /status 2>&1 | Out-String
foreach ($k in 'AzureAdJoined','WorkplaceJoined','WamDefaultSet','AzureAdPrt ') {
  ($s -split "`n" | Where-Object { $_.Trim() -like "$k*" }) | ForEach-Object { Log ('DSREG ' + $_.Trim()) }
}
Log ('SUMMARY failures=' + $script:fail)
if ($script:fail -eq 0) { Log 'POSTBOOT-VERIFY-CLEAN' } else { Log 'POSTBOOT-VERIFY-HAS-ERRORS' }
Get-Content $o
