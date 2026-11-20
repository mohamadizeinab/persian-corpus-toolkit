#!/bin/bash
# PCM-23 step 1: inspect existing compose/env layout + registry admin token
set -uo pipefail
DRAG=/home/saber/dedicated-rag
REG=/home/saber/dedicated-rag-registry
echo "=== compose.mizan.yml ==="
cat "$DRAG/compose.mizan.yml"
echo "=== env/mizan.env (masked) ==="
sed -E 's/=(.{6}).*/=\1****/' "$DRAG/env/mizan.env"
echo "=== data dirs ==="
ls -la "$DRAG/data/" | head -20
echo "=== registry admin token from RUNNING container (masked) ==="
TOK=$(docker inspect rag-registry --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^REGISTRY_ADMIN_TOKEN=' | cut -d= -f2-)
echo "token len: ${#TOK} (stored in /tmp/pcm23-regtok, chmod 600)"
[ -n "$TOK" ] && printf '%s' "$TOK" > /tmp/pcm23-regtok && chmod 600 /tmp/pcm23-regtok
echo "=== registry health (no auth) ==="
curl -s http://127.0.0.1:8200/health; echo
echo "=== mizan /health (embedder field) ==="
curl -s http://127.0.0.1:8101/health | head -c 400; echo
echo "=== blocks presence for alghadir+manla (first 3 each) ==="
for fid in f-ff1443ec f-722a2211 f-fdc2a5fe f-dd709dda f-60af6a0d f-72f3af2a; do
  d="$DRAG/../saberprojects/persian-corpus-toolkit/data/knowledge/out/$fid"
  if [ -f "$d/blocks.jsonl" ]; then echo "OK   $fid ($(wc -l < "$d/blocks.jsonl") blocks)"; else echo "MISS $fid"; fi
done
