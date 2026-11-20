#!/bin/bash
# PCM-23 pre-flight round 4: docs by c-* collection ids
set -uo pipefail
DB=/home/saber/saberprojects/persian-corpus-toolkit/backend/thesaurus.db
echo "=== all document rows (c-* ids) ==="
sqlite3 -readonly "$DB" <<'SQL'
.mode line
SELECT document_id, collection_id, file_name, status, blocks_count, file_id, out_dir, substr(sha256,1,16) AS sha16
FROM knowledge_collection_documents
ORDER BY collection_id, document_id;
SQL
echo "=== does out_dir / f-hash map to a real dir? (sample 5) ==="
sqlite3 -readonly "$DB" -noheader "SELECT out_dir FROM knowledge_collection_documents WHERE out_dir IS NOT NULL AND out_dir != '' LIMIT 5;" | while read d; do
  [ -z "$d" ] && continue
  if [ -d "$d" ]; then echo "OK   $d"; else echo "MISS $d"; fi
done
