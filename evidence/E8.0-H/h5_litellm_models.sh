#!/bin/bash
# H5: discover actual RAG LLM generation endpoint via litellm model store (read-only)
set -u
echo "=== tables (names only) ==="
docker exec litellm-personal-db psql -U litellm -d litellm -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1" | head -40
echo "=== proxy model rows (params head, secrets stripped on host) ==="
docker exec litellm-personal-db psql -U litellm -d litellm -Atc \
 "SELECT model_name || ' | mode=' || mode || ' | params=' || left(litellm_params,800) FROM \"LiteLLM_ProxyModelTable\" ORDER BY model_name" \
 | sed -E 's/("api_key"[[:space:]]*:[[:space:]]*")[^"]*("|\x27)/\1[REDACTED]\3/g; s/("key"[[:space:]]*:[[:space:]]*")[^"]*("|\x27)/\1[REDACTED]\3/g; s/(api_key[=:][^&",[:space:]]+)/api_key=[REDACTED]/g'
echo "=== row count ==="
docker exec litellm-personal-db psql -U litellm -d litellm -Atc "SELECT count(*) FROM \"LiteLLM_ProxyModelTable\""
echo "=== qwen38-hub row api_base host only ==="
docker exec litellm-personal-db psql -U litellm -d litellm -Atc \
 "SELECT model_name, coalesce(litellm_params::json->>'api_base','<none>') FROM \"LiteLLM_ProxyModelTable\" WHERE model_name LIKE '%qwen%'"
