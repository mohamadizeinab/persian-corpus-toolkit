#!/bin/bash
# PCM-25 DC#1: deploy failed_by_stage fix + /resume auto-restart + stat labels
# Standard sequence (AGENTS §3): DB backup -> snapshot -> .env -> extract code
# -> docker compose build backend && up -d backend -> health + smoke -> integrity
#
# Code transfer: `git archive HEAD` tarball (pct-code.tgz) must already be at
# /tmp/pct-code.tgz on s52 (scp'd from the operator box).
set -u
APP=~/saberprojects/persian-corpus-toolkit
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /home/saber/backups

echo "=== 1. DB online backup + integrity ==="
sqlite3 "$APP/backend/thesaurus.db" ".backup /home/saber/backups/thesaurus-${TS}.db"
sqlite3 "/home/saber/backups/thesaurus-${TS}.db" "PRAGMA integrity_check;"
echo "backup: /home/saber/backups/thesaurus-${TS}.db"

echo
echo "=== 2. snapshot current deploy dir (excludes DB) ==="
tar czf /home/saber/backups/pct-deploy-${TS}.tar.gz \
  --exclude=backend/thesaurus.db --exclude='backend/thesaurus.db-*' \
  -C "$HOME/saberprojects" "persian-corpus-toolkit"
echo "snapshot: /home/saber/backups/pct-deploy-${TS}.tar.gz"

echo
echo "=== 3. .env check (chmod 600) ==="
if [ ! -f "$APP/.env" ]; then echo "FATAL: $APP/.env missing"; exit 1; fi
chmod 600 "$APP/.env"
grep -q '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" && echo ".env has PCT_DASHBOARD_PASSWORD (len $(grep '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" | cut -d= -f2- | wc -c))"
echo ".env perms: $(stat -c '%a' "$APP/.env")"

echo
echo "=== 4. live counts BEFORE deploy ==="
sqlite3 "$APP/backend/thesaurus.db" \
  "SELECT 'crawl_queue pending', COUNT(*) FROM crawl_queue WHERE status='pending';
   SELECT 'crawl_queue crawling', COUNT(*) FROM crawl_queue WHERE status='crawling';
   SELECT 'crawl_queue done', COUNT(*) FROM crawl_queue WHERE status='done';
   SELECT 'knowledge_file_queue total', COUNT(*) FROM knowledge_file_queue;
   SELECT 'knowledge jobs', COUNT(*) FROM knowledge_jobs;"

echo
echo "=== 5. extract new code (commit f711478) ==="
[ -f /tmp/pct-code.tgz ] || { echo "FATAL: /tmp/pct-code.tgz missing"; exit 1; }
tar xzf /tmp/pct-code.tgz -C "$APP"
echo "extracted. backend .py files:"
ls "$APP/backend/"*.py | xargs -n1 basename | tr '\n' ' '; echo
echo "dashboard files:"
ls "$APP/dashboard/" | tr '\n' ' '; echo
echo "sanity: failed_by_stage SQL now filters status='failed':"
grep -c "status='failed'" "$APP/backend/knowledge_api.py"
grep -c "resumed" "$APP/backend/knowledge_api.py"

echo
echo "=== 6. rebuild image + recreate backend container (no down) ==="
cd "$APP"
docker compose build backend
docker compose up -d backend

echo
echo "=== 7. wait for health ==="
ok=0
for i in $(seq 1 45); do
  if curl -sf http://127.0.0.1:5055/api/auth/status >/dev/null 2>&1; then
    echo "healthy after ${i}s"; ok=1; break
  fi
  sleep 1
done
[ "$ok" = "1" ] || { echo "FATAL: not healthy after 45s"; docker compose logs backend --tail 40; exit 1; }

echo
echo "=== 8. smoke tests ==="
PW=$(grep '^PCT_DASHBOARD_PASSWORD=' "$APP/.env" | cut -d= -f2-)
rm -f /tmp/pct-cookies.txt
echo "--- /api/auth/status (expect auth_enabled true) ---"
curl -s http://127.0.0.1:5055/api/auth/status; echo
echo "--- login (expect ok true) ---"
curl -s -c /tmp/pct-cookies.txt -X POST http://127.0.0.1:5055/api/auth/login \
  -H 'Content-Type: application/json' -d "{\"password\": \"$PW\"}"; echo
echo "--- /api/stats (extension write API, public) ---"
curl -s http://127.0.0.1:5055/api/stats | head -c 300; echo
echo "--- /api/reset-queue (EXPECT new 'reset' field) ---"
curl -s -b /tmp/pct-cookies.txt -X POST http://127.0.0.1:5055/api/reset-queue \
  -H 'Content-Type: application/json' -d '{}'; echo
echo "--- /api/knowledge/queue/summary?collection_id=c-86347897 (EXPECT failed_by_stage []) ---"
curl -s -b /tmp/pct-cookies.txt \
  "http://127.0.0.1:5055/api/knowledge/queue/summary?collection_id=c-86347897" | head -c 700; echo
echo "--- /api/knowledge/import/batches?collection_id=c-86347897 (queue block) ---"
curl -s -b /tmp/pct-cookies.txt \
  "http://127.0.0.1:5055/api/knowledge/import/batches?collection_id=c-86347897&per_page=5" | head -c 900; echo
echo "--- /api/corpus/list (expect 200) ---"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' -b /tmp/pct-cookies.txt http://127.0.0.1:5055/api/corpus/list
echo "--- /api/dashboard/stats WITHOUT cookie (expect 401) ---"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' http://127.0.0.1:5055/api/dashboard/stats
echo "--- dashboard HTML served (stat label check) ---"
curl -s -b /tmp/pct-cookies.txt http://127.0.0.1:5055/dashboard | grep -c 'صفحات در صف' || true
curl -s -b /tmp/pct-cookies.txt http://127.0.0.1:5055/studio.html | grep -c 'ادامهٔ پردازش شروع شد' || true

echo
echo "=== 9. integrity + counts AFTER ==="
sqlite3 "$APP/backend/thesaurus.db" "PRAGMA integrity_check;"
sqlite3 "$APP/backend/thesaurus.db" \
  "SELECT 'crawl_queue pending', COUNT(*) FROM crawl_queue WHERE status='pending';
   SELECT 'crawl_queue crawling', COUNT(*) FROM crawl_queue WHERE status='crawling';
   SELECT 'crawl_queue done', COUNT(*) FROM crawl_queue WHERE status='done';
   SELECT 'knowledge_file_queue total', COUNT(*) FROM knowledge_file_queue;"
rm -f /tmp/pct-cookies.txt
echo "=== DONE ==="
