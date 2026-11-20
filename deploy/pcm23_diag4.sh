#!/usr/bin/env bash
# pcm23_diag4 - (1) پیدا کردن نسخهٔ جدیدتر registry api.py روی host (روت /rags)
#              (2) cache یا per-request بودن بارگذاری provider توسط registry/gateway
#              (3) منبع 36s search: embedding query یا retrieval؟
#              (4) آیا route آپدیت/patch provider وجود دارد؟
set -u
REGDB=/home/saber/dedicated-rag-registry/data/registry/rag-registry.db

echo "=== md5 local recon copy vs container ==="
md5sum /tmp/pcm23-registry-api.py 2>/dev/null || echo "local /tmp copy absent"
docker exec rag-registry md5sum /app/drag/registry/api.py 2>/dev/null || true
echo "local lines:"; wc -l /tmp/pcm23-registry-api.py 2>/dev/null || true

echo
echo "=== find registry api.py on host (newer, with /rags) ==="
find /home/saber/dedicated-rag-registry /home/saber/dedicated-rag -name "api.py" -path "*registry*" 2>/dev/null | while read -r f; do
  echo "--- $f  bytes=$(wc -c <"$f")  mtime=$(stat -c %y "$f" | cut -d. -f1)  md5=$(md5sum "$f" | cut -d' ' -f1)"
  echo "    has /rags route: $(grep -c 'consumer_id>/rags' "$f")"
done
echo "host registry top-level:"
ls -la /home/saber/dedicated-rag-registry/ 2>/dev/null | head -30
echo
echo "=== compose.registry.yml build section ==="
grep -nA8 "build" /home/saber/dedicated-rag-registry/compose.registry.yml 2>/dev/null || true
echo "image created:"
docker images rag-registry --format '{{.Repository}}:{{.Tag}}  createdSince={{.CreatedSince}}' 2>/dev/null || true

echo
echo "=== registry provider load: per-request or cached? ==="
docker exec rag-registry grep -n "FROM rag_providers" /app/drag/registry/api.py /app/drag/registry/db.py 2>/dev/null | head
docker exec rag-registry grep -nE "lru_cache|_CACHE|functools" /app/drag/registry/api.py 2>/dev/null | head || echo "no cache markers (api.py)"

echo
echo "=== gateway: how does it fetch providers (cache/ttl)? ==="
docker exec rag-gateway grep -nE "cache|ttl|def .*providers|list_providers|registry" /app/drag/gateway/api.py 2>/dev/null | head -15 || true

echo
echo "=== provider update/patch routes in registry ==="
docker exec rag-registry grep -nE "app\.(post|put|patch)" /app/drag/registry/api.py 2>/dev/null | grep -iE "priority|patch|<rag_id>" | head
echo "full post route list:"
docker exec rag-registry grep -nE "@app\.(post|put|patch)" /app/drag/registry/api.py 2>/dev/null | head -40

echo
echo "=== ollama single-query embedding latency (under current load) ==="
for i in 1 2; do
  curl -sS -o /dev/null -w "embed#%{num_trials} time_total=%{time_total}s http=%{http_code}\n" \
    -X POST http://172.20.1.53:11434/v1/embeddings \
    -H "Content-Type: application/json" \
    -d '{"model":"mxbai-embed-large","input":"غدیر خم"}' --max-time 60
done

echo
echo "=== provider index-versions status (are they 'ready' yet?) ==="
for n in mizan3 alghadir manla; do
  echo "--- $n ---"
  sqlite3 /home/saber/dedicated-rag/data/$n/drag.db \
    "SELECT collection_id,status FROM collections; SELECT version_id,status,chunk_count,embed_count FROM index_versions;" 2>/dev/null || true
done
echo
echo "=== current new-provider timeout_ms (before) ==="
sqlite3 "$REGDB" "SELECT rag_id, timeout_ms, enabled FROM rag_providers WHERE rag_id IN ('mizan3','alghadir','manla');"
echo "DIAG4-DONE"
