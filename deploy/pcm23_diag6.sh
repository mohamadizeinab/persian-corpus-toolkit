#!/usr/bin/env bash
# pcm23_diag6 - چرا E2E gateway citations خالی و degraded:true؟
set -u
PT=$(docker inspect alghadir-rag --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^DRAG_SERVICE_TOKEN=' | cut -d= -f2-)
MT=$(docker inspect mizan-rag --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^DRAG_SERVICE_TOKEN=' | cut -d= -f2-)

echo "=== provider_client.search body (gateway container) ==="
docker exec rag-gateway sed -n '108,160p' /app/drag/gateway/provider_client.py

echo
echo "=== gateway: score filtering (similarity_threshold usage) ==="
docker exec rag-gateway grep -n "similarity_threshold\|score" /app/drag/gateway/api.py | head -15 || true

echo
echo "=== alghadir /v1/audit (last 4) ==="
curl -sS -H "Authorization: Bearer $PT" http://127.0.0.1:8104/v1/audit | python3 -c "
import sys,json
d=json.load(sys.stdin)
for e in d.get('audit',[])[-4:]:
    print(json.dumps(e,ensure_ascii=False)[:400])
" 2>&1 | head -20

echo
echo "=== direct /v1/search same query as gateway (alghadir) ==="
curl -sS -X POST http://127.0.0.1:8104/v1/search \
  -H "Authorization: Bearer $PT" -H "Content-Type: application/json" \
  -d '{"query":"غدیر خمین در نزدیکی کجاست؟","top_k":5}' --max-time 90 \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('ok:',d.get('ok'),'n_results:',len(d.get('results',[])))
for r in d.get('results',[])[:3]:
    c=r.get('citation',{})
    print('score=',r.get('score'),'| heading=',c.get('heading'),'| snippet=',(c.get('snippet') or '')[:60].replace(chr(10),' '))
" 2>&1

echo
echo "=== E2E gateway chat rag-mizan (provider کهنه 2560-dim، مقایسه) ==="
GSK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_SERVICE_KEY=' | cut -d= -f2-)
CKEY=$(cat /tmp/pcm23-ckey)
curl -sS -o /tmp/pcm23-e2em.json -w "http=%{http_code} time_total=%{time_total}s\n" \
  -X POST http://127.0.0.1:8210/v1/chat/completions \
  -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H "Content-Type: application/json" \
  -d '{"model":"rag-mizan","messages":[{"role":"user","content":"تفسیر آیه نور چیست؟"}],"max_tokens":150}' --max-time 120
head -c 700 /tmp/pcm23-e2em.json; echo
echo "DIAG6-DONE"
