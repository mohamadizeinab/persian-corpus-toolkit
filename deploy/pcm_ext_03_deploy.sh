#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-EXT-03 — controlled deploy of the cross-browser run lock to s52
# (172.20.1.52)
#
# What this deploy ships:
#   1. backend/projects.py — per-project run lock (cross-browser single-run
#      enforcement): additive migration (run_owner / run_token /
#      run_heartbeat on projects) + 3 new routes:
#        POST /api/projects/<id>/run          (atomic claim; 409 + locked_by)
#        POST /api/projects/<id>/run/heartbeat (409 when no longer owner)
#        POST /api/projects/<id>/run/release   (owner-only; expired clearable)
#      RUN_LOCK_TTL = 180 s (self-heal for dead browsers).
#   2. extension v3.8 (background.js + content_picker.js + manifest) is
#      consumed LOCALLY by each user's Chrome (Load unpacked / Reload).
#      Nothing in this script deploys the extension; it only makes the
#      backend the single source of truth across browsers.
#
# Code identity: commit e38f914 (branch pcm-20.9-knowledge-studio-factory,
#   GitHub). Blobs verified below via `git hash-object` after extraction.
#
# PREP (on Windows, before SSH):
#   git archive --format=tar.gz --prefix=persian-corpus-toolkit/ \
#       e38f914 -o pct-code-ext03.tgz
#   scp -P 22 pct-code-ext03.tgz saber@172.20.1.52:/tmp/
#   scp -P 22 deploy/pcm_ext_03_deploy.sh saber@172.20.1.52:/tmp/
#   ssh -p 22 saber@172.20.1.52 'bash /tmp/pcm_ext_03_deploy.sh'
#
# Safety model (AGENTS.md §2/§3):
#   1. sqlite3 online backup (WAL-safe) + integrity_check BEFORE any change
#   2. tar snapshot of the whole deploy dir (DB excluded)
#   3. code extracted from `git archive e38f914` — NEVER rewrites
#      thesaurus.db, .env, or data/ (all untracked -> not in the tar)
#   4. blob-hash verification of key files against commit e38f914
#   5. `docker compose build backend && docker compose up -d backend` —
#      ONLY the backend service. NO `docker compose down`, NO volume removal.
#   6. The schema change is ADDITIVE (3x ALTER TABLE ... ADD COLUMN),
#      executed lazily by ensure_projects_schema on the first /run request
#      (the smoke probe below triggers it; a 404 probe on a non-existent
#      project changes NO state).
#   7. Live-crawl protection: project_pages / crawl_queue counters logged
#      BEFORE/AFTER and asserted not-decreasing. Extension write API
#      (/api/projects*) stays OPEN (AGENTS.md §2.6).
#
# ROLLBACK (if anything looks wrong):
#   a) code:  tar xzf /home/saber/backups/pct-deploy-<TS>.tar.gz \
#              -C /home/saber/saberprojects
#             docker compose build backend && docker compose up -d backend
#      (additive columns are ignored by old code — no DB rollback needed)
#   b) DB:    sqlite3 /home/saber/backups/thesaurus-<TS>.db \
#              ".restore /home/saber/saberprojects/persian-corpus-toolkit/backend/thesaurus.db"
#      (only if data rows were corrupted; not expected for this change)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
TS=$(date +%Y%m%d-%H%M%S)
BK=/home/saber/backups
CODE_TGZ=/tmp/pct-code-ext03.tgz
mkdir -p "$BK"

# expected blob SHAs (git rev-parse e38f914:<path>) — commit identity check
declare -A EXPECT=(
  [backend/projects.py]=b0411c05788cbba18f8e5c6a0f245360466894d0
  [backend/server.py]=b0cfa21357928aa125f70f7e47a647f087fc8b78
  [backend/Dockerfile]=0d211b9b1cb4f02a229189ed8d516c7ea7262032
  [docker-compose.yml]=fc05c99800a3c70d7516ee4aa3b1332ddd2df2ec
  [dashboard/index.html]=e548c3ac068faf17d3e6ed8ac35a2984eef38e08
  [extension/manifest.json]=68a963f8d39684b7ba365873628b9093f25e0c7e
)

STEP="init"
fail() { echo "!!! FAILED at [$STEP]: $1"; echo "!!! rollback: see header (snapshot + DB backup at TS=$TS)"; exit 1; }
trap 'fail "abnormal exit (line $LINENO)"' ERR

echo "=== 0. preconditions ==="
command -v docker >/dev/null || fail "docker missing"
[ -f "$CODE_TGZ" ] || fail "code tar not found at $CODE_TGZ (build with git archive e38f914, scp to s52:/tmp)"
[ -f "$APP/.env" ] || fail ".env missing (refusing to touch auth config)"
[ -f "$APP/backend/thesaurus.db" ] || fail "production DB missing — refusing"
cd "$APP"
docker compose config -q || fail "compose file invalid"

echo "=== 1. DB online backup (WAL-safe) + integrity ==="
sqlite3 "$APP/backend/thesaurus.db" ".backup $BK/thesaurus-${TS}.db"
[ "$(sqlite3 "$BK/thesaurus-${TS}.db" 'PRAGMA integrity_check;')" = "ok" ] || fail "backup integrity_check"
echo "backup ok: $BK/thesaurus-${TS}.db"

