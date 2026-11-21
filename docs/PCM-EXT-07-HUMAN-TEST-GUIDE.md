# PCM-EXT-07 — راهنمای تست انسانی (Human UI Acceptance)

Mission stage **M6**. Everything in this guide was machine-verified first
(real outputs: `evidence/pcm-ext07-m6-ui-evidence.log`); the steps below are
what the **project owner** now does in a real Chrome/Edge on their own machine,
with PASS/FAIL criteria per step.

**Staging address:** `https://pct-staging.ai.ismc.ir` — self-signed cert →
one-time browser warning, click *Advanced → Proceed* (expected; staging uses a
wildcard self-signed vhost, prod `corpus.ai.ismc.ir` keeps its real cert).

- Staging dashboard: `https://pct-staging.ai.ismc.ir/dashboard/` (login = the
  dashboard password, same as production).
- Staging extension (same bytes as the tracked zip):
  `https://pct-staging.ai.ismc.ir/dashboard/pct-extension-staging.zip`
  (sha256 `6f706371495a6f65e1c68efd72e5539c9b9c17a00a57be76170245218251ba32`).
- Staging DB state at test time (real, from `/api/khamenei/stats` +
  `/api/khamenei/crawl-status`): **245 بیانات** (1398:3, 1400:35, 1401:43,
  1402:56, 1403:69, 1404:39), **245 با تاریخ / 0 بدون تاریخ**, **70 در صف**
  (همه سال 1398), آخرین کراول `2026-11-21 20:05:09`, 905,185 کاراکتر.

---

## ۱. نصب اکستنشن (install)

Two equivalent options (both proven byte-identical in M5):

1. **load-unpacked (recommended for testing):** `chrome://extensions` →
   Developer mode ON → *Load unpacked* → folder `extension-staging/`
   (or the unzipped download from option 2).
2. **live zip:** download
   `https://pct-staging.ai.ismc.ir/dashboard/pct-extension-staging.zip`,
   unzip, *Load unpacked* the folder.

**Verify installed identity:** the extension name must be
**"Persian Corpus Crawler (STAGING)"** and the version **3.10-staging**
(`extension-staging/manifest.json`). A name without "(STAGING)" = wrong copy
(talk to the dev, do NOT test against prod).

| Step | Expected | PASS/FAIL |
|---|---|---|
| Extension appears in `chrome://extensions` | name "Persian Corpus Crawler (STAGING)", version 3.10-staging | ☐ |
| Popup opens on toolbar-icon click | popup with project UI + collapsed "ابزارهای قبلی" | ☐ |

---

## ۲. داشبورد: login + تب «🎤 بیانات» (menu path)

Machine-verified: before login the overlay is `display:flex`; after
`POST /api/auth/login` (200, `pct_session` cookie) the overlay is `none` and
`authenticated:true`; tab renders (full DOM dump + screenshot in evidence).

Menu path: **`https://pct-staging.ai.ismc.ir/dashboard/` → overlay ورود →
رمز → nav «🎤 بیانات»**.

| Step | Expected (real values captured) | PASS/FAIL |
|---|---|---|
| Login overlay appears, password accepted | overlay gone, all tabs usable | ☐ |
| «🎤 بیانات» tab opens | h1 «🎤 بیانات khamenei.ir» | ☐ |
| Stat cards | کل بیانات ۲۴۵ · با تاریخ ۲۴۵ · بدون تاریخ ۰ · در صف ۷۰ · آخرین کراول 2026-11-21 20:05:09 · کل کاراکتر ۹۰۵٬۱۸۵ | ☐ |
| Year chart | bars for 1398/1400/1401/1402/1403/1404 (3/35/43/56/69/39) | ☐ |
| Pending-years status line | «📅 سال‌های در انتظار کراول (از crawl_queue): 1398 (۷۰) — دکمه «ادامه سال‌های گذشته»…» | ☐ |
| «📋 آخرین بیانات» table | 20 rows; first row `#62948 · بیانات در مراسم قرائت خطبه عقد ازدواج · 1401/12/19 · ۲٬۵۱۰` | ☐ |

**Real screenshot (headless Edge, this session):** `evidence/pcm-ext07-m6-khamenei-tab.png`
(67,056 B — the logged-in Khamenei tab with the numbers above). Take your own:
login → «🎤 بیانات» → screenshot of the full tab.

---

## ۳. کراول بیانات: start + select 1400/1402 (operations)

### Option A — dashboard button (the 1398 pending year)

