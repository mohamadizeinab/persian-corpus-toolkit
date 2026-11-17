# E6.3 C3 — Docker Standardization Audit (s52 + s53)

**Date:** 2026-11-17 (s52 audit 02:04:02Z, s53 audit 02:10:30Z + 02:11:20Z)
**Scope:** C3 of WS-C (E7.0) — read-only audit of container deployment patterns across
both servers: network modes, restart policies, image pinning, mount strategies, metrics
exposure, and operational incidents observed during E6.2/E6.3.
**Method:** read-only `docker inspect`/`docker ps`/`docker images` + GET probes on
`/metrics`. No container was started, stopped, or modified.

**Raw logs:** `e63-c3-docker-audit-s52-20261117.log`, `e63-c3-docker-audit-s53-20261117.log`,
`e63-c3b-docker-audit-s53-20261117.log` (this directory).

---

## 1. Inventory — s52 (RAG core, 172.30.0.133 / 172.20.1.52)

| Container | Network | Restart | State | Image (short) |
|---|---|---|---|---|
| `rag-gateway` | **host** | unless-stopped | running/healthy (PID 3188997) | `ef9da642a15a` |
| `rag-registry` | **host** | unless-stopped | running/healthy (PID 92415) | `3701f33aed37` |
| `rag-keyfwd` | litellm-personal-net | (n/a — audit template gap) | running | `979e5a8a5684` (python:3.12-alpine) |
| `litellm-personal` | litellm-personal-net | unless-stopped | running | `c2eea0ab9754` (**ghcr.io/berriai/litellm:latest** — UNPINNED) |
| `litellm-personal-db` | litellm-personal-net | unless-stopped | running | `264e9dea325c` (postgres:13) |
| `mizan-rag` | dedicated-rag_default | unless-stopped | running/healthy (PID 3097149) | `230c333c1a5a` |
| `fiqh-rag` | dedicated-rag_default | unless-stopped | running/healthy (PID 3127659) | `3045c62a782c` |

