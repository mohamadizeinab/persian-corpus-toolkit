# PCM-EXT-07 — Deployment Report (KHAMENEI CRAWLER STAGING DEPLOYMENT)

Date: 2026-11-21 (UTC) · Operator: Zoo (Senior SWE + DevOps + E2E Acceptance)
Mission: move the PCM-EXT-06 year-based Khamenei crawler (Python + Chrome extension) to
**Staging**, prove real operation, and deliver a human-acceptance scenario.
Rule of the mission: **هیچ نتیجه‌ای را بدون اجرای واقعی PASS اعلام نکن** — every PASS below
carries its real command + real output (or its evidence file).

Companion reports (M8):
- `PCM-EXT-07-CRAWLER-E2E-ACCEPTANCE.md` (M4)
- `PCM-EXT-07-EXTENSION-ACCEPTANCE.md` (M5)
- `PCM-EXT-07-HUMAN-TEST-GUIDE.md` (M6 + "WHAT SHOULD THE PROJECT OWNER TEST NOW?")

---

## M1 — Git audit (COMPLETE)

| Item | Value | Evidence |
|---|---|---|
| Branch | `pcm-20.9-knowledge-studio-factory` | `git branch --show-current` |
| Remote | GitHub `saber13812002/persian-corpus-toolkit` | `git remote -v` |
| Base commit (PCM-25 DC#5) | `ae94ede` | pre-session HEAD |
| New commits | **10106e9** (PCM-EXT-06, 7 files, +716/−116) · **8708163** (PCM-EXT-08, 11 files, +514/−35) · **6f7f2d2** (hygiene/.gitignore, 1 file, +6) | `git log --oneline ae94ede..6f7f2d2` |
| Pushed | `ae94ede..6f7f2d2` → origin | `git push` output |
| Working tree | clean | `git status --porcelain` = empty |
| Secrets in git | none — `.env`, `*.db`, probes all gitignored; no `*.db.bak` tracked | `git ls-files` audit |
| Tests at commit time | backend 232/232 OK (11 modules) + node 71/9/8/8 + corpus 13/13 | full regression re-run this session |

Hunk-level split of the mixed files (`extension/background.js`, `extension/popup.js`,
`AGENTS.md`) was done with a Python patch splitter (`git apply --cached --recount`) so that
commit 10106e9 contains **only** PCM-EXT-06 and 8708163 **only** PCM-EXT-08 (verified:
staged EXT-06 diff had 0 hash-mode mentions, 18 year-walk mentions).

**Code identity for staging:** commit **`6f7f2d2`**
(HEAD of branch = EXT-06 + EXT-08 + hygiene).

---

## M2 — Environment discovery (COMPLETE — all live-verified 2026-11-21 18:14–18:26 UTC)

### 2.1 Where does the Corpus backend run? (production)

| Fact | Value | How verified |
|---|---|---|
| Public URL | `https://corpus.ai.ismc.ir` → **200** on `/api/db/info` | `curl` from LAN |
| Host | s52 = `172.30.0.133` (hostname `AI-TOOLS`, Ubuntu 24.04, 20 vCPU, 78 GiB RAM, **371 GiB free** on /) | `ssh s52` live probe |
| Edge | BT-Panel nginx (root) at `/www/server/panel/vhost/nginx/*.conf`; prod vhost = `corpus.ai.ismc.ir.conf` → `proxy_pass http://127.0.0.1:5055` | vhost read + `ss -tlnp` (5055 on 127.0.0.1) |
| Container | `persian-corpus-toolkit-backend-1` (image `persian-corpus-toolkit-backend:latest`, id `2f3ef57fdd11`) Up 15 h, `127.0.0.1:5055:5055` | `docker ps` |
| Code dir | `/home/saber/saberprojects/persian-corpus-toolkit` — **a copy, NOT a git repo** | `git rev-parse` fails there |
| Code identity vs git | `server.py` on s52 **==** git blob `008330dc…` (commit 6f7f2d2); `scrape_khamenei.py` + `extension/background.js` on s52 are **older** (pre EXT-06/08 — hash `7c1605c3…` / `98b35eaf…` ≠ git) | `git hash-object` on both sides |
| Prod DB | `backend/thesaurus.db` → bind-mount `/data/thesaurus.db`; `khamenei_speeches` = **151 rows** (1401:43, 1403:69, 1404:39) — **no 1400/1402 yet** | `sqlite3` read-only |
| Backups | `/home/saber/backups/` — latest `thesaurus-20261121-010021.db` (1.66 GB) + `pct-deploy-20261121-010021.tar.gz` | `ls -lt` |
| Python on s52 | system `python3` **3.12.3** + `requests 2.31.0`, **no venv** in app dir | `which`/`import` |
| Ports free | **5056, 5057 free** on s52 | `ss -tlnp` |
| DC#5 workers | `pct-elasticsearch` (8.13.4, 127.0.0.1:9200) + shared Ollama on 172.20.1.53 — **untouched by this mission** | `docker ps` |

Local dev DB (this Windows workspace) holds 242 khamenei rows = 151 + **1400:35 + 1402:56**
(the PCM-EXT-06 e2e ran against the local dev DB, not prod).

### 2.2 Where is Staging?

| Candidate | State | Verdict |
|---|---|---|
| s53 E7.0 staging (172.20.1.53, ports 8045–8048) | RAG chain only (radio2/rag2: registry/gateway/litellm/synth-provider/keyfwd). **Not the Corpus backend.** `corpus2.ai.ismc.ir` was planned (E7.0 C4, owner-blocked on DNS) | documented; NOT used for this mission |
| `corpus2.ai.ismc.ir` today | DNS → 172.30.0.133, but serves **another product** (Next.js CMS «سامانه مدیریت محتوا»; `/api/db/info` = 404) | name collision — avoided |
| Existing pct-staging dir on s52 | none (`ls /home/saber/saberprojects/pct*` = empty) | **corpus staging does not exist yet** |

**Decision (M3):** create a self-contained corpus **staging on s52** (same host as prod,
fully isolated: separate dir + separate DB + separate port 5056 + separate compose project
`pct-staging` + separate domain). Rationale: the s53 staging belongs to the RAG chain; s52
has the proven nginx/ACME pattern, free port 5056, Python 3.12 for the crawler, and 371 GiB
free. Nothing in the mission requires s53 — and adding load to s53 needs approval, which a
s52-local staging avoids.

### 2.3 How will the crawler be run? (Python + extension)

- **Python:** on s52, system `python3` (3.12.3, `requests` present),
  `cd /home/saber/saberprojects/pct-staging && python3 corpus/scrape_khamenei.py --year Y --backend http://127.0.0.1:5056`.
  No venv needed (only stdlib + requests; `urllib3` ships with requests).
- **Extension:** MV3 `extension/` (v3.10) with `BACKEND` **hardcoded** to `https://corpus.ai.ismc.ir`
  in 6 files (`background.js`, `popup.js`, `content_picker.js`, `content_khamenei.js`,
  `content_thesaurus.js`, `shared.js`). Distribution today = **load-unpacked**
  (`chrome://extensions` → Developer mode → Load unpacked), documented in
  `docs/EXT-NEXT-PAGE-METHODS.md` §نصب/آپدیت. For staging a build-variant is produced:
  same 6 files with `BACKEND → https://pct-staging.ai.ismc.ir`, zipped, version 3.10-staging.

### 2.4 Reachability & permissions (for M3/M6)

| Fact | Value |
|---|---|
| `*.ai.ismc.ir` DNS | wildcard → 172.22.6.1 (edge) → 172.30.0.133 (verified with a random subdomain) — **no DNS change needed for a new subdomain** |
| Public port reachability | only 443/80 via edge (2222 GitLab unreachable from LAN, 5056 not exposed) — **staging must be served through the edge nginx** |
| saber sudo | `(ALL:ALL) ALL` **with password** + NOPASSWD: `/www/server/nginx/sbin/nginx`, `systemctl`, `ss`, `journalctl`, `chmod` |
| Proven vhost pattern (no password) | PCM-24: `sudo chmod o+rx` on vhost dir → write file in place → `sudo nginx -t` + `sudo nginx -s reload` (all NOPASSWD) |
| Proven self-signed pattern | PCM-23: `/etc/letsencrypt/selfsigned/<domain>.pem/.key` + optional LE upgrade via certbot HTTP-01 (`/www/acme` **writable by saber**, `certbot` installed) |
| s53 | 172.20.1.53:22 UP; 172.30.0.134:22 UP (new vCenter host, context only) |

### 2.5 Open items handed to M3

1. Create staging dir + code from `git archive 6f7f2d2`.
2. Fresh online prod DB backup → staging DB (WAL-safe `.backup`).
3. Staging `.env`: same dashboard password; **ES/embedding vars blanked** (config-guarded
   `blocked` path → zero side effects on shared ES/Ollama).
4. Compose override: port 5056, project `pct-staging`.
5. vhost `pct-staging.ai.ismc.ir` (self-signed first, LE upgrade attempted).
6. Record **Image digest + commit SHA** after build.
7. Staging extension build (BACKEND rewrite) + zip.

---

## 3. M3 — Staging deployment (DONE — real run 2026-11-21 18:58 UTC, TS=20261121-185842)

Script: [`deploy/pcm_ext07_staging_deploy.sh`](../deploy/pcm_ext07_staging_deploy.sh)
(11 steps, fail-fast, blob-identity checks). Full server-side output captured at
[`evidence/pcm-ext07-m3-staging-deploy.log`](../evidence/pcm-ext07-m3-staging-deploy.log).

### 3.1 Identity (recorded, per mission M3)

| Item | Value |
|---|---|
| Code commit | `6f7f2d2` (branch `pcm-20.9-knowledge-studio-factory`, GitHub) — built with `git archive`, **not** a working-copy copy |
| Image name | `pct-staging-backend` (compose project `pct-staging`) |
| **Image ID** | `sha256:c5bbc8783ece3c228e6739fb6c6ee1b3e153036454e6a7c06cee659351f1ea37` |
| Container | `pct-staging-backend-1` on `127.0.0.1:5056` |
| Staging DB | `/home/saber/saberprojects/pct-staging/backend/thesaurus.db` (online `sqlite3 .backup` of **prod** DB — prod file only ever READ) |
| Staging seed backup | `/home/saber/backups/thesaurus-staging-seed-20261121-185842.db` |
| vhost file | `/www/server/panel/vhost/nginx/pct-staging.ai.ismc.ir.conf` (sha256 `d25e243f…c9902d`, recorded in `/home/saber/backups/staging-vhost-20261121-185842.sha256`) |
| TLS | self-signed 365d, CN + SAN `pct-staging.ai.ismc.ir`, keys in `$STAGE/certs/` (PCM-23 pattern) |
| Staging extension | `pct-extension-staging.zip` (v3.10-staging, BACKEND → `https://pct-staging.ai.ismc.ir`), also served at `https://pct-staging.ai.ismc.ir/dashboard/pct-extension-staging.zip` |
| Staging URL | `https://pct-staging.ai.ismc.ir` (wildcard DNS → edge → s52; **no DNS change was needed**) |

### 3.2 Blob-identity checks (script step 1, all PASS)

| File | `git hash-object` on extracted staging copy |
|---|---|
| `backend/server.py` | `008330dc07e1d3a20933326d24da11c24427e675` ✅ |
| `corpus/scrape_khamenei.py` | `d12b76d6cdf2fc39a9e2174cac7c3561cd622d8f` ✅ |
| `extension/background.js` | `e4fe748e71cd7784822d48ce4da4a7c2447e2229` ✅ |
| `docker-compose.yml` | `bccd873c51b1df3928b43afed701d241cd8289a7` ✅ |

(The compose hash was corrected once pre-flight: the originally recorded
`fc05c998…` predates the `.gitattributes` LF-export fix; `git rev-parse
6f7f2d2:docker-compose.yml` = `bccd873c…` is the authoritative value.)

### 3.3 Smoke results (script steps 6–9, on s52)

| Check | Result |
|---|---|
| health (`/api/stats` on 5056) | healthy after ~2 s |
| `/api/db/info` | 200, `khamenei_speeches = 151` (seed intact), 3 tables |
| `/api/projects` (extension write API, no cookie) | **200** (open, per AGENTS §2.6) |
| `/api/knowledge/collections` (no cookie) | **401** (dashboard namespace behind auth) |
| `/dashboard/` | 200 |
| `/api/khamenei/crawl-status` | 200, `pending_by_year` present |
| extension zip via dashboard | 200 |
| vhost `nginx -t` | syntax ok, reload OK (only pre-existing `http2` deprecation warns from other vhosts) |
| via vhost from s52 | `https://pct-staging.ai.ismc.ir/api/db/info` = 200, proxies to staging |

### 3.4 LAN verification (this Windows box, owner vantage — real curls, 18:55 UTC)

| Endpoint | Result |
|---|---|
| `https://pct-staging.ai.ismc.ir/api/db/info` | 200 — `crawl_queue=352842, crawled_data=146909, khamenei_speeches=151` |
| `https://pct-staging.ai.ismc.ir/dashboard/` | 200 |
| `https://pct-staging.ai.ismc.ir/dashboard/pct-extension-staging.zip` | 200 |
| `https://corpus.ai.ismc.ir/api/db/info` (prod) | 200 — untouched |

### 3.5 Prod regression (script step 10, AFTER staging up)

| Check | Result |
|---|---|
| prod container | `persian-corpus-toolkit-backend-1` — Up 15 hours (never restarted) |
| prod 5055 `/api/stats` | 200 |
| prod `khamenei_speeches` | **151** (unchanged) |
| prod `PRAGMA integrity_check` | ok |
| DC#5 workers (ES container + shared Ollama) | not touched |

### 3.6 M3 verdict

**PASS** — staging deployed, reachable over the edge from the LAN, identity recorded,
prod untouched (counters + integrity + container status verified before/after).
Self-signed cert: browser will show a one-time "not secure" warning — expected for
staging (LE upgrade possible later via certbot HTTP-01, `/www/acme` writable).

Rollback (staging only): `docker compose -p pct-staging stop backend && rm -f backend` →
remove the vhost file + `nginx -s reload` → `rm -rf $STAGE` (seed DB kept in backups).

---

## M4 — Real Python-crawler E2E acceptance (COMPLETE — final clean run 2026-11-21 20:00 UTC)

Runner: `deploy/pcm_ext07_m4_crawler_test.sh` (S0–S9, 36 checks), executed **on s52**
against the staging backend `127.0.0.1:5056` + staging DB only. Before the definitive
run the staging DB was restored to the M3 seed (151 rows) via
`sqlite3 thesaurus-staging-seed-20261121-185842.db ".backup …"` — so every count below
starts from the clean 151-row baseline.

### 4.1 Test plan (what each step proves)

| Step | Action | Proves |
|---|---|---|
| S0 | baseline counts | staging starts at 151 / 1400=0 / 1402=0, pending queue = 164 |
| S1 | `--year 1400` | **35 discovered, 35 inserted, 0 errors** — baseline met |
| S2 | `--year 1402` | **56 discovered, 56 inserted, 0 errors** — baseline met |
| S3 | re-run 1400 | idempotency: 0 inserted / **35 skipped** / total unchanged (242) |
| S4 | re-run 1402 | idempotency: 0 inserted / **56 skipped** / total unchanged (242) |
| S5 | SQL on DB | all 91 new rows: valid Jalali `YYYY/MM/DD`, date-year == speech-year, no empty content |
| S6 | live re-extract | re-fetch 1 sample per year from the site NOW, byte-equal title+content vs DB |
| S7 | `--discover` on empty years | clean 0-ID behavior + clean exit below the archive floor |
| S8 | unfiltered `--max 3` | pending-queue resume: "Resuming … pending IDs" banner, exactly 3 processed, no auto-walk hijack |
| S9 | final state | 1400=35, 1402=56, 0 duplicate speech_ids, integrity ok, 1400/1402 queue rows all done |

### 4.2 Run history (no FAIL ever hidden)

| Run | Result | Explanation of FAILs |
|---|---|---|
| 1 (20:35 local, seed baseline) | 32 PASS / 4 FAIL | 2 = harness grep bug (`grep -o` captured the year digits too); 2 = real findings (see 4.3) |
| 2 (after grep fix, seed baseline) | 35 PASS / 1 FAIL | 1360 assumed empty but returned 8 IDs (real data) |
| 3 (S7 → 1370+1350, seed baseline) | 35 PASS / 1 FAIL | **1370 returned 131 IDs** (it had returned 0 in runs 1–2) — site flakiness, real finding |
| **4 (S7 → fast-empty 1354+1350, seed baseline) — DEFINITIVE** | **36 PASS / 0 FAIL** | — |

Each run started from the restored 151-row seed; the final run left staging at
245 rows (151 seed + 91 crawl + 3 S8 resume inserts), pending queue 70.

### 4.3 Findings (probed, not hidden — mission rule)

**F-M4-1 · 48 of 91 rows are short because the SOURCE is short (PDF-only pages).**
`char_count<100` count = 48 (distribution: min 36 / p25 62 / median 98 / p75 9,820 /
max 40,419; buckets `<50: 8, <100: 48, =0: 0, 100–999: 8, >=1000: 35`). The 4 shortest
rows (sids 54897 / 54526 / 52837 / 55611) store exactly `«title» [دریافت PDF]` — and the
live pages were re-fetched: **no `div.Content` exists at all**; the site offers a PDF
download instead of inline text. The crawler is source-true; the S5 check was corrected
to `length(content)=0` (0 rows) and the <100 count is reported as INFO.

**F-M4-2 · The archive floor is far lower than the old assumption (≤1379).**
Probe-verified counts: `1379: 67, 1378: 67, 1377: 57, 1376: 70, 1375: 43, 1370: 131,
1360: 8, 1359: 4, 1358: 3, 1357: 4, 1356: 1, 1355: 1, 1352: 1`; confirmed fast-empty
years: 1354, 1353, 1351, 1350 (0.0–0.4 s each). The crawler's
`ARCHIVE_START_YEAR=1379` default underestimates available history; the
2-consecutive-empty-years stop rule still terminates the walk, but a full historical
crawl needs the floor pushed to ~1351. (Documented; not changed in this mission.)

**F-M4-3 · Old-year list pages are FLAKY — a timeout masquerades as an empty year.**
Same year, same code, three separate live runs: **1370 → `0` (run 1), `131` (run 3),
`0/0/0` via 3×30 s read-timeouts (stability probe)**. The failure mode is a 30 s read
timeout (3 retries, 2 s/4 s backoff ≈ 96 s per failed year), and the crawler returns
`[]` for both "site says empty" and "gave up" — indistinguishable. Consequence: the
auto-walk's 2-consecutive-empty stop rule can halt early on a slow day (walk stops at a
timeout-pair) — but it can also **miss a whole year's worth of IDs** (1370 had 131).
Backfill safety: `discover_year` is cheap to re-run and the submit endpoint dedups, so
re-walking old years is lossless. (Product note for the roadmap: treat
"timeout after retries" as a distinct, non-counted-toward-stop outcome.)

