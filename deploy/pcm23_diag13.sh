#!/usr/bin/env bash
set -u
DRAG=/home/saber/dedicated-rag
NOW=$(date '+%H:%M:%S')
echo "== now: $NOW =="
echo "== index.log mtime + tail =="
for n in mizan3 alghadir manla; do
  f="$DRAG/data/$n/index.log"
  echo "--- $n (mtime: $(date -r "$f" '+%H:%M:%S' 2>/dev/null), size: $(stat -c%s "$f" 2>/dev/null))"
  tail -c 500 "$f" | tr '\n' ' '; echo
done
echo "== ps inside containers =="
for c in mizan3-rag alghadir-rag manla-rag; do
  echo "--- $c"
  docker exec "$c" sh -c 'ps -ef 2>/dev/null || ps aux 2>/dev/null || (for p in /proc/[0-9]*; do echo "pid ${p#/proc/}: $(tr "\0" " " < $p/cmdline 2>/dev/null)"; done)' | tail -n 10
done
echo "== ollama liveness (11434) =="
curl -s -m 6 -o /dev/null -w "api/tags http=%{http_code} time=%{time_total}s\n" http://172.20.1.53:11434/api/tags
echo "== docker logs (last lines) =="
for c in mizan3-rag alghadir-rag manla-rag; do echo "--- $c"; docker logs --tail 4 "$c" 2>&1; done
echo DIAG13-DONE
