#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-23 — new RAG instances on s52 (172.30.0.133)
#   mizan3-rag   127.0.0.1:8103  (تفسیر المیزان — fresh, re-indexed)
#   alghadir-rag 127.0.0.1:8104  (الغدیر علامه امینی — 11 approved)
#   manla-rag    127.0.0.1:8105  (من لایحضر — 24 parsed)
# Embedding: ONLY live endpoint = ollama mxbai-embed-large (1024-dim)
#   @ 172.20.1.53:11434/v1 (OpenAI-compat, verified)
# Chat: vLLM qwen3.8-27b-uncensored @ 172.22.188.80:8000/v1 (LLM only)
# Source: Word Factory blocks.jsonl (data/knowledge/out/<file_id>/)
# Pipeline per instance: init-db → ingest-manifest → index (resume-safe,
#   run in background; check <data>dir/index.log when done)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
DB=$APP/backend/thesaurus.db
DRAG=/home/saber/dedicated-rag
TS=$(date +%Y%m%d-%H%M%S)

fail() { echo "!!! FAILED: $1"; exit 1; }

echo "=== 0. verify blocks for every doc we will index ==="
MISS=0
check() { # coll_id label
  local cid=$1 label=$2
  while IFS='|' read -r fid; do
    [ -z "$fid" ] && continue
    d="$APP/data/knowledge/out/$fid"
    if [ -f "$d/blocks.jsonl" ]; then
      echo "OK   $label $fid ($(wc -l < "$d/blocks.jsonl") blocks)"
    else
      echo "MISS $label $fid"
      MISS=$((MISS+1))
    fi
  done < <(sqlite3 -readonly "$DB" -noheader "SELECT file_id FROM knowledge_collection_documents WHERE collection_id='$cid' AND status IN ('parsed','approved') ORDER BY document_id;")
}
check c-f4571ff9 alghadir
check c-77bdcbe8 manla
check c-29a205c5 mizan
check c-86347897 khamenei
echo "missing: $MISS"
[ "$MISS" -le 1 ] || fail "$MISS blocks missing (only 1 tolerated: manla f-60af6a0d)"

echo "=== 1. data dirs + ownership ==="
UID1001=$(id -u)
for n in mizan3 alghadir manla; do
  mkdir -p "$DRAG/data/$n"
  chown 1001:1001 "$DRAG/data/$n" 2>/dev/null || chown "$UID1001:$UID1001" "$DRAG/data/$n"
  chmod 775 "$DRAG/data/$n"
  echo "ready $DRAG/data/$n"
done

echo "=== 2. env files (fresh provider tokens, embedded) ==="
gen() { openssl rand -hex 24; }
make_env() { # name source chat
  local n=$1 src=$2
  local tok=$(gen)
  {
    echo "DRAG_SOURCE_ID=$src"
    echo "DRAG_DB_PATH=/data/drag.db"
    echo "DRAG_SERVICE_TOKEN=$tok"
    echo "DRAG_EMBED_ENDPOINTS=http://172.20.1.53:11434/v1|mxbai-embed-large"
    echo "DRAG_EMBED_DIM=1024"
    echo "DRAG_EMBED_VERSION=mxbai-embed-large-v1"
    echo "DRAG_EMBED_BATCH=32"
    echo "DRAG_CHAT_ENDPOINT=http://172.22.188.80:8000/v1"
    echo "DRAG_CHAT_MODEL=qwen3.8-27b-uncensored"
    echo "DRAG_PRODUCTION_MODE=1"
    echo "DRAG_DEFAULT_TOPK=5"
    echo "DRAG_HYBRID_ALPHA=0.6"
  } > "$DRAG/env/$n.env"
  chmod 600 "$DRAG/env/$n.env"
  echo "env $n.env (token $tok) written"
}
make_env mizan3 mizan3
make_env alghadir alghadir
make_env manla manla

echo "=== 3. compose files ==="
make_compose() { # name port
  local n=$1 port=$2
  cat > "$DRAG/compose.$n.yml" <<EOF
# PCM-23 independent instance: $n ($port). Isolated DB/index/port/token.
services:
  ${n}-rag:
    build: .
    image: dedicated-rag:0.1.0
    container_name: ${n}-rag
    restart: unless-stopped
    user: "1001:1001"
    ports:
      - "127.0.0.1:${port}:8100"
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    deploy:
      resources:
        limits: { cpus: "4.0", memory: 4G }
    volumes:
      - ./data/${n}:/data
      - ./openapi:/app/openapi:ro
      - ${APP}/data/knowledge/out:/blocks:ro
    env_file:
      - ./env/${n}.env
    environment:
      DRAG_SOURCE_ID: ${n}
      DRAG_DB_PATH: /data/drag.db
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8100/health',timeout=4).status==200 else 1)"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
EOF
  echo "compose.$n.yml written"
}
make_compose mizan3 8103
make_compose alghadir 8104
make_compose manla 8105

