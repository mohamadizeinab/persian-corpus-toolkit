# P6-1b — Public RAG chat path dead in production: s53→s52:4101 firewall DROP

**Status:** BLOCKED — owner firewall action required
**Discovered:** 2026-11-17 (E6.3 B2 verification phase)
**Severity:** HIGH (public RAG chat non-functional on both radio.ai.ismc.ir and rag.ai.ismc.ir)
**Pre-existing:** YES — not a B2 regression (see §5)
**Owner action:** open TCP 172.20.1.53 (s53) → 172.30.0.133:4101/tcp (litellm-personal, RAG); strongly recommended also :8200/tcp (registry, picker) and :8210/tcp (gateway, future direct path)

---

## 1. Symptom

Every public RAG chat request (`POST /api/rag/chat/stream` on radio and rag portal UIs)
hangs exactly **120 seconds** and then returns:

```
HTTP 200
data: {"error": "timed out", "code": "upstream_unreachable", "type": "error"}
```

Observed 3+ times, both products, final confirmed run 2026-11-17T01:23 UTC:

| Product  | Endpoint                      | Time      | Result                          |
|----------|-------------------------------|-----------|---------------------------------|
| radio    | /api/rag/chat/stream (mizan)  | 120.134s  | upstream_unreachable (79B SSE)  |
| rag      | /api/rag/chat/stream (mizan)  | 120.126s  | upstream_unreachable (79B SSE)  |

120s = `RAG_TIMEOUT_S` (httpx timeout in `rag_proxy.py`), i.e. the UI container's
outbound HTTP call to its configured LiteLLM never receives a response.

The legacy radio path (`/api/chat/stream`, Neo4j + :4000 litellm) answers in 2–6s —
"two paths, two fates" (T17, `evidence/E6.3/browser/results.json`).

## 2. Root cause (fully proven, 6 independent proof points)

**The prod UI containers on s53 point `RAG_LITELLM_URL` at `http://172.30.0.133:4101/v1`,
but the s53→s52 firewall DROPs :4101. The only litellm port open from s53 is :4000 —
which belongs to a DIFFERENT product's LiteLLM instance.**

### Proof point 1 — s52 port ownership (`e63-b2-s52-who4000-20261117.log`)

`s52 docker ps` port column:

| Container                  | Published ports                          |
|----------------------------|------------------------------------------|
| `litellm-personal`         | `4000/tcp -> 0.0.0.0:4101`  ← **THE RAG LiteLLM** |
| `learn-lite-llm-litellm-1` | `4000/tcp -> 0.0.0.0:4000`, `4010/tcp -> 0.0.0.0:4010` |
| `llmhub-litellm-public`    | `4000/tcp -> 172.30.0.133:4102` |
| `rag-keyfwd` / `rag-gateway` / `rag-registry` | no published ports |

So on s52: **:4101 = RAG litellm** (11 models incl. rag-mizan/rag-fiqh/rag-general,
portal-rag-*, q1-embedding-*), **:4000 = a different LiteLLM** (learn-lite-llm product).

### Proof point 2 — :4000 is NOT our LiteLLM (`e63-b2-s52-4000probe`, see s52-probe logs)

- `GET /v1/models` via :4101 with the rotated master key (digest 8aad12d40c26d89a, len 67)
  → **200**, 11 models.
- `GET /v1/models` via :4000 with the same key → **401 `token_not_found_in_db`**
  (Key Hash mismatch) — a different LiteLLM database.
- `POST /v1/chat/completions` rag-mizan via :4000 → **401 in 0.04s**.

Conclusion: repointing the UI to :4000 is impossible — it is another product's
gateway and would also fail auth.

### Proof point 3 — prod UI container env (s53, `e63-b2-s53-conn-20261117.log`)

```
radio_api      (15.15.12.18, graph-rag_default):  RAG_LITELLM_URL=http://172.30.0.133:4101/v1
ragportal_api  (15.15.15.5,  rag-portal_default): RAG_LITELLM_URL=http://172.30.0.133:4101/v1
              RAG_REGISTRY_URL=http://172.30.0.133:8200
              RAG_TIMEOUT_S=120
```

### Proof point 4 — in-container connectivity from s53 (`e63-b2-s53-incont-20261117.log`)

From inside both `radio_api` and `ragportal_api`:

| Target                    | TCP (10s)       | HTTP /health/liveliness     |
|---------------------------|-----------------|-----------------------------|
| 172.30.0.133:4101         | **TIMEOUT**     | URLError after 15s          |
| 172.30.0.133:4000         | OPEN 0.00s      | **200 "I'm alive!" 0.01s**  |
| 172.30.0.133:8200         | **TIMEOUT**     | —                           |

### Proof point 5 — 42-port firewall scan from s53 (`e63-b2-s53-fwscan-20261117.log`,
01:22 UTC)

From the s53 host toward 172.30.0.133, **only 2 of 42 probed ports are OPEN**:

- **4000** (learn-lite-llm — wrong product)
- **8000** (cms_nginx)

