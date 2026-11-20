#!/bin/bash
# E8.0-H5 (s53 final): cloudflared ingress config via docker cp audit copy (token/secret REDACTED), then cleanup.
# No tunnel state is modified; only an ephemeral copy in /tmp which is removed at the end.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
TMP=/tmp/e80h5-cf-$$
mkdir -p "$TMP"
echo "=== docker cp audit copies ==="
docker cp h200-public-tunnel:/etc/cloudflared/config.yml "$TMP/config.yml" 2>&1
docker cp h200-public-tunnel:/etc/cloudflared/credentials.json "$TMP/credentials.json" 2>&1
echo "=== config.yml (token/secret/password/key values REDACTED) ==="
sed -E -e 's/^([[:space:]]*token:[[:space:]]*).*$/\1[REDACTED]/' \
       -e 's/([Ss]ecret|[Pp]assword|[Kk]ey|BasicAuth):[[:space:]]*.*/\1: [REDACTED]/' \
       "$TMP/config.yml" 2>&1
echo "=== credentials.json: keys only + UUID suffix (no secret values) ==="
python3 -c "
import json
d = json.load(open('$TMP/credentials.json'))
print('keys:', sorted(d.keys()))
print('tunnel uuid suffix (last 4):', str(d.get('Tunnel',''))[-4:])
" 2>&1
rm -rf "$TMP"
echo "audit copy removed: $TMP"
echo "=== full container inventory (s53) ==="
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort
echo "=== who serves :3001 on s53 ==="
ss -tlnp 2>/dev/null | grep ':3001 ' | head -3
echo "END H5-CF"
