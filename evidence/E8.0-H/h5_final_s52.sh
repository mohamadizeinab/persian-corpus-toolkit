#!/bin/bash
# E8.0-H5 final (s52): exact qwen38-hub api_base via admin API + in-container decrypt fallback;
# RAG chain functional probe (local, 1 short chat). Keys never leave the container.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== /model/info admin (in-container; key stays inside) ==="
docker exec litellm-personal python3 -c "
import json, os, urllib.request
k = os.environ.get('LITELLM_MASTER_KEY') or ''
try:
    req = urllib.request.Request('http://127.0.0.1:4000/model/info',
        headers={'Authorization': 'Bearer ' + k})
    d = json.load(urllib.request.urlopen(req, timeout=15))
    for m in d.get('data', []):
        if m.get('model_name') == 'qwen38-hub':
            print('QWEN38_HUB_API_BASE=' + repr(m.get('api_base')))
            print('QWEN38_HUB_MODEL=' + repr(m.get('model')))
            print('QWEN38_HUB_PROVIDER=' + repr(m.get('litellm_provider') or m.get('custom_llm_provider')))
except Exception as e:
    print('model-info-fail:', type(e).__name__, str(e)[:200])
"
echo "=== in-container decrypt fallback (ciphertext via stdin; salt stays inside) ==="
ENC=$(psql -U litellm -d litellm -tA -c "SELECT api_base FROM \"LiteLLM_ProxyModelTable\" WHERE model_name='qwen38-hub'" 2>&1)
printf '%s' "$ENC" | docker exec -i litellm-personal python3 -c "
import importlib, sys
v = sys.stdin.read().strip()
if not v:
    print('NO_CIPHERTEXT'); sys.exit(0)
tried = []
for mod, name in [('litellm.utils','decrypt_value'), ('litellm._utils','decrypt_value'), ('litellm.cryptographic','decrypt_value'), ('litellm.proxy.proxy_server','decrypt_value')]:
    try:
        fn = getattr(importlib.import_module(mod), name)
        print('DECRYPTED_VIA ' + mod + '.' + name + ' -> ' + fn(v))
        sys.exit(0)
    except Exception as e:
        tried.append(mod + '.' + name + ': ' + str(e)[:60])
print('ALL_DECRYPT_IMPORTS_FAILED:', tried)
"
echo "=== RAG chain functional probe (local, model=rag-mizan, 1 short chat) ==="
docker exec litellm-personal python3 -c "
import json, os, time, urllib.request
k = os.environ.get('LITELLM_MASTER_KEY') or ''
body = json.dumps({'model':'rag-mizan','messages':[{'role':'user','content':'سلام'}],'max_tokens':30,'temperature':0}).encode()
req = urllib.request.Request('http://127.0.0.1:4000/v1/chat/completions', data=body,
    headers={'Authorization':'Bearer '+k,'Content-Type':'application/json'})
t0 = time.time()
try:
    r = urllib.request.urlopen(req, timeout=150)
    d = json.loads(r.read().decode('utf-8','replace'))
    ms = int((time.time()-t0)*1000)
    ch = (d.get('choices') or [{}])[0]
    msg = ch.get('message') or {}
    print('RAG-CHAT OK status=%d ms=%d model=%s usage=%s content80=%r' % (r.status, ms, d.get('model'), d.get('usage'), (msg.get('content') or '')[:80]))
except Exception as e:
    print('RAG-CHAT FAIL %s %s ms=%d' % (type(e).__name__, str(e)[:200], int((time.time()-t0)*1000)))
"
echo "END H5-FINAL"
