# E6.3 Browser Acceptance — Findings (WS-A3/A4/A5/A6)

Run: 2026-11-16 (run 1 ~16:10Z, final full pass ~16:47Z). Harness: `_e63_a3_browser.py`
(Playwright + system Chrome, headless, 1440x900, locale fa-IR, `ignore_https_errors=True`
for radio self-signed TLS). Artifacts per test: `screenshots/T*.png`, `traces/T*.zip`
(Playwright trace), `network/T*.json` (API calls only). Run-1 copies preserved in `run1/`.

## Final tally: 14 PASS / 2 NOTE / 0 FAIL (16 tests) + T17 PASS (added in re-run)

| ID | Test | Result | Key evidence |
|----|------|--------|--------------|
| T01 | prod radio loads | PASS | site='دستیار صوتی رادیو معارف'; #rag-btn, admin btn, 3 product chips, #input/#send all present |
| T02 | prod radio picker (P6-1) | PASS | Settled 502 text: 'دریافت منابع ناموفق.' (class=rag-status err), 0 provider rows — graceful degradation |
| T03 | prod admin gate, wrong token | PASS | Rejected with 'رمز نادرست است.'; no token/topology leak (21.9s run 1: 181s due to long settle wait — fixed in harness) |
| T04 | prod admin gate + A5 UI | PASS | Gate ACCEPTS the E6.1 token on PRODUCTION ('/admin/status' 200) → **prod RAG_ADMIN_TOKEN == staging E6.1 token**. Panel settles: 'ارتباط با Registry برقرار نیست (سرور در دسترس نیست یا خطای شبکه).' — registry 502 (P6-1). Master-prompt UI section not rendered until registry reachable (BLOCKED by P6-1 for the full create/activate flow) |
| T05 | prod ask Q_FA «مضمون سوره حمد چیست؟» | NOTE | Answered in 5.9s via **legacy path** `POST /api/chat/stream` (network log). RAG path unavailable, UI does not advertise that — user sees a normal answer sourced from the legacy archive+local LLM |
| T06 | prod ask Q_WUDU «آداب وضو گرفتن پس از خواب چیست؟» | PASS | **G4 REPRODUCED IN PRODUCTION BROWSER**: bot says 'این موضوع در آرشیو رادیو یافت نشد' (abstention) **yet renders 5 citations** (e.g. 'كلام امام 1404-02-21 · 0:06:18–0:07:37 · radio-maaref 78%'). Abstention + irrelevant citations = misleading UI |
| T07 | prod legacy A6 «نقش خانواده و تربیت فرزند چگونه بیان شده؟» | NOTE | Honest empty: 'بر اساس منابع آرشیو رادیو معارف، نقش خانواده…' (no archive hit, no fabricated answer); 20s via legacy |
| T08 | prod radio direct fetch matrix | PASS | /api/rag/status=200, /api/rag/sources=502, /api/rag/admin/status (no tok)=404 (no leak), (+token)=200 |
| T10 | prod portal guest state | PASS | accTxt='مهمان', btnAuth='ورود / عضویت', navAdmin hidden, RAG entry visible; portal /api/corpora lists 6+ corpora (eiis, eiis-1000, mesbah, radio, radio-06b, radio-4b…) |
| T11 | prod portal RAG entry (P6-1) | PASS | Portal 'مدیریت RAG' modal settles 'دریافت منابع ناموفق.' — same graceful 502 as radio (shared registry dependency) |
| T12 | stg radio2 (172.20.1.53:8046) | PASS | Same matrix as prod: /status=200 /sources=502 /admin-nok=404 /admin+tok=200 |
| T13 | stg radio2 admin gate | PASS | Gate OK, panel settles 'ارتباط با Registry برقرار نیست…' (staging registry also unreachable from s53 — P6-1 applies to staging too) |
| T14 | stg rag2 (172.20.1.53:8048) | PASS | Loads (guest) |
| T15 | stg rag2 direct fetch | PASS | /status=200 /sources=502 — consistent with stg radio2 (same registry upstream) |
| T16 | A4 cross-UI consistency | PASS | Prod radio + prod portal + both staging UIs all share the same registry-failure signature (502). Live list comparison of the two UIs still BLOCKED by P6-1 (no UI can fetch the list) |
| T17 | RAG chat path direct probe | PASS | **DEFINITIVE P6-1 UI-PATH PROOF**: `POST /api/rag/chat/stream {message, rag_ids:['mizan']}` → HTTP 200 SSE opened, then after ~120s the stream ends with `data: {"error": "timed out", "code": "upstream_unreachable", "type": "error"}`. Meanwhile legacy `/api/chat/stream` answers in 2–6 s (T05/T06/T07). Two paths, two fates: RAG path (LiteLLM :4101 → gateway :8210) dead; legacy path (neo4j :4000 + s53-local vLLM) alive |

## Key findings

1. **P6-1 is the single root cause of every UI RAG-path failure.** Radio/portal UIs
   gracefully degrade to the 'registry unreachable' states; the user is NOT broken,
   only the RAG feature is. The iptables fix (s52 DOCKER-USER rule for
   s53→s52 :4101/:8200/:8210) unblocks all four UIs at once (evidence/E6.3/network/).
2. **Production is running the LEGACY pipeline for all chat.** All three mandated
   questions were answered via `/api/chat/stream` (neo4j + s53-local vLLM). The RAG
   pipeline (registry/gateway/LiteLLM) is fully configured but 100% blocked by P6-1.
3. **G4 (irrelevant citations on abstention) is live in production** — reproduced in
   the real browser (T06). This is a UX-correctness defect independent of P6-1.
4. **The E6.1 staging admin token IS the production RAG_ADMIN_TOKEN** (T04/T08).
   Good: A5 admin-gate is verifiable. Bad: a token minted on staging is valid in
   production — secrets are not environment-isolated (feeds WS-B3/B4).
5. **A5 Master-Prompt full flow (create/activate/reactivate) is BLOCKED in the UI**
   by P6-1 (panel cannot reach registry). The 12-step config acceptance (WS-C6) is
   the vehicle to prove that flow end-to-end directly on s52 where the registry is
   reachable.
6. **Staging (radio2/rag2) mirrors production exactly** — same 502 signature, same
   token, same graceful degradation. Staging is a valid P6-1 repro environment.

## Per-UI verdict (WS-A7 input)

- **radio.ai.ismc.ir** — READY_WITH_CONDITIONS: site works, legacy answers work,
  RAG features blocked by P6-1 (owner firewall action), G4 UX defect.
- **rag.ai.ismc.ir** — READY_WITH_CONDITIONS: portal works (guest + corpora list),
  RAG picker blocked by P6-1.
- **radio2/rag2 (staging)** — READY_WITH_CONDITIONS (same as prod; plus: no public
  DNS/TLS for the staging domains yet — WS-C4).

## Files

- `results.json` — machine-readable results (final run)
- `run1/` — first-run artifacts (kept for comparison; run1 T02/T04/T11/T13 were
  NOTE/FAIL due to loading-state wait bugs, fixed in harness re-run)
- `screenshots/`, `traces/`, `network/` — per-test raw evidence (no secrets in any file)
