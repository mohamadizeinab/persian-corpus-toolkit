#!/bin/bash
# E8.0-H1: s52 firewall preflight — READ-ONLY (no iptables/ufw mutation of any kind)
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== address + route to s53 ==="
ip -4 -o addr show ens33 2>/dev/null
ip route get 172.20.1.53 2>/dev/null | head -2
echo "=== listeners: RAG chain + legacy + 4102 ==="
ss -tln | awk 'NR==1 || /:(4101|4102|8200|8210|8211|8212|4000|8000|8101|8102) /'
echo "=== firewall framework ==="
ufw --version 2>&1 | head -2
ufw status 2>&1 | head -3
command -v netfilter-persistent || echo "netfilter-persistent: ABSENT"
ls -d /etc/iptables 2>&1
ls -la /etc/ufw/ 2>&1 | head -12
echo "--- /etc/ufw/user.rules (first 40 lines, if readable as non-root) ---"
head -40 /etc/ufw/user.rules 2>&1
echo "=== DOCKER-USER chain (root required) ==="
iptables -S DOCKER-USER 2>&1 | head -15
echo "=== RAG containers ==="
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'rag|mizan|fiqh|keyfwd|gateway|registry|litellm'
echo "=== RAG health (local) ==="
curl -s -m 5 -o /dev/null -w "gateway :8210 /health -> %{http_code}\n" http://127.0.0.1:8210/health
curl -s -m 5 -o /dev/null -w "registry :8200 /health -> %{http_code}\n" http://127.0.0.1:8200/health
curl -s -m 5 -o /dev/null -w "provider :8101 /health -> %{http_code}\n" http://127.0.0.1:8101/health
curl -s -m 5 -o /dev/null -w "provider :8102 /health -> %{http_code}\n" http://127.0.0.1:8102/health
echo "=== 4102 owner (do NOT open) ==="
docker ps --format '{{.Names}}\t{{.Ports}}' | grep 4102 || echo "no 4102 mapping in docker ps"
echo "END H1-PREFLIGHT"
