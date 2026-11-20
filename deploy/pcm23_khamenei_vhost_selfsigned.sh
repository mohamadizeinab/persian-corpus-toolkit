#!/bin/bash
# PCM-23: khamenei.ai.ismc.ir — final vhost with SELF-SIGNED cert (interim).
# Public path to 185.213.10.25:80 is timing out for the LE CA right now
# (verified from public vantage points), so we bring the site up immediately
# with a self-signed cert. pcm23_certbot_watch.sh (root, nohup) retries LE
# HTTP-01 every 20 min and auto-upgrades the vhost to the LE cert on success.
# Runs AS ROOT on 172.30.0.133.
set -euo pipefail
DOMAIN=khamenei.ai.ismc.ir
VDIR=/www/server/panel/vhost/nginx
VHOST=$VDIR/$DOMAIN.conf
TS=$(date -u +%Y%m%dT%H%M%SZ)
SSDIR=/etc/letsencrypt/selfsigned
BK=/home/saber/backups/khamenei-vhost-$TS
mkdir -p "$SSDIR" "$BK"; chmod 700 "$BK"
echo "backup dir: $BK"

echo "== [1/4] backup current vhost (if any) =="
if [ -f "$VHOST" ]; then cp -a "$VHOST" "$BK/$DOMAIN.conf.bak"; sha256sum "$VHOST" | tee "$BK/vhost.sha256.before"; else echo "(no existing vhost)"; fi

echo "== [2/4] self-signed cert (365d, RSA-2048, SAN) =="
if [ -f "$SSDIR/$DOMAIN.pem" ]; then
  echo "(self-signed cert already exists, keeping)"
else
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "$SSDIR/$DOMAIN.key" -out "$SSDIR/$DOMAIN.pem" \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
    | sed 's/^/  /'
fi
chmod 600 "$SSDIR/$DOMAIN.key"
chmod 644 "$SSDIR/$DOMAIN.pem"
ls -l "$SSDIR/$DOMAIN.pem" "$SSDIR/$DOMAIN.key" | sed 's/^/  /'

echo "== [3/4] write final vhost (443 self-signed + port 80 ACME kept for future renewal) =="
cat > "$VHOST" <<EOF
# khamenei.ai.ismc.ir — کتب امام خامنه‌ای RAG (PCM-23)
# Edge vhost on 52: proxies to the RAG portal frontend on 53:8034
# (same pattern as rag.ai.ismc.ir). Currently SELF-SIGNED because the
# public port-80 path to 185.213.10.25 is timing out for the LE CA
# (2026-11-20). pcm23_certbot_watch.sh auto-upgrades to the LE cert
# at /etc/letsencrypt/live/$DOMAIN/ once issuance succeeds.
server {
    listen 80;
    server_name $DOMAIN;
    access_log  /www/wwwlogs/khamenei.ai.ismc.ir.log;
    error_log   /www/wwwlogs/khamenei.ai.ismc.ir.error.log;
    location ^~ /.well-known/acme-challenge/ { root /www/acme; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;
    ssl_certificate     $SSDIR/$DOMAIN.pem;
    ssl_certificate_key $SSDIR/$DOMAIN.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    access_log  /www/wwwlogs/khamenei.ai.ismc.ir.log;
    error_log   /www/wwwlogs/khamenei.ai.ismc.ir.error.log;
    client_max_body_size 100m;
    location / {
        proxy_pass http://172.20.1.53:8034;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
EOF
chmod 644 "$VHOST"
sha256sum "$VHOST" | tee "$BK/vhost.sha256.after"

echo "== [4/4] validate + reload + verify =="
if nginx -t; then
  systemctl reload nginx && echo "NGINX_RELOADED"
else
  echo "NGINX_TEST_FAILED"
  exit 12
fi
sleep 2
echo -n "http_301="; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "http://$DOMAIN/"
echo -n "https_code="; curl -sk -o /dev/null -w '%{http_code}\n' --max-time 15 "https://$DOMAIN/"
echo "cert (self-signed):"
echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -subject -issuer -dates | sed 's/^/  /'
echo "=== KHAMENEI VHOST SELF-SIGNED OK (TS=$TS) — LE upgrade pending via watcher ==="