echo "=== 4. manifests from PCT DB (blocks_path = /blocks/<file_id>/blocks.jsonl) ==="
# NOTE: drag manifest 'collection' is an OBJECT {collection_id, name, source_id[,work_id]}
# (verified against data/mizan_manifest.json). index --collection-id takes the c-* id.
python3 - <<'PY'
import json, os, re, sqlite3
db = sqlite3.connect('file:/home/saber/saberprojects/persian-corpus-toolkit/backend/thesaurus.db?mode=ro', uri=True)
db.row_factory = sqlite3.Row
DRAG = '/home/saber/dedicated-rag'
OUT = '/home/saber/saberprojects/persian-corpus-toolkit/data/knowledge/out'
# (collection_id, source_id, Persian name, work_id or None, manifest file)
specs = [
    ('c-f4571ff9', 'alghadir', 'الغدیر علامه امینی', None, 'alghadir_manifest.json'),
    ('c-77bdcbe8', 'manla',    'من لا يحضره الفقيه', None, 'manla_manifest.json'),
    ('c-29a205c5', 'mizan3',   'تفسیر المیزان', 'w-mizan', 'mizan3_manifest.json'),
    ('c-86347897', 'khamenei', 'کتب امام خامنه‌ای', None, 'khamenei_manifest.json'),
]
for cid, src, name, work_id, fn in specs:
    rows = db.execute(
        "SELECT document_id, file_name, sha256, file_id, work_id "
        "FROM knowledge_collection_documents "
        "WHERE collection_id=? AND status IN ('parsed','approved') "
        "ORDER BY document_id", (cid,)).fetchall()
    docs, skipped = [], []
    for r in rows:
        if not os.path.isfile(os.path.join(OUT, r['file_id'], 'blocks.jsonl')):
            skipped.append('%s %s' % (r['document_id'], r['file_id']))
            continue
        m = re.search(r'j(\d+)\.docx', r['file_name'] or '')
        entry = {
            'document_id': r['document_id'],
            'source_file': r['file_name'],
            'source_hash': r['sha256'],
            'blocks_path': '/blocks/%s/blocks.jsonl' % r['file_id'],
        }
        if m:
            entry['volume_number'] = int(m.group(1))
        docs.append(entry)
    col = {'collection_id': cid, 'name': name, 'source_id': src}
    if work_id:
        col['work_id'] = work_id
    elif rows and rows[0]['work_id']:
        col['work_id'] = rows[0]['work_id']
    man = {'collection': col, 'documents': docs}
    p = os.path.join(DRAG, 'data', fn)
    with open(p, 'w', encoding='utf-8') as fh:
        json.dump(man, fh, ensure_ascii=False, indent=1)
    print('%s: %d docs (skipped no-blocks: %s)' % (fn, len(docs), skipped or 'none'))
PY

echo "=== 5. start the 3 new containers (NO down of existing) ==="
cd "$DRAG"
for n in mizan3 alghadir manla; do
  docker compose -f "compose.$n.yml" up -d
done
docker ps --filter "name=rag" --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'

echo "=== 6. health wait (60s each) ==="
for p in 8103 8104 8105; do
  ok=""
  for i in $(seq 1 60); do
    curl -sf "http://127.0.0.1:$p/health" >/dev/null 2>&1 && { ok=yes; break; }
    sleep 1
  done
  [ -n "$ok" ] || fail "port $p not healthy"
  echo "port $p healthy (~${i}s): $(curl -s http://127.0.0.1:$p/health | head -c 160)"
done

echo "=== 7. init-db + ingest-manifest (fast, no embedding) ==="
# manifests are under /home/saber/dedicated-rag/data/<fn> — the container only
# sees its own data dir mounted at /data, so copy the manifest into it first.
for pair in "mizan3-rag:mizan3_manifest.json" "alghadir-rag:alghadir_manifest.json" "manla-rag:manla_manifest.json"; do
  c=${pair%%:*}; m=${pair##*:}
  cp "$DRAG/data/$m" "$DRAG/data/${c%-rag}/$m"
  chown 1001:1001 "$DRAG/data/${c%-rag}/$m" 2>/dev/null || true
  docker exec "$c" python -m drag.cli init-db
  docker exec "$c" python -m drag.cli ingest-manifest --manifest "/data/$m"
  echo "--- $c ingested ---"
done

echo "=== 8. start index in BACKGROUND (resume-safe; watch index.log) ==="
for pair in "mizan3-rag:c-29a205c5:mizan3" "alghadir-rag:c-f4571ff9:alghadir" "manla-rag:c-77bdcbe8:manla"; do
  IFS=':' read -r c cid datadir <<< "$pair"
  docker exec -d "$c" sh -c "python -m drag.cli index --collection-id $cid > /data/index.log 2>&1"
  echo "index started in $c ($cid; log: /home/saber/dedicated-rag/data/$datadir/index.log)"
done

echo "=== 9. early progress (10s) ==="
sleep 10
for n in mizan3 alghadir manla; do
  echo "--- $n ---"
  tail -3 "$DRAG/data/$n/index.log" 2>/dev/null || echo "(no log yet)"
done
echo "=== SETUP OK (TS=$TS) — indexing continues in background ==="