1. In the «🎤 بیانات» tab click **«⏭️ ادامه سال‌های گذشته»**.
2. Alert lists pending years (currently `1398`) → OK.
3. Browser opens `https://farsi.khamenei.ir/speech?nt=2&year=1398` in a new tab.
4. The extension content script **auto-seeds** that list page: it finds the
   dated speech links (anchors whose first child is a `skyText` date span) and
   POSTs them to `/api/phase1/seed-batch`. Already-queued URLs come back as
   `duplicates` (verified live: `{"added":0,"duplicates":3}`).

### Option B — open 1400 / 1402 explicitly (the acceptance years)

Open in Chrome (extension installed):

- `https://farsi.khamenei.ir/speech?nt=2&year=1400`
- `https://farsi.khamenei.ir/speech?nt=2&year=1402`

Expected: each list page auto-seeds (35 and 56 items respectively — already in
the queue from M4, so the seed response is all `duplicates`; no new rows).

### Option C — extension start flow (year walk)

Popup → expand **«ابزارهای قبلی — اصطلاح‌نامه و بیانات»** → site button
**«🎤 بیانات»** → **«🚀 هر دو فاز»** (or «🌱 فاز ۱» alone).

- **Phase 1** opens `https://farsi.khamenei.ir/speech` (latest year), then
  walks **downward** year by year (`1404 → 1403 → … → 1379`) — this is the
  PCM-EXT-06 algorithm: each list page = one request, stop after **2
  consecutive empty years** or below year 1370. (Year walk + stop proven by
  8/8 node tests on the shipped artifact: `evidence/pcm-ext07-m5-node-khamenei-years.log`.)
- **Phase 2** then pulls pending detail pages (`/api/phase2/next-batch`) and
  visits each `speech-content?id=…`; the content script extracts
  title/date/content/audio and POSTs `/api/phase2/complete`.

**Job status while crawling:**

- Extension popup: log box (phase1 «لیست یکتا», phase2 «مانده فاز۲»,
  «ذخیره‌شده», «آخرین») — pending count must go **down** over time.
- Dashboard «🎤 بیانات» → stat card «در صف» must go down (refresh the tab);
  pending-years line updates from `crawl_queue`.
- «⏹ توقف» in the popup stops cleanly (state saved; resume = same button).

| Step | Expected | PASS/FAIL |
|---|---|---|
| 1400/1402 list pages auto-seed | popup log: seed with `added=0`, `duplicates=35`/`56` (or dashboard queue unchanged) | ☐ |
| Phase 2 visits detail pages | popup «مانده فاز۲» decreases; dashboard «در صف» decreases | ☐ |
| A 1398 page gets crawled (Option A) | a NEW row appears: total 245 → 246+ (1398: 3 → 4+) | ☐ |
| Stop button | crawl halts, queue keeps remaining rows (no crash, no lost state) | ☐ |

---

## ۴. نتیجه: counts + open a record + no duplicates (acceptance)

### Counts (dashboard «🎤 بیانات», real DB counters — no fabricated numbers)

| Check | Before (this session) | After your crawl | PASS/FAIL |
|---|---|---|---|
| کل بیانات | ۲۴۵ | ۲۴۵ + (number of 1398 pages you actually crawled) | ☐ |
| با تاریخ / بدون تاریخ | ۲۴۵ / ۰ | still 100% with date | ☐ |
| در صف | ۷۰ | ۷۰ − (crawled 1398 pages) | ☐ |
| by_year 1400 / 1402 | 35 / 56 | **unchanged 35 / 56** (re-crawl = skipped, not re-inserted) | ☐ |

### Open a record (date + text)

The dashboard table shows id/title/date/size (no click-through in the current
build). To see the **full text** of a record:

1. In the dashboard «📋 آخرین بیانات» table note a row, e.g.
   `#62948 · بیانات در مراسم قرائت خطبه عقد ازدواج · 1401/12/19 · ۲٬۵۱۰`.
2. Open the source page: `https://farsi.khamenei.ir/speech-content?id=62948`
   — the same date + text must be visible (date in the page meta, full text in
   the article body). The extension's own extraction of this page is what
   landed in the DB (M4 verified the stored content matches the page
   verbatim for the sampled rows).
3. Knowledge Studio result location: `https://pct-staging.ai.ismc.ir/dashboard/studio.html`
   — the Khamenei bank is the *upstream* of the studio pipeline
   (roadmap note in the tab: ① Word Factory → ② استودیو → ③ dataset/ES →
   ④ dump → ⑤ registry). Khamenei records are not yet studio collections —
   that is the documented next phase, not part of this acceptance.

| Step | Expected | PASS/FAIL |
|---|---|---|
| Open `speech-content?id=62948` | same date (1401/12/19) + full text visible | ☐ |
| Studio reachable | `/dashboard/studio.html` loads (logged in) | ☐ |

