#!/usr/bin/env bash
# pcm23_diag5 - خواندن handler PATCH provider + مقدار TTL cache gateway
set -u
echo "=== PATCH /api/rag-registry/<rag_id> handler (container) ==="
docker exec rag-registry sed -n '248,310p' /app/drag/registry/api.py
echo
echo "=== gateway provider_cache_ttl_s default ==="
docker exec rag-gateway grep -nE "provider_cache_ttl" /app/drag/gateway/*.py 2>/dev/null | head
docker exec rag-gateway env | grep -iE "cache|ttl" || true
echo "DIAG5-DONE"
