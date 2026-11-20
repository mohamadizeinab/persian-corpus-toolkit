#!/bin/bash
# E8.0-H5 (s52): direct functional proof of the LLM endpoint at s53:8000 (vllm, no auth). READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== s52 -> s53:8000 /v1/models (no auth; vllm has no --api-key) ==="
curl -s -m 10 http://172.20.1.53:8000/v1/models | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for m in d.get('data',[]):
        print('model id:', m.get('id'))
except Exception as e:
    print('parse-fail:', e)
"
echo "=== s52 -> s53:8000 /health ==="
curl -s -m 10 -o /dev/null -w "vllm /health -> %{http_code}\n" http://172.20.1.53:8000/health
echo "END VLLM-DIRECT"
