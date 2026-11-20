#!/bin/bash
# PCM-23 pre-flight round 3: docs + out_dir + manifest template
set -uo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
DB=$APP/backend/thesaurus.db
echo "=== documents with out_dir ==="
sqlite3 -readonly "$DB" <<'SQL'
.mode line
SELECT c.slug AS coll, d.document_id, d.file_name, d.status, d.blocks_count, d.out_dir, d.file_id
FROM knowledge_collection_documents d
JOIN knowledge_collections c ON c.id = d.collection_id
ORDER BY c.slug, d.document_id;
SQL
echo "=== mizan manifest template (first entry) ==="
python3 - <<'PY'
import json
m = json.load(open('/home/saber/dedicated-rag/data/mizan_manifest.json'))
if isinstance(m, dict):
    print("keys:", list(m.keys()))
    docs = m.get("documents") or m.get("entries") or m.get("files") or []
else:
    docs = m
print("docs in manifest:", len(docs))
print(json.dumps(docs[0], ensure_ascii=False, indent=1)[:800])
PY
echo "=== verify blocks exist for a few out_dirs ==="
sqlite3 -readonly "$DB" -noheader "SELECT out_dir FROM knowledge_collection_documents WHERE collection_id='10' LIMIT 3;" | while read d; do
  if [ -d "$d" ]; then echo "OK   $d ($(ls "$d" | tr '\n' ' '))"; else echo "MISS $d"; fi
done
