#!/bin/bash
# H5: s53 exposure assessment for vllm 0.0.0.0:8000 (no --api-key) — read-only
set -u
echo "=== ufw status (may need root; try anyway) ==="
ufw status verbose 2>&1 | head -40
echo "=== listening sockets (port/state) ==="
ss -tln | head -40
echo "=== iptables INPUT policy + filter count (may need root) ==="
iptables -S INPUT 2>&1 | head -30
echo "=== docker published ports on host ==="
docker ps --format '{{.Names}}\t{{.Ports}}' | head -30
