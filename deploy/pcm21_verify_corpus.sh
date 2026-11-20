#!/bin/bash
# PCM-21 verify: corpus section now shows tasnim artifacts
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
echo "=== disk ==="
du -sh "$APP/data/tasnim"
echo "=== /api/corpus/list (tasnim rows) ==="
curl -s http://127.0.0.1:5055/api/corpus/list > /tmp/pcm21-cl.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/pcm21-cl.json'))
ts = [f for f in d["files"] if f.get("root")]
lg = [f for f in d["files"] if not f.get("root")]
print("tasnim items:", len(ts))
for f in ts:
    print(" ", f["name"], "|", f["kind"], "|", f["version"], "|", f["size"], "| entries:", f["entries"])
print("legacy items:", len(lg))
PY
echo "=== integrity (final) ==="
sqlite3 "$APP/backend/thesaurus.db" "PRAGMA integrity_check;"
rm -f /tmp/pcm21-cl.json
