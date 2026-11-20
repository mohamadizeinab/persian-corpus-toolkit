#!/bin/bash
# PCM-23 build watcher loop — standalone (launched by pcm23_watch.sh start).
# Every 300s: per instance — progress line, liveness via /proc scan
# (containers have NO procps: pgrep/ps missing), auto-restart dead job
# (single-session build: crash = rollback to 0 → restart re-embeds from start).
# When all 3 are done: run E2E chat suite -> pcm23_build_complete_E2E.log, exit.
set -u
DRAG=/home/saber/dedicated-rag
LOG="$DRAG/data/pcm23_build_watch.log"
E2E_OUT="$DRAG/data/pcm23_build_complete_E2E.log"
PROBES="mizan3:c-29a205c5 alghadir:c-f4571ff9 manla:c-77bdcbe8"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

progress_line() {
  tail -c 300 "$DRAG/data/$1/index.log" 2>/dev/null | tr '\n' ' ' \
    | grep -oE '\{"embedded": [0-9]+, "remaining": [0-9]+\}|\{"ok": true, "status": "indexed"[^}]*\}' | tail -1
}
is_done() { case "$(progress_line "$1")" in *'"remaining": 0'*|*'"status": "indexed"'*) return 0 ;; *) return 1 ;; esac; }
idx_alive() {
  docker exec "$1-rag" sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null); case "$c" in "python -m drag.cli index"*) return 0 ;; esac; done; return 1' 2>/dev/null
}

log "watcher loop started (pid $$)"
while :; do
  alldone=1
  for pair in $PROBES; do
    n="${pair%%:*}"; cid="${pair#*:}"
    if is_done "$n"; then st=DONE; else st=RUN; alldone=0; fi
    if [ "$st" = RUN ] && ! idx_alive "$n"; then
      log "RESTART $n (process dead, build incomplete) -> $cid (re-embed from start)"
      docker exec -d "$n-rag" sh -c "python -m drag.cli index --collection-id $cid >> /data/index.log 2>&1"
    fi
    log "tick $n=$st $(progress_line "$n")"
  done
  if [ "$alldone" = 1 ]; then
    GSK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_SERVICE_KEY=' | cut -d= -f2-)
    CKEY=$(cat /tmp/pcm23-ckey 2>/dev/null || true)
    {
      echo "=== PCM-23 build-complete E2E — $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
      if [ -z "$CKEY" ]; then
        echo "NO verify consumer key (/tmp/pcm23-ckey)"
      else
        for pair in "rag-mizan3:تفسیر آیه نور 24/35 در المیزان چیست؟" \
                    "rag-alghadir:علامه امینی در کتاب الغدیر درباره خطبه غدیر چه می‌گوید؟" \
                    "rag-manla:من لا يحضره الفقیه چه کتابی است؟"; do
          m="${pair%%:*}"; q="${pair#*:}"
          echo
          echo "### $m — $q"
          curl -s -m 240 http://127.0.0.1:8210/v1/chat/completions \
            -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H 'Content-Type: application/json' \
            -d '{"model":"'"$m"'","messages":[{"role":"user","content":"'"$q"'"}],"max_tokens":200}' \
          | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    if "error" in d: print("ERROR:", json.dumps(d["error"],ensure_ascii=False)[:400])
    else:
        r=d.get("rag",{})
        print("answer:", d["choices"][0]["message"]["content"][:400].replace(chr(10)," "))
        print("citations:", len(d.get("citations",[])), "| degraded:", r.get("degraded"), "| latency_ms:", r.get("latency_ms"))
        for c in d.get("citations",[])[:5]: print("  -", json.dumps(c,ensure_ascii=False)[:200])
except Exception as e: print("parse-err:", e)'
        done
      fi
      echo
      echo "=== E2E done $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
    } > "$E2E_OUT" 2>&1
    log "BUILD-COMPLETE — E2E results: $E2E_OUT"
    break
  fi
  sleep 300
done