Commands:
- gateway: `python -m drag.gateway serve --host 0.0.0.0 --port 8210`
- registry: `python -m drag.registry serve --host 0.0.0.0 --port 8200`
- keyfwd: `python3 /opt/keyfwd/rag_keyfwd.py --listen 0.0.0.0:8211 --consumer radio --listen 0.0.0.0:8212 --consumer portal --keyfile /opt/keyfwd/keys.json --upstream http://10.240.17.1:8210 --timeout 300`
- mizan/fiqh: `python -m drag.cli serve --host 0.0.0.0 --port 8100`
- litellm: `--port 4000` (host-publish → **0.0.0.0:4101** — THE RAG LiteLLM; 4000→:4000 is a DIFFERENT product's litellm)

Mounts (s52):
- rag-registry: `/home/saber/dedicated-rag-registry/data/registry → /data`, `openapi → /app/openapi` (directory mounts — good)
- rag-keyfwd: `/home/saber/e63-b2-keyfwd → /opt/keyfwd:ro` (directory mount — good; chosen deliberately after the inode-pinning incident)

### Metrics exposure (s52)
| Endpoint | Result |
|---|---|
| `http://127.0.0.1:8210/metrics` (gateway) | **404** (HTML 404 page — route not reachable from host at /metrics) |
| `http://127.0.0.1:8200/metrics` (registry) | **200** — `rag_up 1`, `rag_providers_total …` |

**Finding C3-1:** the gateway exposes `/metrics` (see `drag/gateway/api.py` L213) but the
probe on the host port returns 404 — the Flask route is mounted but a URL-prefix or
wsgi entrypoint mismatch makes it unreachable at the bare path. Registry metrics work.
Until fixed, gateway metrics cannot be scraped (PCM-10-style Grafana would show rag
gateway DOWN).

### Registry DB perms (B3 finding recheck)
| File | Perms | Size |
|---|---|---|
| **live** `/home/saber/dedicated-rag-registry/data/registry/rag-registry.db` | **644** | 380928 |
| backup `e63-20261116-153338/registry-data…/rag-registry.db` | 644 | 335872 |
| backup `e63-b2-20261117-000829/rag-registry.db` | **600** | 368640 |

**Finding C3-2 (MEDIUM, OPEN):** the live registry DB (consumers, keys, audit) is still
world-readable (644) on s52. The B3 secret audit already flagged this; E6.3 B2 backup
copy is 600, but the **live** file was not tightened (fix = `chmod 600` — owner/sudo
step, out of E6.3 scope per Part 7 allowed-actions: security fix with backup is allowed,
but the file is in a container-mapped dir owned by `saber`; `chmod 600` can be run by
`saber` if the user owns it — recorded as owner follow-up with backup-first procedure).

### Image pinning (s52)
| Tag | ID | Note |
|---|---|---|
| `rag-gateway:0.1.0` | `ef9da642a15a` | **same image as** `rag-gateway:0.2.0-e61-da40c4d` (dual-tag of the E6.1 hotfix build) |
| `rag-gateway:0.2.0-e61-da40c4d` | `ef9da642a15a` | dual-tag |
| `rag-registry:0.1.0` | `3701f33aed37` | |
| `dedicated-rag:0.1.0` | `3045c62a782c` | |
| `drag-ingest:0.1.0` | `0d5af37b6a18` | |
| **`ghcr.io/berriai/litellm:latest`** | `c2eea0ab9754` | **UNPINNED `:latest` tag in use by litellm-personal** |
| **`python:latest`** | `4547a58e79e7` | **UNPINNED base present** |
| `python:3.12-alpine` | `979e5a8a5684` | keyfwd base (pinned) |
| `postgres:13` | `264e9dea325c` | pinned version |

**Finding C3-3:** `litellm-personal` runs `ghcr.io/berriai/litellm:latest` (float).
A future `docker pull` + recreate silently upgrades the RAG chat backbone.
Recommendation: pin to the observed digest `c2eea0ab9754…` (or a dated tag).

**Finding C3-4 (deployment hygiene):** the running gateway image is the **E6.1
hotfix** code, but it was historically applied via `docker cp` (file-level hotfix) —
the image tag story (0.1.0 vs 0.2.0-e61-da40c4d both = `ef9da642a15a`) shows a
rebuild/tag was eventually done, yet the tag scheme does not record what the RUNNING
container started from. Recommendation: single tag = git short SHA
(`rag-gateway:0.2.0-<sha>`) and compose references the tag, never a bare `latest`.

---

## 2. Inventory — s53 (UI host `llm`, 172.20.1.53)

| Container | Network | Restart | State | Image (short) | Host ports |
|---|---|---|---|---|---|
| `radio_api` (prod radio) | graph-rag_default | unless-stopped | running | `00195a93a455` (mrbaqeri/qa_lang_neo4j_mesbah:1.0.0) | none (in-net) |
| `ragportal_api` (prod portal) | rag-portal_default | unless-stopped | running | `03672141264d` (rag-portal-ragportal_api:latest) | **8000/tcp→8033** |
| `radio2_api` (staging radio) | graph-rag_default | unless-stopped | running/healthy | `00195a93a455` (same prod radio image) | none (in-net) |
| `rag2_api` (staging portal) | rag2-staging_default | unless-stopped | running | `eb9278462bfb` (rag2-staging-api:latest) | **8000/tcp→8047** |
| `rag2-staging-core-registry-1` | (staging net) | — | healthy | `rag-registry:0.1.0` = `3701f33aed37` | 18200 |
| `rag2-staging-core-gateway-1` | (staging net) | — | healthy | `rag-gateway:0.1.0` = `ef9da642a15a` | 18210 |
| `rag2-staging-core-litellm-1` | (staging net) | — | healthy | `ghcr.io/berriai/litellm:main-latest` | 14101 |
| `rag2-staging-core-synth-provider-1` | (staging net) | — | healthy | `rag-registry:0.1.0` image repurposed as synthetic provider | 18101 |
| staging `rag2_frontend`, `radio2_frontend` | nginx:alpine | — | running | | 8045 / 8046 (behind nginx) |
| `vllm-embedding-06b` | `vllm/vllm-openai:v0.11.0` | | running | | |
| `vllm-qwen38`, `vllm-qwen38-gpu1` | `vllm/vllm-openai:nightly` | | running | | **:8000 no auth** (G5) |
| `tyk-*` suite | tyk v5.15.0 | | running | | `tyk-portal` **unhealthy** (pre-existing, unrelated to RAG) |
| `mock-litellm` | litellm:main-latest | | running | | staging test double |

**Staging keyfwd (B2 prototype):** runs as a **bare host process** (NOT a container):
`python3 /home/saber/saberprojects/rag2-staging-core/e63-b2/bin/rag_keyfwd.py --listen 127.0.0.1:18211 --consumer radio --listen 127.0.0.1:18212 --consumer portal --keyfile …/e63-b2/keys.json` (pid 1159368).
**Finding C3-5:** prod keyfwd = container (good); staging keyfwd = bare process (fine
for a staging prototype, but has no restart policy). Documented as intentional.

### Mounts — the inode-pinning pattern (s53)
| Container | Mounts |
|---|---|
| `radio_api` (prod) | **bind FILE** `/home/saber/saberprojects/radio-rag-service/api.py → /app/app/api.py`, **bind FILE** `…/rag_proxy.py → /app/app/rag_proxy.py` |
| `radio2_api` (staging) | **bind FILE** `/home/saber/saberprojects/radio2-staging/api.py → /app/app/api.py`, **bind FILE** `…/rag_proxy.py → /app/app/rag_proxy.py` |
| `ragportal_api`, `rag2_api` | (mounts not captured — template error; image-level code only) |

**Finding C3-6 (HIGH, incident-proven):** prod + staging radio containers pin **individual
files** as bind-mounts. Docker captures the bind-mount source **inode** at container
start; any editor save that replaces the file (new inode) leaves the container serving
the OLD code until the container is recreated. This caused a real E6.3 staging incident
(same symptom as E6.1's docker-cp confusion).
**Mitigation (applied pattern):** the UI repos are not in VCS yet (C1 blocked), so the
operational rule adopted in E6.3 is: after editing a mounted file,
`docker compose up -d --force-recreate <svc>`; the durable fix is either directory
mounts (`backend/ → /app/app`) or a real image build per release. Recorded as an
owner decision item (needs new image pipeline → Part 7 "needs approval").

### Staging registry DB (WAL host-poison recheck)
| File | Perms | Size |
|---|---|---|
| `/home/saber/saberprojects/rag2-staging-core/data/rag-registry.db` (staging live) | 644 | 90112 |
| `…/e63-b2/backup/rag-registry.db.pre-fix-20261116-230629` | 644 | 73728 |

**Finding C3-7:** the earlier "WAL host-poison" incident (staging registry DB copied
to host without `-wal`/`-shm`, then container recreated on stale host file) is closed:
current staging DB is 90112B and the registry is healthy with the expected consumers;
the pre-fix backup retained. Standing rule recorded in C6: always
`sqlite3 <db> ".backup <path>"`, never raw `cp`, for any registry DB.

### Image tag pinning (s53)
- `rag-gateway:0.1.0 ef9da642a15a`, `rag-registry:0.1.0 3701f33aed37` — **same digests as
  s52 prod** (staging == prod image parity for the RAG core; parity verified).
- `rag-portal-ragportal_api:latest` + `:p5-slug` + `:prev-p5-20261101` — **multi-tag
  shadowing** on prod portal image; `:latest` is the running one. Recommend SHA/dated tags.
- `vllm/vllm-openai:nightly` — float tag on production vLLM (acceptance risk; G5-adjacent).
- `tyk-portal` container **unhealthy** — pre-existing, outside RAG scope, flagged only.

---

## 3. Cross-cutting findings & recommendations

| # | Severity | Finding | Recommendation (owner) |
|---|---|---|---|
| C3-1 | MEDIUM | gateway `/metrics` 404 on s52 host port 8210 | Fix gateway route/prefix or scrape via in-container path; then add to PCM-10 dashboards |
| C3-2 | MEDIUM | live prod registry DB 644 | `chmod 600` after a fresh `.backup` + integrity_check (backup-first rule) |
| C3-3 | MEDIUM | `litellm:latest` (prod) + `python:latest` present | Pin to digest `c2eea0ab9754` / remove unused `python:latest` |
| C3-4 | MEDIUM | dual-tag gateway image; hotfix history | Single tag = `0.x-y-<gitsha>`; compose pins the tag |
| C3-5 | LOW | staging keyfwd = bare host process | containerize when staging hardens (optional) |
| C3-6 | HIGH | prod+staging radio use **file** bind-mounts (inode pinning incident) | directory mount or per-release image; until then: `--force-recreate` after every edit |
| C3-7 | CLOSED | staging registry WAL host-poison | rule: `sqlite3 .backup` only; pre-fix backup retained |
| C3-8 | INFO | network_mode:host for gateway/registry (s52) | intentional (multi-port + keyfwd upstream via 10.240.17.1); keep, document |
| C3-9 | INFO | all RAG containers `unless-stopped` | acceptable; consider `on-failure` for one-shot ingest only |

### Operational lessons banked from E6.2/E6.3 (root causes now documented)
1. **File bind-mount inode pinning** → container keeps serving old code after
   in-place file replacement (incident: E6.3 staging, re-verified pattern in prod).
2. **Multiple LiteLLM instances on one host** — always verify PORT OWNER by model
   set + master-key probe before redirecting traffic (lesson: `:4000` vs `:4101`).
3. **Hotfixes via `docker cp`** diverge running code from the image — acceptable only
   with immediate image rebuild + re-tag + compose recreate (applied for E6.1 gateway).
4. **`/model/info` display artifact** — LiteLLM shows a redacted/Fernet value; verify
   the real `api_base` by decrypting the DB row, not by trusting the UI.
5. **WAL SQLite** — never `cp` a live registry DB; use `.backup`.
6. **P6-1b firewall** (s53→s52:4101/8200/8210 DROP) blocks the public RAG path —
   infra fix, not docker; see `../security/e63-b2-p6-1b-public-rag-blocked.md`.

---

## 4. Verdict

**STANDARDIZATION: PARTIAL.** Staging achieved image parity with prod (same
registry/gateway digests), directory mounts for the RAG core, and healthy containers.
Non-compliant items remaining are the prod UI **file bind-mounts** (C3-6), **unpinned
litellm:latest** (C3-3), **dual-tag/shadow-tag image scheme** (C3-4), **gateway
metrics 404** (C3-1), and **registry DB 644** (C3-2) — all documented above with
owner-actionable fixes and none introduced by E6.3.

**Evidence:** the three raw audit logs in this directory (SHA-256 in the tree
checksums file) + `evidence/E6.3/security/` (P6-1b + B3 cross-references).
