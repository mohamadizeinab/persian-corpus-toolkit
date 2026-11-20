#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-23 — background build watcher (run on s52):
#   bash pcm23_watch.sh start    → start watcher loop (idempotent via pidfile)
#   bash pcm23_watch.sh status   → show last watch log lines
#   bash pcm23_watch.sh stop     → stop watcher
# The loop itself lives in /tmp/pcm23_watch_loop.sh (validated with bash -n
# BEFORE nohup; old inline nohup version died silently — no procps in
# containers, errors went to /dev/null).
# ═══════════════════════════════════════════════════════════════════════════
set -u
DRAG=/home/saber/dedicated-rag
LOG="$DRAG/data/pcm23_build_watch.log"
PIDF="$DRAG/data/pcm23_build_watch.pid"
LOOP=/tmp/pcm23_watch_loop.sh

case "${1:-status}" in
start)
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "already running (pid $(cat "$PIDF"))"; exit 0
  fi
  [ -f "$LOOP" ] || { echo "loop script missing: $LOOP"; exit 1; }
  bash -n "$LOOP" || { echo "loop script has syntax error — not starting"; exit 1; }
  rm -f "$PIDF"
  nohup bash "$LOOP" >> "$LOG" 2>&1 &
  echo $! > "$PIDF"
  echo "watcher started (pid $(cat "$PIDF")) — log: $LOG"
  ;;
status)
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "watcher ALIVE (pid $(cat "$PIDF"))"
  else
    echo "watcher NOT RUNNING"
  fi
  echo "--- last 12 watch log lines ---"
  tail -12 "$LOG" 2>/dev/null || echo "(no log yet)"
  ;;
stop)
  if [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; then
    rm -f "$PIDF"; echo "stopped"
  else
    rm -f "$PIDF"; echo "not running"
  fi
  ;;
*)
  echo "usage: $0 start|status|stop"; exit 2 ;;
esac
