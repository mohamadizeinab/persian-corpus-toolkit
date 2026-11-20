#!/usr/bin/env bash
# pcm23_diag12 - خواندن کامل cmd_index + store_embeddings + session (رفتار commit)
set -u
echo "=== cli.py cmd_index (lines 90-135) ==="
docker exec alghadir-rag sh -c "sed -n '90,135p' /app/drag/cli.py"
echo
echo "=== store.py store_embeddings ==="
docker exec alghadir-rag sh -c "sed -n '/def store_embeddings/,/^def /p' /app/drag/store.py"
echo
echo "=== db.py session + connect (isolation/commit) ==="
docker exec alghadir-rag sh -c "sed -n '137,165p' /app/drag/db.py"
echo
echo "=== index.log first lines (how batches start) ==="
head -c 500 /home/saber/dedicated-rag/data/alghadir/index.log; echo
echo
echo "=== mizan (ready) embeddings for comparison ==="
sqlite3 /home/saber/dedicated-rag/data/mizan/drag.db "SELECT 'mizan embeddings', COUNT(*) FROM embeddings;"
echo "DIAG12-DONE"
