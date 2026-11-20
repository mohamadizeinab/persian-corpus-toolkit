#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-23 — background build watcher (run on s52 via nohup):
#   bash pcm23_watch.sh start    → start watcher (idempotent via pidfile)
#   bash pcm23_watch.sh status   → show last watch log lines + progress
#   bash pcm23_watch.sh stop     → stop watcher
# Polls the 3 index logs every 5 min; on completion runs the E2E chat suite
# and stores it in pcm23_build_complete_E2E.log. Auto-restarts a dead index
# job (single-session build: crash = rollback to 0, so restart re-embeds from
# the start — cheap enough vs. waiting forever).
# ═══════════════════════════════════════════════════════════════════════════
set -u
DRAG=/home/saber/dedicated-rag
LOG="$DRAG/data/pcm23_build_watch.log"
PIDF="$DRAG/data/pcm23_build_watch.pid"
E2E_OUT="$DRAG/data/pcm23_build_complete_E2E.log"
PROBES="mizan3:c-29a205c5 alghadir:c-f4571ff9 manla:c-77bdcbe8"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

progress_line() { # name
  tail -c 300 "$DRAG/data/$1/index.log" 2>/dev/null | tr '\n' ' ' \
    | grep -oE '\{"embedded": [0-9]+, "remaining": [0-9]+\}|\{"ok": true, "status": "indexed"[^}]*\}' | tail -1
}
is_done() { case "$(progress_line "$1")" in *'"remaining": 0'*|*'"status": "indexed"'*) return 0 ;; *) return 1 ;; esac; }
idx_alive() { docker exec "$1-rag" sh -c "pgrep -f 'drag.cli index' >/dev/null" 2>/dev/null; }

restart_index() { # name collection_id
  log "RESTART $1 (process dead, build incomplete) — re-embedding from start"
  docker exec -d "$1-rag" sh -c "python -m drag.cli index --collection-id $2 >> /data/index.log 2>&1"
}

run_e2e() {
  GSK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_SERVICE_KEY=' | cut -d= -f2-)
  CKEY=$(cat /tmp/pcm23-ckey 2>/dev/null || true)
  {
    echo "=== PCM-23 build-complete E2E — $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
    echo "provider index stats:"
    for n in mizan3 alghadir manla; do
      docker exec "$n-rag" python3 -m drag.cli stats 2>/dev/null | head -c 400; echo
    done
    if [ -z "$CKEY" ]; then echo "NO verify consumer key (/tmp/pcm23-ckey)"; return 0; fi
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
    echo
    echo "=== E2E done $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  } > "$E2E_OUT" 2>&1
  log "BUILD-COMPLETE — E2E results: $E2E_OUT"
}

cmd="${1:-status}"
case "$cmd" in
start)
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDF"))"; exit 0
  fi
  nohup bash -c '
    DRAG=/home/saber/dedicated-rag
    LOG="$DRAG/data/pcm23_build_watch.log"; E2E_OUT="$DRAG/data/pcm23_build_complete_E2E.log"
    log() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $*" >> "$LOG"; }
    progress_line() { tail -c 300 "$DRAG/data/$1/index.log" 2>/dev/null | tr "\n" " " | grep -oE "\{\"embedded\": [0-9]+, \"remaining\": [0-9]+\}|\{\"ok\": true, \"status\": \"indexed\"[^}]*\}" | tail -1; }
    is_done() { case "$(progress_line "$1")" in *\"remaining\": 0*|*\"status\": \"indexed\"*) return 0 ;; *) return 1 ;; esac; }
    idx_alive() { docker exec "$1-rag" sh -c "pgrep -f \"drag.cli index\" >/dev/null" 2>/dev/null; }
    log "watcher started"
    while :; do
      alldone=1
      for n in mizan3 alghadir manla; do
        if is_done "$n"; then st=DONE; else st=RUN; alldone=0; fi
        if [ "$st" = RUN ]; then
          if ! idx_alive "$n"; then
            cid=$(docker exec "$n-rag" python3 -c "import sqlite3,os; c=sqlite3.connect(os.environ[\"DRAG_DB_PATH\"]); print(c.execute(\"select collection_id from collections limit 1\").fetchone()[0])" 2>/dev/null)
            [ -n "$cid" ] && log "RESTART $n (dead) -> $cid" && docker exec -d "$n-rag" sh -c "python -m drag.cli index --collection-id $cid >> /data/index.log 2>&1"
          fi
        fi
        log "tick $n=$st $(progress_line "$n")"
      done
      [ "$alldone" = 1 ] && { 
        GSK=$(docker inspect rag-gateway --format "{{.Config.Env}}" | tr " " "\n" | grep "^GATEWAY_SERVICE_KEY=" | cut -d= -f2-)
        CKEY=$(cat /tmp/pcm23-ckey 2>/dev/null || true)
        {
          echo "=== PCM-23 build-complete E2E — $(date "+%Y-%m-%d %H:%M:%S %Z") ==="
          if [ -z "$CKEY" ]; then echo "NO verify consumer key"; else
            for pair in "rag-mizan3:تفسیر آیه نور 24/35 در المیزان چیست؟" "rag-alghadir:علامه امینی در کتاب الغدیر درباره خطبه غدیر چه می‌گوید؟" "rag-manla:من لا يحضره الفقیه چه کتابی است؟"; do
              m="${pair%%:*}"; q="${pair#*:}"; echo; echo "### $m — $q"
              curl -s -m 240 http://127.0.0.1:8210/v1/chat/completions -H "Authorization: Bearer $GSK" -H "X-Consumer-Key: $CKEY" -H "Content-Type: application/json" -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"$q\"}],\"max_tokens\":200}" \
              | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    if \"error\" in d: print(\"ERROR:\", json.dumps(d[\"error\"],ensure_ascii=False)[:400])
    else:
        r=d.get(\"rag\",{})
        print(\"answer:\", d[\"choices\"][0][\"message\"][\"content\"][:400].replace(chr(10),\" \"))
        print(\"citations:\", len(d.get(\"citations\",[])), \"| degraded:\", r.get(\"degraded\"), \"| latency_ms:\", r.get(\"latency_ms\"))
        for c in d.get(\"citations\",[])[:5]: print(\"  -\", json.dumps(c,ensure_ascii=False)[:200])
except Exception as e: print(\"parse-err:\", e)"
            done
          fi
          echo; echo "=== E2E done $(date "+%Y-%m-%d %H:%M:%S %Z") ==="
        } > "$E2E_OUT" 2>&1
        log "BUILD-COMPLETE — E2E: $E2E_OUT"; break
      }
      sleep 300
    done
  ' >/dev/null 2>&1 &
  echo $! > "$PIDF"
  echo "watcher started (pid $(cat "$PIDF")) — log: $LOG"
  ;;
status)
  echo "--- last 12 watch log lines ---"
  tail -12 "$LOG" 2>/dev/null || echo "(no log yet)"
  ;;
stop)
  [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null && rm -f "$PIDF" && echo "stopped" || echo "not running"
  ;;
*)
  echo "usage: $0 start|status|stop"; exit 2 ;;
esac
