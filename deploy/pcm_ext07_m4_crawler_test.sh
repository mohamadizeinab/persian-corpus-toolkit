#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-EXT-07 M4 — REAL Python-crawler acceptance against STAGING (s52)
#
# Runs on s52 as saber. Targets ONLY the staging backend (127.0.0.1:5056)
# and the staging DB. Production (5055 + its DB) is not opened at all.
#
# Test plan (mission M4):
#   S0  baseline: khamenei=151, 1400=0, 1402=0; record pending queue size
#   S1  --year 1400  -> discover 35, insert 35, 0 errors        (1400=35)
#   S2  --year 1402  -> discover 56, insert 56, 0 errors        (total=242)
#   S3  re-run 1400  -> 0 inserted, 35 skipped, total unchanged (idempotency)
#   S4  re-run 1402  -> 0 inserted, 56 skipped, total unchanged (idempotency)
#   S5  date validity of all 91 new rows (SQL, no fabrication) + no empty
#       content. NOTE: ~48 rows legitimately have char_count<100 — the site
#       itself serves them as "[دریافت PDF]" with NO div.Content (probe-verified);
#       that is a source characteristic, reported as INFO, not a crawl bug.
#   S6  live re-verification: re-extract 2 samples from the site NOW and
#       compare text+title with the DB (mismatch = FAIL, never hidden)
#   S7  empty-year behavior: 1354 & 1350 (CONFIRMED fast-empty, 0 IDs) -> clean
#       exit. These respond in <0.2s (truly empty pages, NOT timeouts).
#       FLAKINESS FINDING (probe-verified 2026-11-21): old-year pages are
#       unreliable — year 1370 returned 131 IDs in one run but 0 (via 3x30s
#       read-timeouts) in another; a timeout is indistinguishable from "empty",
#       which affects the auto-walk 2-consecutive-empty stop rule. True floor:
#       real data extends to 1352; sparse tail 1360=8,1359=4,1358=3,1357=4,
#       1356=1,1355=1,1352=1; 1354/1353/1351/1350 fast-empty.
#   S8  resume: unfiltered run consumes the pending queue (no auto-walk
#       hijack); targeted runs already proved they ignore the queue (S1/S2)
#   S9  final state: counts, no duplicate speech_id, integrity ok
#
# Output: structured PASS/FAIL lines + "M4 SUMMARY". Exit 0 iff 0 FAIL.
# ═══════════════════════════════════════════════════════════════════════════
set -u
B=http://127.0.0.1:5056
STAGE=/home/saber/saberprojects/pct-staging
DB="$STAGE/backend/thesaurus.db"
LOGDIR=/tmp/pcm-ext07-m4
mkdir -p "$LOGDIR"
DELAY=1.2

PASS=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
chk_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1 (= $3)"; else bad "$1 (want=$2 got=$3)"; fi
}
c_total() { sqlite3 "$DB" "SELECT COUNT(*) FROM khamenei_speeches;"; }
c_year()  { sqlite3 "$DB" "SELECT COUNT(*) FROM khamenei_speeches WHERE speech_year='$1';"; }
c_dup()   { sqlite3 "$DB" "SELECT COUNT(*) - COUNT(DISTINCT speech_id) FROM khamenei_speeches;"; }
results_line() { grep -o 'Results: {.*}' "$1" | tail -1; }

