#!/bin/bash
# PCM-24: fix 413 on 40MB DOCX uploads — corpus vhost client_max_body_size 20m -> 60m
# ROOT CAUSE (verified 2026-11-20, .recon/p24c_413_repro.sh):
#   - Edge serving corpus.ai.ismc.ir = BT-Panel nginx (root), vhost dir:
#       /www/server/panel/vhost/nginx/*.conf
#   - Live vhost has client_max_body_size 20m (same as deploy/nginx-corpus.vhost.conf)
#   - Empirical: 2MB POST passes to Flask (5055); 21MB -> 413; 41MB -> 413
#   - App cap is 50MB (backend/knowledge_api.py MAX_UPLOAD_BYTES) and has no
#     Flask MAX_CONTENT_LENGTH, so Flask itself accepts 40MB fine.
# FIX: raise the vhost limit to 60m (>= 50MB cap + multipart overhead), keep the
#     300s proxy timeouts, test + reload. Idempotent: backs up before touching.
# RUN AS ROOT on 172.30.0.133:   sudo bash /home/saber/saberprojects/persian-corpus-toolkit/deploy/pcm24_vhost_bodyfix_root.sh
set -u
VDIR=/www/server/panel/vhost/nginx
VHOST=$VDIR/corpus.ai.ismc.ir.conf
TS=$(date -u +%Y%m%d-%H%M%S)
BK=/home/saber/backups/corpus-vhost-bodyfix-$TS
mkdir -p "$BK"; chmod 700 "$BK"

echo "== [1/5] pre-state =="
[ -f "$VHOST" ] || { echo "FATAL: $VHOST not found"; exit 1; }
grep -nE 'client_max_body_size|proxy_read_timeout|proxy_send_timeout' "$VHOST"
cp -a "$VHOST" "$BK/$VHOST.bak"
sha256sum "$VHOST" | tee "$BK/vhost.sha256.before"

echo "== [2/5] patch client_max_body_size 20m -> 60m (only that directive) =="
sed -i -E 's/^([[:space:]]*client_max_body_size[[:space:]]+)20m[[:space:]]*;/\160m;/' "$VHOST"
grep -nE 'client_max_body_size' "$VHOST"

echo "== [3/5] nginx -t =="
NGINX_BIN=/www/server/nginx/sbin/nginx
[ -x "$NGINX_BIN" ] || NGINX_BIN=$(command -v nginx)
"$NGINX_BIN" -t 2>&1 || { echo "NGINX_TEST_FAILED — restoring"; cp -a "$BK/$VHOST.bak" "$VHOST"; exit 1; }

echo "== [4/5] reload (graceful, no downtime) =="
"$NGINX_BIN" -s reload 2>&1 && echo "NGINX_RELOADED"

echo "== [5/5] post-state verify (empirical 41MB POST through 443) =="
sleep 1
dd if=/dev/zero of=/tmp/pcm24body41 bs=1M count=41 2>/dev/null
CODE=$(curl -sk -o /tmp/pcm24resp.txt -w '%{http_code}' --max-time 60 -X POST \
  --data-binary @/tmp/pcm24body41 https://127.0.0.1/api/health -H 'Host: corpus.ai.ismc.ir')
echo "41MB POST via 443 -> HTTP $CODE (expect: 401/404/405 = reached Flask, NOT 413)"
head -c 300 /tmp/pcm24resp.txt; echo
rm -f /tmp/pcm24body41 /tmp/pcm24resp.txt
sha256sum "$VHOST" | tee "$BK/vhost.sha256.after"
echo "BACKUP: $BK"
echo "DONE"
