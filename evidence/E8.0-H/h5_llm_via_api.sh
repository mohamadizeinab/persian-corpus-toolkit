#!/bin/bash
# H5: resolve qwen38-hub backend endpoint via litellm API (key stays inside container)
set -u
echo "=== litellm /v1/models (api_base per model; key never leaves container) ==="
docker exec litellm-personal sh -c 'curl -s -m 10 http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"' \
  | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for m in d.get('data',[]):
        print(m.get('id'), '->', m.get('api_base','<none>'), '|', m.get('model',''))
except Exception as e:
    print('parse-fail:', e)
"
echo "=== health ==="
docker exec litellm-personal sh -c 'curl -s -m 10 -o /dev/null -w "litellm-personal /health/liveliness -> %{http_code}\n" http://127.0.0.1:4000/health/liveliness'
echo "=== gateway health ==="
curl -s -m 5 -o /dev/null -w "gateway :8210 /health -> %{http_code}\n" http://127.0.0.1:8210/health
curl -s -m 5 -o /dev/null -w "registry :8200 /health -> %{http_code}\n" http://127.0.0.1:8200/health
echo "=== keyfwd :8211/:8212 (container net) ==="
docker exec rag-keyfwd sh -c 'wget -qO- -T 5 http://127.0.0.1:8211/health 2>/dev/null || echo "keyfwd 8211 no /health (expected)"; echo'
echo "=== providers (auth header from registry env? use stats endpoint if public) ==="
curl -s -m 5 http://127.0.0.1:8101/health 2>/dev/null | head -c 200; echo
curl -s -m 5 http://127.0.0.1:8102/health 2>/dev/null | head -c 200; echo
