# Token-elevation probe: dispatched AS the user via a per-user Interactive+Highest scheduled
# task - the SAME mechanism gcc-one-pass uses. Answers in ~20 s: does a dispatched
# task get an ELEVATED token for this user on this box? Needed because an operator may vouch
# "already a local admin" with unknown promotion time - membership added AFTER the user's
# current logon means an Interactive+Highest task still runs FILTERED (field lesson),
# and a filtered one-pass wastes a broken-box window on a NONADMIN rerun.
#
# Dispatch (e.g. via a ScreenConnect REST staging driver):
#   stage + run as the user:  powershell -NoProfile -ExecutionPolicy Bypass -File gcc-token-elevation-probe.ps1
#   then read:                C:\Users\<alias>\AppData\Local\Temp\elev-probe.log
#
# READ THE LOG:
#   PASS (fire one-pass immediately) =
#     "Mandatory Label\High Mandatory Level" present
#     AND BUILTIN\Administrators line reads "Mandatory group, Enabled by default, Enabled
#         group" (optionally "Group owner") — NOT "deny only"
#   FAIL (logoff/logon needed first, then re-probe) =
#     "Medium Mandatory Level" or Administrators shown as "Group used for deny only"
#
# The probe result IS the one-pass result by construction (same dispatch mechanism).
$log = 'C:\Users\' + $env:USERNAME + '\AppData\Local\Temp\elev-probe.log'
Remove-Item $log -ErrorAction SilentlyContinue
"PROBE-START $(Get-Date -Format s) user=$env:USERNAME" | Out-File $log -Encoding unicode
whoami /groups | Out-File $log -Encoding unicode -Append
Add-Content $log 'PROBE-DONE'
