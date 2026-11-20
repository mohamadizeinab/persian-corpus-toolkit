#!/usr/bin/env bash
# PCM-23: quick checks — watcher liveness + consumer state (read-only) + index jobs
# NOTE: containers have NO procps (pgrep/ps missing) → liveness via /proc scan
set -u
DRAG=/home/saber/dedicated-rag
REGDB=/home/saber/dedicated-rag-registry/data/registry/rag-registry.db

echo "== watcher process =="
if [ -f "$DRAG/data/pcm23_build_watch.pid" ]; then
  PID=$(cat "$DRAG/data/pcm23_build_watch.pid")
  if kill -0 "$PID" 2>/dev/null; then echo "watcher ALIVE pid=$PID"; else echo "watcher DEAD pid=$PID"; fi
else
  echo "pidfile missing"
fi
echo "== watcher log (tail) =="
tail -n 8 "$DRAG/data/pcm23_build_watch.log" 2>/dev/null || echo "(no log yet)"
echo "== consumers (read-only) =="
sqlite3 "$REGDB" "SELECT consumer_id, display_name, allowed_rag_ids, enabled FROM rag_consumers WHERE consumer_id IN ('portal','pcm23-verify');"
echo "== index jobs alive (/proc scan) =="
for c in mizan3-rag alghadir-rag manla-rag; do
  if docker exec "$c" sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null); case "$c" in "python -m drag.cli index"*) exit 0 ;; esac; done; exit 1' 2>/dev/null; then
    echo "$c index RUNNING"
  else
    echo "$c index NOT RUNNING"
  fi
done
echo CHECK-DONE
