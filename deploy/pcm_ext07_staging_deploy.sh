#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# PCM-EXT-07 M3 — Corpus STAGING deployment on s52 (172.30.0.133)
#
# Self-contained staging: separate dir + separate DB + port 5056 +
# domain pct-staging.ai.ismc.ir (wildcard DNS already -> edge -> s52).
# PRODUCTION (dir /data/DB/vhost on 5055) is only READ, never written.
#
# Code identity: commit 6f7f2d2 (branch pcm-20.9-knowledge-studio-factory,
# GitHub) — tarball built with `git archive 6f7f2d2` on the operator box.
#
# PREP (on Windows, before SSH):
#   git archive --format=tar.gz --prefix=pct-staging/ 6f7f2d2 -o pct-code-ext07-staging.tgz
#   scp -P 22 pct-code-ext07-staging.tgz pct-extension-staging.zip deploy/pcm_ext07_staging_deploy.sh saber@172.30.0.133:/tmp/
#   ssh -p 22 -o BatchMode=yes saber@172.30.0.133 'bash /tmp/pcm_ext07_staging_deploy.sh'
#
# Safety model (AGENTS.md §2/§3):
#   1. prod DB touched only via `sqlite3 .backup` (WAL-safe, read-only source)
#   2. staging .env: same dashboard password, ES/embedding vars EMPTY
#      (config-guarded 'blocked' path — zero calls to shared ES/Ollama)
#   3. compose project `pct-staging` — different project name + port, so
#      `down -v` here can never touch the prod project
#   4. vhost added in place of NOTHING (new file), dir perms restored after;
#      self-signed cert (PCM-23 pattern) + optional LE upgrade afterwards
#   5. prod regression at the end: container up, 5055 answers, khamenei=151
#
# ROLLBACK (staging only, prod untouched by definition):
#   cd /home/saber/saberprojects/pct-staging
#   docker compose -p pct-staging stop backend && docker compose -p pct-staging rm -f backend
#   sudo chmod o+w /www/server/panel/vhost/nginx
#   rm /www/server/panel/vhost/nginx/pct-staging.ai.ismc.ir.conf
#   sudo /www/server/nginx/sbin/nginx -s reload
#   rm -rf /home/saber/saberprojects/pct-staging   (DB backup kept in /home/saber/backups)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
STAGE=/home/saber/saberprojects/pct-staging
PROD=/home/saber/saberprojects/persian-corpus-toolkit
TS=$(date -u +%Y%m%d-%H%M%S)
BK=/home/saber/backups
CODE_TGZ=/tmp/pct-code-ext07-staging.tgz
EXT_ZIP=/tmp/pct-extension-staging.zip
BASE=http://127.0.0.1:5056
NGX=/www/server/nginx/sbin/nginx
VDIR=/www/server/panel/vhost/nginx
DOMAIN=pct-staging.ai.ismc.ir
STEP=init
fail() { echo "!!! FAILED at [$STEP]: $1"; exit 1; }
trap 'fail "abnormal exit (line $LINENO)"' ERR

echo "=== 0. preconditions ==="
command -v docker >/dev/null || fail "docker missing"
[ -f "$CODE_TGZ" ] || fail "code tar not at $CODE_TGZ"
[ -f "$EXT_ZIP" ] || fail "extension zip not at $EXT_ZIP"
[ -f "$PROD/.env" ] || fail "prod .env missing"
[ -f "$PROD/backend/thesaurus.db" ] || fail "prod DB missing"
ss -tln | grep -q ':5056 ' && fail "port 5056 already used"
if [ -d "$STAGE" ]; then
  # safe to clear: this script is the only thing that creates $STAGE
  echo "removing partial staging dir from a previous run: $STAGE"
  rm -rf "$STAGE"
fi

echo "=== 1. staging dir + code from git archive 6f7f2d2 ==="
tar xzf "$CODE_TGZ" -C /home/saber/saberprojects
[ -d "$STAGE/backend" ] || fail "extract did not create $STAGE/backend"
declare -A EXPECT=(
  [backend/server.py]=008330dc07e1d3a20933326d24da11c24427e675
  [corpus/scrape_khamenei.py]=d12b76d6cdf2fc39a9e2174cac7c3561cd622d8f
  [extension/background.js]=e4fe748e71cd7784822d48ce4da4a7c2447e2229
  [docker-compose.yml]=bccd873c51b1df3928b43afed701d241cd8289a7
)
for f in "${!EXPECT[@]}"; do
  [ -f "$STAGE/$f" ] || fail "missing $f after extract"
  got=$(git hash-object "$STAGE/$f")
  [ "$got" = "${EXPECT[$f]}" ] || fail "blob mismatch $f: got $got want ${EXPECT[$f]}"
  echo "ok  $f  ($got)"
