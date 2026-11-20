#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-22 — controlled deploy of Studio stage cards (A→B→C→D→E→RELEASE) +
# guarded embedding export (contract emb-1) to s52 (172.30.0.133)
#
# What this deploy ships (NO schema change on disk — the 4 embedding_*
# columns are ADDITIVE and created idempotently by _ensure_build_columns):
#   1. backend/knowledge_api.py
#        - guarded embedding factory _embed_corpus_factory (emb-1):
#          no PCT_EMBEDDING_URL + PCT_EMBEDDING_MODEL -> row
#          embedding_status='blocked' (Persian detail, endpoint never
#          called); config present -> batched embeddings of
#          normalized.unique.jsonl -> embeddings.jsonl +
#          embedding-manifest.json (deterministic archive sha UNCHANGED);
#          idempotent reuse when manifest (corpus_sha256+model+sha) matches;
#          PCT_EMBEDDING_DIM mismatch -> job retryable failure.
#        - _job_kind_corpus_build settles embeddings at all 3 exit points
#          (reuse / no-ES / ES-success) + audit 'embeddings' entries.
#        - GET /corpus/builds + index-build detail expose the 4 new
#          embedding_* columns (NULL = pre-PCM-22 rows).
#   2. dashboard/studio.html
#        - stage-card strip A_IMPORT→B_PROCESS→C_SCHEMA→D_BUILD→E_ACCEPT→
#          RELEASE with real counters + per-stage actions.
#        - Embedding badge column in the corpus builds table.
#   3. backend/test_pipeline.py (EM-01..EM-06 regression, 34 tests)
#
# Code identity: commit 05c31a5 (branch pcm-20.9-knowledge-studio-factory,
#   GitHub). Blobs verified below via `git hash-object` after extraction.
#
# PREP (on Windows, before SSH):
#   git archive --format=tar.gz --prefix=persian-corpus-toolkit/ \
#       05c31a5 -o pct-code-pcm22.tgz
#   scp -P 22 pct-code-pcm22.tgz saber@172.30.0.133:/tmp/
#   scp -P 22 deploy/pcm22_deploy.sh saber@172.30.0.133:/tmp/
#   ssh -p 22 -o BatchMode=yes saber@172.30.0.133 'bash /tmp/pcm22_deploy.sh'
#
# Safety model (AGENTS.md §2/§3):
#   1. sqlite3 online backup (WAL-safe) + integrity_check BEFORE any change
#   2. tar snapshot of the deploy dir (DB/data excluded)
#   3. code extracted from `git archive 05c31a5` — NEVER rewrites
#      thesaurus.db, .env, or data/ (untracked -> not in the tar)
#   4. blob-hash verification of key files against commit 05c31a5
#   5. `docker compose build backend && docker compose up -d backend` —
#      ONLY the backend service. NO `docker compose down`, NO volume removal.
#   6. NO destructive migration: _ensure_build_columns is additive +
#      idempotent (CREATE TABLE IF NOT EXISTS + ADD COLUMN if missing).
#   7. Live-crawl protection: project_pages / crawl_queue counters logged
#      BEFORE/AFTER and asserted not-decreasing. Extension write API
#      (/api/projects*) stays OPEN; /api/knowledge/* stays behind auth.
#   8. The PCM-22 LIVE smoke runs a real corpus build on collection
#      c-29a205c5 (mizan3, 20 parsed docs): with .env holding ONLY
#      PCT_DASHBOARD_PASSWORD the expected settlement is
#      es_index_status='blocked' + embedding_status='blocked' +
#      non-null content_sha256 (guarded path, zero external calls).
#
# ROLLBACK (if anything looks wrong):
#   a) code:  tar xzf /home/saber/backups/pct-deploy-<TS>.tar.gz \
#              -C /home/saber/saberprojects
#             docker compose build backend && docker compose up -d backend
#   b) DB:    sqlite3 /home/saber/backups/thesaurus-<TS>.db \
#              ".restore /home/saber/saberprojects/persian-corpus-toolkit/backend/thesaurus.db"
#      (only if rows were corrupted; not expected — additive columns only)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
TS=$(date +%Y%m%d-%H%M%S)
BK=/home/saber/backups
CODE_TGZ=/tmp/pct-code-pcm22.tgz
CK=/tmp/pcm22-cookies
BASE=http://127.0.0.1:5055
mkdir -p "$BK"

