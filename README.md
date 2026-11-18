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
| `scripts/gcc-one-pass.ps1` | **The canonical pass.** Kill order (broker host first) → Teams package data wipe → Outlook anchor delete → Explorer OCS-map/Substrate purge → user-context identity/Office/OneDrive/CredMan wipe → admin half (CloudAPCache, MS-Organization-Access certs, WorkplaceJoin trees, WebAccounts, IdentityStore per-SID, broker re-register) → licensing stores → **VERIFY** (`.us` + optional tenant-GUID scan) → structured failure log → 120s reboot. Idempotent — non-admin reruns cleanly after promotion. |
| `scripts/gcc-postboot-verify.ps1` | Run after the reboot as the user: wipes the file-locked broker `Settings` leftover, re-deletes the Outlook anchor if it survived, independently re-verifies everything, probes the live OCS federation map (optional `-Domain`), fresh `dsregcmd`. |
| `scripts/gcc-id-content-check.ps1` | Logon **re-seeds** of identity keys are EXPECTED — this checks their *content* for `.us`/old-tenant poison instead of existence. |
| `scripts/gcc-token-elevation-probe.ps1` | 20-second pre-flight: does a dispatched task actually get an **elevated** token for this user? (Admin membership added *after* logon runs filtered — this probe prevents a wasted broken-box window on a failed pass.) |
| `scripts/gcc-postboot-watcher.sh` | Polls `quser` and fires the post-boot pass the moment the user signs back in (a pre-reboot dispatch prints FIRED but the task sits queued forever — FIRED ≠ ran). Needs your own ScreenConnect/REST dispatch tooling. |
| `scripts/realm-flip-sampler.py` | Cross-cloud realm sampler for **drain-window verification** after a domain move (see the companion repo below). |

**The clean-claim rule this tool is built around:** never declare a box clean after a wipe-verification. The only clean claim that counts is **the user signing in successfully on the new tenant** (Outlook first → Word already-activated → reboot → Teams SSO → OneDrive). Until then the state is *"scrubbed, unverified."*

## Usage

Desk-side, **one machine at a time**, as the *working* user (their HKCU hive is what must be scrubbed — never run it as an elevation-only account):

```powershell
# elevated per-user scheduled task (or run from an elevated PowerShell as the user)
powershell -NoProfile -ExecutionPolicy Bypass -File gcc-one-pass.ps1 `
  -UserDir 'C:\Users\<alias>\AppData' -TenantId <old-tenant-GUID>
```

`-TenantId` is optional but recommended: it adds the old tenant's GUID to every file/registry scan. Without it, detection falls back to the generic GCC host markers (`microsoftonline.us` / `office365.us`).

After the reboot: kill `backgroundTaskHost`, remove any broker `Settings` leftover, then run `gcc-postboot-verify.ps1 -Alias <alias> -Domain <cutover-domain>` before the user opens anything. Every run writes a timestamped log ending in `SUMMARY failures=N`; `ONE-PASS-COMPLETE-WITH-ERRORS` is **not** a clean pass.

**Warnings:** the box is intentionally broken for its user between script start and reboot (identity wiped, sign-in half-built). Wipes are backed up to `M365ScrubBackup\` first. The script schedules its own reboot (120 s) unless `-NoReboot`. Not for servers/domain controllers; test on one sacrificial VM first.

## Related project: RealmProbe

**Scrubbing the PC is pointless if the *server* side is still flip-flopping.** Our companion repo
[**m365-realm-probe**](https://github.com/lalliexperience/m365-realm-probe) repeatedly probes Microsoft's anonymous discovery surfaces (dual `getuserrealm` planes + the Office/Teams federation map), tallies the answers, and classifies whether the domain routes consistently to one cloud — or **flip-flops between them** (a stale realm record on Microsoft's side; the fix is a Microsoft support ticket, not another scrub).

The pairing:

- **Before you scrub a PC:** run RealmProbe against the cut-over domain. Consistent answers → the poison is client-side, `gcc-one-pass` is the fix. **Flip-flopping / split answers → stop scrubbing** and escalate to Microsoft first.
- **After the sweep:** RealmProbe confirms the domain routes to the intended cloud, closing the loop alongside the on-box post-boot verification.

## License

[MIT](LICENSE)
