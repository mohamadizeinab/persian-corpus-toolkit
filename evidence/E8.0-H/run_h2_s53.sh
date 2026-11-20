#!/bin/bash
# E8.0-H2: s53 -> s52 network verification (P6-1b live re-check) + source IP. READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== route to s52 (source IP) ==="
ip route get 172.30.0.133 2>&1 | head -2
echo "=== TCP probes s53 -> s52 (3s timeout; BLOCKED expected for 4101/8200/8210) ==="
for p in 4101 8200 8210 4000 8000; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/172.30.0.133/$p" 2>/dev/null; then
    echo "port $p: OPEN (connect ok)"
  else
    echo "port $p: BLOCKED/TIMEOUT"
  fi
done
echo "END H2-S53"