### 4.4 Definitive run — per-step results (2026-11-21 20:00 UTC, seed baseline)

| Step | Result (real output) |
|---|---|
| S0 | `baseline: total=151 y1400=0 y1402=0 pending=164` — 3/3 PASS |
| S1 | `discover=35` · `{"inserted": 35, "updated": 0, "skipped": 0, "errors": 0}` · db 1400=35, total=186 — 5/5 PASS |
| S2 | `discover=56` · `{"inserted": 56, …, "errors": 0}` · db 1402=56, total=242 — 5/5 PASS |
| S3 | `{"inserted": 0, "updated": 0, "skipped": 35, "errors": 0}` · total still 242 — 4/4 PASS |
| S4 | `{"inserted": 0, "updated": 0, "skipped": 56, "errors": 0}` · total still 242 — 4/4 PASS |
| S5 | `bad_dates=0 wrong_year_date=0 empty_text=0` (INFO: 48 rows <100 chars = F-M4-1) — 3/3 PASS |
| S6 | sid 47576 (1400): `title_equal=True text_equal=True` (33,741 chars both sides) · sid 52275 (1402): `title_equal=True text_equal=True` (60 chars both sides) — 1/1 PASS |
| S7 | year 1354 → 0 IDs · year 1350 → 0 IDs (both <0.5 s) — 2/2 PASS |
| S8 | "Resuming … pending IDs from backend queue" banner · exactly 3 processed (incl. sid 47190, 735 chars) · 0 errors · total 242→245 · pending 164→73 → 4/4 PASS |
| S9 | `final: total=245 y1400=35 y1402=56 integrity=ok dups=0` · crawl-status `pending_by_year` 1400=0, 1402=0 — 5/5 PASS |

