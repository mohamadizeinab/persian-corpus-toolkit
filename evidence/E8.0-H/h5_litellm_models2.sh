#!/bin/bash
# H5 (take 2): resolve qwen38-hub backend endpoint from litellm model store
set -u
echo "=== all 13 rows: model_name + api_base host/port only (keys never printed) ==="
docker exec litellm-personal-db psql -U litellm -d litellm -Atc \
 "SELECT model_name || ' => api_base=' || coalesce(litellm_params::json->>'api_base', '<none>') || ' | custom_llm_provider=' || coalesce(litellm_params::json->>'custom_llm_provider','<none>') FROM \"LiteLLM_ProxyModelTable\" ORDER BY model_name"
echo "=== LiteLLM_Config params (names only) ==="
docker exec litellm-personal-db psql -U litellm -d litellm -Atc "SELECT param_name FROM \"LiteLLM_Config\" ORDER BY 1"
echo "=== qwen38-hub api_base hostname/port extracted (no key material) ==="
docker exec litellm-personal-db psql -U litellm -d litellm -Atc \
 "SELECT coalesce(litellm_params::json->>'api_base','') FROM \"LiteLLM_ProxyModelTable\" WHERE model_name LIKE '%qwen%'" \
 | grep -oE 'https?://[A-Za-z0-9._-]+(:[0-9]+)?' | sort -u
echo "=== does s52 host resolve 172.20.1.53 / s53 hosts? ==="
getent hosts 172.20.1.53 2>/dev/null || echo "no reverse-resolve (normal)"
echo "=== can s52 reach s53 vllm port? (conn only, no auth, no request) ==="
timeout 5 bash -c 'cat < /dev/null > /dev/tcp/172.20.1.53/8000' 2>/dev/null && echo "s52->s53:8000 TCP OPEN" || echo "s52->s53:8000 TCP BLOCKED/none"
echo "=== local vllm/llm ports on s52 ==="
ss -tlnp 2>/dev/null | grep -E ':(8000|8001|8080|8081)\s' || echo "no local 8000-family listeners"
