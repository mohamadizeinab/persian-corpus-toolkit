#!/bin/bash
# E8.0-H6 gap (s52): all host IPs + loki bind + internal s52->s53:8000 path. READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== all IPv4 addresses (look for 172.20.1.22) ==="
ip -4 -o addr show | awk '{print $2, $4}'
echo "=== loki listener ==="
ss -tln | grep ':3100 ' || echo "no 3100 listener"
echo "=== internal path s52 -> s53:8000 (vllm) ==="
if timeout 3 bash -c "exec 3<>/dev/tcp/172.20.1.53/8000" 2>/dev/null; then echo "s52->s53:8000 OPEN"; else echo "s52->s53:8000 BLOCKED/TIMEOUT"; fi
echo "END H6-GAP-S52"