**M4 SUMMARY: 36 PASS / 0 FAIL** (exit 0).

### 4.5 Evidence

- `evidence/pcm-ext07-m4-crawler-e2e.log` — full structured output of the definitive run
- `evidence/pcm-ext07-m4-step-logs/` — per-step crawler logs: `s1_1400.log`, `s2_1402.log`,
  `s3_re1400.log`, `s4_re1402.log`, `s6_live.txt` (live re-verification), `s7_1354.log`,
  `s7_1350.log`, `s8_resume.log`, `stability_probe.log` (F-M4-3 data)
- `deploy/pcm_ext07_m4_crawler_test.sh` — the runner (36 checks, idempotent, seed-restorable)
- `deploy/pcm_ext07_m4_probe.py` — char-distribution / PDF-only / floor probe
- `deploy/pcm_ext07_m4_floor.py` — archive-floor + year-stability probe

### 4.6 M4 verdict

**PASS** — the Python crawler (commit 6f7f2d2) against the live site, on real staging:
baseline years 1400=35 and 1402=56 exactly, every stored date valid Jalali and
year-consistent, re-runs fully idempotent, live text byte-identical on re-verification,
pending-queue resume works without auto-walk hijack, no duplicates, DB integrity ok.
Three genuine site characteristics documented (F-M4-1..3) instead of being hidden.

*Full acceptance narrative for M4: `PCM-EXT-07-CRAWLER-E2E-ACCEPTANCE.md` (M8).*
