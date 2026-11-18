# GCC Registry Sweep — one-pass GCC/.us client-side identity scrub for tenant-cut-over Windows PCs

**The problem this solves:** after a company moves its Microsoft 365 domain from a Government Cloud (**GCC / GCC High**) tenant to the worldwide **commercial** tenant (or between any two M365 tenants), the *directory* side is clean — but the Windows PCs keep **client-side identity caches that still point at the old cloud**. Outlook, Word, Teams, OneDrive, and even the Windows Settings account tile keep routing sign-ins to the defunct tenant, producing *"we couldn't find an account with that username"* / AADSTS900383 *"login directly to your National Cloud"* class errors for perfectly valid commercial accounts.

This repo contains the field-proven fix: **one atomic scrub script** (`gcc-one-pass.ps1`) that kills every re-seeder, wipes every identity layer, verifies its own work, reboots — plus the post-boot verification companions. Written and hardened during a real cross-cloud fleet migration (several dozen machines), where the naive "delete a few registry keys" approach kept relapsing.

## Why "delete a few keys" kept failing

Every layer below was discovered by chasing a box that *came back broken* after a "clean" scrub:

1. **Teams is a re-seeder.** Teams auto-starts at logon and re-seeds GCC state into the WAM broker **from its own package cache** — scrubs that never touch `Packages\MSTeams_8wekyb3d8bbwe` get re-poisoned minutes later.
2. **The Outlook anchor survives.** `HKCU\...\Office\Outlook\Settings\Accounts` carries a GCC `anchorMailbox` that steers Outlook's mailbox discovery to the old tenant.
3. **The Explorer OCS map is the cold-start killer.** `HKCU\...\Explorer\Mru` *root-key values* map `<domain> → microsoftonline.us` and drive **every Office and OneDrive** auth flow — and it lives outside the Office/identity trees that normal scrubs wipe.
4. **The broker's `settings.dat` is file-locked** while `backgroundTaskHost` runs — and re-locks at logon, so a leftover needs a **post-boot** wipe. `IdentityStore\<SID>` branches restore it on broker restart.
5. **Machine-level DmsClient C2R caches** (both registry views) survive every user pass and steer Office's cloud selection at cold start.
6. **Server-side anchors**: enabled device objects left in the old tenant re-pull GCC state on the next reboot. Delete them (Entra ID) per machine as part of the pass.

`gcc-one-pass.ps1` consolidates all of it: **ONE dispatch, ONE reboot, ONE broken-user window, no relapse window** — Teams is dead and empty *before* the user's first sign-in.

## What's in the box

| Script | Purpose |
|--------|---------|
| `scripts/gcc-one-pass.ps1` | **The whole tool - one script, two modes.** *Full scrub mode* (default): kill order (broker host first) → Teams package data wipe → Outlook anchor delete → Explorer OCS-map/Substrate purge → user-context identity/Office/OneDrive/CredMan wipe → admin half (CloudAPCache, MS-Organization-Access certs, WorkplaceJoin trees, WebAccounts, IdentityStore per-SID, broker re-register) → licensing stores → **VERIFY** (`.us` + optional tenant-GUID scan) → structured failure log → 120s reboot. Idempotent — non-admin reruns cleanly after promotion. *`-PostBoot` mode*: run after the reboot as the user — kills the broker host, wipes the file-locked `Settings` leftover, re-deletes the Outlook anchor if it survived, content-checks the re-seeded identity keys, re-verifies all file trees + DmsClient caches, probes the live OCS federation map (optional `-Domain`), fresh `dsregcmd`. |
| `scripts/gcc-postboot-watcher.sh` | Optional: polls `quser` and fires `gcc-one-pass.ps1 -PostBoot` the moment the user signs back in (a pre-reboot dispatch prints FIRED but the task sits queued forever — FIRED ≠ ran). Needs your own ScreenConnect/REST dispatch tooling. |
| `scripts/realm-flip-sampler.py` | Cross-cloud realm sampler for **drain-window verification** after a domain move (see the companion repo below). |

### Why one script but two invocations

The WAM broker's `Settings\settings.dat` is **file-locked** while `backgroundTaskHost` runs, and re-locks at logon — so a broker-settings leftover can only be reliably wiped *after* the reboot, in a fresh session. Everything else is deliberately atomic in the first pass: **ONE dispatch, ONE reboot, ONE broken-user window, no relapse window** — Teams is dead and empty *before* the user's first sign-in. Each wipe stage inside the script exists because skipping it was proven to cause a relapse (Teams auto-start re-seeds GCC from its own package cache; the Outlook `anchorMailbox` survives profile rebuilds; the Explorer OCS map steers every Office/OneDrive auth flow from *outside* the Office trees normal scrubs wipe; machine-level DmsClient caches survive every user pass; disabled WorkplaceJoin tasks stop the old join from rebuilding itself).