done

echo "=== 2. DB: prod online .backup -> staging (prod read-only) ==="
sqlite3 "$PROD/backend/thesaurus.db" ".backup $STAGE/backend/thesaurus.db"
rm -f "$STAGE/backend/thesaurus.db-wal" "$STAGE/backend/thesaurus.db-shm"
[ "$(sqlite3 "$STAGE/backend/thesaurus.db" 'PRAGMA integrity_check;')" = "ok" ] || fail "staging DB integrity"
sqlite3 "$STAGE/backend/thesaurus.db" \
  "SELECT 'staging_khamenei', COUNT(*) FROM khamenei_speeches;
   SELECT 'staging_projects', COUNT(*) FROM projects;"
cp -a "$STAGE/backend/thesaurus.db" "$BK/thesaurus-staging-seed-$TS.db"
echo "staging DB backup: $BK/thesaurus-staging-seed-$TS.db"

echo "=== 3. .env (password from prod; ES/embedding EMPTY = guarded blocked) ==="
grep -q '^PCT_DASHBOARD_PASSWORD=' "$PROD/.env" || fail "prod .env lacks PCT_DASHBOARD_PASSWORD"
{
  echo "PCT_DASHBOARD_PASSWORD=$(grep '^PCT_DASHBOARD_PASSWORD=' "$PROD/.env" | cut -d= -f2-)"
  echo "PCT_ES_URL="
  echo "PCT_EMBEDDING_URL="
  echo "PCT_EMBEDDING_MODEL="
  echo "PCT_EMBEDDING_DIM="
  echo "PCT_EMBEDDING_TIMEOUT="
  echo "PCT_EMBEDDING_BATCH="
} > "$STAGE/.env"
chmod 600 "$STAGE/.env"
echo ".env written (secret not printed)"

echo "=== 4. compose: publish 127.0.0.1:5056 ==="
sed -i 's/127\.0\.0\.1:5055:5055/127.0.0.1:5056:5055/' "$STAGE/docker-compose.yml"
grep -q '127.0.0.1:5056:5055' "$STAGE/docker-compose.yml" || fail "port rewrite failed"
mkdir -p "$STAGE/data"
cd "$STAGE"
docker compose -p pct-staging config -q || fail "compose invalid"

echo "=== 5. build + up (project pct-staging ONLY) ==="
docker compose -p pct-staging build backend
docker compose -p pct-staging up -d backend
IMG=$(docker inspect pct-staging-backend-1 --format '{{.Image}}')
IMGID=$(docker image inspect "$IMG" --format '{{.Id}}')
echo "image: $IMG ($IMGID)"
echo "code commit: 6f7f2d2 (blobs verified above)"

echo "=== 6. health wait ==="
ok=""
for i in $(seq 1 60); do
  if curl -sf "$BASE/api/stats" >/dev/null 2>&1; then ok=yes; break; fi
  sleep 1
done
[ -n "$ok" ] || fail "staging server not healthy after 60s"
echo "healthy after ~${i}s"

STEP=smoke
echo "=== 7. smoke (staging 5056) ==="
echo "-- /api/db/info (expect 200 + khamenei_speeches 151) --"
DBI=$(curl -s "$BASE/api/db/info")
echo "$DBI" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows={t["name"]:t["rows"] for t in d["tables"]}
assert rows.get("khamenei_speeches")==151, rows
print("db/info ok: khamenei_speeches=151, tables=%d" % len(d["tables"]))'
echo "-- /api/projects (extension write API must be OPEN, 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/api/projects"
echo "-- /api/knowledge/collections NO cookie (expect 401) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/api/knowledge/collections"
echo "-- /dashboard/ (expect 200) --"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/dashboard/"
echo "-- /api/khamenei/crawl-status (expect 200 + pending_by_year) --"
KC=$(curl -s "$BASE/api/khamenei/crawl-status")
case "$KC" in *pending_by_year*) echo "pending_by_year present";; *) fail "crawl-status regression";; esac
echo "-- extension zip served by staging dashboard --"
cp "$EXT_ZIP" "$STAGE/dashboard/pct-extension-staging.zip"
curl -s -o /dev/null -w 'HTTP:%{http_code}\n' "$BASE/dashboard/pct-extension-staging.zip"

