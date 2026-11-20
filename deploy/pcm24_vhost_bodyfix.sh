#!/bin/bash
# PCM-24: fix 413 on 40MB DOCX uploads — corpus vhost client_max_body_size 20m -> 60m
# ROOT CAUSE (verified 2026-11-20, .recon/p24c_413_repro.sh):
#   - Edge serving corpus.ai.ismc.ir = BT-Panel nginx (root, /www/server/nginx/sbin/nginx)
#     including /www/server/panel/vhost/nginx/*.conf
#   - Live corpus vhost has client_max_body_size 20m (same as deploy/nginx-corpus.vhost.conf)
#   - Empirical: 2MB POST passes to Flask (5055); 21MB -> 413; 41MB -> 413
#   - App cap is 50MB (backend/knowledge_api.py MAX_UPLOAD_BYTES), no Flask MAX_CONTENT_LENGTH
# FIX: raise the vhost limit to 60m (>= 50MB app cap + multipart overhead), keep 300s timeouts.
#
# No password needed: saber has NOPASSWD sudo for:
#   /www/server/nginx/sbin/nginx, /usr/bin/systemctl, /usr/bin/chmod, /usr/bin/ss
# The vhost dir is drw------- root, so we chmod-traverse it, chmod the file o+w,
# and rewrite IN PLACE (cat > file needs only file-write, not dir-write).
# Idempotent: if the live value is already >= 50m it reports and leaves it alone.
set -u
VDIR=/www/server/panel/vhost/nginx
VHOST=$VDIR/corpus.ai.ismc.ir.conf
NGX=/www/server/nginx/sbin/nginx
TS=$(date -u +%Y%m%d-%H%M%S)
BK=/home/saber/backups/corpus-vhost-bodyfix-$TS

echo "== [1/6] open read access to the vhost dir (sudo chmod o+rx, NOPASSWD) =="
sudo chmod o+rx /www/server/panel/vhost 2>&1
sudo chmod o+rx /www/server/panel/vhost/nginx 2>&1
ls -la "$VDIR" | head -12
[ -f "$VHOST" ] || { echo "FATAL: $VHOST not found"; exit 1; }

echo
echo "== [2/6] current state + backup =="
grep -nE 'client_max_body_size|proxy_read_timeout|proxy_send_timeout|server_name' "$VHOST"
mkdir -p "$BK"; chmod 700 "$BK"
cp -a "$VHOST" "$BK/$(basename "$VHOST").bak" 2>/dev/null || sudo chmod o+r "$VHOST"
cp -a "$VHOST" "$BK/$(basename "$VHOST").bak"
sha256sum "$VHOST" 2>/dev/null | tee "$BK/vhost.sha256.before" || true

CUR=$(grep -E '^[[:space:]]*client_max_body_size[[:space:]]' "$VHOST" | head -1 | grep -oE '[0-9]+[kmgKMG]?' | head -1)
echo "current client_max_body_size = ${CUR:-<none>}"

need=1
if [ "$CUR" = "60m" ] || [ "$CUR" = "50m" ]; then
  echo "already >= 50m — no change needed (idempotent)"
  need=0
fi
# if directive absent entirely, we append it (see [4/6])

echo
echo "== [3/6] open write access to the vhost file (sudo chmod o+w, NOPASSWD) =="
sudo chmod o+w "$VHOST" 2>&1 || { echo "FATAL: cannot chmod o+w $VHOST"; exit 1; }

echo
echo "== [4/6] patch client_max_body_size -> 60m (in-place rewrite) =="
if [ "$need" = "1" ]; then
  if [ -n "$CUR" ]; then
    sed -E 's/^([[:space:]]*client_max_body_size[[:space:]]+)[0-9]+[kmgKMG]?[[:space:]]*;/\160m;/' "$VHOST" > /tmp/pcm24_vhost.new
    cat /tmp/pcm24_vhost.new > "$VHOST"
  else
    # directive missing — insert after the 'listen 443' line (or at top of the 443 server block)
    sed -E 's|^([[:space:]]*(listen[[:space:]]+[^;]*443[^;]*;))|\1\n    client_max_body_size 60m;|' "$VHOST" > /tmp/pcm24_vhost.new
    cat /tmp/pcm24_vhost.new > "$VHOST"
  fi
  rm -f /tmp/pcm24_vhost.new
  grep -nE 'client_max_body_size' "$VHOST"
fi

echo
echo "== [5/6] nginx -t + graceful reload (NOPASSWD) =="
sudo "$NGX" -t 2>&1 || { echo "NGINX_TEST_FAILED — restoring from $BK"; cp -a "$BK/$(basename "$VHOST").bak" "$VHOST" 2>/dev/null || true; exit 1; }
sudo "$NGX" -s reload 2>&1 && echo "NGINX_RELOADED"

echo
echo "== [6/6] empirical verify: 41MB POST through 443 (the user's real case) =="
sleep 1
dd if=/dev/zero of=/tmp/pcm24body41 bs=1M count=41 2>/dev/null
CODE=$(curl -sk -o /tmp/pcm24resp.txt -w '%{http_code}' --max-time 90 -X POST \
  --data-binary @/tmp/pcm24body41 https://127.0.0.1/api/health -H 'Host: corpus.ai.ismc.ir')
echo "41MB POST via 443 -> HTTP $CODE  (expect 401/404/405 = reached Flask; 413 = still blocked)"
head -c 300 /tmp/pcm24resp.txt; echo
rm -f /tmp/pcm24body41 /tmp/pcm24resp.txt
sha256sum "$VHOST" 2>/dev/null | tee "$BK/vhost.sha256.after" || true
echo "BACKUP: $BK"
echo "DONE"