**The clean-claim rule this tool is built around:** never declare a box clean after a wipe-verification. The only clean claim that counts is **the user signing in successfully on the new tenant** (Outlook first → Word already-activated → reboot → Teams SSO → OneDrive). Until then the state is *"scrubbed, unverified."*

## Requirements (fleet-proven)

- **Run it as the WORKING user, and that user must be a local admin.** The HKCU hive that must be scrubbed lives in the working user's profile — running it as an admin-only "elevation twin" account scrubs the wrong hive and fixes nothing. If the working user isn't an admin yet, **promote them first, then have them log off/on**: admin membership only lands in a fresh logon token. The promotion is temporary by design — demote the user once their sign-ins on the new tenant are verified. Add `-RequireElevation` to make the script abort *before any wipe* if the token is filtered (Medium Mandatory Level).
- **Dispatch mechanism:** per-user scheduled task (Interactive + RunLevel Highest — no UAC prompt for an elevated user) or an elevated PowerShell console running as that user.
- **Sign-out steps before clicking Yes** (the pre-flight popup lists these; processes are force-killed anyway, so save work first):
  1. Sign out of **Outlook** (classic and new Outlook).
  2. Sign out of **Teams** (quit fully).
  3. Sign out of **OneDrive**.
  4. Close **Word / Excel / PowerPoint / OneNote** (any open document is lost on force-kill).
  5. No browser sign-outs are needed — this script has no browser layer by design.

## Usage

Desk-side, **one machine at a time**, as the *working* user (their HKCU hive is what must be scrubbed — never run it as an elevation-only account):

```powershell
# 1) FULL SCRUB - elevated per-user scheduled task (or elevated PowerShell as the user)
powershell -NoProfile -ExecutionPolicy Bypass -File gcc-one-pass.ps1 `
  -UserDir 'C:\Users\<alias>\AppData' -TenantId <old-tenant-GUID>

# 2) POST-BOOT - after the reboot, as the user, BEFORE they open anything
powershell -NoProfile -ExecutionPolicy Bypass -File gcc-one-pass.ps1 -PostBoot `
  -UserDir 'C:\Users\<alias>\AppData' -TenantId <old-tenant-GUID> -Domain <cutover-domain>
```

`-TenantId` is optional but recommended: it adds the old tenant's GUID to every file/registry scan. Without it, detection falls back to the generic GCC host markers (`microsoftonline.us` / `office365.us`).

Every run writes a timestamped log ending in `SUMMARY failures=N`; `ONE-PASS-COMPLETE-WITH-ERRORS` and `POSTBOOT-VERIFY-HAS-ERRORS` are **not** clean passes. The full scrub shows a **pre-flight popup** on the user's desktop (sign-out checklist + elevation status + Yes/No confirm — declining aborts with nothing wiped); the post-boot pass shows a shorter "don't open apps yet" popup. Exit codes: `0` done, `2` bad parameters, `3` aborted by `-RequireElevation`, `4` pre-flight declined.

**Warnings:** the box is intentionally broken for its user between script start and reboot (identity wiped, sign-in half-built). Wipes are backed up to `M365ScrubBackup\` first. The script schedules its own reboot (120 s) unless `-NoReboot`. Not for servers/domain controllers; test on one sacrificial VM first.

## Related project: RealmProbe

**Scrubbing the PC is pointless if the *server* side is still flip-flopping.** Our companion repo
[**m365-realm-probe**](https://github.com/lalliexperience/m365-realm-probe) repeatedly probes Microsoft's anonymous discovery surfaces (dual `getuserrealm` planes + the Office/Teams federation map), tallies the answers, and classifies whether the domain routes consistently to one cloud — or **flip-flops between them** (a stale realm record on Microsoft's side; the fix is a Microsoft support ticket, not another scrub).

The pairing:

- **Before you scrub a PC:** run RealmProbe against the cut-over domain. Consistent answers → the poison is client-side, `gcc-one-pass` is the fix. **Flip-flopping / split answers → stop scrubbing** and escalate to Microsoft first.
- **After the sweep:** RealmProbe confirms the domain routes to the intended cloud, closing the loop alongside the on-box post-boot verification.

## License

[MIT](LICENSE)
