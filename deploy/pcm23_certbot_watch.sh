#!/bin/bash
# PCM-23: background watcher — retry LE HTTP-01 for khamenei.ai.ismc.ir and
# auto-upgrade the vhost from self-signed to the LE cert on success.
# Runs AS ROOT on 172.30.0.133 under nohup. One pid, bounded attempts.
# Stop: kill $(cat /home/saber/dedicated-rag/data/khamenei_cert_watch.pid)
set -uo pipefail
DOMAIN=khamenei.ai.ismc.ir
VDIR=/www/server/panel/vhost/nginx
VHOST=$VDIR/$DOMAIN.conf
LEDIR=/etc/letsencrypt/live/$DOMAIN
LOG=/home/saber/dedicated-rag/data/khamenei_vhost_cert.log
PIDF=/home/saber/dedicated-rag/data/khamenei_cert_watch.pid
MAX_ATTEMPTS=5
SLEEP_S=1200
echo $$ > "$PIDF"
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"; }

log "watcher started pid=$(cat "$PIDF") domain=$DOMAIN max_attempts=$MAX_ATTEMPTS interval=${SLEEP_S}s"
if [ -f "$LEDIR/fullchain.pem" ]; then
  log "LE cert already present — upgrading vhost now"
fi

upgrade_to_le() {
  # rewrite vhost to LE cert paths (keep port-80 ACME block for future renewals)
  local TS BK
  TS=$(date -u +%Y%m%dT%H%M%SZ); BK=/home/saber/backups/khamenei-vhost-le-$TS
  mkdir -p "$BK"; chmod 700 "$BK"
  cp -a "$VHOST" "$BK/$DOMAIN.conf.bak" 2>/dev/null || true
  cat > "$VHOST" <<EOF
# khamenei.ai.ismc.ir — کتب امام خامنه‌ای RAG (PCM-23)
# Edge vhost on 52: proxies to the RAG portal frontend on 53:8034
# (same pattern as rag.ai.ismc.ir). LE cert (HTTP-01 webroot /www/acme).
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
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
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
  if nginx -t 2>>"$LOG"; then
    systemctl reload nginx >>"$LOG" 2>&1 && log "NGINX_RELOADED (LE vhost)"
  else
    log "NGINX_TEST_FAILED after LE upgrade — vhost left as-is"
    return 1
  fi
  sleep 2
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/")
  log "https_code_after_upgrade=$code"
  echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -issuer -dates | sed 's/^/  /' >> "$LOG"
  log "CERT_UPGRADED_LE (TS=$TS)"
}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if [ -f "$LEDIR/fullchain.pem" ]; then
    upgrade_to_le && { log "watcher done (upgraded)"; exit 0; }
  fi
  log "attempt $attempt/$MAX_ATTEMPTS: certbot certonly --webroot"
  certbot certonly --webroot -w /www/acme -d "$DOMAIN" \
    --cert-name "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring >>"$LOG" 2>&1
  RC=$?
  if [ "$RC" -eq 0 ] && [ -f "$LEDIR/fullchain.pem" ]; then
    log "attempt $attempt: ISSUANCE OK"
    upgrade_to_le && { log "watcher done (upgraded)"; exit 0; }
  fi
  log "attempt $attempt: rc=$RC — not issued yet"
  if grep -qi "rate limited" "$LOG" 2>/dev/null; then
    log "RATE_LIMIT detected — stopping to preserve weekly quota"
    exit 3
  fi
  [ "$attempt" -lt "$MAX_ATTEMPTS" ] && sleep "$SLEEP_S"
done
log "watcher finished after $MAX_ATTEMPTS attempts without LE cert (public :80 path still failing?)"
exit 4
