# Regression baseline — dedicated-rag (151 tests) — BEFORE E6.3 changes

Date: 2026-11-16 (UTC), local Windows checkout `..\dedicated-rag`,
HEAD `da40c4dc99cd81a0b3eb49af00bc89387139fc3c` (branch `pcm-20.10-mizan-rag`,
no remotes configured — C1 gap).

Command: `py -3.13 -m unittest discover -s tests -t . -v` (top-level = repo root,
tests import `drag.*`)

Result: **Ran 151 tests in 56.950s — OK (151/151, 0 failures, 0 errors, 0 skips)**

Notes:
- First attempt `discover -s tests` (without `-t .`) ran 0 tests (import path) —
  `-t .` is required.
- ResourceWarnings (unclosed sockets) present but benign (test-harness).
- No production changes made to this repo in E6.3 (it is the target of C1/C3
  git/docker work; test-only repo otherwise untouched).

**Baseline target 151 met.**
