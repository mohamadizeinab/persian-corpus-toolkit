#!/bin/bash
# E8.0-H2: s52 RAG chain baseline (containers + local health). READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== RAG containers ==="
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'rag|mizan|fiqh|keyfwd|litellm'
echo "=== local health ==="
curl -s -m 5 -o /dev/null -w "gateway :8210 /health -> %{http_code}\n" http://127.0.0.1:8210/health
curl -s -m 5 -o /dev/null -w "registry :8200 /health -> %{http_code}\n" http://127.0.0.1:8200/health
echo "END H2-S52"
