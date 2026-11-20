#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-21 — controlled deploy of dashboard counters with EXPLICIT SOURCES to
# s52 (172.30.0.133 — new vCenter IP)
#
# What this deploy ships (NO schema change — queries + code only):
#   1. backend/server.py
#        - /api/stats gains queue_by_site (per-site total/pending/done,
#          source: crawl_queue.site) so the dashboard can show WHERE
#          "در صف" comes from.
#        - NEW GET /api/thesaurus/progress — per-science list-scan
#          (crawl_progress cursors), content queue (crawl_queue), saved
#          items (crawled_data), main-type totals, harvest job state.
#        - /api/khamenei/crawl-status gains pending_by_year (past years
#          still waiting in the queue, parsed from source_page year=YYYY).
#        - /api/corpus/list also lists built versioned tasnim artifacts
#          (data/tasnim/<root>/{corpus,datasets,dumps}/vNNNN) when present;
#          empty section when the dir is absent (graceful).
#   2. backend/dashboard_api.py
#        - dash_project_detail pages_summary gains last_page_number =
#          the REAL last page captured (item_index in last URL, else max
#          numeric captured value, else null) — NEVER the configured
#          stop_number.
#   3. dashboard/index.html
#        - "در صف" labelled with its source (crawl_queue) + per-site chips.
#        - "ادامه پردازش" button -> POST /api/reset-queue (crawling ->
#          pending) so stuck crawl resumes automatically via the extension.
#        - Thesaurus card: real scan/content progress + per-science table
#          + "اسکن / ادامه اسکن" button (async elastic-harvest job,
#          resumes from last cursor).
#        - Khamenei card: pending past years + "ادامه سال‌های گذشته"
#          button (opens each pending year list page in a new tab; the
#          browser extension auto-seeds+crawls — CloudGuard is browser
#          only) + roadmap note to studio.
#        - Corpus section: versioned tasnim artifacts table + legacy.
#        - Project detail: "آخرین شماره صفحه واقعی" stat card.
#
# Code identity: commit 998ecaf (branch pcm-20.9-knowledge-studio-factory,
#   GitHub). Blobs verified below via `git hash-object` after extraction.
#
# PREP (on Windows, before SSH):
#   git archive --format=tar.gz --prefix=persian-corpus-toolkit/ \
#       998ecaf -o pct-code-pcm21.tgz
#   scp -P 22 pct-code-pcm21.tgz saber@172.30.0.133:/tmp/
#   scp -P 22 deploy/pcm21_deploy.sh saber@172.30.0.133:/tmp/
#   ssh -p 22 saber@172.30.0.133 'bash /tmp/pcm21_deploy.sh'
#
# Safety model (AGENTS.md §2/§3):
#   1. sqlite3 online backup (WAL-safe) + integrity_check BEFORE any change
#   2. tar snapshot of the whole deploy dir (DB excluded)
#   3. code extracted from `git archive 998ecaf` — NEVER rewrites
#      thesaurus.db, .env, or data/ (all untracked -> not in the tar)
#   4. blob-hash verification of key files against commit 998ecaf
#   5. `docker compose build backend && docker compose up -d backend` —
#      ONLY the backend service. NO `docker compose down`, NO volume
#      removal.
#   6. NO schema migration in this deploy (read-only queries + code).
#   7. Live-crawl protection: project_pages / crawl_queue counters logged
#      BEFORE/AFTER and asserted not-decreasing. Extension write API
#      (/api/projects*) stays OPEN (AGENTS.md §2.6); /api/dashboard/* +
#      /api/knowledge/* stay behind auth.
#
# ROLLBACK (if anything looks wrong):
#   a) code:  tar xzf /home/saber/backups/pct-deploy-<TS>.tar.gz \
#              -C /home/saber/saberprojects
#             docker compose build backend && docker compose up -d backend
#   b) DB:    sqlite3 /home/saber/backups/thesaurus-<TS>.db \
#              ".restore /home/saber/saberprojects/persian-corpus-toolkit/backend/thesaurus.db"
#      (only if data rows were corrupted; not expected for this change)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
APP=/home/saber/saberprojects/persian-corpus-toolkit
TS=$(date +%Y%m%d-%H%M%S)
BK=/home/saber/backups
CODE_TGZ=/tmp/pct-code-pcm21.tgz
mkdir -p "$BK"

