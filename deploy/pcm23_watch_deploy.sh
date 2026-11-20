#!/usr/bin/env bash
# PCM-23: deploy new watcher (old inline version died silently)
set -u
echo "== 1) old inline syntax check (root-cause proof) =="
awk '/^  nohup bash -c /{f=1;next} f && /^  '"'"' >\/dev\/null 2>&1 &/{f=0} f' /tmp/pcm23_watch.sh > /tmp/old_inline.sh
echo "extracted lines: $(wc -l < /tmp/old_inline.sh)"
bash -n /tmp/old_inline.sh && echo OLD-INLINE-SYNTAX-OK || echo OLD-INLINE-SYNTAX-FAIL
echo "== 2) new script syntax checks =="
bash -n /tmp/pcm23_watch_loop.sh && echo LOOP-SYNTAX-OK || echo LOOP-SYNTAX-FAIL
bash -n /tmp/pcm23_watch.sh && echo WATCH-SYNTAX-OK || echo WATCH-SYNTAX-FAIL
echo "== 3) start new watcher =="
rm -f /home/saber/dedicated-rag/data/pcm23_build_watch.pid
bash /tmp/pcm23_watch.sh start
sleep 5
echo "== 4) first tick =="
tail -n 6 /home/saber/dedicated-rag/data/pcm23_build_watch.log 2>/dev/null || echo "(no log yet)"
echo "== 5) index liveness via /proc =="
for c in mizan3-rag alghadir-rag manla-rag; do
  if docker exec "$c" sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null); case "$c" in "python -m drag.cli index"*) exit 0 ;; esac; done; exit 1' 2>/dev/null; then
    echo "$c index RUNNING"
  else
    echo "$c index NOT RUNNING"
  fi
done
echo DEPLOY-WATCH-DONE
