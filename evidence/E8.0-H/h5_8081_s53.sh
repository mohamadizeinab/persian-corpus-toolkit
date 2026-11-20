#!/bin/bash
# E8.0-H5 (s53 final): identify 127.0.0.1:8081 (cloudflared tunnel ingress target). READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== all listeners on 8081 (any bind) ==="
ss -tlnp 2>/dev/null | grep ':8081 ' || ss -tln | grep ':8081 '
echo "=== HTTP probe of 127.0.0.1:8081 (head only) ==="
curl -s -m 8 -o /dev/null -D - http://127.0.0.1:8081/ 2>&1 | head -15
echo "=== /health variant ==="
curl -s -m 8 -o /dev/null -w "8081 /health -> %{http_code}\n" http://127.0.0.1:8081/health 2>&1
echo "=== docker containers with 8081 in ports ==="
docker ps --format '{{.Names}}\t{{.Ports}}' | grep 8081 || echo "no docker port mapping for 8081"
echo "=== process via /proc for 8081 (may need root; try) ==="
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  if ls -l "$p/fd" 2>/dev/null | grep -q socket; then :; fi
done 2>/dev/null
fuser 8081/tcp 2>&1 | head -3
echo "END H5-8081"