# expected blob SHAs (git rev-parse 998ecaf:<path>) — commit identity check
declare -A EXPECT=(
  [backend/server.py]=e6868ea564182051c220e5025069484c8341d05e
  [backend/dashboard_api.py]=a72baa3369de22a8a83b1a1898eed5585c0174c1
  [dashboard/index.html]=0f596b82dfce93e4431aab6672ddb23b63a994db
  [backend/test_api.py]=659293001e773690efb538930f2d6138c0eff9d6
  [backend/test_dashboard.py]=368c6ab7e55eac1b5a084b06658ae8089e782e6f
  [backend/Dockerfile]=0d211b9b1cb4f02a229189ed8d516c7ea7262032
  [docker-compose.yml]=fc05c99800a3c70d7516ee4aa3b1332ddd2df2ec
)

STEP="init"
fail() { echo "!!! FAILED at [$STEP]: $1"; echo "!!! rollback: see header (snapshot + DB backup at TS=$TS)"; exit 1; }
trap 'fail "abnormal exit (line $LINENO)"' ERR

echo "=== 0. preconditions ==="
command -v docker >/dev/null || fail "docker missing"
[ -f "$CODE_TGZ" ] || fail "code tar not found at $CODE_TGZ (build with git archive 998ecaf, scp to s52:/tmp)"
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

echo "=== 4. code tar ==="
ls -la "$CODE_TGZ"

echo "=== 5. extract new code (DB/.env/data untouched by definition) ==="
# tar carries prefix 'persian-corpus-toolkit/' -> extract into the PARENT dir
tar xzf "$CODE_TGZ" -C "$(dirname "$APP")"
echo "-- blob-identity check vs commit 998ecaf --"
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

echo "=== 9. smoke: PCM-21 endpoints live + auth + extension API open ==="
echo "-- /api/auth/status --"
curl -s http://127.0.0.1:5055/api/auth/status; echo
echo "-- /api/projects (extension, must stay OPEN, expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://127.0.0.1:5055/api/projects
echo "-- /api/dashboard/projects NO cookie (expect 401) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://127.0.0.1:5055/api/dashboard/projects
echo "-- /dashboard/ (expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://127.0.0.1:5055/dashboard/

echo "-- /api/stats (expect queue_by_site key) --"
STATS=$(curl -s http://127.0.0.1:5055/api/stats)
echo "$STATS" | head -c 400; echo
echo "$STATS" | grep -q '"queue_by_site"' || fail "/api/stats has no queue_by_site (old backend?)"
echo "queue_by_site present"

echo "-- GET /api/thesaurus/progress (expect 13 sciences, real counters) --"
PROG=$(curl -s http://127.0.0.1:5055/api/thesaurus/progress)
echo "$PROG" | head -c 400; echo
echo "$PROG" | grep -q '"sciences"' || fail "/api/thesaurus/progress has no sciences"
NSC=$(echo "$PROG" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sciences"]))' 2>/dev/null || echo 0)
[ "$NSC" = "13" ] || fail "expected 13 sciences, got $NSC"
echo "sciences: $NSC"
SCAN=$(echo "$PROG" | python3 -c 'import json,sys; d=json.load(sys.stdin)["list_scan"]; print(d["scanned_pages"], d["expected_pages"])' 2>/dev/null || echo "?")
echo "list scan (scanned/expected): $SCAN"

echo "-- /api/khamenei/crawl-status (expect pending_by_year key) --"
KC=$(curl -s http://127.0.0.1:5055/api/khamenei/crawl-status)
echo "$KC" | head -c 300; echo
echo "$KC" | grep -q '"pending_by_year"' || fail "/api/khamenei/crawl-status has no pending_by_year (old backend?)"
echo "pending_by_year present"

echo "-- /api/corpus/list (expect files key; tasnim section may be empty here) --"
CL=$(curl -s http://127.0.0.1:5055/api/corpus/list)
echo "$CL" | head -c 300; echo
echo "$CL" | grep -q '"files"' || fail "/api/corpus/list has no files"
echo "corpus list ok"

echo "-- GET /api/thesaurus/elastic-harvest/status (expect JSON, not 404) --"
HS=$(curl -s -o /tmp/pcm21-hs -w '%{http_code}' http://127.0.0.1:5055/api/thesaurus/elastic-harvest/status)
echo "HTTP:$HS body: $(cat /tmp/pcm21-hs)"
[ "$HS" = "200" ] || fail "harvest status probe expected 200, got $HS"
rm -f /tmp/pcm21-hs

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
echo "PCM-21 live: dashboard now shows the SOURCE of every counter"
echo "(در صف <- crawl_queue.site, thesaurus progress <- crawl_progress + crawl_queue"
echo "+ crawled_data, khamenei pending years <- crawl_queue.source_page),"
echo "has a continue/resume button (POST /api/reset-queue), a scan/continue"
echo "button (async elastic-harvest from last cursor), past-year continue"
echo "button (opens list pages for the browser extension), versioned tasnim"
echo "corpus listing, and the REAL last page number (item_index — never the"
echo "configured stop_number)."
