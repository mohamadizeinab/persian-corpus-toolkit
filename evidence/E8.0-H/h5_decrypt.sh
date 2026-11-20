#!/bin/bash
# H5 take 3: decrypt qwen38-hub api_base INSIDE litellm container (salt key never leaves);
# then a single 1-token completion as a functional liveness probe (writes a spend log row - documented)
set -u
echo "=== decrypt qwen38-hub api_base (in-container; only URL printed) ==="
docker exec litellm-personal python3 -c "
import os
enc = None
import psycopg2
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute('SELECT api_base, model FROM \"LiteLLM_ProxyModelTable\" WHERE model_name=%s', ('qwen38-hub',))
row = cur.fetchone()
print('row found:', row is not None)
if row:
    enc, model = row
    print('model field:', model)
    print('api_base raw (first 12 chars, masked):', (enc or '<null>')[:12] + '...')
    plain = enc
    try:
        from litellm.utils import decrypt_value
        plain = decrypt_value(enc)
        print('decrypt via litellm.utils.decrypt_value OK')
    except Exception as e1:
        try:
            from litellm._utils import decrypt_value
            plain = decrypt_value(enc)
            print('decrypt via litellm._utils.decrypt_value OK')
        except Exception as e2:
            print('decrypt-fail:', e1, '|', e2)
    print('qwen38-hub api_base (plain):', plain)
conn.close()
"
echo "=== functional probe: 1-token completion via qwen38-hub (key stays inside) ==="
docker exec litellm-personal python3 -c "
import json, os, time, urllib.request
k = os.environ['LITELLM_MASTER_KEY']
body = json.dumps({'model':'qwen38-hub','messages':[{'role':'user','content':'Hi'}],'max_tokens':1,'temperature':0}).encode()
req = urllib.request.Request('http://127.0.0.1:4000/v1/chat/completions', data=body,
    headers={'Authorization':'Bearer '+k,'Content-Type':'application/json'})
t0=time.time()
try:
    d = json.load(urllib.request.urlopen(req, timeout=60))
    ms = int((time.time()-t0)*1000)
    msg = d.get('choices',[{}])[0].get('message',{}).get('content','')
    print('OK in %d ms | model=%s | usage=%s | first-40-chars=%r' % (ms, d.get('model'), d.get('usage'), msg[:40]))
except Exception as e:
    print('FAIL in %d ms: %s %s' % (int((time.time()-t0)*1000), type(e).__name__, str(e)[:200]))
"
