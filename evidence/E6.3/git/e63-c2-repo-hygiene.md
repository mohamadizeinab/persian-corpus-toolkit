# E6.3 C2 — Repo Hygiene: findings + applied fixes

**Date:** 2026-11-17 (02:12 UTC)
**Scope:** C2 of WS-C (E7.0) — .gitignore discipline, CI metadata accuracy,
tracked-file cleanliness across the three product repos.

## 1. `dedicated-rag` (RAG core) — **PASS, no change**

`.gitignore` already covers: `__pycache__/`, `*.pyc`, `*.db*`, `data/`,
`env/*.env`, `*.env`, `!env/*.example`, `acceptance/*`, `evidence/`.
Only 4 `*.env.example` files are tracked (placeholders, no secrets).
Working tree clean. **No fix needed** — this is the reference pattern.

## 2. `persian-corpus-toolkit` (pct) — 2 fixes applied

### Fix C2-1: `.gitignore` — E6.3/E7.0 scratch patterns
Before this run, pct had **108 untracked files**, almost all `_e63_*` session
scratch (scripts, logs, image tars) that would pollute any commit.
Added patterns (end of `.gitignore`):

```
_e63_*.sh
_e63_*.ps1
_e63_*.py
_e63_*.cmd
_e63_*.tgz
_e63_*.tar
_e63_logs/
_e63_images/
```

**Deliberately NOT ignored:**
- `_e63_b2_keyfwd/` — the E6.3 B2 forwarder (`rag_keyfwd.py`, `test_keyfwd.py`;
  no secrets) is the only VCS-tracked copy of that code until `dedicated-rag`
  reaches GitLab (C1 blocked, no PAT). Comment added in `.gitignore`.
- `evidence/` — mission deliverable, MUST be committed.
- `_e63_registry_hotfix.tar.gz` — deployment artifact referenced by the
  rollback procedure; kept trackable.

Result: untracked count 108 → 3 (`_e63_b2_keyfwd/`, `_e63_registry_hotfix.tar.gz`,
`evidence/`).

### Fix C2-2: `.gitlab-ci.yml` — stale test count
Header comment said `188 tests: 182 historical + 18 contract tests`.
The 2026-11-16 full regression run (and the PCM-20.9 baseline) report **200**
tests passing. Corrected the comment to `200 tests: 182 historical + 18
contract tests` with an E6.3 reference. Comment-only change; the pipeline
logic, job list, and PCM-19 contract are untouched (still test-only, no
deploy jobs — AGENTS.md hard rule preserved).

## 3. `rag-radio` / `rag-portal-patches` (s53 UI deployment copies)

**Not git repos** — nothing to fix locally; the fix is C1's GitLab bootstrap
(owner action, blocked on PAT). Until then the hygiene rule recorded for s53:
- never `git add` a directory containing `.env`/`keys.json`/`e61_phase5*`;
- any future `git init` must add a `.gitignore` (env, keys, backups) FIRST.

## 4. Verification

- `git check-ignore _e63_a3_browser.py _e63_logs _e63_images` → all ignored.
- `git check-ignore _e63_b2_keyfwd` → NOT ignored (intended).
- `git status --porcelain` → exactly 3 untracked entries, all intended
  (keyfwd, hotfix tarball, evidence/).
- No tracked file was modified except `.gitignore` and `.gitlab-ci.yml`
  (both committed with the E6.3 evidence commit).

## 5. Verdict

**C2 = DONE (pct + dedicated-rag).** UI repos deferred to C1 GitLab bootstrap.
