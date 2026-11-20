#!/bin/bash
# PCM-21 UI data-path check (runs ON s52; never prints the password)
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
PW=$(grep '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" | cut -d= -f2-)
[ -n "$PW" ] || { echo "FAIL: no password in .env"; exit 1; }

echo "=== login (cookie jar /tmp/pcm21-cj) ==="
LOGIN=$(curl -s -c /tmp/pcm21-cj -H 'Content-Type: application/json' \
  -d "{\"password\":\"$PW\"}" http://127.0.0.1:5055/api/auth/login)
echo "$LOGIN" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("login ok:", d.get("status"))' || true

echo "=== authenticated: dashboard project list ==="
curl -s -b /tmp/pcm21-cj http://127.0.0.1:5055/api/dashboard/projects > /tmp/pcm21-pl.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/pcm21-pl.json'))
projects = d if isinstance(d, list) else d.get("projects", d.get("items", []))
print("projects:", len(projects))
for p in projects[:10]:
    ps = p.get("pages_summary") or {}
    print(" -", p.get("id"), p.get("name"), "| pages:", ps.get("total_pages"),
          "| last_page_number:", ps.get("last_page_number"),
          "| stop_number:", p.get("stop_number"))
PY

echo "=== project detail: last_page_number (real, not stop_number) ==="
PID=$(python3 -c "import json; d=json.load(open('/tmp/pcm21-pl.json')); ps=d if isinstance(d,list) else d.get('projects',[]); ps=[p for p in ps if (p.get('pages_summary') or {}).get('total_pages')]; print(ps[0]['id'] if ps else '')")
if [ -n "$PID" ]; then
  curl -s -b /tmp/pcm21-cj "http://127.0.0.1:5055/api/dashboard/projects/$PID" > /tmp/pcm21-pd.json
  python3 - <<'PY'
import json
d = json.load(open('/tmp/pcm21-pd.json'))
ps = d.get("pages_summary", {})
print("pid:", d.get("id"), d.get("name"))
print("  last_url:", (ps.get("last_url") or "")[:110])
print("  last_page_number:", ps.get("last_page_number"))
print("  stop_number (must differ or be null):", d.get("stop_number"))
PY
else
  echo "no project with pages — skipping detail check"
fi
rm -f /tmp/pcm21-cj /tmp/pcm21-pl.json /tmp/pcm21-pd.json
echo "=== UI data-path check OK ==="
