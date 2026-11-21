#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-25 DC#5 — controlled deploy of the configurable embedding timeout to
# s52 (172.30.0.133), then re-submit the al-Ghadir corpus build and
# re-launch the DC5 embed watch.
#
# Why: the previous build (job j-7a192943) died at retry 3 with
# TimeoutError: the per-request embedding timeout was hardcoded 120s and
# the ~2,656-batch al-Ghadir export (mxbai-embed-large via shared Ollama)
# runs ~6s per batch — any slow batch killed the whole export with no
# checkpoint. DC5 watch final: 5 PASS / 3 FAIL (the 3 embedding asserts).
#
# What this deploy ships:
#   1. backend/knowledge_api.py — _embedding_timeout() (PCT_EMBEDDING_TIMEOUT,
#      default 600.0) used by _embedding_request.
#   2. backend/test_pipeline.py — EM-07 (3 tests: default/override/invalid).
#   3. docker-compose.yml — PCT_EMBEDDING_TIMEOUT: ${PCT_EMBEDDING_TIMEOUT:-}
#      in the backend environment block (compose change -> container
#      recreated by `up -d`, so the new env is guaranteed live).
#   4. .env (s52) — idempotent append PCT_EMBEDDING_TIMEOUT=600.
#
# Code identity: commit ad729fa (branch pcm-20.9-knowledge-studio-factory).
# Blobs verified below via `git hash-object` after extraction.
#
# PREP (on Windows, before SSH):
#   git archive -o pct-code-dc5embed.tgz ad729fa21257311b528b81fb898174b09ce4e036
#   scp pct-code-dc5embed.tgz saber@172.30.0.133:/tmp/
#   scp .recon/p48_dc5_embed_watch.sh saber@172.30.0.133:/tmp/dc5_embed_watch.sh
#   scp deploy/pcm25_dc5embed_deploy.sh saber@172.30.0.133:/tmp/
#   ssh -p 22 -o BatchMode=yes saber@172.30.0.133 'bash /tmp/pcm25_dc5embed_deploy.sh'
#
# Safety model (AGENTS.md §2/§3):
#   1. sqlite3 online backup + integrity_check BEFORE any change.
#   2. tar snapshot of the deploy dir (DB/data excluded).
#   3. code from `git archive ad729fa` — never rewrites thesaurus.db,
#      .env, or data/ (untracked -> not in the tar).
#   4. blob-hash verification against commit ad729fa.
#   5. `docker compose build backend && up -d backend` — ONLY backend.
#      NO `down`, NO volume removal. The compose env change recreates the
#      container (required so PCT_EMBEDDING_TIMEOUT is live).
#   6. No schema change (embedding_* columns already additive from PCM-22).
#   7. Re-submit POST /collections/10/corpus/build: force_retry resets the
#      failed row j-7a192943 (retry_count 3->4) — SAME job id, so the
#      watch script's JOB variable stays valid. The build short-circuits
#      (dumps REUSED, corpus REUSED, ES alias no-op switch) and spends
#      its ~2.2h in the embedding export.
#
# ROLLBACK: see pcm22_deploy.sh header (snapshot + DB backup at TS below).
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
TS=$(date +%Y%m%d-%H%M%S)
BK=/home/saber/backups
CODE_TGZ=/tmp/pct-code-dc5embed.tgz
WATCH=/tmp/dc5_embed_watch.sh
CK=/tmp/dc5c-deploy
BASE=http://127.0.0.1:5055
CID_INT=10
mkdir -p "$BK"

declare -A EXPECT=(
  [backend/knowledge_api.py]=42fa119825f84c3274b3f310700b1dd69879d304
  [backend/test_pipeline.py]=9888d4becc9d96dc60f8cde5f2d962294a639c11
  [docker-compose.yml]=430bb5c41e3c93051b234b513bc1acd31b395f66
  [backend/server.py]=008330dc07e1d3a20933326d24da11c24427e675
  [backend/Dockerfile]=0d211b9b1cb4f02a229189ed8d516c7ea7262032
  [dashboard/studio.html]=81ec6f8852b6bea4e93ef93538fb2fdd2d42243c
  [backend/requirements.txt]=128c57e09a1c78c82f4c2244cc3ae8267ba3630e
)

