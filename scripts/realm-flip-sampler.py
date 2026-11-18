#!/usr/bin/env python3
"""Cross-cloud realm-flip sampler — drain-window + post-flush verification.

Anonymous probes only (no auth, zero traffic to customer PCs):
  1. getuserrealm.srf on the .com AND .us STS for a test UPN
  2. OCS federationProvider map for the domain

Usage:
  python3 realm-flip-sampler.py <domain> [upn] [ticks] [spacing_seconds]

  Run once per record. After a domain move between clouds there can be a MIRROR
  record in the other cloud's realm plane — check BOTH:
    python3 realm-flip-sampler.py example.com probe@example.com 10 20
    python3 realm-flip-sampler.py tenant.onmicrosoft.us user@tenant.onmicrosoft.us 8 15

Clean result shapes:
  commercial-native domain (moved GCC->commercial):
    .com realm = Managed ; .us realm = Unknown ; OCS = environment:Global
    (.us CloudFederated = STALE GCC record still being served)
  GCC-native domain:
    .com realm = Unknown ; .us realm = Managed ; OCS = US-GCC
    (US-GCC is the CORRECT answer for a domain that genuinely lives in GCC —
     do not misread it as a stale record; .com CloudFederated claiming
     microsoftonline.us for it = stale mirror record, causes AADSTS500011
     misroutes on fresh/broker-less sign-ins)

Operational notes:
  - Spaced ticks (15-20s) matter: the flip is time-based; back-to-back probes
    can hit the same cache node and under-report flipping.
  - Per-request --max-time 15 is mandatory: the OCS endpoint can hang >60s once
    (transient, 2026-11-17) and one hung call must not kill the run.
  - Closure discipline: a ~10-min clean window does NOT close the MS ticket if
    the original flip was intermittent across hours — re-run once more the next
    morning / before the next desk-side, then report counts and close.
"""
import collections
import datetime
import re
import subprocess
import sys
import time


def curl(url, timeout=15):
    try:
        r = subprocess.run(["curl", "-s", "--max-time", str(timeout), url],
                           capture_output=True, text=True, timeout=timeout + 5)
        return r.stdout
    except Exception as e:  # noqa: BLE001 - sampler must never die on one probe
        return f"__ERR__ {type(e).__name__}: {e}"


def realm(host, upn):
    r = curl(f"https://login.microsoftonline.{host}/getuserrealm.srf?login={upn}&xml=1")
    if r.startswith("__ERR__"):
        return "ERR:" + r[:70]
    m = re.search(r"<NameSpaceType>([^<]*)</NameSpaceType>", r)
    return m.group(1) if m else "NO-XML:" + r[:70]


def ocs(dom):
    r = curl(f"https://odc.officeapps.live.com/odc/v2.1/federationProvider?domain={dom}")
    if r.startswith("__ERR__"):
        return "ERR:" + r[:70]
    if not r.strip():
        return "EMPTY"
    if "microsoftonline.us" in r.lower():
        return "US-GCC"
    m = re.search(r'"environment"\s*:\s*"([^"]+)"', r)
    return f"ENV:{m.group(1)}" if m else "UNPARSED:" + r[:80]


def main():
    dom = sys.argv[1] if len(sys.argv) > 1 else "example.com"
    upn = sys.argv[2] if len(sys.argv) > 2 else f"probe@{dom}"
    ticks = int(sys.argv[3]) if len(sys.argv) > 3 else 10
    spacing = float(sys.argv[4]) if len(sys.argv) > 4 else 20.0
    ts = lambda: datetime.datetime.now().strftime("%H:%M:%S")

    tc, tu, to = collections.Counter(), collections.Counter(), collections.Counter()
    print(f"sampler: domain={dom} upn={upn} ticks={ticks} spacing={spacing}s")
    for i in range(1, ticks + 1):
        c, u, o = realm("com", upn), realm("us", upn), ocs(dom)
        tc[c] += 1
        tu[u] += 1
        to[o] += 1
        print(f"[{ts()}] tick {i:2d}  .com={c:<14} .us={u:<16} ocs={o[:50]}")
        if i < ticks:
            time.sleep(spacing)

    print("\nSUMMARY")
    print("  .com realm:", dict(tc))
    print("  .us  realm:", dict(tu))
    print("  OCS map   :", dict(to))

    surfaces = list(tc) + list(tu) + list(to)
    bad = any(k.startswith(("ERR", "NO-XML", "UNPARSED", "EMPTY")) for k in surfaces)
    flipped = (len(tc) > 1 or len(tu) > 1 or len(to) > 1)
    if bad:
        print("  ANOMALY: errors/unparseable responses present")
    elif flipped:
        print("  FLIPPING: mixed answers across the window")
    else:
        print("  STABLE: all surfaces consistent — compare against the clean shapes above")


if __name__ == "__main__":
    main()
