# E6.3-B3 — Secret Exposure Audit (Consolidated)

Date: 2026-11-16 (UTC) · Operator: E6.3 execution · Scope: Multi-RAG (radio.ai.ismc.ir / rag.ai.ismc.ir + staging radio2/rag2/corpus2)
Rule honored: **secret NAMES, locations, lengths and risk only — NO secret values anywhere in this tree** (all masked).

## 0. Surfaces audited (all five CLOSED)

| # | Surface | Method | Evidence file |
|---|---------|--------|---------------|
| 1 | Local filesystem (workstation) | masked scanner over `evidence/`, workspace, `../dedicated-rag`, `../rag` | `cmd-1794858532578.txt` (scanner run), findings below |
| 2 | Git history (2 repos) + pushed commit + tarball | `git rev-list`, `git log --all -S<name>` ×5, `ls-tree` at f1d43fa, bsdtar extract + content scan | `_e63_b3_local_scan.ps1`, `_e63_b3_f1d43fa_check.ps1`, `_e63_b3_tgz_scan.ps1` outputs |
| 3 | s52 production (RAG core, 172.30.0.133) | per-container env names+lengths, host .env perms, registry DB perms, `ss -ltn`, unauthenticated probes | `e63-b3-envs-s52-20261116-195354.log` (48,464 B) |
| 4 | s53 UI host (172.20.1.53) | same + host .env inventory + `.env.radio2` candidate | `e63-b3-envs-s53-20261116-200055.log` (80,854 B), `e63-b3-envs-s53b-20261116-200614.log` (13,241 B) |
| 5 | Public/edge responses (6 domains, from workstation) | read-only GETs, `-k` (G5 self-signed) | `e63-b3-public-probes-20261116.log` |

## 1. Findings register (name / location / risk / remediation)

### 1.1 Local workstation (Windows operator box)

| ID | Finding | Risk | Remediation |
|----|---------|------|-------------|
| B3-L1 | **Real LiteLLM master key `sk-…` (len 67) present in `_tmp_e61_deploy_gateway.sh` lines 30/32** (workspace worktree, **UNTRACKED**, never pushed) | HIGH — raw value on local disk + possibly seen in past terminal scrollback. NOT git/network-exposed (see B3-G1). | Treated as leaked → B1 rotation (see `E6.3-B` §B1). Local file redacted in place 2026-11-16 (value no longer exists on disk). |
| B3-L2 | Evidence tree masking: 25 masked matches / 37 files in `evidence/E6.3/**` | NONE (masking held; no raw values) | None — scanner re-run after each evidence fetch as standing practice. |
| B3-L3 | No raw `rc_…` consumer-key literal anywhere on the workstation (0 hits, all worktrees) | NONE | None. |

### 1.2 Git (both repos + pushed commit + tarball)

| ID | Finding | Risk | Remediation |
|----|---------|------|-------------|
| B3-G1 | `persian-corpus-toolkit` (100 commits): no `.env*` ever tracked. Last pushed commit **f1d43fa verified CLEAN** — exactly 6 added files (2 diag PNGs, `docs/reports/E6.2-PRODUCTION-ACCEPTANCE.md`, `e62_portal_index.html`, `e62_radio_index.html`, `pct-code-208.tgz`); `git ls-tree -r f1d43fa` has no `_tmp*`/`.env*`. The `-S` count changes for `x-consumer-key`/`LITELLM_MASTER_KEY` came from the E6.2 report doc (secret **names** only). | NONE for key material | None. |
| B3-G1b | `pct-code-208.tgz` content-scanned (187 files, masked): 16 hits, **ALL false positives** — `flask-cors` contains literal substring `sk-`; Python vars `src_blocks`/`src_snapshot`/`src_path` contain `rc_`; doc prose about password/secret scans. No real token. | NONE | None. |
| B3-G2 | `../dedicated-rag` (23 commits): no `.env` ever tracked; `.gitignore` present. `-S` hits are code/doc **name references** only: `x-consumer-key` (4 commits), `REGISTRY_ADMIN_TOKEN` (5), `GATEWAY_SERVICE_KEY` (2), `LITELLM_MASTER_KEY` (1), `RAG_ADMIN_TOKEN` (0). | NONE | None. |

