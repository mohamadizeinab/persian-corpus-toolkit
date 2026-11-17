# E6.3 C1 — Git/GitLab Status: BLOCKED (no GitLab PAT)

**Date:** 2026-11-17 (recon 02:05 UTC)
**Scope:** C1 of WS-C (E7.0) — git hygiene, GitLab project mapping, push/pull readiness.
**Verdict:** **BLOCKED** — a GitLab Personal Access Token is missing, so no GitLab
operation (push, project creation, clone) could be performed. All git state below was
captured read-only from the local working copies.

---

## 1. Git state of each repo (read-only recon)

### 1.1 `persian-corpus-toolkit` (pct) — THIS WORKSPACE
| Item | Value |
|---|---|
| Remote | `origin` = **GitHub** `https://github.com/saber13812002/persian-corpus-toolkit.git` |
| Branch | `pcm-20.9-knowledge-studio-factory` |
| HEAD | `f1d43fa` (already pushed to GitHub) |
| Untracked | **108 files** — all `_e63_*` scratch (scripts, `_e63_logs/`, `_e63_images/`, `_e63_b2_keyfwd/`) + `evidence/` tree |
| GitLab remote | **NONE configured** |

Note: pct is a **GitHub** repo, not GitLab. GitLab mapping for pct is therefore
*optional* (mirror) and not required for the mission's delivery.

### 1.2 `dedicated-rag` (drag: registry/gateway/providers/keyfwd code)
| Item | Value |
|---|---|
| Remote | **NONE** (no `origin`, no GitLab) |
| Branch | `pcm-20.10-mizan-rag` |
| HEAD | `da40c4d` (local only) |
| Tree | clean (no untracked, no modified) |
| .gitignore | **PASS** — covers `env/*.env`, `*.env`, `!env/*.example`, `data/`, `evidence/`; 4 tracked `*.env.example` only |

Implication: the entire RAG core code (registry E1, gateway E2, providers, and the
E6.3 B2 `rag_keyfwd.py` forwarder) currently exists **only in this local clone + the
running containers**. The B2 keyfwd is deployed via **directory bind-mount**
(`/home/saber/e63-b2-keyfwd:/opt/keyfwd:ro` on s52), not from git.

### 1.3 `rag-radio` (radio UI backend) and `rag-portal-patches`
| Item | Value |
|---|---|
| VCS | **NOT git repos** — plain deployment copies on s53 (`/home/saber/saberprojects/…`) |
| G7 flaky-test fix (`test_rag_proxy.py`) | **local-only** — exists in the s53 deployment copy, not in any VCS |
| `rag-portal` | directory missing on s53 (portal UI runs from `rag-portal-patches` copy) |

Implication: the G7 test fix and all E6.1/E6.3 UI patches to `rag_proxy.py`/`api.py`
have **no version control** and are propagated to prod via **file bind-mounts**
(`api.py`, `rag_proxy.py` mounted into the UI containers — see C3 audit). This is the
root enabler of the inode-pinning incident.

### 1.4 GitLab instance
- Instance: `git.ai.ismc.ir` (reached via s52 port `2222`, which is the GitLab SSH
  port — **2222 is GitLab, not SSH**).
- Existing projects (from `_tmp_gitlab_projects.json`):
  - `Hmdmmd/observability` (id 45)
  - `ai-tools/ai-dump-builder` (id 34)
  - `rag/langgraph-neo4j-qa` (id 27)
- GitLab refs known from E6.1 (NOT accessible without PAT):
  - `rag/radio-rag-service` @ e6.1 = `193225e8…`
  - `rag/rag-portal` @ e6.1 = `334e8541…`

---

## 2. Why BLOCKED

No GitLab Personal Access Token (PAT) is available to the executing environment.
Every GitLab action (auth via `git push`/`git clone` over HTTPS, or API project
creation) requires the owner to mint a PAT with `read_repository`+`write_repository`
(or `api`). Without it:

- dedicated-rag cannot be pushed to GitLab → no protected copy of the RAG core.
- UI repos (radio/portal) cannot be bootstrapped as GitLab projects → G7 fix + E6.3
  UI patches remain local-only.
- No CI can be attached to any of these repos.

**No GitLab change was made in this run.** (Read-only recon only.)

---

## 3. Unblock procedure (owner action)

1. On the owner's machine, mint a GitLab PAT:
   `git.ai.ismc.ir` → User → Settings → Access Tokens → create with
   `read_repository`, `write_repository`, `api` scopes.
2. Provide the token to the deployment (never commit it; store in a gitignored env
   or the owner's `~/.git-credentials`).
3. For each repo, add the GitLab remote and push:

```bash
# dedicated-rag (RAG core — highest priority)
cd dedicated-rag
git remote add gitlab git@git.ai.ismc.ir:rag/dedicated-rag.git   # or https
git push gitlab pcm-20.10-mizan-rag

# persian-corpus-toolkit (optional mirror; already on GitHub)
cd persian-corpus-toolkit
git remote add gitlab git@git.ai.ismc.ir:ai-tools/persian-corpus-toolkit.git
git push gitlab pcm-20.9-knowledge-studio-factory
```

4. Bootstrap the two UI repos (currently plain copies) — create projects, then
   `git init` + first commit + push from the s53 deployment copies:

```bash
# on s53
cd /home/saber/saberprojects/radio-rag-service && git init && git add -A && git commit -m "radio-rag-service: initial import (E6.3 C1)"
cd /home/saber/saberprojects/rag-portal-patches  && git init && git add -A && git commit -m "rag-portal: initial import (E6.3 C1)"
# then push to newly created git.ai.ismc.ir projects rag/radio-rag-service, rag/rag-portal
```

---

## 4. What is deliverable WITHOUT the PAT (already done this run)

- C2 repo-hygiene fixes in `persian-corpus-toolkit` (`.gitignore` scratch patterns +
  `.gitlab-ci.yml` test-count comment) — committed to the existing **GitHub** remote.
- C3 Docker standardization audit (this folder's parent: `../docker/`) — read-only.
- All evidence logs captured locally (no GitLab dependency).

---

## 5. Evidence index

| File | Purpose |
|---|---|
| `_tmp_gitlab_projects.json` (workspace root) | GitLab project list snapshot (ids/names/defaults) |
| `git` states in §1 | captured from `git remote -v`, `git status`, `git rev-parse` |
| `evidence/E6.3/git/` (this dir) | this doc |

**Owner follow-up:** mint PAT → execute §3 → report push SHAs to attach to the
E7.0 report.
