#!/bin/bash
# PCM-23 pre-flight round 2: correct paths + schema
set -uo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
OUT=$APP/data/knowledge/out
echo "=== blocks.jsonl inventory (correct path) ==="
N=$(ls -d "$OUT"/f-* 2>/dev/null | wc -l)
echo "f-* dirs: $N | size: $(du -sh "$OUT" 2>/dev/null | cut -f1)"
echo
echo "=== knowledge_collection_documents schema ==="
sqlite3 "$APP/backend/thesaurus.db" "PRAGMA table_info(knowledge_collection_documents);"
echo
echo "=== document rows (all 4 collections) ==="
sqlite3 -readonly "$APP/backend/thesaurus.db" <<'SQL'
.mode line
SELECT c.slug AS coll, d.id AS doc, d.status,
       d.word_factory_status, substr(coalesce(d.source_hash,''),1,12) AS hash12
FROM knowledge_collection_documents d
JOIN knowledge_collections c ON c.id = d.collection_id
ORDER BY c.slug, d.id;
SQL
echo "=== collections ==="
sqlite3 -readonly "$APP/backend/thesaurus.db" "SELECT id, slug, name, indexing_status FROM knowledge_collections;"
