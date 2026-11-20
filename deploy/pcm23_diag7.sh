#!/usr/bin/env bash
# pcm23_diag7 - خواندن پیاده‌سازی search در drag + تست کاوری query برای فهم رفتار 0-result
set -u
PT=$(docker inspect alghadir-rag --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^DRAG_SERVICE_TOKEN=' | cut -d= -f2-)

echo "=== search implementation files ==="
docker exec alghadir-rag sh -c "grep -rln 'def search' /app/drag/ | head -5"
echo
echo "=== /v1/search handler in drag api.py ==="
docker exec alghadir-rag sh -c "grep -n 'v1/search' /app/drag/api.py"
docker exec alghadir-rag sh -c "awk '/v1.search/,/^    @app/' /app/drag/api.py | head -60"

echo
echo "=== QUERY MATRIX (direct /v1/search, top_k=3) ==="
Q() {
  local q="$1"
  local n=$(curl -sS -X POST http://127.0.0.1:8104/v1/search \
    -H "Authorization: Bearer $PT" -H "Content-Type: application/json" \
    -d "{\"query\":\"$q\",\"top_k\":3}" --max-time 90 \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    rs=d.get('results',[])
    print(len(rs), '|', json.dumps([(round(r.get('score') or 0,3),(r.get('citation') or {}).get('heading')) for r in rs[:2]],ensure_ascii=False))
except Exception as e:
    print('ERR',e)
" 2>&1)
  printf "%-45s -> %s\n" "$q" "$n"
}
Q "غدیر خم"
Q "غدیر خمین"
Q "خداحافظی"
Q "در نزدیکی"
Q "چه خبر"
Q "خداحافظی پیامبر از مسلمانان"
echo "DIAG7-DONE"
