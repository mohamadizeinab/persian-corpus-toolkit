# PCM-EXT-07 — Python Crawler E2E Acceptance (M4)

**Verdict: 36 PASS / 0 FAIL** — real run on s52 against the staging backend
(`127.0.0.1:5056`) + staging DB only. Runner: `deploy/pcm_ext07_m4_crawler_test.sh`
(scenario log `evidence/pcm-ext07-m4-crawler-e2e.log`; per-step crawler output
kept on s52 under `/tmp/pcm-ext07-m4/`). Staging DB restored to the M3 seed
(151 rows) before the definitive run, so every count starts clean.

Rule of the mission: **هیچ نتیجه‌ای را بدون اجرای واقعی PASS اعلام نکن** —
every check below quotes the real output.

---

## 1. Environment under test

| Item | Value |
|---|---|
| Crawler | `corpus/scrape_khamenei.py` (git blob `d12b76d6…`, commit `6f7f2d2`) — PCM-EXT-06 year-based algorithm |
| Site | `https://farsi.khamenei.ir` — `?page=N` ignored by the site; **one Jalali year = one list page** `/speech?nt=2&year=YYYY` (1379–1404) |
| Backend | staging Flask on `127.0.0.1:5056` (compose project `pct-staging`) |
| DB | staging `backend/thesaurus.db` — seeded from a prod online backup, **151 rows** baseline |
| Baseline (S0) | `total=151 y1400=0 y1402=0 pending=164` |

## 2. Algorithm proven (what the crawl actually does)

- **Year walk (descending):** unfiltered `/speech` seeds the latest year; then
  `--year Y` per list page; stop after **2 consecutive empty years**.
- **Item selection:** anchors whose first child is a `skyText` date span
  (sidebar widgets without dates are excluded — verified: 0 false IDs).
- **Digit normalization:** Persian/Arabic digits → ASCII before date parsing.
- **Date validation:** Jalali `YYYY/MM/DD`; the year must equal the list-page
  year (a speech listed under 1400 must have a 1400 date).
- **Write path:** `submit_to_backend` → `POST /api/khamenei/submit` →
  `_phase2_save_khamenei` dedup (`speech_id` + `content_hash(content|date)`).

## 3. Check-by-check results (real outputs)

| # | Scenario | Real result | Checks |
|---|---|---|---|
| S0 | Baseline | `total=151 y1400=0 y1402=0 pending=164` | 3 PASS |
| S1 | Crawl year **1400** | `{"inserted": 35, "updated": 0, "skipped": 0, "errors": 0}`; DB `y1400=35`, `total=186`; last row `#47576 … (33741 chars)` | 5 PASS |
| S2 | Crawl year **1402** | `{"inserted": 56, "updated": 0, "skipped": 0, "errors": 0}`; DB `y1402=56`, `total=242`; last row `#52275 … (60 chars)` | 5 PASS |
| S3 | **Idempotency** re-run 1400 | `{"inserted": 0, "updated": 0, "skipped": 35, "errors": 0}`; total still 242 | 4 PASS |
| S4 | **Idempotency** re-run 1402 | `{"inserted": 0, "updated": 0, "skipped": 56, "errors": 0}`; total still 242 | 4 PASS |
| S5 | **Date validity** of all 91 new rows (SQL) | `bad_dates=0 wrong_year_date=0 empty_text=0`; 48 rows `<100 chars` = source-true PDF-only pages (site has no `div.Content` for them) — **documented, not a bug** | 3 PASS |
| S6 | **Live re-verification** (re-extract from site NOW vs DB) | 1400 `#47576`: `title_equal=True text_equal=True 33741=33741`; 1402 `#52275`: `title_equal=True text_equal=True 60=60`; `S6_FAILS 0` | 1 PASS |
| S7 | **Empty-year behavior** | `year 1354 → 0 IDs`, `year 1350 → 0 IDs` (no false items, no error) | 2 PASS |
| S8 | **Resume via pending queue** (unfiltered `--max 3`) | consumes the global `crawl_queue` (no auto-walk hijack): exactly 3 crawled, 0 errors, `total 242→245` | 4 PASS |
| S9 | **Final state** | `total=245 y1400=35 y1402=56 integrity=ok dups=0`; queue rows for 1400/1402 all `done` | 5 PASS |

**Total: 36 PASS / 0 FAIL.**

## 4. Baseline match (mission requirement)

| Required | Real | Match |
|---|---|---|
| 1400 = 35 | 35 inserted, 35 in DB | ✅ |
| 1402 = 56 | 56 inserted, 56 in DB | ✅ |
| total 91 | 91 (35+56), 0 errors | ✅ |
| every date validated | 0 bad dates, 0 wrong-year dates, 0 empty text | ✅ |
| text sampled vs site | S6: title+text identical for both sampled rows | ✅ |
| sidebar false IDs | 0 (skyText-first-child selection) | ✅ |
| re-run → no duplicates | S3/S4: 0 inserted, all skipped, total unchanged | ✅ |
| resume + pending queue | S8: unfiltered run drains the queue, no year-walk | ✅ |
| empty-year behavior | S7: 0 IDs, no error | ✅ |

## 5. Discrepancies (none hidden)

- **48 short rows (<100 chars):** the source pages are PDF-only (the site has
  no `div.Content` article body for them). The crawler stores the page text as
  found; this is source-true, not a crawl bug. No date is missing on any of them.
- **1398 year is NOT crawled in M4** (out of the acceptance years); it remains
  in `crawl_queue` (70 pending) — this is exactly what the dashboard
  «⏭️ ادامه سال‌های گذشته» button + M6 acceptance covers.
- Everything else: 0 errors across 91+91+3 rows = 185 live page fetches.

## 6. Evidence

- `evidence/pcm-ext07-m4-crawler-e2e.log` — full scenario log (quoted above, verbatim)
- `evidence/pcm-ext07-m4-step-logs/` — per-step crawler output (s1..s8)
- `evidence/pcm-ext07-m4-regression.txt` — backend regression after M4 (232 OK)
- `deploy/pcm_ext07_m4_crawler_test.sh` — the 36-check runner (S0–S9)
- Staging state after M4: `total=245` (1398:3, 1400:35, 1401:43, 1402:56,
  1403:69, 1404:39), `integrity_check=ok`, 0 duplicate `speech_id`s

**Acceptance: PASS — the Python crawler implements the PCM-EXT-06 year-based
algorithm end-to-end against the real site + real staging backend, matches the
required 1400=35/1402=56 baseline exactly, is idempotent, and leaves the DB
intact.**
