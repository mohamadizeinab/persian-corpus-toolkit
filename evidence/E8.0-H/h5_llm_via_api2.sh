#!/bin/bash
# H5 take 2: litellm /v1/models via python inside container (key never leaves); provider chat health (s52)
set -u
echo "=== litellm /v1/models (in-container python; master key stays inside) ==="
docker exec litellm-personal python3 -c "
import json, os, urllib.request
k = os.environ.get('LITELLM_MASTER_KEY') or ''
print('master key env present:', bool(k))
for port in (4000, 4101):
    try:
        req = urllib.request.Request(
            'http://127.0.0.1:%d/v1/models' % port,
            headers={'Authorization': 'Bearer ' + k})
        d = json.load(urllib.request.urlopen(req, timeout=10))
        print('port', port, 'OK; models:', len(d.get('data', [])))
        for m in d.get('data', []):
            print('  ', m.get('id'), '->', m.get('api_base', '<none>'), '|', m.get('model', ''))
        break
    except Exception as e:
        print('port', port, 'fail:', type(e).__name__, str(e)[:120])
"
echo "=== provider /health chat section (8101/8102) ==="
for p in 8101 8102; do
  echo "--- :$p"
  curl -s -m 5 "http://127.0.0.1:$p/health" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('keys:', sorted(d.keys()))
    print('chat:', json.dumps(d.get('chat', '<absent>'), ensure_ascii=False)[:500])
except Exception as e:
    print('parse-fail:', e)
"
done
