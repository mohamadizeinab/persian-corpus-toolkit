# E6.3 A2 — Connectivity matrix s53 → s52 (network evidence)

**Date:** 2026-11-17 (probes 01:22:08Z – 01:23:57Z, host `llm` = s53)
**Scope:** A2 of WS-A — verify exactly which RAG ports on s52 (172.30.0.133) are
reachable from s53 (172.20.1.53), both host-side and container-side.

## 1. Raw probes (42-port scan + conn probe)

| Probe | Result |
|---|---|
| 42-port TCP scan s53→s52 (`e63-b2-s53-fwscan-20261117.log`) | **OPEN: only `4000` and `8000`**. CLOSED/DROP: 22, 81, 444, 2222, 3001-3006, **4101**, 4102, 5055, 5070, 5433, 5435, 5678, 6379, 7777, 7779, 7810, **8100/8101/8102**, **8200**, **8210**, 8888, 9001, 9090, 9099, 9100, 18xxx range |
| Host TCP 4000 | OPEN, HTTP 200 in 0.0056s (learn-lite-llm — a DIFFERENT product) |
| Host TCP 8200 (registry) | **FAIL** (P6-1) |
| Host TCP 8210 (gateway) | **FAIL** (P6-1) |
| Host TCP 4101 (RAG LiteLLM) | **FAIL** (P6-1) |

## 2. What is open — and what it is NOT

- `:4000` → `learn-lite-llm-litellm-1` (port mapping 4000/tcp → 0.0.0.0:4000 on s52).
  Proven to be a **different product's** LiteLLM: it rejects the RAG master key with
  `401 token_not_found_in_db` (`e63-b2-s52-who4000-20261117.log`,
  `e63-b2-s52-litellm-probe-20261117.log`).
- `:8000` → `cms_nginx` (another product's public web tier).
- The RAG chain ports **:4101 (litellm-personal), :8200 (registry), :8210 (gateway),
  :4102 (llmhub-public) are all DROPped** by the s53→s52 firewall = **P6-1/P6-1b**.

## 3. Container-side corroboration

From inside `radio_api` (15.15.12.18, graph-rag_default) and `ragportal_api`
(15.15.15.5, rag-portal_default) — the prod UI containers:
- `RAG_LITELLM_URL=http://172.30.0.133:4101/v1` (both) → chat POST hangs 120s
  (RAG_TIMEOUT_S) → `{"error":"timed out","code":"upstream_unreachable"}`
  (browser T17, 2026-11-16T16:53:35Z — pre-dates B2 changes).
- `RAG_REGISTRY_URL=http://172.30.0.133:8200` → picker `/api/rag/sources` = 502.

Staging containers point at their own staging core (15.15.12.1:14101/18200,
15.15.19.1:14101/18200) — fully reachable on s53 (that is why the staging B2 chain
is green end-to-end).

## 4. Conclusion

- **A2 verdict: connectivity to the RAG core from s53 is BLOCKED by firewall for
  exactly the 3 RAG ports** (4101/8200/8210); everything else on s52 is also closed
  (correct default posture). The two OPEN ports belong to other products.
- This is the network-level proof that P6-1b is a **firewall rule gap**, not a
  service fault: every RAG component on s52 is up + healthy (C3 audit), yet s53
  cannot reach any of them.
- Owner fix (see `../security/e63-b2-p6-1b-public-rag-blocked.md` §4):
  `ALLOW TCP 172.20.1.53 → 172.30.0.133:4101` (required), `:8200` + `:8210`
  (recommended for picker + direct gateway calls).

## 5. Evidence files

| File | Content |
|---|---|
| `../security/e63-b2-s53-fwscan-20261117.log` | 42-port scan (above) |
| `../security/e63-b2-s53-conn-20261117.log` | host+container probes, UI env, NAT topology |
| `../security/e63-b2-s53-incont-20261117.log` | in-container timing probes |
| `../security/e63-b2-s53-matrix-20261117.log` | prod/staging target matrix |
| `../browser/network/T17.json` | browser RAG-chat SSE capture (120s timeout) |
| `../security/e63-b2-p6-1b-public-rag-blocked.md` | full diagnosis + owner rule set |

**Note:** the original A2 logs of 2026-11-16 (`_e63_a2*.sh` runs) were superseded by
these 2026-11-17 re-probes (identical result, fresher timestamps) and are not kept
separately; the harness scripts `_e63_a2_s53.sh`/`_e63_a2b_s53.sh` remain in the repo
root for re-run (gitignored scratch).