echo "=== 8. vhost $DOMAIN (self-signed; PCM-23 pattern) ==="
mkdir -p "$STAGE/certs"
if [ ! -f "$STAGE/certs/$DOMAIN.pem" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$STAGE/certs/$DOMAIN.key" -out "$STAGE/certs/$DOMAIN.pem" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" >/dev/null
fi
chmod 600 "$STAGE/certs/$DOMAIN.key"; chmod 644 "$STAGE/certs/$DOMAIN.pem"
cat > "/tmp/${DOMAIN}.conf" <<EOF
# $DOMAIN — PCM-EXT-07 corpus STAGING (self-contained, port 5056)
# Prod corpus.ai.ismc.ir.conf is untouched. Staging = separate dir/DB/port.
server {
    listen 80;
    server_name $DOMAIN;
    access_log  /www/wwwlogs/$DOMAIN.log;
    error_log   /www/wwwlogs/$DOMAIN.error.log;
    location ^~ /.well-known/acme-challenge/ { root /www/acme; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate     $STAGE/certs/$DOMAIN.pem;
    ssl_certificate_key $STAGE/certs/$DOMAIN.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    access_log  /www/wwwlogs/$DOMAIN.log;
    error_log   /www/wwwlogs/$DOMAIN.error.log;
    client_max_body_size 60m;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    location / {
        proxy_pass http://127.0.0.1:5056;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
EOF
chmod 644 "/tmp/${DOMAIN}.conf"
DIR_PERMS_BEFORE=$(stat -c '%a' "$VDIR")
sudo chmod o+rx /www/server/panel/vhost
sudo chmod o+w /www/server/panel/vhost/nginx
cp -a "/tmp/${DOMAIN}.conf" "$VDIR/${DOMAIN}.conf"
sha256sum "$VDIR/${DOMAIN}.conf" | tee "$BK/staging-vhost-$TS.sha256"
# restore dir perms (keep o+rx on parent — PCM-24 left it readable too)
chmod "$DIR_PERMS_BEFORE" "$VDIR" 2>/dev/null || true
sudo "$NGX" -t || { cp -a "$VDIR/${DOMAIN}.conf" /tmp/staging-vhost.broken; fail "nginx -t failed"; }
sudo "$NGX" -s reload && echo "NGINX_RELOADED"

echo "=== 9. external verification (via the vhost, self-signed -k) ==="
curl -sk -o /dev/null -w "https://$DOMAIN/api/db/info = %{http_code}\n" --max-time 20 "https://$DOMAIN/api/db/info"
EXT=$(curl -sk --max-time 20 "https://$DOMAIN/api/db/info")
echo "$EXT" | grep -q 'khamenei_speeches' || fail "vhost did not proxy to staging"
echo "vhost verified from s52 loopback"

echo "=== 10. PROD regression (must be untouched) ==="
curl -s -o /dev/null -w "prod 5055 /api/stats = %{http_code}\n" "http://127.0.0.1:5055/api/stats"
docker ps --format '{{.Names}}\t{{.Status}}' | grep persian-corpus-toolkit-backend-1 || fail "prod container down?!"
PROD_N=$(sqlite3 "$PROD/backend/thesaurus.db" "SELECT COUNT(*) FROM khamenei_speeches;")
[ "$PROD_N" = "151" ] || fail "prod khamenei count changed: $PROD_N != 151"
[ "$(sqlite3 "$PROD/backend/thesaurus.db" 'PRAGMA integrity_check;')" = "ok" ] || fail "prod integrity"
echo "prod intact: container up, khamenei=151, integrity ok"

echo
echo "=== STAGING DEPLOY OK (TS=$TS) ==="
echo "staging URL (LAN): https://$DOMAIN   (self-signed cert; owner should accept in browser)"
echo "staging backend: 127.0.0.1:5056 (s52) | image $IMGID | commit 6f7f2d2"
echo "staging DB: $STAGE/backend/thesaurus.db (seed backup $BK/thesaurus-staging-seed-$TS.db)"
echo "extension: load-unpacked from $STAGE/dashboard/pct-extension-staging.zip (v3.10-staging)"
echo "LE upgrade (optional, later): certbot --nginx -d $DOMAIN (needs public port 80 path open)"
echo "prod: corpus.ai.ismc.ir (5055) untouched; vhost backup sha at $BK/staging-vhost-$TS.sha256"
