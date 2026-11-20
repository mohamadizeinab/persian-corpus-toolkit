#!/bin/bash
# PCM-23 pre-flight round 5: what does `drag index --collection-id` expect?
set -euo pipefail
DRAG=/home/saber/dedicated-rag
echo '=== drag.cli index --help ==='
docker exec mizan-rag python -m drag.cli index --help 2>&1 || true
echo
echo '=== drag.cli stats --help ==='
docker exec mizan-rag python -m drag.cli stats --help 2>&1 || true
echo
echo '=== mizan drag.db: collections + index_versions (raw) ==='
docker exec -i mizan-rag python - <<'PY'
import sqlite3
con = sqlite3.connect('/data/drag.db')
for t in ('collections', 'index_versions'):
    cur = con.execute('SELECT * FROM %s' % t)
    cols = [d[0] for d in cur.description]
    print(t, 'cols:', cols)
    for r in cur.fetchall():
        print('  ', r)
PY
echo '=== manifests: collection fields ==='
python3 - <<'PY'
import json
m = json.load(open('/home/saber/dedicated-rag/data/mizan_manifest.json'))
print('mizan_manifest keys:', sorted(m.keys()))
print('  collection:', repr(m.get('collection')), '| docs:', len(m['documents']))
print('  first doc keys:', sorted(m['documents'][0].keys()))
for fn in ('fiqh_main_manifest.json', 'fiqh_sharh_manifest.json'):
    f = json.load(open('/home/saber/dedicated-rag/data/' + fn))
    print(fn, '-> collection:', repr(f.get('collection')), '| docs:', len(f['documents']))
PY
echo '=== mizan index.log (first/last 3) ==='
head -3 "$DRAG/data/mizan/index.log" 2>/dev/null || true
echo '  ...'
tail -3 "$DRAG/data/mizan/index.log" 2>/dev/null || true
echo 'PREFLIGHT5-DONE'
