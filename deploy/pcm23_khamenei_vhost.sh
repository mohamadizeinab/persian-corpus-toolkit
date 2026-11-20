#!/bin/bash
# PCM-23: install khamenei.ai.ismc.ir edge vhost on 52 (runs AS ROOT on 172.30.0.133)
# Pattern cloned from rag.ai.ismc.ir.conf. Two-phase: 80-only (ACME) -> LE cert -> final 443.
set -euo pipefail
DOMAIN=khamenei.ai.ismc.ir
VDIR=/www/server/panel/vhost/nginx
VHOST=$VDIR/$DOMAIN.conf
TS=$(date -u +%Y%m%dT%H%M%SZ)
BK=/home/saber/backups/khamenei-vhost-$TS
mkdir -p "$BK"; chmod 700 "$BK"
echo "backup dir: $BK"

echo "== [1/6] backup existing vhost (if any) =="
if [ -f "$VHOST" ]; then cp -a "$VHOST" "$BK/$DOMAIN.conf.bak"; sha256sum "$VHOST" | tee "$BK/vhost.sha256.before"; else echo "(no existing vhost)"; fi

echo "== [2/6] phase-1 vhost (port 80 + ACME challenge) =="
cat > "$VHOST" <<'EOF'
# khamenei.ai.ismc.ir — phase 1 (ACME only); final file replaces this.
server {
    listen 80;
    server_name khamenei.ai.ismc.ir;
    access_log  /www/wwwlogs/khamenei.ai.ismc.ir.log;
    error_log   /www/wwwlogs/khamenei.ai.ismc.ir.error.log;
    location ^~ /.well-known/acme-challenge/ { root /www/acme; }
    location / { return 301 https://$host$request_uri; }
}
EOF
chmod 644 "$VHOST"
nginx -t
systemctl reload nginx
echo "phase-1 reloaded"

echo "== [3/6] issue LE cert (HTTP-01 webroot /www/acme) =="
certbot certonly --webroot -w /www/acme -d "$DOMAIN" \
  --cert-name "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring 2>&1 | tee "$BK/certbot.log"
RC=${PIPESTATUS[0]}
if [ "$RC" -ne 0 ]; then
  echo "ISSUANCE_FAILED rc=$RC"
  tail -12 "$BK/certbot.log"
  exit 10
fi
[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || { echo "cert files missing"; exit 11; }

echo "== [4/6] final vhost (443 + proxy to portal 172.20.1.53:8034) =="
cat > "$VHOST" <<'EOF'
# khamenei.ai.ismc.ir — کتب امام خامنه‌ای RAG (PCM-23)
# Edge vhost on 52: proxies to the RAG portal frontend on 53:8034
# (same pattern as rag.ai.ismc.ir). The portal lists rag-khamenei via the
# gateway dual filter (portal consumer allowed_rag_ids ∩ provider
# allowed_consumers).
server {
    listen 80;
    server_name khamenei.ai.ismc.ir;
    access_log  /www/wwwlogs/khamenei.ai.ismc.ir.log;
    error_log   /www/wwwlogs/khamenei.ai.ismc.ir.error.log;
    location ^~ /.well-known/acme-challenge/ { root /www/acme; }
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl;
    http2 on;
    server_name khamenei.ai.ismc.ir;
    ssl_certificate     /etc/letsencrypt/live/khamenei.ai.ismc.ir/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/khamenei.ai.ismc.ir/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    access_log  /www/wwwlogs/khamenei.ai.ismc.ir.log;
    error_log   /www/wwwlogs/khamenei.ai.ismc.ir.error.log;
    client_max_body_size 100m;
    location / {
        proxy_pass http://172.20.1.53:8034;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
chmod 644 "$VHOST"
sha256sum "$VHOST" | tee "$BK/vhost.sha256.after"

echo "== [5/6] validate + reload =="
if nginx -t; then
  systemctl reload nginx && echo "NGINX_RELOADED"
else
  echo "NGINX_TEST_FAILED -> restoring phase-1 file"
  exit 12
fi

echo "== [6/6] verify =="
sleep 2
echo -n "http_301="; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "http://$DOMAIN/"
echo -n "https_code="; curl -sk -o /dev/null -w '%{http_code}\n' --max-time 15 "https://$DOMAIN/"
echo "cert:"
echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -dates | sed 's/^/  /'
echo "=== KHAMENEI VHOST OK (TS=$TS) ==="