STEP="init"
fail() { echo "!!! FAILED at [$STEP]: $1"; echo "!!! rollback: snapshot + DB backup at TS=$TS"; exit 1; }
trap 'fail "abnormal exit (line $LINENO)"' ERR

echo "=== 0. preconditions ==="
command -v docker >/dev/null || fail "docker missing"
[ -f "$CODE_TGZ" ] || fail "code tar not found at $CODE_TGZ"
[ -f "$WATCH" ] || fail "watch script not found at $WATCH (scp .recon/p48_dc5_embed_watch.sh)"
[ -f "$APP/.env" ] || fail ".env missing (refusing to touch auth config)"
[ -f "$APP/backend/thesaurus.db" ] || fail "production DB missing — refusing"
cd "$APP"
docker compose config -q || fail "compose file invalid (pre-extract check)"

echo "=== 1. DB online backup (WAL-safe) + integrity ==="
sqlite3 "$APP/backend/thesaurus.db" ".backup $BK/thesaurus-${TS}.db"
[ "$(sqlite3 "$BK/thesaurus-${TS}.db" 'PRAGMA integrity_check;')" = "ok" ] || fail "backup integrity_check"
echo "backup ok: $BK/thesaurus-${TS}.db"

echo "=== 2. snapshot current deploy dir (DB/data excluded) ==="
tar czf "$BK/pct-deploy-${TS}.tar.gz" \
  --exclude=backend/thesaurus.db --exclude='backend/thesaurus.db-*' \
  --exclude=data \
  -C /home/saber/saberprojects persian-corpus-toolkit
echo "snapshot ok: $BK/pct-deploy-${TS}.tar.gz"

echo "=== 3. BEFORE: crawl + knowledge state ==="
sqlite3 "$APP/backend/thesaurus.db" \
  "SELECT 'projects', COUNT(*) FROM projects;
   SELECT 'project_pages', COUNT(*) FROM project_pages;
   SELECT 'crawl_queue', COUNT(*) FROM crawl_queue;
   SELECT 'index_builds', COUNT(*) FROM knowledge_index_builds;
   SELECT 'knowledge_jobs', COUNT(*) FROM knowledge_jobs;"
PAGES_BEFORE=$(sqlite3 "$APP/backend/thesaurus.db" "SELECT COUNT(*) FROM project_pages;")
sqlite3 -header "$APP/backend/thesaurus.db" \
  "SELECT job_id, status, stage, retry_count, error FROM knowledge_jobs
   WHERE job_key='corpus_build:c-f4571ff9' ORDER BY created_at DESC LIMIT 2;"

echo "=== 4. extract new code (DB/.env/data untouched by definition) ==="
tar xzf "$CODE_TGZ" -C "$(dirname "$APP")"
echo "-- blob-identity check vs commit ad729fa --"
for f in "${!EXPECT[@]}"; do
  [ -f "$APP/$f" ] || fail "missing $f after extract"
  got=$(git hash-object "$APP/$f")
  [ "$got" = "${EXPECT[$f]}" ] || fail "blob mismatch $f: got $got want ${EXPECT[$f]}"
  echo "ok  $f"
done
[ -f "$APP/backend/thesaurus.db" ] || fail "production DB vanished after extract"
docker compose config -q || fail "compose file invalid (post-extract)"

echo "=== 5. .env ensure (password untouched; PCT_EMBEDDING_TIMEOUT idempotent) ==="
grep -q '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" || fail ".env lacks PCT_DASHBOARD_PASSWORD"
if grep -q '^PCT_EMBEDDING_TIMEOUT=' "$APP/.env"; then
  echo ".env already has PCT_EMBEDDING_TIMEOUT: $(grep '^PCT_EMBEDDING_TIMEOUT=' "$APP/.env")"
