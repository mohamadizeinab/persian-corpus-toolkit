#!/usr/bin/env bash
# pcm23_diag10 - خواندن handler /v1/search در api.py + store.fts_search
set -u
echo "=== api.py lines 60-170 (/v1/search handler) ==="
docker exec alghadir-rag sh -c "sed -n '60,170p' /app/drag/api.py"
echo
echo "=== store.py: fts_search + iter_embeddings ==="
docker exec alghadir-rag sh -c "sed -n '/def fts_search/,/^def /p' /app/drag/store.py"
docker exec alghadir-rag sh -c "sed -n '/def iter_embeddings/,/^def /p' /app/drag/store.py"
echo
echo "=== alghadir drag.db: counts (chunks, embeddings, fts) ==="
sqlite3 /home/saber/dedicated-rag/data/alghadir/drag.db "
SELECT 'chunks', COUNT(*) FROM chunks WHERE collection_id='c-f4571ff9';
SELECT 'embeddings', COUNT(*) FROM embeddings WHERE collection_id='c-f4571ff9';
SELECT 'fts', COUNT(*) FROM chunks_fts;
" 2>&1
echo "DIAG10-DONE"
