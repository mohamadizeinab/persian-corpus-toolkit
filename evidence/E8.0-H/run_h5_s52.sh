#!/bin/bash
# E8.0-H5 (s52 part): qwen38-hub backend resolution + functional liveness. READ-ONLY except one 1-token completion.
# Security: LITELLM_MASTER_KEY and LITELLM_SALT_KEY never leave the litellm-personal container.
# The encrypted api_base ciphertext flows host->container via stdin pipe (ciphertext only; salt stays inside).
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== litellm /v1/models (in-container python; key stays inside) ==="
docker exec litellm-personal python3 -c "
import json, os, urllib.request
k = os.environ.get('LITELLM_MASTER_KEY') or ''
print('master key env present:', bool(k))
try:
    req = urllib.request.Request('http://127.0.0.1:4000/v1/models',
        headers={'Authorization': 'Bearer ' + k})
    d = json.load(urllib.request.urlopen(req, timeout=10))
    print('models:', len(d.get('data', [])))
    for m in d.get('data', []):
        print('  ', m.get('id'))
except Exception as e:
    print('fail:', type(e).__name__, str(e)[:150])
"
echo "=== qwen38-hub api_base (decrypt INSIDE container; only plaintext URL printed) ==="
ENC=$(psql -U litellm -d litellm -tA -c "SELECT api_base FROM \"LiteLLM_ProxyModelTable\" WHERE model_name='qwen38-hub'" 2>&1)
echo "encrypted api_base length: ${#ENC}"
printf '%s' "$ENC" | docker exec -i litellm-personal python3 -c "
import sys
v = sys.stdin.read().strip()
if not v:
    print('NO_ENCRYPTED_VALUE'); sys.exit(0)
fn = None
try:
    from litellm.utils import decrypt_value as fn
except Exception:
    try:
        from litellm._utils import decrypt_value as fn
    except Exception as e:
        print('IMPORT_FAIL:', e); sys.exit(0)
try:
    print('QWEN38_HUB_API_BASE=' + fn(v))
except Exception as e:
    print('DECRYPT_FAIL:', type(e).__name__, str(e)[:150])
"
echo "=== functional probe: 1-token completion via qwen38-hub ==="
docker exec litellm-personal python3 -c "
import json, os, time, urllib.request, urllib.error
k = os.environ.get('LITELLM_MASTER_KEY') or ''
body = json.dumps({'model':'qwen38-hub','messages':[{'role':'user','content':'Hi'}],'max_tokens':1,'temperature':0}).encode()
req = urllib.request.Request('http://127.0.0.1:4000/v1/chat/completions', data=body,
    headers={'Authorization':'Bearer '+k,'Content-Type':'application/json'})
t0 = time.time()
try:
    r = urllib.request.urlopen(req, timeout=90)
    raw = r.read().decode('utf-8','replace')
    ms = int((time.time()-t0)*1000)
    try:
        d = json.loads(raw)
        ch = d.get('choices')
        if ch:
            msg = (ch[0] or {}).get('message') or {}
            print('OK status=%d ms=%d model=%s usage=%s content40=%r' % (r.status, ms, d.get('model'), d.get('usage'), (msg.get('content') or '')[:40]))
        else:
            print('NO-CHOICES status=%d ms=%d body200=%r' % (r.status, ms, raw[:200]))
    except Exception:
        print('NONJSON status=%d ms=%d body200=%r' % (r.status, ms, raw[:200]))
except urllib.error.HTTPError as e:
    raw = e.read().decode('utf-8','replace')[:300]
    print('HTTPERROR code=%d ms=%d body=%r' % (e.code, int((time.time()-t0)*1000), raw))
except Exception as e:
    print('FAIL %s %s ms=%d' % (type(e).__name__, str(e)[:150], int((time.time()-t0)*1000)))
"
echo "END H5-S52"
