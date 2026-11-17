# Regression baseline — rag-radio (28 tests) — BEFORE E6.3 changes

Date: 2026-11-16 (UTC), local Windows checkout `..\rag\rag-radio` (repo ref re-verified on
GitLab: `e6.1-rag-production` = 193225e8c5aed23817ccc336b338d883d8053d4c).

Command: `py -3.13 -m unittest test_rag_proxy -v` (backend/)

## Baseline (pre-fix)
- Run 1 (full suite, discovery order): **27/28** — 1 FAIL:
  `TestRagProxyAdmin.test_patch_requires_if_match` → `AssertionError: 502 != 428`
  (G7 — order-dependent flaky test, registered in Part 6)
- Isolated run of the failing test: PASS
- 2-test subset (applies + requires_if_match): PASS

## Root cause (diagnosed, not just flake-marked)
- The fake registry handler (`_FakeRegistryHandler` in `test_rag_proxy.py`) early-returned
  on 401/404/409/428 responses **without reading the request body**.
- On Windows, closing a socket with unread bytes in the receive buffer sends **RST**
  instead of FIN → the httpx client in `rag_proxy._registry_call` sees
  `ReadError: [WinError 10053]` → proxy maps it to `502 registry_unreachable`.
- Instrumented repro (`httpx.Client.request` wrapper + fake-handler exception log) captured:
  `PATCH http://127.0.0.1:<port>/api/rag-registry/alpha -> ReadError: [WinError 10053]
  An established connection was aborted by the software in your host machine`
  in full-suite order only.

## Fix (G7 closed)
`test_rag_proxy.py`: `_body()` now caches the parsed body; new `_drain()` helper;
`do_POST`/`do_PATCH` call `self._drain()` first so the body is always consumed before
any early-return response. No production code changed (test-harness only).

## After fix — 3 consecutive full-suite runs
1. `Ran 28 tests in 44.587s — OK`
2. `Ran 28 tests in 45.561s — OK`
3. `Ran 28 tests in 45.036s — OK`

**Result: 28/28 deterministic. Baseline target 28/28 met.**
