"""PCM-EXT-07 M4 — archive-floor + stability probe for farsi.khamenei.ir.

Two goals:
  1) Characterize the FLAKINESS of old-year list pages: the SAME year can
     return different ID counts on consecutive requests (observed: 1370 ->
     0, 0, 131 across three separate runs). We test a set of years several
     times each to see which are stable-empty vs. flaky.
  2) Identify years that are RELIABLY empty (fast response + 0 IDs on every
     try) so the M4 S7 "empty-year behavior" check is deterministic.

Run on s52:  cd /home/saber/saberprojects/pct-staging
             python3 /tmp/pcm_ext07_m4_floor.py
"""
import sys
import time

sys.path.insert(0, "corpus")
import scrape_khamenei as sk  # noqa: E402

# Candidate years to characterize. Includes the flaky 1370, the sparse tail,
# and the confirmed-empty candidates from the earlier floor probe.
CANDIDATES = [1370, 1354, 1353, 1351, 1350]
TRIES = 3


def main():
    print(f"Stability probe: {len(CANDIDATES)} years x {TRIES} tries each\n")
    stable_empty = []
    for y in CANDIDATES:
        counts = []
        for i in range(TRIES):
            t0 = time.time()
            try:
                ids = sk.discover_year(y)
                n = len(ids)
            except Exception as e:  # noqa: BLE001
                n = -1
            dt = time.time() - t0
            counts.append(n)
            print(f"  {y} try{i+1}: {n} IDs  ({dt:.1f}s)", flush=True)
            time.sleep(1)
        uniq = set(counts)
        ok = (uniq == {0})
        if ok:
            stable_empty.append(y)
        verdict = "STABLE-EMPTY" if ok else "FLAKY/DATA"
        print(f"  -> {y}: counts={counts}  => {verdict}\n", flush=True)
    print("STABLE EMPTY YEARS (safe for S7):", stable_empty)
    print("FLOOR/STABILITY PROBE DONE")


if __name__ == "__main__":
    main()
