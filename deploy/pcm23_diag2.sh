#!/bin/bash
# PCM-23: gateway 'provider_unreachable' + portal/rags KeyError diagnosis
set -euo pipefail
GSK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_SERVICE_KEY=' | cut -d= -f2-)
RAUTH="Authorization: Bearer $(cat /tmp/pcm23-regtok)"
CKEY=$(cat /tmp/pcm23-ckey)

echo '=== gateway audit (last entries) ==='
curl -s -m 10 http://127.0.0.1:8210/v1/audit -H "Authorization: Bearer $GSK" | tail -c 2000; echo
echo
echo '=== gateway logs (tail) ==='
docker logs rag-gateway --tail 40 2>&1 | tail -40
echo
echo '=== direct provider /v1/search (alghadir, provider token) ==='
PT=$(grep '^DRAG_SERVICE_TOKEN=' /home/saber/dedicated-rag/env/alghadir.env | cut -d= -f2-)
curl -s -m 60 -X POST http://127.0.0.1:8104/v1/search -H "Authorization: Bearer $PT" -H 'Content-Type: application/json' \
  -d '{"query":"غدیر خم","top_k":2}' | head -c 700; echo
echo
echo '=== portal/rags raw response ==='
curl -s -m 10 -H "$RAUTH" http://127.0.0.1:8200/api/rag-registry/consumers/portal/rags | head -c 800; echo
echo 'DIAG2-DONE'
