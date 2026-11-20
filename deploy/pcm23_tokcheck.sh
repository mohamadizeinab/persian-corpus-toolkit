#!/bin/bash
# PCM-23: compare registry admin tokens (container vs file vs gateway) — masked
set -euo pipefail
REG=/home/saber/dedicated-rag-registry
CTOK=$(docker inspect rag-registry --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^REGISTRY_ADMIN_TOKEN=' | cut -d= -f2-)
FTOK=$(grep '^REGISTRY_ADMIN_TOKEN=' "$REG/env/registry.env" | cut -d= -f2-)
GTOK=$(docker inspect rag-gateway --format '{{.Config.Env}}' | tr ' ' '\n' | grep '^GATEWAY_REGISTRY_ADMIN_TOKEN=' | cut -d= -f2-)
echo "container admin: $(printf '%s' "$CTOK" | md5sum | cut -c1-8) len=${#CTOK}"
echo "file      admin: $(printf '%s' "$FTOK" | md5sum | cut -c1-8) len=${#FTOK}"
echo "gateway   admin: $(printf '%s' "$GTOK" | md5sum | cut -c1-8) len=${#GTOK}"
echo '=== how gateway auths to registry ==='
docker exec rag-gateway grep -n 'admin_token\|REGISTRY_ADMIN\|registry' /app/drag/gateway/config.py 2>/dev/null | head -15
docker exec rag-gateway grep -n 'Authorization\|Bearer' /app/drag/gateway/api.py 2>/dev/null | head -15
echo 'TOKCHECK-DONE'
