# Regression baseline — persian-corpus-toolkit (200 tests) — BEFORE E6.3 changes

Date: 2026-11-16 (UTC), workspace checkout `persian-corpus-toolkit`,
branch `pcm-20.9-knowledge-studio-factory` = f1d43faa25 (pushed to GitHub at same SHA).

Command (per AGENTS.md §4):
```
cd backend && py -3.13 -m unittest test_api test_projects test_dashboard \
  test_knowledge_api test_word_factory test_dump test_work_registry test_queue \
  test_corpus_builder test_studio_api test_api_contract
```

Result: **Ran 200 tests in 78.418s — OK (200/200, 0 failures, 0 errors, 0 skips)**

Breakdown (AGENTS.md §4):
- test_api (8), test_projects (9), test_dashboard (22), test_knowledge_api (40),
  test_word_factory (27), test_dump (26), test_work_registry (10), test_queue (9),
  test_corpus_builder (24), test_studio_api (7), test_api_contract (18).

Notes:
- ResourceWarnings (unclosed files/sockets) benign (test-harness).
- docx UserWarning (style lookup by style_id deprecated) benign.
- No production code changes made to the corpus toolkit in E6.3; this is the
  third product in the inventory (R4). Deployed commit on s52 = bcd985fa8 (PCM-14A).

**Baseline target 200 met.**