# expected blob SHAs (git rev-parse 05c31a5:<path>) — commit identity check
declare -A EXPECT=(
  [backend/knowledge_api.py]=5e871c08c6391860b1ea88160538e367104f9142
  [backend/test_pipeline.py]=fde25f1f9d594e0d757010065c4ba997ea7bb743
  [dashboard/studio.html]=0cbeef2bd4d6833aa2f900df10fe8cb27a682dd7
  [backend/server.py]=e6868ea564182051c220e5025069484c8341d05e
  [backend/Dockerfile]=0d211b9b1cb4f02a229189ed8d516c7ea7262032
  [docker-compose.yml]=fc05c99800a3c70d7516ee4aa3b1332ddd2df2ec
)

STEP="init"
fail() { echo "!!! FAILED at [$STEP]: $1"; echo "!!! rollback: see header (snapshot + DB backup at TS=$TS)"; exit 1; }
trap 'fail "abnormal exit (line $LINENO)"' ERR

echo "=== 0. preconditions ==="
command -v docker >/dev/null || fail "docker missing"
[ -f "$CODE_TGZ" ] || fail "code tar not found at $CODE_TGZ (build with git archive 05c31a5, scp to s52:/tmp)"
[ -f "$APP/.env" ] || fail ".env missing (refusing to touch auth config)"
[ -f "$APP/backend/thesaurus.db" ] || fail "production DB missing — refusing"
cd "$APP"
docker compose config -q || fail "compose file invalid"

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
BUILDS_BEFORE=$(sqlite3 "$APP/backend/thesaurus.db" "SELECT COUNT(*) FROM knowledge_index_builds;")

echo "=== 4. code tar ==="
ls -la "$CODE_TGZ"

echo "=== 5. extract new code (DB/.env/data untouched by definition) ==="
tar xzf "$CODE_TGZ" -C "$(dirname "$APP")"
echo "-- blob-identity check vs commit 05c31a5 --"
for f in "${!EXPECT[@]}"; do
  [ -f "$APP/$f" ] || fail "missing $f after extract"
  got=$(git hash-object "$APP/$f")
  [ "$got" = "${EXPECT[$f]}" ] || fail "blob mismatch $f: got $got want ${EXPECT[$f]}"
  echo "ok  $f"
done
[ -f "$APP/backend/thesaurus.db" ] || fail "production DB vanished after extract (should be impossible — not in tar)"

echo "=== 6. .env ensure (password untouched, chmod 600) ==="
if grep -q '^PCT_DASHBOARD_PASSWORD=' "$APP/.env"; then
  echo ".env already has PCT_DASHBOARD_PASSWORD — leaving untouched"
else
  fail ".env lacks PCT_DASHBOARD_PASSWORD (refusing to guess)"
fi
chmod 600 "$APP/.env"

echo "=== 7. rebuild image + recreate backend container (NO down, NO volume removal) ==="
OLD_IMAGE=$(docker inspect persian-corpus-toolkit-backend-1 --format '{{.Image}}' 2>/dev/null || echo none)
docker compose build backend
docker compose up -d backend
NEW_IMAGE=$(docker inspect persian-corpus-toolkit-backend-1 --format '{{.Image}}')
echo "image: $OLD_IMAGE -> $NEW_IMAGE"

echo "=== 8. health wait ==="
ok=""
for i in $(seq 1 60); do
  if curl -sf "$BASE/api/stats" >/dev/null 2>&1; then ok=yes; break; fi
  sleep 1
done
[ -n "$ok" ] || fail "server not healthy after 60s"
echo "healthy after ~${i}s"