### 1.3 s52 production

| ID | Finding | Risk | Remediation |
|----|---------|------|-------------|
| B3-S1 | World-readable (644/664) host `.env` files: `kong-gateway/.env`, `flowise-deployment/.env`, `graph-rag/.env`, `ai_ismc_ir/.env`, `benchmark/.env`, `automated/WordPress-…/.env`, `Flowise/docker/.env` (11,792 B) + `.env.` + `.env.example`. Any local user/process on s52 can read these (other products). | MEDIUM | `chmod 600` (owner action, no downtime, no data change). |
| B3-S2 | **Prod registry DB `/home/saber/dedicated-rag-registry/data/registry/rag-registry.db` is `-rw-r--r--` (352,256 B) in a `drwxrwxr-x` dir** — world-readable. Consumer/provider keys are stored hashed, so impact is limited, but it is still a secret-bearing file. | MEDIUM | `chmod 600` on the DB (owner action; safe while service holds the file open). |
| B3-S3 | Large multi-product 0.0.0.0 socket surface (65 containers: 8200/8210/4101/4102/8100/8443/9090/6379/5433/3306/22/80/443/…). | LOW (context) | Already mitigated by the P6-1 firewall closure (s53→s52 all RAG ports CLOSED except :4000). Keep P6-1 enforced. |
| B3-S4 | Unauthenticated probes: `:8200/health` 200 (`enabled/producers/version` only), `:8200/metrics` 200 (Prom text, no secrets), `:8200/api/rag-registry` 401, `:8200/consumers` 401, `:8210/health` 200, `:8210/v1/models` 401, `:4101/health/liveliness` 200, `:4101/v1/models` 401. | NONE | **No secret leakage in any unauthenticated response body.** As designed. |
| B3-S5 | Config note: `REGISTRY_ALLOWED_HOSTS` empty (0 chars) on prod registry; internal reach controlled via `REGISTRY_INTERNAL_NETS` + `REGISTRY_ALLOW_LOOPBACK`. | LOW (info) | Optional: populate the allow-list when provider base URLs change. |
| B3-S6 | `litellm-personal`: `LITELLM_MASTER_KEY` len 67, `LITELLM_SALT_KEY` len 64 — **proven distinct values** (B1 analysis). | LOW (context) | Limits blast radius of a leaked master key (cannot derive salt hash / other keys). See B1. |

### 1.4 s53 (UI host) — staging stack + host

| ID | Finding | Risk | Remediation |
|----|---------|------|-------------|
| B3-U1 | `rag2-staging-core/secrets/` **directory is `drwxrwxrwx` (777)** — file *names* listable world-wide; the key files themselves are 600 (`portal-key`, `radio-key`, 46 B). | MINOR | `chmod 700 secrets/` (owner action). |
| B3-U2 | Staging `litellm.yaml` (600) contains 6 inline `api_key` + `x-consumer-key` pairs — **by-design mirror of the production B2 defect**; staging is the B2 fix test vehicle. | BY DESIGN (test vehicle) | Fixed by the B2 procedure (file-based keys / env, no plaintext in model config). |
| B3-U3 | World-readable (664) secret-bearing files, adjacent products: **RAG-family**: `rag-portal/.env.new` (466 B), `rag-portal/.env.bak.v2kg2-…` (388 B), `rag2-staging/.env.new` (466 B), `backups/deploy-20261016/rag-portal/.env` + `.env.new`. **Other**: `surfsense/.env` (24 KB), many `langgraph-neo4j-qa/.env.*.bak`, `iranseda-crawler-golang-` ×3, `graph-rag/.env`, `qa-knowledge-graph-pipeline/.env`, `open-notebook/.env`, `sources-portal/.env.sources`; `backups/m25_secret_backup/` dir 775. | MEDIUM (RAG-family: stale rag-portal configs) / LOW (others) | `chmod 600` the RAG-family files first; batch `chmod 600` for the rest (owner action, no downtime). |
| B3-U4 | `.env.radio2` candidate **REFUTED**: `/home/saber/saberprojects/radio2-staging/.env.radio2` is 600; masked key-grep matched only two descriptive comment lines. No key material inlined in comments. | NONE | None. |
| B3-U5 | Other-product context flags: weak/short DB passwords (`rag2_auth_db` 4 ch, `ragportal_auth_db` 4 ch, `rag2_db` 9, `ragportal_db` 9, `taghrir_feedback_db` 7, `mesbah_feedback_db` 6, `eiis_feedback_db` 22, `tyk-postgres` 16, `iranseda-mysql` root 8); `open-webui` + `mock-open-webui` `WEBUI_SECRET_KEY` **empty**; `h200-public-tunnel` (cloudflared) RUNNING; staging litellm `:14101` on 0.0.0.0; `tyk-portal` unhealthy. | LOW (out of RAG scope) | Owner context; recommended for their respective product owners. |
| B3-U6 | `radio_api` (prod radio UI on s53) `RAG_ADMIN_TOKEN` len 46 vs staging 43 — prod carries the old staging-era admin token (known carry-over; value never printed). | LOW (context) | Rotate with the B2 window (new token generated at rotation time). |

