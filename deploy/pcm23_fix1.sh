#!/usr/bin/env bash
# pcm23_fix1 - رفع provider_unreachable: افزایش timeout_ms سه provider جدید به 60000
#              (PATCH با If-Match / optimistic concurrency) + تست مجدد E2E gateway
set -u
REG=http://127.0.0.1:8200/api/rag-registry
RAUTH="Authorization: Bearer $(cat /tmp/pcm23-regtok)"
J='Content-Type: application/json'

echo "=== PATCHABLE_FIELDS (container) ==="
docker exec rag-registry grep -n "PATCHABLE_FIELDS" /app/drag/registry/api.py | head -3
docker exec rag-registry grep -A14 "^PATCHABLE_FIELDS" /app/drag/registry/api.py | head -20

for rid in mizan3 alghadir manla; do
  echo
  echo "=== PATCH $rid -> timeout_ms=60000 ==="
  CUR=$(curl -sS -H "$RAUTH" "$REG/$rid")
  UA=$(echo "$CUR" | python3 -c "import sys,json; print(json.load(sys.stdin)['provider']['updated_at'])")
  echo "current updated_at=$UA"
  curl -sS -X PATCH -H "$RAUTH" -H "$J" -H "If-Match: $UA" \
    -d '{"timeout_ms":60000}' "$REG/$rid"; echo
done

echo
echo "=== DB verify ==="
sqlite3 /home/saber/dedicated-rag-registry/data/registry/rag-registry.db \
  "SELECT rag_id, timeout_ms, updated_at FROM rag_providers WHERE rag_id IN ('mizan3','alghadir','manla');"

echo
echo "=== wait 20s for gateway cache TTL (15s) ==="
sleep 20

GSK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_SERVICE_KEY=' | cut -d= -f2-)
CKEY=$(cat /tmp/pcm23-ckey)

echo
echo "=== E2E gateway chat rag-alghadir ==="
curl -sS -o /tmp/pcm23-e2e1.json -w "http=%{http_code} time_total=%{time_total}s\n" \
  -X POST http://127.0.0.1:8210/v1/chat/completions \
  -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H "$J" \
  -d '{"model":"rag-alghadir","messages":[{"role":"user","content":"غدیر خمین در نزدیکی کجاست؟"}],"max_tokens":150}' --max-time 150
head -c 900 /tmp/pcm23-e2e1.json; echo

echo
echo "=== E2E gateway chat rag-manla ==="
curl -sS -o /tmp/pcm23-e2e2.json -w "http=%{http_code} time_total=%{time_total}s\n" \
  -X POST http://127.0.0.1:8210/v1/chat/completions \
  -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H "$J" \
  -d '{"model":"rag-manla","messages":[{"role":"user","content":"من لایحضره الفقیه چه کتابی است؟"}],"max_tokens":150}' --max-time 150
head -c 900 /tmp/pcm23-e2e2.json; echo

echo
echo "=== E2E gateway chat rag-mizan3 ==="
curl -sS -o /tmp/pcm23-e2e3.json -w "http=%{http_code} time_total=%{time_total}s\n" \
  -X POST http://127.0.0.1:8210/v1/chat/completions \
  -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H "$J" \
  -d '{"model":"rag-mizan3","messages":[{"role":"user","content":"تفسیر آیه‌ی نور چیست؟"}],"max_tokens":150}' --max-time 150
head -c 900 /tmp/pcm23-e2e3.json; echo

echo
echo "=== index progress ==="
for n in mizan3 alghadir manla; do
  printf "%-9s: %s\n" "$n" "$(tail -c 300 /home/saber/dedicated-rag/data/$n/index.log | tr '\n' ' ' | grep -oE '\{\"embedded\": [0-9]+, \"remaining\": [0-9]+\}' | tail -1)"
done
echo "FIX1-DONE"
