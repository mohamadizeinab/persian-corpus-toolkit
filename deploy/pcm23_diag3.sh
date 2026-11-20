#!/usr/bin/env bash
# pcm23_diag3 - دیگنوستیک عمیق: (1) چرا روت /consumers/<id>/rags در container 404 می‌دهد
# (2) چرا gateway POST /v1/search -> provider_unreachable (تایم‌اوت؟)
set -u
cd /home/saber/dedicated-rag-registry

echo "=== rag containers (names/images/started) ==="
docker ps --format '{{.Names}} | {{.Image}} | {{.Status}}' | grep -iE 'rag|registry|gateway' || true

echo
echo "=== registry: route در کد داخل container ==="
docker exec rag-registry grep -n "consumer_id>/rags" /app/drag/registry/api.py || echo "ROUTE NOT IN CONTAINER FILE"
docker exec rag-registry md5sum /app/drag/registry/api.py 2>/dev/null || true
docker exec rag-registry ls -la /app/drag/registry/api.py 2>/dev/null || true

echo
echo "=== registry: ساختار create_app / چند app ==="
docker exec rag-registry grep -nE "def create_app|app = Flask|def serve|def main" /app/drag/registry/api.py || true

echo
echo "=== gateway: provider_client (بخش search + timeout) ==="
docker exec rag-gateway sh -c "sed -n '1,200p' /app/drag/gateway/provider_client.py 2>/dev/null | grep -nE 'def |search|timeout|unreachable|except|http' " || true

echo
echo "=== provider rows (timeout_ms / retrieval_config) ==="
sqlite3 /home/saber/dedicated-rag-registry/data/registry/rag-registry.db \
  "SELECT rag_id, base_url, timeout_ms, top_k, enabled FROM rag_providers ORDER BY priority;"

echo
echo "=== index progress (last line each) ==="
for n in mizan3 alghadir manla; do
  echo "--- $n ---"
  tail -c 400 /home/saber/dedicated-rag/data/$n/index.log 2>/dev/null | tr '\n' ' ' | tail -c 300; echo
done

echo
echo "=== TIMED direct /v1/search (alghadir) ==="
PT=$(docker inspect alghadir-rag --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^DRAG_SERVICE_TOKEN=' | cut -d= -f2-)
curl -sS -o /tmp/pcm23-srch.json -w "http=%{http_code} time_total=%{time_total}s\n" \
  -X POST http://127.0.0.1:8104/v1/search \
  -H "Authorization: Bearer $PT" -H "Content-Type: application/json" \
  -d '{"query":"غدیر خم","top_k":2}' --max-time 60
head -c 200 /tmp/pcm23-srch.json; echo

echo
echo "=== TIMED gateway chat retry (rag-alghadir) ==="
GSK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_SERVICE_KEY=' | cut -d= -f2-)
CKEY=$(cat /tmp/pcm23-ckey)
curl -sS -o /tmp/pcm23-gw.json -w "http=%{http_code} time_total=%{time_total}s\n" \
  -X POST http://127.0.0.1:8210/v1/chat/completions \
  -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H "Content-Type: application/json" \
  -d '{"model":"rag-alghadir","messages":[{"role":"user","content":"غدیر چیست؟"}],"max_tokens":120}' --max-time 90
head -c 500 /tmp/pcm23-gw.json; echo

echo "DIAG3-DONE"