### 1.5 Public / edge responses (6 domains, unauthenticated)

| ID | Probe | Result | Risk |
|----|-------|--------|------|
| B3-P1 | `rag.ai.ismc.ir/api/health` | 200 — flags only (gpu/v3), no secrets | NONE |
| B3-P1 | `rag.ai.ismc.ir/api/v1/models` | 404 (route not exposed) | NONE |
| B3-P1 | `radio.ai.ismc.ir/api/health` | 200 — see B3-P2 | — |
| B3-P1 | `radio.ai.ismc.ir/api/rag/status` | 200 — `consumer_id:"radio"` (by design) | NONE |
| B3-P1 | `radio.ai.ismc.ir/api/v1/models` | **401** "Invalid service token" — gated | NONE |
| B3-P1 | `radio.ai.ismc.ir/api/programs` | 200 — public program catalog (by design) | NONE |
| B3-P3 | `radio2/rag2/corpus2.ai.ismc.ir` (root) | all **307** redirects — reachable, no body exposure | NONE |
| B3-P2 | radio `/api/health` response contains the **internal LiteLLM URL `http://172.30.0.133:4000/v1`** + model name — internal topology disclosure to any internet visitor. | LOW | Strip `litellm` (and optionally `gen_model`) from the public health payload (small code change in `rag-radio/backend/api.py` health endpoint). |

**No secret value appeared in any public or unauthenticated response on any surface.**

## 2. Incident record (this E6.3 execution — documented, not hidden)

| ID | Incident | Disposition |
|----|----------|-------------|
| B3-I1 | C6 v1: a consumer `api_key` was printed to the operator terminal exactly once at creation (API shows-once design). | Consumer `e6-c6-temp` **disabled** same run; the fetched log was sanitized (value never persisted to evidence). Residual: possible s53 terminal scrollback — owner to clear shell history if desired. |
| B3-I2 | B4-prod: the in-run "online" registry backup used `sqlite3.connect("file:…?mode=memory", uri=True)` → **in-memory destination, no file written**; python rc=0 so the guard passed. | Mutation impact = one additive consumer row (`e6-b4-prod`), **disabled in the same run** and audit-logged. Prior full backup `e63-20261116-153338` (litellm SQL 1.72 MB + registry-data 332 K) predates the mutation by ~4 h and is in `/home/saber/backups/`. Lesson codified: on-disk backup must use `sqlite3.connect(dest)` without a `mode=memory` URI. |
| B3-I3 | Prod temp consumer `e6-b4-prod` remains in the prod registry (disabled) — the API has no delete endpoint. | Acceptable; audit-trail complete. Documented for transparency. |

## 3. Verdict (B3)

**B3 = COMPLETE — no secret material exposed in git (any repo/commit/tarball), the evidence tree, or any public/unauthenticated response.**

Residual exposures requiring action (all tracked in the master report):
1. **B3-L1** real master key in untracked local file → B1 (rotation; local copy redacted 2026-11-16).
2. **B2 defect** — plaintext `x-consumer-key` (len 46) in prod LiteLLM model config (6 models) → B2 atomic-rotate procedure.
3. **B3-S1/B3-S2/B3-U3/B3-U1** file-permission hardening on s52/s53 (owner one-liners, no downtime).
4. **B3-P2** public health payload internal-URL disclosure (LOW, small code fix).
