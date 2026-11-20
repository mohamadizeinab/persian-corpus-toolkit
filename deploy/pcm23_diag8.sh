#!/usr/bin/env bash
# pcm23_diag8 - خواندن کامل منطق search در router.py + env فعلی alghadir-rag
set -u
echo "=== alghadir-rag env (DRAG_*) ==="
docker inspect alghadir-rag --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^DRAG_' | sed 's/\(TOKEN=\).\{6\}/\1******/'
echo
echo "=== router.py: search function (full) ==="
docker exec alghadir-rag sh -c "grep -n 'def \|threshold\|hybrid\|alpha\|fts\|AND\|OR' /app/drag/router.py" | head -40
echo
echo "--- search body ---"
docker exec alghadir-rag sh -c "sed -n '/def search/,/^def /p' /app/drag/router.py | head -120"
echo
echo "=== hybrid/fts modules ==="
docker exec alghadir-rag sh -c "ls /app/drag/*.py"
docker exec alghadir-rag sh -c "grep -n 'def \|alpha\|and\|or\|threshold' /app/drag/fts.py 2>/dev/null | head -20" || true
echo "DIAG8-DONE"