All of the following are CLOSED-DROP: 22, 81, 444, 2222, 3001–3006, **4101**, 4102,
5055, 5070, 5433, 5435, 5678, 6379, 7777, 7779, 7810, 8087, 8088, 8100, 8101, 8102,
**8200**, **8210**, 8888, 9001, 9090, 9099, 9100, 18050, 18060, 18080, 18001, 18090,
18092, 18788, 18789, 18790.

### Proof point 6 — s52 side never sees the public requests
(`e63-b2-s52-logwindow-20261117.log`, 01:29 UTC)

While the 01:23 UTC public smoke was running (120s × 2), the `rag-keyfwd` access log
window (last 15 min) contains **no POST from the public UIs** — only our own 01:28
s52-local probes. The requests die in the firewall before reaching s52.

## 3. Why this is PRE-EXISTING (not a B2 regression)

- T17 (browser acceptance, `evidence/E6.3/browser/results.json`,
  **2026-11-16T16:53:35Z — before any B2 change**) already recorded the identical
  symptom: SSE opened (HTTP 200), then error event after upstream timeout, 121.5s.
- The B2 changes (key forwarder + consumer-key rotation) are all **on s52 internal
  paths** (keyfwd :8211/:8212 inside `litellm-personal-net`, gateway :8210, registry
  :8200). Nothing on s52 changed the firewall or the UI containers' env.
- Counter-evidence (chain is GREEN from s52 itself, fresh 2026-11-17 ~01:28 UTC,
  `e63-b2-s52-litellm-probe-20261117.log`):
  - `POST /v1/chat/completions` model=rag-mizan via :4101 → **200 in 21.4s and 30.5s**,
    real Persian answers citing Tafsir al-Mizan.
  - `rag-keyfwd` access log: `POST rag-mizan 200` ×2, `GET /v1/models 200`.
  - Old consumer keys dead (401×3); DB `extra_headers` x-consumer-key count = 0.

So: the RAG chain s52-side works end-to-end; the public path is severed solely by the
firewall between s53 and s52 on the ports the prod UI env expects.

## 4. Owner action required (exact)

On the s53→s52 firewall (or whatever filter sits between 172.20.1.53 and 172.30.0.133):

1. **Required:** `ALLOW TCP 172.20.1.53 → 172.30.0.133:4101`  (litellm-personal, RAG chat path)
2. **Recommended:** `ALLOW TCP 172.20.1.53 → 172.30.0.133:8200`  (rag-registry — the Settings→RAG picker currently 502s, T02/T08/T11)
3. **Recommended:** `ALLOW TCP 172.20.1.53 → 172.30.0.133:8210`  (rag-gateway — enables the direct gateway path and B4-style external authz checks)

No code, image, env, or container change is needed for any of this. No rollback
concern: the firewall rule only ADDS reachability to ports already bound on s52.

## 5. Verification after the owner opens the ports

1. From s53: `curl -sS -m 5 http://172.30.0.133:4101/health/liveliness` → expect `"I'm alive!"`
2. Re-run `_e63_b2_public_smoke.ps1` (local) → expect both products to stream a full
   RAG answer (SSE `delta` events, final answer, no `upstream_unreachable`), in the
   20–60s range (model inference time), NOT 120s.
3. In the browser (radio.ai.ismc.ir Settings → RAG picker): expect the source list
   to load (registry :8200 reachable) instead of 502.
4. s52 confirmation: `docker logs rag-keyfwd` shows new `POST /v1/chat/completions ... 200`
   entries during the smoke; gateway/registry access logs show the UI's consumer verify calls.

## 6. Evidence index (this directory)

| File | What it proves |
|------|----------------|
| `e63-b2-public-smoke-20261117.log` | Final public smoke: 120.1s × 2 → upstream_unreachable |
| `e63-b2-s52-who4000-20261117.log` | s52 port→container ownership (4101 = RAG litellm, 4000 = learn-lite) |
| `e63-b2-s53-conn-20261117.log` | Prod UI container env (RAG_LITELLM_URL=:4101) + container IPs |
| `e63-b2-s53-incont-20261117.log` | In-container probes: 4101 timeout, 4000 instant |
| `e63-b2-s53-matrix-20261117.log` | 5-port matrix from s53 host |
| `e63-b2-s53-fwscan-20261117.log` | 42-port scan: only 4000+8000 open |
| `e63-b2-s52-litellm-probe-20261117.log` | s52-local chain GREEN (200 × 2, 21.4s/30.5s) |
| `e63-b2-s52-ragids-20261117.log` | Registry consumer/rags data intact post-rotation |
| `e63-b2-s52-logwindow-20261117.log` | No public POSTs ever reach keyfwd |
| `e63-b2-prod-deploy-fwd-20261117-001720.log`, `e63-b2-prod-patch-20261117-002205.log`, `e63-b2-prod-rotate-20261117-003100.log`, `e63-b2-prod-repair-20261117-003926.log` | B2 prod chain steps (all green) |
| `e63-b2-prod-backup.log` | Pre-change backup manifest (e63-b2-20261117-000829) |
