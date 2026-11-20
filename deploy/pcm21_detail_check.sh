#!/bin/bash
# PCM-21 detail check: last_page_number on a real project with pages
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
PW=$(grep '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" | cut -d= -f2-)
curl -s -c /tmp/pcm21-cj2 -H 'Content-Type: application/json' \
  -d "{\"password\":\"$PW\"}" http://127.0.0.1:5055/api/auth/login >/dev/null
for PID in 2 4 7 11; do
  curl -s -b /tmp/pcm21-cj2 "http://127.0.0.1:5055/api/dashboard/projects/$PID" > /tmp/pcm21-d.json
  python3 - "$PID" <<'PY'
import json, sys
pid = sys.argv[1]
d = json.load(open('/tmp/pcm21-d.json'))
ps = d.get("pages_summary", {}) or {}
name = d.get("name", "?")
lu = ps.get("last_url") or ""
print(f"pid={pid} {name}")
print(f"   pages total: {ps.get('total_pages')}")
print(f"   last_url: {lu[:120]}")
print(f"   last_page_number (REAL): {ps.get('last_page_number')}")
print(f"   stop_number (config, not used): {d.get('stop_number')}")
PY
done
rm -f /tmp/pcm21-cj2 /tmp/pcm21-d.json
echo "=== detail check OK ==="
