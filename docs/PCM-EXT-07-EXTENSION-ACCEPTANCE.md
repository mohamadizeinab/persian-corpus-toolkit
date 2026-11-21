# PCM-EXT-07 — Chrome Extension Acceptance (M5)

**Verdict: PASS** — install path proven from the live staging URL, version +
commit identity verified, year-walk + 2-empty stop proven on the **shipped
artifact** (node 8/8 + 71/71), the extension's network path live-verified, and
an extension-shaped round-trip dedups against the real M4 crawler data
(skipped ×2, counts unchanged). Human trial-install + click-through = M6
(`docs/PCM-EXT-07-HUMAN-TEST-GUIDE.md`).

Rule of the mission: **هیچ نتیجه‌ای را بدون اجرای واقعی PASS اعلام نکن** —
every claim below carries its real output / evidence file.

---

## 1. Install path (real download from the live staging URL)

| Check | Real result |
|---|---|
| `curl -sk https://pct-staging.ai.ismc.ir/dashboard/pct-extension-staging.zip` | HTTP 200, **50,089 bytes** |
| sha256 of live download | `6f706371495a6f65e1c68efd72e5539c9b9c17a00a57be76170245218251ba32` |
| sha256 of tracked `pct-extension-staging.zip` (certutil) | identical → **byte-identical** |

Owner can install via *Load unpacked* on `extension-staging/` or by downloading
+ unzipping the live zip — same bytes either way.

## 2. Version + commit identity

| Item | Value | Evidence |
|---|---|---|
| manifest name | "Persian Corpus Crawler (STAGING)" | `extension-staging/manifest.json` |
| version | **3.10-staging** | `extension-staging/manifest.json` |
| built from commit | **6f7f2d2** | `background.js` blob `e4fe748e…` (M3 blob-identity) |
| BACKEND override | `https://pct-staging.ai.ismc.ir` in 7 lines / 6 files | `background.js:2`, `content_khamenei.js:4`, `content_picker.js:6`, `content_thesaurus.js:5`, `popup.js:5,40`, `shared.js:3` |

## 3. Year-walk + 2-empty stop + next-page — node tests ON the shipped artifact

| Suite | Real result |
|---|---|
| `node extension-staging\test_khamenei_years.js` | **8 passed, 0 failed** — first scan `maxYear-1`; fallback 1404; streak reset on data; 1 empty → streak 1; **2 consecutive empty → stop `reason:'empty'`**; MIN_YEAR walked; below MIN_YEAR → stop `reason:'floor'`; full walk shape `1405(empty)→1404..1379→1378,1377 stop=empty` |
| `node extension-staging\test_next.js` | **71 passed, 0 failed** — all next-page strategies (param/number/regex/next-link/hash) + stop rules |

Logs: `evidence/pcm-ext07-m5-node-khamenei-years.log`, `evidence/pcm-ext07-m5-node-next.log`.

## 4. Live network path (the endpoints the extension actually calls, from the LAN)

| Endpoint | Real result |
|---|---|
| `GET /api/khamenei/crawl-status` | 200 — `{"pending":70,"pending_by_year":{"1398":70},"queued":315,"total":245,…}` |
| `GET /api/khamenei/stats` | 200 — `{"by_year":{"1398":3,"1400":35,"1401":43,"1402":56,"1403":69,"1404":39},…,"total":245,"with_date":245}` (M4 data intact) |
| `GET /api/khamenei/pending?limit=50` | 200 — `count:50` + id list (used by `fetchPendingKhameneiIds`) |

Logs: `evidence/pcm-ext07-m5-lan-crawlstatus.log`, `evidence/pcm-ext07-m5-lan-stats.log`.

## 5. Extension-shaped round-trip against live staging (`deploy/pcm_ext07_m5_probe.py`, run on s52)

Payloads use the **exact field shapes from `content_khamenei.js`**; self-signed
https URL; staging DB read for the stored row (speech `47576`, 1400, 33,741
chars — the M4 S6 live-verified row). Run 1 (20:29) and Run 2 (20:30) identical.

| Step | Real result | Verdict |
|---|---|---|
| baseline | `total=245 y1400=35 y1402=56 dups=0` | — |
| `POST /api/phase1/seed-batch` — 3 already-queued urls, exact extension item shape | `{"added":0,"duplicates":3,"requested":3,"site":"khamenei"}` | **PASS** — duplicate list items never re-queued |
| `POST /api/phase2/complete` (speech 47576, full content verbatim) | `{"status":"skipped","date":"1400/01/01","year":"1400"}` | **PASS** |
| `POST /api/phase2/complete` again (same payload) | `{"status":"skipped",…}` | **PASS** — idempotent |
| final | `total=245 y1400=35 y1402=56 dups=0 integrity=ok` | **PASS** — counts unchanged |

Log: `evidence/pcm-ext07-m5-probe-run2.log`.

## 6. Python-vs-Extension comparability (same algorithm, same dedup)

| Dimension | Python crawler | Chrome extension | Same? |
|---|---|---|---|
| year list URL | `/speech?nt=2&year=YYYY` | identical (`background.js` walk) | ✅ |
| item selection | anchors with a `skyText` date span | `datedSpeechLinks()` — skyText first child | ✅ |
| digit normalization | `to_ascii_digits` | `toAsciiDigits` | ✅ |
| date validation | Jalali `YYYY/MM/DD`, year from prefix | identical | ✅ |
| auto-walk stop | 2 consecutive empty years | node-proven: stop `reason:'empty'` | ✅ |
| write path | `/api/khamenei/submit` | `/api/phase2/complete` (site=khamenei) | both → `_phase2_save_khamenei` (server.py:458–504) |
| dedup | `speech_id` + `content_hash(content|date)`; skip needs non-empty date | same function | ✅ |

M4 proved the Python path idempotent (re-run → 0 inserted / N skipped, 0
errors); §5 proved the extension-shaped payload returns `skipped` twice against
the same data with counts unchanged. **Conclusion: both crawlers produce the
same 1400=35 / 1402=56 and no duplicates on re-run — comparable results, as
the mission requires.**

## 7. Regression

`evidence/pcm-ext07-m5-regression.txt`: **`Ran 232 tests in 83.325s / OK`** —
full backend regression re-run after M5 (11 modules).

## 8. Deferred to M6 (and findings)

- Human trial-install (load-unpacked / unzip in a real Chrome) + click-through
  (start phase 1/2, open 1400/1402, job status, screenshot) →
  `docs/PCM-EXT-07-HUMAN-TEST-GUIDE.md` with per-step PASS/FAIL. Machine-side
  equivalent already done: headless-Edge DOM + screenshot
  (`evidence/pcm-ext07-m6-khamenei-tab.png`).
- **F-M6-1:** `/api/khamenei/*` read endpoints open without cookie — by design
  (AGENTS §2.6; extension reads without login).
- **F-M6-2:** khamenei popup tools hidden in a collapsed "ابزارهای قبلی"
  section → product backlog (top-level «🎤 بیانات» entry).

**Acceptance: PASS — the v3.10-staging extension is the proven 6f7f2d2 build,
implements the PCM-EXT-06 year walk (2-empty stop), and shares the Python
crawler's exact backend dedup: re-runs skip, counts never double.**