echo "=== 2. snapshot current deploy dir (DB excluded) ==="
tar czf "$BK/pct-deploy-${TS}.tar.gz" \
  --exclude=backend/thesaurus.db --exclude='backend/thesaurus.db-*' \
  --exclude=data \
  -C /home/saber/saberprojects persian-corpus-toolkit
echo "snapshot ok: $BK/pct-deploy-${TS}.tar.gz"

echo "=== 3. BEFORE: crawl state ==="
sqlite3 "$APP/backend/thesaurus.db" \
  "SELECT 'projects', COUNT(*) FROM projects;
   SELECT 'project_pages', COUNT(*) FROM project_pages;
   SELECT 'crawl_queue', COUNT(*) FROM crawl_queue;"
PAGES_BEFORE=$(sqlite3 "$APP/backend/thesaurus.db" "SELECT COUNT(*) FROM project_pages;")
echo "-- projects table columns BEFORE (lock cols may be absent on older DB) --"
sqlite3 "$APP/backend/thesaurus.db" "PRAGMA table_info(projects);" | sed 's/^/  /'

echo "=== 4. code tar ==="
ls -la "$CODE_TGZ"

echo "=== 5. extract new code (DB/.env/data untouched by definition) ==="
# tar carries prefix 'persian-corpus-toolkit/' -> extract into the PARENT dir
tar xzf "$CODE_TGZ" -C "$(dirname "$APP")"
echo "-- blob-identity check vs commit e38f914 --"
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
  if curl -sf http://127.0.0.1:5055/api/stats >/dev/null 2>&1; then ok=yes; break; fi
  sleep 1
done
[ -n "$ok" ] || fail "server not healthy after 60s"
echo "healthy after ~${i}s"

echo "=== 9. smoke: run-lock routes live + auth + extension API open ==="
echo "-- /api/auth/status --"
curl -s http://127.0.0.1:5055/api/auth/status; echo
echo "-- /api/projects (extension, must stay OPEN, expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://127.0.0.1:5055/api/projects
echo "-- /api/dashboard/projects NO cookie (expect 401) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://127.0.0.1:5055/api/dashboard/projects
echo "-- /dashboard/studio.html (expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://127.0.0.1:5055/dashboard/studio.html
STEP="9b"
echo "-- POST /api/projects/99999/run (probe: expect JSON 404 = route live; no state change) --"
RUN404=$(curl -s -o /tmp/ext03-run404 -w '%{http_code}' -X POST http://127.0.0.1:5055/api/projects/99999/run \
  -H 'Content-Type: application/json' -d '{"owner":"smoke-ext03","token":"smoke"}')
echo "HTTP:$RUN404 body: $(cat /tmp/ext03-run404)"
[ "$RUN404" = "404" ] || fail "expected 404 from /run probe, got $RUN404"
grep -q 'پروژه' /tmp/ext03-run404 || fail "run probe did not return the JSON 404 body (old backend?)"
rm -f /tmp/ext03-run404
echo "-- projects table columns AFTER probe (migration is lazy, additive) --"
COLS=$(sqlite3 "$APP/backend/thesaurus.db" "PRAGMA table_info(projects);")
echo "$COLS" | sed 's/^/  /'
echo "$COLS" | grep -q 'run_owner'     || fail "run_owner column missing (migration did not run)"
echo "$COLS" | grep -q 'run_token'     || fail "run_token column missing (migration did not run)"
echo "$COLS" | grep -q 'run_heartbeat' || fail "run_heartbeat column missing (migration did not run)"
echo "lock columns present: run_owner / run_token / run_heartbeat"

echo "=== 10. DB integrity (post-deploy) ==="
[ "$(sqlite3 "$APP/backend/thesaurus.db" 'PRAGMA integrity_check;')" = "ok" ] || fail "post-deploy integrity_check"
echo "integrity ok"

echo "=== 11. AFTER: crawl state (must not decrease) ==="
sleep 5
sqlite3 "$APP/backend/thesaurus.db" \
  "SELECT 'projects', COUNT(*) FROM projects;
   SELECT 'project_pages', COUNT(*) FROM project_pages;
   SELECT 'crawl_queue', COUNT(*) FROM crawl_queue;"
PAGES_AFTER=$(sqlite3 "$APP/backend/thesaurus.db" "SELECT COUNT(*) FROM project_pages;")
echo "project_pages: before=$PAGES_BEFORE after=$PAGES_AFTER"
[ "$PAGES_AFTER" -ge "$PAGES_BEFORE" ] || fail "crawl page count decreased!"

echo "=== DEPLOY OK (TS=$TS) ==="
echo "backups: $BK/thesaurus-${TS}.db + $BK/pct-deploy-${TS}.tar.gz"
echo "run-lock routes are live. Extension users should reload the extension"
echo "to v3.8 (chrome://extensions -> Reload) to use the cross-browser lock."
echo "Note: until a browser claims/releases, projects keep run_owner='' (unlocked)."
