# GCC ONE-PASS scrub - v5 CONSOLIDATED (2026-11-17). THE canonical fleet pass.
# Merges every field-proven layer into ONE atomic dispatch = ONE reboot = ONE
# broken-user window, and NO relapse window: Teams is dead+empty BEFORE the user's
# first sign-in ever happens, the Outlook GCC anchorMailbox is deleted, and the
# identity layer is purged in the same run.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File gcc-one-pass.ps1 `
#     -UserDir 'C:\Users\<alias>\AppData' [-TenantId <old-tenant-GUID>] [-NoReboot]
#
# Run AS the target user via per-user scheduled task (Interactive + RunLevel Highest).
# Admin user => everything completes elevated in one shot (marker ONE-PASS-COMPLETE-ELEVATED).
# Non-admin  => user-context phases run; marker ONE-PASS-COMPLETE-NONADMIN-RERUN-AS-ADMIN;
#               promote + re-run (idempotent). Preflight: promote BEFORE first run.
#
# -TenantId (optional): the GUID of the OLD (GCC) tenant. When supplied, file/registry
#   verification also scans for that GUID (stronger detection). Without it, detection
#   falls back to the generic GCC host markers (microsoftonline.us / office365.us).
#
# Layer provenance:
#   v2 gcc-disconnect.ps1     - broker/WAM/Office/Outlook/OneDrive/CM + WPJ cert/trees/tasks + CloudAPCache
#   v3 gcc-identity-scrub.ps1 - Office licensing dirs, IdentityCache/OneAuth move-verify
#   V4 addendum               - Teams package DATA wipe (re-seeder), Outlook Settings\Accounts
#                               GCC anchorMailbox delete, IdentityCRL, IdentityStore per-SID
#   field deep-clean lessons  - backgroundTaskHost killed FIRST (settings.dat lock), teams
#                               classic per-user data, post-boot broker wipe (agent-side step)
# Post-boot steps (AFTER reboot, BEFORE the user signs in): kill backgroundTaskHost,
#   remove broker Settings leftover if any, verify fresh-empty, no stale automation tasks.
param(
  [string]$UserDir = '',
  [string]$TenantId = '',
  [switch]$NoReboot
)
# v5.1 (2026-11-17): + Explorer\Mru whole-key delete (ROOT CAUSE on a fleet box: OCS
#   federation-provider map in ROOT values steering ALL Office/OneDrive auth
#   to .us), + Explorer\Substrate per-UPN cache, + HKLM DmsClient C2R request-cache VALUE
#   deletes (both registry views; values not keys), + structured error logging: every
#   failure increments $script:fail, log ends 'SUMMARY failures=N', COMPLETE marker only
#   when N=0. RegBackDel/Wipe now VERIFY the delete took and count failures.
$ErrorActionPreference = 'Continue'
if (-not $UserDir) { throw 'UserDir required: -UserDir C:\Users\<alias>\AppData' }
$u = $UserDir
if (-not (Test-Path $u)) { throw "UserDir not found: $u" }
$User = (Split-Path (Split-Path $u -Parent) -Leaf)
$t = "$u\Local\Temp"
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$o = "$t\gcc-one-pass-$stamp.log"
$bk = "C:\Users\$User\M365ScrubBackup\gcc-one-pass-$stamp"
$empty = "$t\empty-wipe-dir"
New-Item $empty -ItemType Directory -Force | Out-Null
New-Item $bk -ItemType Directory -Force | Out-Null
function Log($m) { $m | Out-File $o -Append -Encoding ascii }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$MySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Log "=== GCC ONE-PASS v5.1 user=$User admin=$isAdmin sid=$MySid backup=$bk ==="
function Backup($d) { if (Test-Path $d) { $dst = $bk + '\' + (($d -replace '[:\\]','_').Trim('_')); robocopy $d $dst /E /R:1 /W:1 | Out-Null; (Get-Item $dst).Name } }
function Wipe($d) { if (Test-Path $d) { $dst = $bk + '\' + (($d -replace '[:\\]','_').Trim('_')); robocopy $d $dst /E /R:1 /W:1 | Out-Null; robocopy $empty $d /MIR /R:2 /W:1 | Out-Null; Remove-Item $d -Recurse -Force -ErrorAction 0; Log ('WIPED ' + $d + ' exists=' + (Test-Path $d)) } else { Log ('ABSENT ' + $d) } }
function RegBackDel($rk, $tag) {
  & reg export $rk "$bk\reg-$tag.reg" /y > $null 2>&1
  $had = (& reg query $rk 2>&1 | Out-String).Length -gt 40
  & reg delete $rk /f 2>&1 | Out-Null
  Log ('REGDEL ' + $rk + ' existed=' + $had + ' backup=' + (Test-Path "$bk\reg-$tag.reg"))
}
# --- v5.1 overrides: verified deletes + failure counter (later defs win) ---
$script:fail = 0
function Fail($m) { $script:fail++; Log ('ERROR ' + $m) }
function Wipe($d) {
  if (Test-Path $d) {
    $dst = $bk + '\' + (($d -replace '[:\\]','_').Trim('_'))
    robocopy $d $dst /E /R:1 /W:1 | Out-Null
    robocopy $empty $d /MIR /R:2 /W:1 | Out-Null
    Remove-Item $d -Recurse -Force -ErrorAction 0
    if (Test-Path $d) { Fail ('WIPE-FAILED still-exists ' + $d) } else { Log ('WIPED ' + $d) }
  } else { Log ('ABSENT ' + $d) }
}
function RegBackDel($rk, $tag) {
  $q = (& reg query $rk 2>&1 | Out-String)
  $had = (($q.Length -gt 40) -and ($q -notmatch 'ERROR:'))
  if (-not $had) { Log ('REGDEL ' + $rk + ' absent=true'); return }
  & reg export $rk "$bk\reg-$tag.reg" /y > $null 2>&1
  if (-not (Test-Path "$bk\reg-$tag.reg")) { Fail ('REG-BACKUP-MISSING ' + $rk) }
  & reg delete $rk /f > $null 2>&1
  if ($LASTEXITCODE -ne 0) { Fail ('REGDEL-FAILED exit=' + $LASTEXITCODE + ' ' + $rk); return }
  $still = (& reg query $rk 2>&1 | Out-String)
  if ($still -match 'ERROR:') { Log ('REGDEL ' + $rk + ' existed=True deleted=True backup=' + (Test-Path "$bk\reg-$tag.reg")) }
  else { Fail ('REGDEL-STILL-EXISTS ' + $rk) }
}
# --- 0) KILLS: broker host FIRST (releases settings.dat), Teams + webview, Office, OneDrive ---
foreach ($p in @('backgroundTaskHost','ms-teams','MSTeams','Teams','msedgewebview2','OneDrive','WINWORD','OUTLOOK','olk','HxOutlook','excel','powerpnt','onenote','msaccess','lync')) {
  taskkill /f /im "$p.exe" 2>&1 | Out-Null
}
sc.exe stop TokenBroker 2>&1 | Out-Null
sc.exe stop wlidsvc 2>&1 | Out-Null
Start-Sleep -Seconds 3
Log 'KILLS-DONE broker/teams/webview/office/onedrive + TokenBroker+wlidsvc stopped'
# --- 1) TEAMS LAYER (V4): the logon re-seeder. DATA only - Appx/staged pkg stays for re-register ---
Log '--- TEAMS LAYER ---'
$tp = "$u\Local\Packages\MSTeams_8wekyb3d8bbwe"
foreach ($d in @("$tp\LocalCache","$tp\LocalState","$tp\Settings","$tp\AC","$tp\TempState")) { Backup $d; Wipe $d }
Backup "$u\Local\Microsoft\Teams"; Wipe "$u\Local\Microsoft\Teams"   # classic per-user Teams data (invisible in Add/Remove)
# --- 2) OUTLOOK ANCHOR (V4): Settings\Accounts VALUE carries GCC anchorMailbox PUID@<old-tid> ---
Log '--- OUTLOOK ANCHOR ---'
$osk = 'HKCU\Software\Microsoft\Office\Outlook\Settings'
& reg export $osk "$bk\reg-outlook-settings.reg" /y > $null 2>&1
& reg delete "$osk" /v Accounts /f 2>&1 | Out-Null
$still = (& reg query "$osk" /v Accounts 2>&1 | Out-String).Length -gt 40
if ($still) { Fail ('ANCHOR-STILL-EXISTS ' + $osk + ' :: Accounts (re-delete post-boot)') } else { Log 'ANCHOR-DELETED remain=False' }
# --- 2b) EXPLORER LAYER (v5.1, root cause on a fleet box, 2026-11-17): the OCS federation-
# provider map lives in Explorer\Mru ROOT-key VALUES (DomainToFederationProviderEnvironment:
# <domain> -> microsoftonline.us, fetched pre-cutover) and steers EVERY Office AND
# OneDrive auth flow to the .us STS (0xCAA9004D 'Account type unknown' -> 'invalid user'
# for a valid .com UPN). Explorer\Substrate caches .us endpoints per-UPN. Both are pure
# caches: whole-key delete, rebuilt clean from odc.officeapps.live.com (now returns Global).
RegBackDel 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Mru' 'HCU_Explorer_Mru'
RegBackDel 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Substrate' 'HCU_Explorer_Substrate'
Log 'EXPLORER-LAYER-DONE (OCS federation-provider map + Substrate purged)'
# --- 3) PHASE A: user-context identity + Office + Outlook + OneDrive + Credential Manager ---
Log '--- PHASE A (user context) ---'
$pkg = "$u\Local\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy"
foreach ($d in @("$u\Local\Microsoft\IdentityCache","$u\Local\Microsoft\TokenBroker","$u\Local\Microsoft\OneAuth","$pkg\AC\TokenBroker","$pkg\AC\INetCookies","$pkg\AC\INetCache","$pkg\AC\Microsoft\CryptnetUrlCache","$pkg\LocalCache","$pkg\LocalState","$pkg\Settings")) { Backup $d; Wipe $d }
foreach ($d in @("$u\Local\Microsoft\Office\16.0\WebServiceCache","$u\Local\Microsoft\Office\16.0\Wef","$u\Local\Microsoft\Office\16.0\OfficeFileCache","$u\Local\Microsoft\Office\16.0\aggmru","$u\Local\Microsoft\Office\16.0\SitesServiceCache","$u\Local\Microsoft\Office\16.0\SolutionPackages","$u\Local\Microsoft\Office\MIPSDK","$u\Local\Microsoft\Office\OTele","$u\Local\Microsoft\Office\WebView2")) { Backup $d; Wipe $d }
RegBackDel 'HKCU\Software\Microsoft\Office\16.0\Common\Identity' 'HCU_O16_Common_Identity'
RegBackDel 'HKCU\Software\Microsoft\Office\16.0\Common\Internet\WebServiceCache' 'HCU_O16_WebServiceCache'
RegBackDel 'HKCU\Software\Microsoft\Office\16.0\Common\Internet\WebServiceCacheSafe' 'HCU_O16_WSCSafe'
RegBackDel 'HKCU\Software\Microsoft\IdentityCRL' 'HCU_IdentityCRL'
RegBackDel 'HKCU\Software\Microsoft\Office\16.0\Outlook\AutoDiscover' 'HCU_OL_AutoDiscover'
RegBackDel 'HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles' 'HCU_OL_Profiles'
& reg delete 'HKCU\Software\Microsoft\Office\16.0\Outlook' /v DefaultProfile /f 2>&1 | Out-Null
Log 'REGDEL-OUTLOOK DefaultProfile value'
$olDir = "$u\Local\Microsoft\Outlook"
Get-ChildItem $olDir -File -ErrorAction 0 | Where-Object { $_.Extension -in '.ost','.nst' } | ForEach-Object {
  try { Move-Item -LiteralPath $_.FullName -Destination ($bk + '\OST_' + $_.Name) -Force -ErrorAction Stop
        Log ('MOVED-STORE ' + $_.Name + ' ' + [math]::Round($_.Length/1MB) + 'MB') }
  catch { Fail ('MOVE-FAILED ' + $_.Name + ' :: ' + $_.Exception.Message) }
}
foreach ($d in @("$olDir\16","$olDir\RoamCache")) { Backup $d; Wipe $d }
RegBackDel 'HKCU\Software\Microsoft\OneDrive\Accounts\Business1' 'HCU_OD_Business1'
Backup "$u\Local\Microsoft\OneDrive\settings\Business1"; Wipe "$u\Local\Microsoft\OneDrive\settings\Business1"
Remove-Item "$u\Local\Microsoft\OneDrive\settings\PreSignInSettingsConfig.json" -Force -ErrorAction 0
Log 'PRESIGNIN-CONFIG-DELETED'
$cmTargets = cmdkey /list 2>&1 | Select-String 'Target:' | ForEach-Object { ($_ -split 'target=', 2)[1] }
foreach ($ct in $cmTargets) {
  if ($ct -match 'MicrosoftOffice|OneDrive|didlogical|SSIC|virtualapp|AAD\.') {
    Log ('CRED-DELETED ' + $ct)
    & cmdkey /delete:$ct 2>&1 | Out-Null
  } else { Log ('CRED-KEPT ' + $ct) }
}
# --- 4) PHASE B: admin half (skipped cleanly if non-admin) ---
Log '--- PHASE B (admin context) ---'
if ($isAdmin) {
  $cap = 'C:\Windows\System32\config\systemprofile\AppData\Local\Microsoft\Windows\CloudAPCache'
  try { Backup $cap; Wipe $cap; Log 'CLOUDAPCACHE done' } catch { Fail ('CLOUDAPCACHE ' + $_.Exception.Message) }
  # v5.1: machine-level DmsClient C2R caches (survive every user pass; delete the
  # request-cache VALUES, not the keys - both registry views, field findings 2026-11-17).
  $i = 0
  foreach ($rk in @('HKLM\SOFTWARE\Microsoft\Office\DmsClient\C2RReleaseData','HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\DmsClient\C2RReleaseData','HKLM\SOFTWARE\Microsoft\Office\DmsClient\C2RTargetAudience','HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\DmsClient\C2RTargetAudience')) {
    $q = (& reg query $rk 2>&1 | Out-String)
    if ($q -match 'ERROR:') { Log ('DMS-ABSENT ' + $rk); continue }
    $i++
    & reg export $rk "$bk\reg-dms$i.reg" /y > $null 2>&1
    $hitv = $false
    foreach ($v in @('C2RReleaseDataRequestCache','C2RTargetAudienceRequestCache')) {
      if ($q -match [regex]::Escape($v)) {
        $hitv = $true
        & reg delete $rk /v $v /f > $null 2>&1
        if ((& reg query $rk /v $v 2>&1 | Out-String) -match 'ERROR:') { Log ('DMS-VALUE-DELETED ' + $rk + ' :: ' + $v) }
        else { Fail ('DMS-VALUE-FAILED ' + $rk + ' :: ' + $v) }
      }
    }
    if (-not $hitv) { Log ('DMS-CLEAN ' + $rk + ' (no request-cache values present)') }
    if ($TenantId -and $q -match $TenantId) { Log ('DMS-WARN ' + $rk + ' remaining values may still carry old tenant id - flagged for review') }
  }
  $targets = @()
  foreach ($store in 'Cert:\LocalMachine\My','Cert:\CurrentUser\My') {
    Get-ChildItem $store -ErrorAction 0 | Where-Object { ("$($_.Issuer)`n$($_.Subject)") -match 'MS-Organization-Access' } | ForEach-Object {
      Log ('CERT ' + $store + ' thumb=' + $_.Thumbprint)
      $targets += $_
    }
  }
  foreach ($c in $targets) {
    try { Export-Certificate -Cert $c -FilePath (Join-Path $bk ($c.Thumbprint + '.cer')) | Out-Null; Log ('CERT-BACKED-UP ' + $c.Thumbprint) }
    catch { Fail ('CERT-BACKUP-ERR ' + $c.Thumbprint) }
    try { Remove-Item ('Cert:\LocalMachine\My\' + $c.Thumbprint) -Force -ErrorAction 0
          Remove-Item ('Cert:\CurrentUser\My\' + $c.Thumbprint) -Force -ErrorAction 0
          Log ('CERT-DELETED ' + $c.Thumbprint) }
    catch { Fail ('CERT-DEL-ERR ' + $c.Thumbprint + ' :: ' + $_.Exception.Message) }
  }
  if (-not $targets) { Log 'NO-ORG-CERTS-FOUND' }
  foreach ($rp in @('HKLM:\SOFTWARE\Microsoft\Windows\WorkplaceJoin','HKLM:\SOFTWARE\Microsoft\WorkplaceJoin','HKCU:\SOFTWARE\Microsoft\Windows\WorkplaceJoin','HKCU:\SOFTWARE\Microsoft\WorkplaceJoin')) {
    if (Test-Path $rp) {
      $tag = ($rp -replace '[:\\]','_')
      & reg export ($rp -replace '^HKLM:','HKLM' -replace '^HKCU:','HKCU') "$bk\$tag.reg" /y > $null 2>&1
      try { Remove-Item -Path $rp -Recurse -Force; Log ('WPJ-REG-DELETED ' + $rp) }
      catch { Fail ('WPJ-REG-ERR ' + $rp + ' :: ' + $_.Exception.Message) }
    } else { Log ('WPJ-REG-ABSENT ' + $rp) }
  }
  $wa = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\WebAccounts'
  if (Test-Path $wa) {
    Get-ChildItem $wa -ErrorAction 0 | ForEach-Object {
      if ($TenantId -and $_.Name -match $TenantId) {
        & reg export ($_.Name -replace '^HKEY_CURRENT_USER','HKCU') "$bk\reg-WebAccount-$($_.PSChildName).reg" /y > $null 2>&1
        Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction 0
        Log ('WEBACCOUNT-DELETED ' + $_.PSChildName)
      } elseif (-not $TenantId) { Log ('WEBACCOUNT-KEPT-NO-TENANTID ' + $_.PSChildName + ' (pass -TenantId to enable GUID-based deletion)') }
        else { Log ('WEBACCOUNT-KEPT ' + $_.PSChildName) }
    }
  } else { Log 'WEBACCOUNTS-ABSENT' }
  Get-ScheduledTask -ErrorAction 0 | Where-Object { $_.TaskName -like '*WorkplaceJoin*' -or $_.TaskPath -like '*Workplace Join*' } | ForEach-Object {
    try { Disable-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName | Out-Null; Log ('WPJ-TASK-DISABLED ' + $_.TaskPath + $_.TaskName) }
    catch { Log ('WPJ-TASK-ERR ' + $_.TaskName) }
  }
  # IdentityStore per-SID WAM cache (settings.dat restore source). SID from WindowsIdentity -
  # NTAccount.Translate silently returned empty under SilentlyContinue (field bug, 2026-11-17).
  foreach ($base in @("HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$MySid","HKLM:\SOFTWARE\Microsoft\IdentityStore\IdentityCache\$MySid")) {
    if (Test-Path $base) {
      $tag = ($base -replace '[:\\]','_')
      & reg export ($base -replace '^HKLM:','HKLM') "$bk\reg-$tag.reg" /y > $null 2>&1
      try { Remove-Item -Path $base -Recurse -Force; Log ('IDSTORE-DELETED ' + $base + ' remain=' + (Test-Path $base)) }
      catch { Fail ('IDSTORE-ERR ' + $base + ' :: ' + $_.Exception.Message) }
    } else { Log ('IDSTORE-ABSENT ' + $base) }
  }
  try {
    Get-AppxPackage Microsoft.AAD.BrokerPlugin -AllUsers -ErrorAction 0 | ForEach-Object {
      Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
      Log ('REREGISTERED ' + $_.PackageFullName)
    }
  } catch { Fail ('REREG-ERR ' + $_.Exception.Message) }
} else {
  Log 'PHASE-B-SKIPPED (non-admin) - promote user + re-run this same script (idempotent)'
}
# --- 5) PHASE C: v3 extras - Office licensing stores ---
Log '--- PHASE C (licensing) ---'
foreach ($p in @("$u\Local\Microsoft\Office\16.0\Licensing","$u\Roaming\Microsoft\Office\ESRLicensing","$u\Local\Microsoft\Office\ESRLicensing")) {
  if (Test-Path $p) { Backup $p; Wipe $p }
}
# --- 6) VERIFY ---
Log '=== VERIFY ==='
foreach ($d in @("$u\Local\Microsoft\Office","$u\Local\Microsoft\IdentityCache","$u\Local\Microsoft\TokenBroker","$u\Local\Microsoft\OneAuth","$pkg","$tp","$u\Local\Microsoft\Teams")) {
  if (Test-Path $d) {
    $fsCmd = 'findstr /m /s /i /c:"microsoftonline.us" /c:"office365.us"'
    if ($TenantId) { $fsCmd += ' /c:"' + $TenantId + '"' }
    $hits = (Invoke-Expression ("$fsCmd `"$d\*`"")) 2>&1 | Where-Object { $_ -is [string] -and $_ -match '^[A-Z]:\\' }
    Log ('VERIFY ' + $d + ' matches=' + @($hits).Count)
    foreach ($h in $hits) { Log ('  HIT ' + $h) }
  } else { Log ('VERIFY ' + $d + ' ABSENT') }
}
Log ('VERIFY-ANCHOR-VALUE ' + ((& reg query "$osk" /v Accounts 2>&1 | Out-String).Length -gt 40))
Log ('VERIFY-IDENTITY-REG ' + (Test-Path 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity'))
Log ('VERIFY-MRU-ABSENT ' + (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Mru')))
Log ('VERIFY-SUBSTRATE-ABSENT ' + (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Substrate')))
Log ('VERIFY-ONEAUTH-DIR-ABSENT ' + (-not (Test-Path "$u\Local\Microsoft\OneAuth")))
foreach ($rk in @('HKLM\SOFTWARE\Microsoft\Office\DmsClient\C2RReleaseData','HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\DmsClient\C2RReleaseData','HKLM\SOFTWARE\Microsoft\Office\DmsClient\C2RTargetAudience','HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\DmsClient\C2RTargetAudience')) {
  $q = (& reg query $rk 2>&1 | Out-String)
  if ($q -match 'ERROR:') { Log ('VERIFY-DMS-ABSENT ' + $rk) }
  elseif (($TenantId -and $q -match $TenantId) -or $q -match 'microsoftonline\.us|office365\.us') { Fail ('VERIFY-DMS-STILL-POISONED ' + $rk) }
  else { Log ('VERIFY-DMS-CLEAN ' + $rk) }
}
$s = dsregcmd /status 2>&1 | Out-String
foreach ($k in 'AzureAdJoined','WorkplaceJoined','WorkAccountCount','WamDefaultSet','AzureAdPrt ','WorkplaceTenantName') {
  ($s -split "`n" | Where-Object { $_.Trim() -like "$k*" }) | ForEach-Object { Log ('DSREG ' + $_.Trim()) }
}
Log ('SUMMARY failures=' + $script:fail)
if ($script:fail -gt 0) {
  Log ('ONE-PASS-COMPLETE-WITH-ERRORS failures=' + $script:fail + ' - review ERROR lines above; do NOT treat as a clean pass')
} elseif ($isAdmin) { Log 'ONE-PASS-COMPLETE-ELEVATED' } else { Log 'ONE-PASS-COMPLETE-NONADMIN-RERUN-AS-ADMIN' }
if (-not $NoReboot) {
  Log 'REBOOT in 120s (broker/WAM rebuild requires restart). POST-BOOT: agent wipes broker Settings leftover, then GO card.'
  shutdown /r /t 120 /c 'GCC one-pass scrub complete - rebooting to rebuild broker clean'
}
Get-Content $o