echo "=== S0 baseline (staging $B) ==="
curl -s "$B/api/db/info" > /dev/null || { echo "FATAL: staging backend not up"; exit 2; }
T0=$(c_total); Y0_1400=$(c_year 1400); Y0_1402=$(c_year 1402)
PEND0=$(curl -s "$B/api/khamenei/pending?limit=5000" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
echo "baseline: total=$T0 y1400=$Y0_1400 y1402=$Y0_1402 pending=$PEND0"
chk_eq "S0.baseline_total_151" 151 "$T0"
chk_eq "S0.baseline_1400_empty" 0 "$Y0_1400"
chk_eq "S0.baseline_1402_empty" 0 "$Y0_1402"

run_crawl() { # outlog -- args...
  local out="$1"; shift
  (cd "$STAGE" && python3 corpus/scrape_khamenei.py "$@" --delay $DELAY --backend "$B") \
    > "$out" 2>&1
  echo "--- $* (log $out) tail:"; tail -3 "$out"
}

echo "=== S1 crawl year 1400 (expect 35) ==="
run_crawl "$LOGDIR/s1_1400.log" --year 1400
D1=$(sed -n 's/.*Year 1400: \([0-9][0-9]*\) IDs.*/\1/p' "$LOGDIR/s1_1400.log" | tail -1)
R1=$(results_line "$LOGDIR/s1_1400.log")
INS1=$(echo "$R1" | grep -o '"inserted": [0-9]*' | grep -o '[0-9]*')
ERR1=$(echo "$R1" | grep -o '"errors": [0-9]*' | grep -o '[0-9]*')
echo "discover=$D1 results=$R1"
chk_eq "S1.discover_1400_35"   35 "$D1"
chk_eq "S1.inserted_1400_35"   35 "${INS1:-0}"
chk_eq "S1.errors_1400_0"      0  "${ERR1:-1}"
chk_eq "S1.db_1400_35"         35 "$(c_year 1400)"
chk_eq "S1.db_total_186"       186 "$(c_total)"

echo "=== S2 crawl year 1402 (expect 56) ==="
run_crawl "$LOGDIR/s2_1402.log" --year 1402
D2=$(sed -n 's/.*Year 1402: \([0-9][0-9]*\) IDs.*/\1/p' "$LOGDIR/s2_1402.log" | tail -1)
R2=$(results_line "$LOGDIR/s2_1402.log")
INS2=$(echo "$R2" | grep -o '"inserted": [0-9]*' | grep -o '[0-9]*')
ERR2=$(echo "$R2" | grep -o '"errors": [0-9]*' | grep -o '[0-9]*')
echo "discover=$D2 results=$R2"
chk_eq "S2.discover_1402_56"   56 "$D2"
chk_eq "S2.inserted_1402_56"   56 "${INS2:-0}"
chk_eq "S2.errors_1402_0"      0  "${ERR2:-1}"
chk_eq "S2.db_1402_56"         56 "$(c_year 1402)"
chk_eq "S2.db_total_242"       242 "$(c_total)"

echo "=== S3 idempotency: re-run 1400 ==="
run_crawl "$LOGDIR/s3_re1400.log" --year 1400
R3=$(results_line "$LOGDIR/s3_re1400.log")
INS3=$(echo "$R3" | grep -o '"inserted": [0-9]*' | grep -o '[0-9]*')
SK3=$(echo "$R3" | grep -o '"skipped": [0-9]*' | grep -o '[0-9]*')
ERR3=$(echo "$R3" | grep -o '"errors": [0-9]*' | grep -o '[0-9]*')
echo "results=$R3"
chk_eq "S3.reinserted_0"   0  "${INS3:-1}"
chk_eq "S3.reskipped_35"   35 "${SK3:-0}"
chk_eq "S3.reerrors_0"     0  "${ERR3:-1}"
chk_eq "S3.total_still_242" 242 "$(c_total)"

echo "=== S4 idempotency: re-run 1402 ==="
run_crawl "$LOGDIR/s4_re1402.log" --year 1402
R4=$(results_line "$LOGDIR/s4_re1402.log")
INS4=$(echo "$R4" | grep -o '"inserted": [0-9]*' | grep -o '[0-9]*')
SK4=$(echo "$R4" | grep -o '"skipped": [0-9]*' | grep -o '[0-9]*')
ERR4=$(echo "$R4" | grep -o '"errors": [0-9]*' | grep -o '[0-9]*')
echo "results=$R4"
chk_eq "S4.reinserted_0"   0  "${INS4:-1}"
chk_eq "S4.reskipped_56"   56 "${SK4:-0}"
chk_eq "S4.reerrors_0"     0  "${ERR4:-1}"
chk_eq "S4.total_still_242" 242 "$(c_total)"

echo "=== S5 date validity + content sanity (SQL on staging DB) ==="
BADDATES=$(sqlite3 "$DB" "SELECT COUNT(*) FROM khamenei_speeches WHERE speech_year IN ('1400','1402') AND (speech_date IS NULL OR speech_date NOT GLOB '[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]');")
WRONGYEAR=$(sqlite3 "$DB" "SELECT COUNT(*) FROM khamenei_speeches WHERE (speech_year='1400' AND substr(speech_date,1,4)<>'1400') OR (speech_year='1402' AND substr(speech_date,1,4)<>'1402');")
EMPTYTXT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM khamenei_speeches WHERE speech_year IN ('1400','1402') AND (content IS NULL OR length(content)=0);")
SHORTTXT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM khamenei_speeches WHERE speech_year IN ('1400','1402') AND char_count<100;")
echo "bad_dates=$BADDATES wrong_year_date=$WRONGYEAR empty_text=$EMPTYTXT short_text_lt100=$SHORTTXT"
chk_eq "S5.all_91_have_valid_jalali_date" 0 "$BADDATES"
chk_eq "S5.date_year_matches_speech_year"  0 "$WRONGYEAR"
chk_eq "S5.no_empty_content"               0 "$EMPTYTXT"
echo "INFO  S5: $SHORTTXT rows have char_count<100 = source-true PDF-only pages (site has no div.Content for them); documented, not a crawl bug"

echo "=== S6 live re-verification (re-extract from site NOW vs DB) ==="
(cd "$STAGE" && python3 - "$DB" <<'PYEOF'
import sys, re, sqlite3
sys.path.insert(0, "corpus")
from scrape_khamenei import extract_speech
db = sqlite3.connect(sys.argv[1]); db.row_factory = sqlite3.Row
norm = lambda s: re.sub(r"\s+", " ", (s or "")).strip()
fails = 0
for y in ("1400", "1402"):
    row = db.execute(
        "SELECT speech_id,title,content FROM khamenei_speeches "
        "WHERE speech_year=? ORDER BY CAST(speech_id AS INTEGER) LIMIT 1", (y,)).fetchone()
    sid = row["speech_id"]
    live = extract_speech(sid)
    if "error" in live:
        print(f"  {y} sid={sid}: LIVE FETCH ERROR {live['error']}"); fails += 1; continue
    lt, lc = norm(live["title"]), norm(live["content"])
    st, sc = norm(row["title"]), norm(row["content"])
    same_t = (lt == st)
    same_c = (lc == sc)
    print(f"  {y} sid={sid}: title_equal={same_t} text_equal={same_c} "
          f"stored_chars={len(sc)} live_chars={len(lc)}")
    if not (same_t and same_c):
        fails += 1
        print("    TITLE stored:", st[:120]); print("    TITLE live:  ", lt[:120])
        for i in range(0, min(len(sc), 400), 100):
            print("    C stored:", sc[i:i+100])
        for i in range(0, min(len(lc), 400), 100):
            print("    C live:  ", lc[i:i+100])
db.close()
print("S6_FAILS", fails)
PYEOF
) | tee "$LOGDIR/s6_live.txt"
S6F=$(grep -o 'S6_FAILS [0-9]*' "$LOGDIR/s6_live.txt" | grep -o '[0-9]*' | tail -1)
chk_eq "S6.live_reverify_samples_match" 0 "${S6F:-1}"

echo "=== S7 empty-year behavior (fast-empty years: 1354, 1350) ==="
for Y in 1354 1350; do
  (cd "$STAGE" && python3 corpus/scrape_khamenei.py --discover --year $Y) > "$LOGDIR/s7_$Y.log" 2>&1
  N=$(grep -o "found [0-9]* IDs" "$LOGDIR/s7_$Y.log" | grep -o '[0-9]*' | tail -1)
  echo "  year $Y -> ${N:-?} IDs"
  chk_eq "S7.year_${Y}_empty_0_ids" 0 "${N:-?}"
done

echo "=== S8 resume via pending queue (unfiltered run, --max 3) ==="
PEND1=$(curl -s "$B/api/khamenei/pending?limit=5000" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
T_BEFORE=$(c_total)
echo "pending before S8: $PEND1 (was $PEND0 at S0; 1400/1402 rows now done)"
if [ "${PEND1:-0}" -gt 0 ]; then
  run_crawl "$LOGDIR/s8_resume.log" --max 3
  if grep -q 'Resuming .* pending IDs from backend queue' "$LOGDIR/s8_resume.log"; then
    ok "S8.unfiltered_run_consumes_pending_queue (no auto-walk)"
  else
    bad "S8.unfiltered_run_consumes_pending_queue (no 'Resuming' banner; auto-walk or silent?)"
  fi
  R8=$(results_line "$LOGDIR/s8_resume.log")
  INS8=$(echo "$R8" | grep -o '"inserted": [0-9]*' | grep -o '[0-9]*')
  SK8=$(echo "$R8" | grep -o '"skipped": [0-9]*' | grep -o '[0-9]*')
  ERR8=$(echo "$R8" | grep -o '"errors": [0-9]*' | grep -o '[0-9]*')
  DONE8=$(( ${INS8:-0} + ${SK8:-0} ))
  echo "results=$R8"
  chk_eq "S8.crawled_exactly_3" 3 "$DONE8"
  chk_eq "S8.no_errors" 0 "${ERR8:-1}"
  T_AFTER=$(c_total)
  chk_eq "S8.total_increased_by_inserted" "$((T_BEFORE + ${INS8:-0}))" "$T_AFTER"
else
  # nothing pending anywhere: prove unfiltered run auto-walks instead
  run_crawl "$LOGDIR/s8_autowalk.log" --max 2
  if grep -q 'Auto year-walk discovery' "$LOGDIR/s8_autowalk.log"; then
    ok "S8.empty_queue_falls_back_to_auto_walk"
  else
    bad "S8.empty_queue_falls_back_to_auto_walk (no auto-walk banner)"
  fi
fi

echo "=== S9 final state ==="
T_FINAL=$(c_total); Y1400=$(c_year 1400); Y1402=$(c_year 1402)
INTEG=$(sqlite3 "$DB" "PRAGMA integrity_check;")
DUP=$(c_dup)
echo "final: total=$T_FINAL y1400=$Y1400 y1402=$Y1402 integrity=$INTEG dups=$DUP"
chk_eq "S9.final_1400_35"   35 "$Y1400"
chk_eq "S9.final_1402_56"   56 "$Y1402"
chk_eq "S9.no_duplicate_ids" 0 "$DUP"
chk_eq "S9.db_integrity_ok"  "ok" "$INTEG"
# 1400/1402 must be COMPLETE (their queue rows all done)
cs=$(curl -s "$B/api/khamenei/crawl-status" | python3 -c 'import json,sys; d=json.load(sys.stdin); pby=d["pending_by_year"]; print(pby.get("1400",0), pby.get("1402",0))')
chk_eq "S9.queue_rows_1400_1402_all_done" "0 0" "$cs"

echo
echo "════════════════════════════════════════════════"
echo "M4 SUMMARY: $PASS PASS / $FAIL FAIL"
echo "logs: $LOGDIR/  (s1..s8 per-step full crawler output)"
echo "════════════════════════════════════════════════"
[ "$FAIL" = "0" ]
