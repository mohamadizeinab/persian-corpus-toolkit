#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-23 — quick status: index progress + registry/gateway state (+ optional E2E)
# usage: bash pcm23_status.sh [--e2e]
# ═══════════════════════════════════════════════════════════════════════════
set -u
DRAG=/home/saber/dedicated-rag
echo "=== index progress (TS=$(date +%H:%M:%S)) ==="
ALL_DONE=1
for n in mizan3 alghadir manla; do
  last=$(tail -c 300 "$DRAG/data/$n/index.log" 2>/dev/null | tr '\n' ' ' | grep -oE '\{"embedded": [0-9]+, "remaining": [0-9]+\}|\{"ok": true, "status": "indexed"[^}]*\}' | tail -1)
  if [ -z "$last" ]; then last="(no progress line)"; fi
  case "$last" in *'"remaining": 0'*|*'"status": "indexed"'*) st="DONE" ;; *) st="RUNNING"; ALL_DONE=0 ;; esac
  printf "%-9s %-8s %s\n" "$n" "$st" "$last"
done
echo
echo "=== embeddings committed (visible to /v1/search) ==="
for n in mizan3 alghadir manla; do
  c=$(sqlite3 "$DRAG/data/$n/drag.db" "SELECT COUNT(*) FROM embeddings;" 2>/dev/null)
  ch=$(sqlite3 "$DRAG/data/$n/drag.db" "SELECT COUNT(*) FROM chunks;" 2>/dev/null)
  printf "%-9s embeddings=%s / chunks=%s\n" "$n" "$c" "$ch"
done
echo
echo "=== registry: enabled providers (timeout_ms) ==="
TOK=$(docker inspect rag-registry --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^REGISTRY_ADMIN_TOKEN=' | cut -d= -f2-)
curl -s -m 15 -H "Authorization: Bearer $TOK" http://127.0.0.1:8200/api/rag-registry \
  | python3 -c 'import json,sys; [print(p["rag_id"], "prio", p["priority"], "timeout", p["timeout_ms"]) for p in json.load(sys.stdin)["providers"]]'
echo
if [ "${1:-}" = "--e2e" ]; then
  [ $ALL_DONE -eq 1 ] || echo "(build still running — search is FTS-lexical only until remaining:0)"
  GSK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_SERVICE_KEY=' | cut -d= -f2-)
  CKEY=$(cat /tmp/pcm23-ckey 2>/dev/null || true)
  if [ -n "$CKEY" ]; then
    for m in rag-mizan3 rag-alghadir rag-manla; do
      echo "--- E2E $m ---"
      curl -s -m 180 http://127.0.0.1:8210/v1/chat/completions \
        -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H 'Content-Type: application/json' \
        -d '{"model":"'$m'","messages":[{"role":"user","content":"این کتاب درباره چیست؟"}],"max_tokens":150}' \
        | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    if "error" in d: print("ERROR:", json.dumps(d["error"],ensure_ascii=False)[:300])
    else:
        r=d.get("rag",{})
        print("http-ok answer:", d["choices"][0]["message"]["content"][:120].replace(chr(10)," "))
        print("  citations:", len(d.get("citations",[])), "| degraded:", r.get("degraded"), "| latency_ms:", r.get("latency_ms"))
except Exception as e: print("parse-err:", e)'
    done
  else
    echo "(no /tmp/pcm23-ckey — skip E2E)"
  fi
fi
echo "STATUS-DONE"
