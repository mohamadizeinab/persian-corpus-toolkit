#!/bin/bash
# PCM-23 pre-flight on s52: embedding endpoint + blocks availability
set -uo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
OUT=/data/knowledge/out
echo "=== 1. ollama OpenAI-compat /v1/embeddings (mxbai-embed-large) ==="
curl -s -m 30 -X POST http://172.20.1.53:11434/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"mxbai-embed-large","input":"سلام، این یک آزمایش است"}' > /tmp/pcm23-emb.json
head -c 200 /tmp/pcm23-emb.json; echo
python3 - <<'PY'
import json
try:
    d = json.load(open('/tmp/pcm23-emb.json'))
    em = d.get("data", [{}])[0].get("embedding", [])
    print("DIM:", len(em), "| first:", em[:3] if em else None)
except Exception as e:
    print("PARSE-FAIL:", e)
PY
echo
echo "=== 2. blocks.jsonl inventory (Word Factory outputs) ==="
N=$(ls -d "$OUT"/f-* 2>/dev/null | wc -l)
echo "f-* dirs: $N"
DU=$(du -sh "$OUT" 2>/dev/null | cut -f1)
echo "size: $DU"
echo
echo "=== 3. PCT DB: document -> source file mapping (approved/parsed) ==="
sqlite3 "$APP/backend/thesaurus.db" <<'SQL'
.mode line
SELECT c.slug AS coll, d.id AS doc, d.filename, d.status, d.word_factory_status,
       substr(d.source_hash,1,12) AS hash12
FROM knowledge_collection_documents d
JOIN knowledge_collections c ON c.id = d.collection_id
ORDER BY c.slug, d.id;
SQL
echo "=== 4. manifests already on disk ==="
ls -la /home/saber/dedicated-rag/data/*.json 2>/dev/null | head
echo "=== 5. ports 8103-8109 free? ==="
for p in 8103 8104 8105 8106 8107 8108 8109; do
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:$p/health"; then echo "  $p BUSY"; else echo "  $p free"; fi
done
rm -f /tmp/pcm23-emb.json
echo "=== pre-flight done ==="