STEP="smoke"
echo "=== 9. smoke: PCM-22 live + PCM-21 regression ==="
echo "-- /api/auth/status --"
curl -s "$BASE/api/auth/status"; echo
echo "-- /api/projects (extension, must stay OPEN, expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/api/projects"
echo "-- /api/knowledge/collections NO cookie (expect 401) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/api/knowledge/collections"
echo "-- /dashboard/ (expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/dashboard/"
echo "-- /dashboard/studio.html (expect 200 + PCM-22 stage-strip marker) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/dashboard/studio.html"
STU=$(curl -s "$BASE/dashboard/studio.html")
case "$STU" in *stageStrip*) : ;; *) fail "studio.html missing stageStrip (old dashboard?)" ;; esac
case "$STU" in *data-stage-act*) : ;; *) fail "studio.html missing data-stage-act actions (old dashboard?)" ;; esac
echo "studio.html PCM-22 markers present"

echo "-- PCM-21 regression: /api/stats queue_by_site --"
STATS=$(curl -s "$BASE/api/stats")
case "$STATS" in *queue_by_site*) : ;; *) fail "/api/stats has no queue_by_site (regression?)" ;; esac
echo "queue_by_site present"
echo "-- PCM-21 regression: /api/thesaurus/progress (13 sciences) --"
PROG=$(curl -s "$BASE/api/thesaurus/progress")
NSC=$(echo "$PROG" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sciences"]))' 2>/dev/null || echo 0)
[ "$NSC" = "13" ] || fail "expected 13 sciences, got $NSC"
echo "sciences: $NSC"
echo "-- PCM-21 regression: /api/khamenei/crawl-status pending_by_year --"
KC=$(curl -s "$BASE/api/khamenei/crawl-status")
case "$KC" in *pending_by_year*) : ;; *) fail "khamenei crawl-status missing pending_by_year (regression?)" ;; esac
echo "pending_by_year present"

