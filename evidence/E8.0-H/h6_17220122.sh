#!/bin/bash
# E8.0-H6: resolve the owner of 172.20.1.22 (promtail's loki target). READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== ip route get 172.20.1.22 (from this host) ==="
ip route get 172.20.1.22 2>&1 | head -2
echo "=== local ss: any socket on 172.20.1.22 (would prove alias on this host) ==="
ss -tn 2>/dev/null | grep '172.20\.1\.22' | head -5
ss -tln 2>/dev/null | grep '172.20\.1\.22' | head -3
echo "=== loki readiness from here ==="
curl -s -m 6 -o /dev/null -w "172.20.1.22:3100 /ready -> %{http_code}\n" http://172.20.1.22:3100/ready 2>&1
echo "=== ping 172.20.1.22 (1 packet) ==="
ping -c1 -W2 172.20.1.22 2>&1 | head -3
echo "END 172.20.1.22-PROBE"