else
  echo 'PCT_EMBEDDING_TIMEOUT=600' >> "$APP/.env"
  echo ".env: appended PCT_EMBEDDING_TIMEOUT=600"
fi
chmod 600 "$APP/.env"

echo "=== 6. rebuild image + recreate backend (compose env change forces it) ==="
OLD_IMAGE=$(docker inspect persian-corpus-toolkit-backend-1 --format '{{.Image}}' 2>/dev/null || echo none)
docker compose build backend
docker compose up -d backend
NEW_IMAGE=$(docker inspect persian-corpus-toolkit-backend-1 --format '{{.Image}}')
echo "image: $OLD_IMAGE -> $NEW_IMAGE"

echo "=== 7. health wait (90s) ==="
ok=""
for i in $(seq 1 90); do
  if curl -sf "$BASE/api/stats" >/dev/null 2>&1; then ok=yes; break; fi
  sleep 1
done
[ -n "$ok" ] || fail "server not healthy after 90s"
echo "healthy after ~${i}s"

STEP="verify"
echo "=== 8. verify new code + env inside the container ==="
docker exec persian-corpus-toolkit-backend-1 env | grep -E '^PCT_EMBEDDING_(URL|MODEL|DIM|TIMEOUT)=' | sed 's/^/env: /' || true
TMG=$(docker exec persian-corpus-toolkit-backend-1 python3 -c \
  "import knowledge_api as k; print(k._embedding_timeout())" 2>/dev/null || echo import-error)
echo "in-container _embedding_timeout() -> $TMG"
case "$TMG" in 600.0|600) : ;; *) fail "_embedding_timeout() not 600 (got: $TMG)" ;; esac

echo "=== 9. smoke: regression (PCM-21/22 markers) ==="
echo "-- /api/auth/status --"
curl -s "$BASE/api/auth/status"; echo
echo "-- /api/projects (extension, must stay OPEN, expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/api/projects"
echo "-- /api/knowledge/collections NO cookie (expect 401) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/api/knowledge/collections"
echo "-- /dashboard/ + /dashboard/studio.html (expect 200 + stageStrip) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/dashboard/"
STU=$(curl -s "$BASE/dashboard/studio.html")
case "$STU" in *stageStrip*) : ;; *) fail "studio.html missing stageStrip (old dashboard?)" ;; esac
STATS=$(curl -s "$BASE/api/stats")
case "$STATS" in *queue_by_site*) : ;; *) fail "/api/stats has no queue_by_site (regression?)" ;; esac
PROG=$(curl -s "$BASE/api/thesaurus/progress")
NSC=$(echo "$PROG" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sciences"]))' 2>/dev/null || echo 0)
[ "$NSC" = "13" ] || fail "expected 13 sciences, got $NSC"
KC=$(curl -s "$BASE/api/khamenei/crawl-status")
case "$KC" in *pending_by_year*) : ;; *) fail "khamenei crawl-status missing pending_by_year (regression?)" ;; esac
echo "regression smoke OK (projects open, 401 auth, studio, queue_by_site, 13 sciences, pending_by_year)"

