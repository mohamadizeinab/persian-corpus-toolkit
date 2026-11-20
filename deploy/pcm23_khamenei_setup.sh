#!/bin/bash
# PCM-23 / Khamenei RAG: dedicated instance on 127.0.0.1:8106 (image
# dedicated-rag:0.1.1), ingest 12-doc manifest, start index (background).
set -euo pipefail
D=/home/saber/dedicated-rag
STEP="init"
fail() { echo "!!! FAILED at [$STEP]: $1"; exit 1; }
trap 'fail "abnormal exit (line $LINENO)"' ERR

echo "=== 0. preconditions ==="
[ -f "$D/data/khamenei_manifest.json" ] || fail "manifest missing"
docker image inspect dedicated-rag:0.1.1 >/dev/null 2>&1 || fail "image dedicated-rag:0.1.1 missing"
ss -ltn | grep -q '127.0.0.1:8106' && fail "port 8106 already in use" || true

echo "=== 1. data dir + manifest copy ==="
mkdir -p "$D/data/khamenei"
cp "$D/data/khamenei_manifest.json" "$D/data/khamenei/khamenei_manifest.json"
echo "manifest staged in /data (container view)"

echo "=== 2. env (chmod 600, fresh token — value never echoed) ==="
STEP="env"
[ -f "$D/env/khamenei.env" ] || {
  TOK=$(openssl rand -hex 24)
  {
    echo "DRAG_SOURCE_ID=khamenei"
    echo "DRAG_DB_PATH=/data/drag.db"
    echo "DRAG_SERVICE_TOKEN=${TOK}"
    echo "DRAG_EMBED_ENDPOINTS=http://172.20.1.53:11434/v1|mxbai-embed-large"
    echo "DRAG_EMBED_DIM=1024"
    echo "DRAG_EMBED_VERSION=mxbai-embed-large-v1"
    echo "DRAG_EMBED_BATCH=32"
    echo "DRAG_CHAT_ENDPOINT=http://172.22.188.80:8000/v1"
    echo "DRAG_CHAT_MODEL=qwen3.8-27b-uncensored"
    echo "DRAG_PRODUCTION_MODE=1"
    echo "DRAG_DEFAULT_TOPK=5"
    echo "DRAG_HYBRID_ALPHA=0.6"
  } > "$D/env/khamenei.env"
  chmod 600 "$D/env/khamenei.env"
  echo "env created (token length: $(grep '^DRAG_SERVICE_TOKEN=' "$D/env/khamenei.env" | cut -d= -f2 | tr -d '\n' | wc -c))"
} || fail "env creation"
[ "$(stat -c%a "$D/env/khamenei.env")" = "600" ] || fail "env not chmod 600"

echo "=== 3. compose.khamenei.yml (0.1.1, 8106) ==="
STEP="compose"
if [ ! -f "$D/compose.khamenei.yml" ]; then
cat > "$D/compose.khamenei.yml" <<'EOF'
# Khamenei RAG (کتب امام خامنه‌ای): independent instance, port 8106.
# Image dedicated-rag:0.1.1 (busy_timeout + per-batch commit + log_usage guard).
services:
  khamenei-rag:
    image: dedicated-rag:0.1.1
    container_name: khamenei-rag
    restart: unless-stopped
    user: "1001:1001"
    ports:
      - "127.0.0.1:8106:8100"
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    deploy:
      resources:
        limits: { cpus: "4.0", memory: 4G }
    volumes:
      - ./data/khamenei:/data
      - ./openapi:/app/openapi:ro
      - /home/saber/saberprojects/persian-corpus-toolkit/data/knowledge/out:/blocks:ro
    env_file:
      - ./env/khamenei.env
    environment:
      DRAG_SOURCE_ID: khamenei
      DRAG_DB_PATH: /data/drag.db
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8100/health',timeout=4).status==200 else 1)"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
EOF
  echo "compose created"
else
  echo "compose already exists — leaving untouched"
fi

echo "=== 4. up -d (no down, no volume removal) ==="
cd "$D"
docker compose -f compose.khamenei.yml up -d
docker image inspect $(docker inspect khamenei-rag --format '{{.Image}}') --format 'container image: {{.Id}}'

echo "=== 5. health wait ==="
ok=""
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:8106/health >/dev/null 2>&1; then ok=yes; break; fi
  sleep 2
done
[ -n "$ok" ] || fail "khamenei-rag not healthy after 60s"
echo "healthy after ~$((i*2))s"
curl -s http://127.0.0.1:8106/health | head -c 300; echo

echo "=== 6. ingest manifest (12 docs) ==="
STEP="ingest"
docker exec khamenei-rag python -m drag.cli ingest-manifest --manifest /data/khamenei_manifest.json 2>&1 | tail -5

echo "=== 7. stats after ingest ==="
docker exec khamenei-rag python -m drag.cli stats --collection-id c-86347897 2>&1 | tail -10

echo "=== 8. start index in background (resume-safe) ==="
STEP="index"
if docker exec khamenei-rag sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null); case "$c" in "python -m drag.cli index"*) echo ALIVE; exit 0;; esac; done; exit 1' 2>/dev/null | grep -q ALIVE; then
  echo "index job already alive — not starting a second one"
else
  nohup docker exec khamenei-rag python -m drag.cli index --collection-id c-86347897 >> "$D/data/khamenei/index.log" 2>&1 &
  echo "index started (pid $!), log: $D/data/khamenei/index.log"
  sleep 20
  tail -n 3 "$D/data/khamenei/index.log"
fi

echo "=== KHAMENEI SETUP OK ==="
echo "port 127.0.0.1:8106, collection c-86347897, image 0.1.1"
echo "next: verify index completion (index.log tail 'remaining': 0), then"
echo "registry provider + gateway consumer + nginx vhost khamenei.ai.ismc.ir"
