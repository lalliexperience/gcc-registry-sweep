# gcc-postboot-watcher.sh — poll for the user's post-reboot console session, then fire
# gcc-one-pass.ps1 -PostBoot as that user via a ScreenConnect REST driver.
#
# WHY (field-proven 2026-11-17): after the gcc-one-pass reboot there is NO
# auto-logon (quser empty). A driver dispatch of the postboot pass before the user signs
# back in prints FIRED but the Interactive task sits QUEUED (no log ever appears), and the
# driver's cleanup deletes the queued task anyway. FIRED != ran. Fire ONLY once quser shows
# the console session — this watcher does that automatically so the anchor re-delete lands
# before the user opens Outlook.
#
# Usage: gcc-postboot-watcher.sh <SC_SESSION_ID> <ALIAS> [POLL_SECONDS=55] [MAX_POLLS=45]
# Requires: your ScreenConnect REST dispatch tooling (a driver that stages a .ps1 and fires
# it as a per-user Interactive+Highest scheduled task). Point DRIVER/SCCLIENT at your own
# copies via the environment (DRIVER=... SCCLIENT=...) if you do not use the defaults.
set -u
SC=${1:?usage: gcc-postboot-watcher.sh <SC_SESSION_ID> <ALIAS> [POLL_SECONDS=55] [MAX_POLLS=45]}
ALIAS=${2:?alias required}
POLL=${3:-55}
MAX=${4:-45}
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="${DRIVER:-$HERE/../dispatch/stage-fire-user-task.py}"
SCCLIENT="${SCCLIENT:-$HERE/../dispatch/sc_restful_client.py}"
SCRIPT="$HERE/gcc-one-pass.ps1"
LOG="C:\\Users\\$ALIAS\\AppData\\Local\\Temp\\gcc-postboot-*.log"
STAGE="C:\\Users\\$ALIAS\\AppData\\Local\\Temp\\gcc-sweep"
for i in $(seq 1 "$MAX"); do
  out=$(python3 "$SCCLIENT" run "$SC" "quser" --timeout 40 2>&1)
  if echo "$out" | grep -q "$ALIAS"; then
    echo "USER-DETECTED poll#$i $(date '+%H:%M:%S')"
    python3 "$DRIVER" --sid "$SC" --local "$SCRIPT" --remote-name gcc-one-pass.ps1 \
      --stage "$STAGE" --user "$ALIAS" --runlevel Highest \
      --args "-PostBoot -UserDir C:\\Users\\$ALIAS\\AppData" \
      --log "$LOG" --poll-seconds 120
    rc=$?
    echo "POSTBOOT-DISPATCH-RETURNED rc=$rc"
    exit $rc
  fi
  echo "poll#$i not-signed-in $(date '+%H:%M:%S')"
  sleep "$POLL"
done
echo "TIMEOUT: $ALIAS never signed back in after $MAX polls (~$((MAX * POLL / 60)) min)"
exit 1