### No duplicates (re-run)

Re-run the same crawl (Option B: reopen the 1400/1402 list pages, then
phase 2 on those ids; or re-click «🚀 هر دو فاز»). Expected, all
machine-proven by the live round-trip (`evidence/pcm-ext07-m5-probe-run2.log`):

- phase 1 re-seed → `added=0`, all `duplicates`.
- phase 2 re-save of an existing speech → `{"status":"skipped"}` (backend
  dedup: same `speech_id` + same `content_hash(content|date)` + existing date
  → skip; `server.py` `_phase2_save_khamenei`).
- Counts **unchanged** (total stays where step 4 left it; 1400 stays 35,
  1402 stays 56; `PRAGMA integrity_check` = ok).

| Step | Expected | PASS/FAIL |
|---|---|---|
| Re-run 1400/1402 | 0 new rows; `skipped` responses in popup log | ☐ |
| Counts after re-run | identical to after first run | ☐ |

---

## ۵. Findings (from this acceptance — reported, not hidden)

| ID | Finding | Disposition |
|---|---|---|
| **F-M6-1** | `/api/khamenei/*` read endpoints answer **200 without** the `pct_session` cookie (login not required at the API level). By design per AGENTS §2.6 — only `/api/dashboard/*` is auth-gated; the extension must read without a login. The dashboard login overlay (PCM-09) still gates the whole UI. | Accept (by design). If stricter gating is wanted, add `pct_session` to `/api/khamenei/*` — product decision. |
| **F-M6-2** | The khamenei popup tools live inside a **collapsed** `<details>` "ابزارهای قبلی — اصطلاح‌نامه و بیانات" under the new tafsir-project UI — easy to miss during acceptance. | **Product backlog:** promote «🎤 بیانات» to a top-level popup section (or a dedicated menu entry) in a future version. |

---

## WHAT SHOULD THE PROJECT OWNER TEST NOW?

**Address:** `https://pct-staging.ai.ismc.ir/dashboard/` (self-signed →
proceed once). Staging only — production `corpus.ai.ismc.ir` is untouched.

**Install:** `chrome://extensions` → Developer mode → *Load unpacked* →
`extension-staging/` folder (or the live zip above, sha256
`6f706371…`). Name must read "Persian Corpus Crawler (STAGING)" v3.10-staging.

**Menu path:**

- Dashboard: login overlay (password) → nav **«🎤 بیانات»**.
- Extension popup: expand **«ابزارهای قبلی — اصطلاح‌نامه و بیانات»** →
  **«🎤 بیانات»**.

**Operations (in order):**

1. «🎤 بیانات» tab → confirm the 6 stat cards match §4 (245/245/0/70,
   last crawl 2026-11-21 20:05:09) → **screenshot** of the tab.
2. Click **«⏭️ ادامه سال‌های گذشته»** → alert (1398) → the 1398 list page
   opens → extension auto-seeds (popup log).
3. Open `https://farsi.khamenei.ir/speech?nt=2&year=1400` and
   `…year=1402` → popup log shows all-`duplicates` seeding (they're already
   stored from M4) → **this is the duplicate-detection demo**.
4. Popup: **«💾 فاز ۲: ذخیره کامل»** (or «🚀 هر دو فاز») → watch
   «مانده فاز۲» and the dashboard «در صف» card decrease (the 70 pending
   1398 pages). Stop with «⏹ توقف» whenever you want — state is safe.
5. «📋 آخرین بیانات» → pick a row (e.g. `#62948`, 1401/12/19) → open
   `https://farsi.khamenei.ir/speech-content?id=62948` → same date + full text.
6. **Re-run** step 3–4 on 1400/1402 → expect `skipped` everywhere and counts
   **unchanged** (1400=35, 1402=56, no duplicates).

**Expected result:** all steps ☐→✅ in §2–§4; the dashboard shows the real
counters (245 + crawled-1398 rows), 100% with date, zero duplicates on
re-run; your own screenshots match
`evidence/pcm-ext07-m6-khamenei-tab.png`.

**Real screenshot (machine-captured, headless Edge, 2026-11-21 20:49 UTC):**
`evidence/pcm-ext07-m6-khamenei-tab.png` — logged-in staging dashboard,
«🎤 بیانات» tab: stat cards ۲۴۵/۲۴۵/۰/۷۰ + last crawl + total chars, year
chart, pending-1398 status line, 20-row latest table (first row #62948).

**Stop conditions:** if a stat card shows a number that differs from the API
(`/api/khamenei/stats`), if a re-run adds rows instead of skipping, or if the
popup log shows `errors` — take screenshots of both and stop; those are
acceptance failures to report, not things to work around.
