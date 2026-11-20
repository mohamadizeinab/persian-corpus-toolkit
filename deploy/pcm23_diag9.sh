#!/usr/bin/env bash
# pcm23_diag9 - خواندن retrieve.py (امتیازدهی + آستانه + hybrid/FTS)
set -u
echo "=== retrieve.py ==="
docker exec alghadir-rag sh -c "cat /app/drag/retrieve.py"
echo "DIAG9-DONE"