STEP="resubmit"
echo "=== 10. re-submit corpus build for collection 10 (al-Ghadir) ==="
export P25PW=$(grep '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" | cut -d= -f2-)
[ -n "$P25PW" ] || fail ".env PCT_DASHBOARD_PASSWORD empty"
rm -f "$CK"
LOGIN=$(python3 -c 'import json,os; print(json.dumps({"password": os.environ["P25PW"]}))')
curl -s -c "$CK" -H 'Content-Type: application/json' -d "$LOGIN" "$BASE/api/auth/login" -o /dev/null -w 'login HTTP:%{http_code}\n'
[ -f "$CK" ] || fail "login did not set cookie"

BUILD=$(curl -s -b "$CK" -X POST "$BASE/api/knowledge/collections/$CID_INT/corpus/build")
echo "$BUILD" | head -c 400; echo
JOBID=$(echo "$BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["job_id"])')
QUEUED=$(echo "$BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["queued"])')
[ "$JOBID" = "j-7a192943" ] || fail "expected same job row j-7a192943 (force_retry), got $JOBID"
[ "$QUEUED" = "True" ] || fail "build not (re)queued (queued=$QUEUED)"
echo "corpus build re-queued: $JOBID (force_retry reuses the failed row)"

STEP="jobwait"
echo "=== 11. confirm the job actually runs (no instant failure, 120s) ==="
ST="waiting"
ERRMSG=""
for i in $(seq 1 24); do
  sleep 5
  JS=$(curl -s -b "$CK" "$BASE/api/knowledge/jobs")
  ROW=$(echo "$JS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next((x for x in d['jobs'] if x['job_id'] == '$JOBID'), None)
print(row['status'], '|', (row['stage'] or ''), '|', (row['error'] or '')) if row else print('missing', '|', '', '')")
  ST=${ROW%%|*}
  ERRMSG=$(echo "$ROW" | cut -d'|' -f3)
  case "$ST" in
    succeeded|failed) break;;
  esac
  echo "t=$((i*5))s status=$ST stage=$(echo "$ROW" | cut -d'|' -f2)"
done
echo "job after wait: $ST (error: ${ERRMSG:-none})"
[ "$ST" = "failed" ] && fail "job failed immediately after re-submit — error: $ERRMSG"
[ "$ST" = "succeeded" ] && echo "job already succeeded (unexpected this fast — check watch log)"

STEP="watch"
echo "=== 12. re-launch the DC5 embed watch (same JOB id — row was reused) ==="
pkill -f dc5_embed_watch.sh 2>/dev/null || true
sleep 1
grep -q "^JOB=j-7a192943" "$WATCH" || fail "watch script JOB var is not j-7a192943 (update it before nohup)"
nohup bash "$WATCH" >> /tmp/dc5_embed_watch.out 2>&1 &
WPID=$!
sleep 2
kill -0 "$WPID" 2>/dev/null || fail "watch process died at startup (see /tmp/dc5_embed_watch.out)"
echo "watch running (pid $WPID), log: /tmp/dc5_embed_monitor.log"
tail -n 3 /tmp/dc5_embed_monitor.log 2>/dev/null || true

echo "=== 13. DB integrity (post-deploy) + AFTER counters ==="
[ "$(sqlite3 "$APP/backend/thesaurus.db" 'PRAGMA integrity_check;')" = "ok" ] || fail "post-deploy integrity_check"
echo "integrity ok"
PAGES_AFTER=$(sqlite3 "$APP/backend/thesaurus.db" "SELECT COUNT(*) FROM project_pages;")
echo "project_pages: before=$PAGES_BEFORE after=$PAGES_AFTER"
[ "$PAGES_AFTER" -ge "$PAGES_BEFORE" ] || fail "crawl page count decreased!"
sqlite3 -header "$APP/backend/thesaurus.db" \
  "SELECT job_id, status, stage, retry_count, error FROM knowledge_jobs
   WHERE job_key='corpus_build:c-f4571ff9' ORDER BY created_at DESC LIMIT 2;"
rm -f "$CK"

echo "=== DEPLOY OK (TS=$TS) ==="
echo "backups: $BK/thesaurus-${TS}.db + $BK/pct-deploy-${TS}.tar.gz"
echo "PCT_EMBEDDING_TIMEOUT live in container (default 600s verified)."
echo "Build re-queued: $JOBID (retry_count now 4). Watch pid $WPID."
echo "Expected: job runs ~2.2h (embedding export, 2,656 batches), then the"
echo "watch appends 'DC5 TOTAL: 8 PASS / 0 FAIL' to /tmp/dc5_embed_monitor.log."