echo "-- PCM-22 LIVE: login + real corpus build on c-29a205c5 (mizan3, 20 docs) --"
export P22PW=$(grep '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" | cut -d= -f2-)
[ -n "$P22PW" ] || fail ".env PCT_DASHBOARD_PASSWORD empty"
rm -f "$CK"
LOGIN=$(python3 -c 'import json,os; print(json.dumps({"password": os.environ["P22PW"]}))')
curl -s -c "$CK" -H 'Content-Type: application/json' -d "$LOGIN" "$BASE/api/auth/login" -o /tmp/pcm22-login -w 'login HTTP:%{http_code}\n'
[ -f "$CK" ] || fail "login did not set cookie"
unset P22PW

COLLJSON=$(curl -s -b "$CK" "$BASE/api/knowledge/collections")
echo "$COLLJSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("collections total:", d["total"])'
CID=$(echo "$COLLJSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = next(x for x in d["collections"] if x["collection_id"] == "c-29a205c5")
print(r["id"])')
[ -n "$CID" ] || fail "collection c-29a205c5 not found in /api/knowledge/collections"
echo "c-29a205c5 -> int id $CID"

BUILD=$(curl -s -b "$CK" -X POST "$BASE/api/knowledge/collections/$CID/corpus/build")
echo "$BUILD" | head -c 400; echo
JOBID=$(echo "$BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["job_id"])')
DOCSN=$(echo "$BUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["documents"])')
[ -n "$JOBID" ] || fail "no job_id in corpus/build response"
echo "corpus build job: $JOBID (documents: $DOCSN)"

STEP="jobwait"
ST="waiting"
for i in $(seq 1 150); do
  JS=$(curl -s -b "$CK" "$BASE/api/knowledge/jobs")
  ST=$(echo "$JS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next((x for x in d['jobs'] if x['job_id'] == '$JOBID'), None)
print(row['status'] if row else 'waiting')")
  case "$ST" in succeeded|failed|interrupted) break;; esac
  sleep 2
done
echo "job status after wait: $ST"
[ "$ST" = "succeeded" ] || fail "corpus build job not succeeded (status=$ST) — see /api/knowledge/jobs error"
STAGE=$(echo "$JS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
row = next(x for x in d['jobs'] if x['job_id'] == '$JOBID')
print(row['stage'], '| progress:', row['progress'], '/', row['total'], '| error:', repr(row['error']))")
echo "job final: $STAGE"

STEP="builds"
BUILDS=$(curl -s -b "$CK" "$BASE/api/knowledge/collections/$CID/corpus/builds")
echo "$BUILDS" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d.get("ok") is True, d
b = d["builds"][0]
assert b["es_index_status"] == "blocked", "es: %r" % b["es_index_status"]
assert b["embedding_status"] == "blocked", "emb: %r" % b["embedding_status"]
assert b["content_sha256"], "content_sha256 empty"
assert b["embedding_detail"], "embedding_detail empty"
print("build row OK: iv=%s status=%s" % (b["iv_id"], b["status"]))
print("es_index_status=%s embedding_status=%s" % (b["es_index_status"], b["embedding_status"]))
print("content_sha256=%s..." % b["content_sha256"][:16])
print("embedding_detail: %s" % b["embedding_detail"][:160])'
IVID=$(echo "$BUILDS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["builds"][0]["iv_id"])')

echo "-- index-build detail (4 new embedding_* columns, SELECT *) --"
DET=$(curl -s -b "$CK" "$BASE/api/knowledge/index-builds/$IVID")
echo "$DET" | python3 -c '
import json, sys
d = json.load(sys.stdin)
b = d["build"]
for k in ("embedding_status", "embedding_model", "embedding_dim", "embedding_detail"):
    assert k in b, "missing column %s" % k
print("detail columns present: embedding_status=%r model=%r dim=%r" % (
    b["embedding_status"], b["embedding_model"], b["embedding_dim"]))'

echo "-- audit trail: 'embeddings' entry recorded --"
AUD=$(curl -s -b "$CK" "$BASE/api/knowledge/collections/$CID/audit")
echo "$AUD" | python3 -c '
import json, sys
d = json.load(sys.stdin)
acts = [e.get("action") for e in d.get("entries", [])]
assert "embeddings" in acts, "no embeddings audit entry: %s" % acts[-8:]
print("audit entries (tail):", acts[-8:])'

echo "=== 10. DB integrity (post-deploy) ==="
[ "$(sqlite3 "$APP/backend/thesaurus.db" 'PRAGMA integrity_check;')" = "ok" ] || fail "post-deploy integrity_check"
echo "integrity ok"

echo "=== 11. AFTER: crawl + knowledge state ==="
sleep 5
sqlite3 "$APP/backend/thesaurus.db" \
  "SELECT 'projects', COUNT(*) FROM projects;
   SELECT 'project_pages', COUNT(*) FROM project_pages;
   SELECT 'crawl_queue', COUNT(*) FROM crawl_queue;
   SELECT 'index_builds', COUNT(*) FROM knowledge_index_builds;
   SELECT 'knowledge_jobs', COUNT(*) FROM knowledge_jobs;"
PAGES_AFTER=$(sqlite3 "$APP/backend/thesaurus.db" "SELECT COUNT(*) FROM project_pages;")
BUILDS_AFTER=$(sqlite3 "$APP/backend/thesaurus.db" "SELECT COUNT(*) FROM knowledge_index_builds;")
echo "project_pages: before=$PAGES_BEFORE after=$PAGES_AFTER"
echo "index_builds:  before=$BUILDS_BEFORE after=$BUILDS_AFTER (additive smoke row expected: +1 or +0 on reuse)"
[ "$PAGES_AFTER" -ge "$PAGES_BEFORE" ] || fail "crawl page count decreased!"
[ "$BUILDS_AFTER" -ge "$BUILDS_BEFORE" ] || fail "index_builds count decreased!"
rm -f "$CK" /tmp/pcm22-login

echo "=== DEPLOY OK (TS=$TS) ==="
echo "backups: $BK/thesaurus-${TS}.db + $BK/pct-deploy-${TS}.tar.gz"
echo "PCM-22 live: studio stage cards (A→B→C→D→E→RELEASE) + guarded"
echo "embedding export (emb-1). Live smoke: corpus build on c-29a205c5"
echo "settled es=blocked + embedding=blocked (no PCT_ES_URL /"
echo "PCT_EMBEDDING_* in .env) with content_sha256 + audit trail."
echo "Next (new scenario): add PCT_EMBEDDING_URL=http://172.20.1.53:11434/v1"
echo "+ PCT_EMBEDDING_MODEL=mxbai-embed-large + PCT_EMBEDDING_DIM=1024 to"
echo ".env, re-run the corpus build -> REUSED row settles to embedding"
echo "success (emb-1 export written, archive sha unchanged)."
