#!/usr/bin/env bash
# pcm23_diag11 - محل نگه‌داری embeddings در حال build (جدول staging؟) + منطق commit در cli index
set -u
DB=/home/saber/dedicated-rag/data/alghadir/drag.db
echo "=== all tables in alghadir drag.db + counts ==="
sqlite3 "$DB" ".tables"
echo
for t in $(sqlite3 "$DB" ".tables" | tr ' ' '\n'); do
  c=$(sqlite3 "$DB" "SELECT COUNT(*) FROM \"$t\";" 2>/dev/null)
  echo "$t: $c"
done
echo
echo "=== index-related code in cli.py ==="
docker exec alghadir-rag sh -c "grep -n 'def cmd_index\|def index\|staging\|tmp\|commit\|embeddings' /app/drag/cli.py | head -30"
echo
echo "=== db.py: index build / embeddings write paths ==="
docker exec alghadir-rag sh -c "grep -n 'def \|embeddings\|staging\|INSERT INTO embeddings' /app/drag/db.py | head -40"
echo
echo "=== how does index finish (ready transition)? ==="
docker exec alghadir-rag sh -c "grep -n 'ready\|remaining\|0' /app/drag/cli.py | grep -iE 'ready|remaining' | head -15"
echo "DIAG11-DONE"
