#!/bin/bash
# PCM-23: embedding speed diagnosis
set -euo pipefail
echo '=== ollama /api/ps (which processor?) ==='
curl -s -m 10 http://172.20.1.53:11434/api/ps | python3 -m json.tool 2>/dev/null || echo '(not loaded / no model)'
echo '=== live timing test: 1 batch of 32 chunks through the OpenAI-compat endpoint ==='
python3 - <<'PY'
import json, time, urllib.request
texts = ["این یک جمله آزمایشی از متن فارسی برای اندازه‌گیری سرعت embedding است. " * 8] * 32
body = json.dumps({"model": "mxbai-embed-large", "input": texts}).encode()
req = urllib.request.Request("http://172.20.1.53:11434/v1/embeddings", data=body,
                             headers={"Content-Type": "application/json"})
t0 = time.time()
with urllib.request.urlopen(req, timeout=120) as r:
    d = json.loads(r.read())
dt = time.time() - t0
n = len(d["data"]); dim = len(d["data"][0]["embedding"])
print(f"batch=32 -> {n} vectors dim={dim} in {dt:.1f}s ({n/dt:.1f} chunks/s)")
PY
echo '=== mizan2: which embedder + timing history ==='
docker exec -i mizan2-rag python - <<'PY' 2>/dev/null || echo '(mizan2-rag not running; inspecting host file)'
import sqlite3
con = sqlite3.connect('/data/drag.db')
for r in con.execute('SELECT version_id, collection_id, status, chunk_count, embed_count, embed_model, embed_dim, embed_version, created_at, updated_at FROM index_versions'):
    print(r)
PY
ls -la /home/saber/dedicated-rag/data/mizan2/ 2>/dev/null
[ -f /home/saber/dedicated-rag/data/mizan2/index.log ] && { echo '--- mizan2 index.log first/last ---'; head -2 /home/saber/dedicated-rag/data/mizan2/index.log; tail -2 /home/saber/dedicated-rag/data/mizan2/index.log; }
echo 'DIAG-DONE'
