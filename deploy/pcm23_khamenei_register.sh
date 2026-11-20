#!/usr/bin/env bash
# PCM-23: register khamenei provider in rag-registry + wire consumers + gateway models
# Safety: DB .backup before, no compose down, no volume removal, tokens never echoed.
set -euo pipefail
RD=/home/saber/dedicated-rag-registry
DR=/home/saber/dedicated-rag
TS=$(date +%Y%m%d-%H%M%S)
fail(){ echo "!!! FAILED at [$1]: $2" >&2; exit 1; }
STEP=init

# 0. preconditions
[ -f "$DR/env/khamenei.env" ] || fail pre "khamenei.env missing"
[ -f "$RD/env/registry.env" ] || fail pre "registry.env missing"
[ -f /tmp/pcm23-regtok ] || fail pre "/tmp/pcm23-regtok missing"
TOK=$(cat /tmp/pcm23-regtok)
[ -n "$TOK" ] || fail pre "admin token empty"
docker ps --format '{{.Names}}' | grep -q '^rag-registry$' || fail pre "rag-registry not running"

STEP=db-backup
sqlite3 "$RD/data/registry/rag-registry.db" ".backup /home/saber/backups/rag-registry-$TS.db"
sqlite3 "/home/saber/backups/rag-registry-$TS.db" "PRAGMA integrity_check;"
echo "registry DB backed up: rag-registry-$TS.db"

STEP=env
KKTOK=$(grep '^DRAG_SERVICE_TOKEN=' "$DR/env/khamenei.env" | cut -d= -f2-)
[ -n "$KKTOK" ] || fail env "DRAG_SERVICE_TOKEN empty in khamenei.env"
if grep -q '^KHAMENEI_PROVIDER_TOKEN=' "$RD/env/registry.env"; then
  echo "KHAMENEI_PROVIDER_TOKEN already present in registry.env"
else
  printf 'KHAMENEI_PROVIDER_TOKEN=%s\n' "$KKTOK" >> "$RD/env/registry.env"
  echo "KHAMENEI_PROVIDER_TOKEN appended to registry.env (len ${#KKTOK})"
fi
chmod 600 "$RD/env/registry.env"

STEP=recreate
cd "$RD"
docker compose -f compose.registry.yml up -d rag-registry

STEP=health
ok=""
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8200/health || true)
  if [ "$code" = 200 ]; then ok=yes; break; fi
  sleep 2
done
[ "$ok" = yes ] || fail health "registry /health not 200 after 60s"
echo "registry healthy"

STEP=auth-check
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" http://127.0.0.1:8200/api/rag-registry || true)
[ "$code" = 200 ] || fail auth "admin token no longer works after recreate (got $code)"
echo "admin token still valid after recreate"

STEP=register
python3 - "$TOK" <<'PYEOF'
import json, sys, urllib.request, urllib.error
tok = sys.argv[1]
body = {
    "rag_id": "khamenei",
    "display_name": "\u06a9\u062a\u0628 \u0627\u0645\u0627\u0645 \u062e\u0627\u0645\u0646\u0647\u200c\u0627\u06cc (mxbai-1024)",
    "description": "Khatib-e Imam Khamenei corpus, 12 volumes, mxbai-embed-large 1024",
    "provider_type": "dedicated",
    "base_url": "http://127.0.0.1:8106",
    "api_endpoint": "/v1",
    "api_contract_version": "v1",
    "healthcheck_endpoint": "/health",
    "auth_ref": "env:KHAMENEI_PROVIDER_TOKEN",
    "embedding_model": "mxbai-embed-large",
    "priority": 6,
    "enabled": True,
    "allowed_consumers": ["radio", "portal", "gateway", "pcm23-verify"],
    "top_k": 5,
}
req = urllib.request.Request(
    "http://127.0.0.1:8200/api/rag-registry",
    data=json.dumps(body, ensure_ascii=False).encode(),
    headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
    method="POST")
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.load(r)
        print("create status:", r.status, "rag_id:", d["provider"]["rag_id"])
except urllib.error.HTTPError as e:
    print("create HTTP", e.code, e.read().decode()[:500]); sys.exit(1)
PYEOF

STEP=test
for ep in test-connection test-auth; do
  out=$(curl -s -X POST -H "Authorization: Bearer $TOK" http://127.0.0.1:8200/api/rag-registry/khamenei/$ep)
  echo "$ep: $out"
done

STEP=consumers
python3 - "$TOK" <<'PYEOF'
import json, sys, urllib.request
tok = sys.argv[1]
def patch(cid, rags):
    req = urllib.request.Request(
        f"http://127.0.0.1:8200/api/rag-registry/consumers/{cid}",
        data=json.dumps({"allowed_rag_ids": rags}).encode(),
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
        method="PATCH")
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.load(r)
        print(cid, "->", d["consumer"]["allowed_rag_ids"])
patch("portal", ["mizan", "fiqh", "mizan3", "alghadir", "manla", "khamenei"])
patch("pcm23-verify", ["mizan3", "alghadir", "manla", "khamenei"])
PYEOF

STEP=verify
curl -s -H "Authorization: Bearer $TOK" http://127.0.0.1:8200/api/rag-registry | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in d.get("providers",[]):
    print("provider:", p.get("rag_id"), "|", p.get("base_url"), "| enabled:", p.get("enabled"), "| priority:", p.get("priority"))
'

STEP=gateway-models
if [ -f /tmp/pcm23-gwkey ] && [ -f /tmp/pcm23-ckey ]; then
  sleep 20   # gateway provider cache TTL 15s
  curl -s -H "Authorization: Bearer $(cat /tmp/pcm23-gwkey)" \
         -H "X-Consumer-Key: $(cat /tmp/pcm23-ckey)" \
         http://127.0.0.1:8210/v1/models | python3 -m json.tool
else
  echo "gateway keys not in /tmp — skipping gateway models check"
fi

echo "=== KHAMENEI REGISTRATION OK (TS=$TS) ==="
