#!/bin/bash
# H3: staging UI endpoint targets (env names + non-secret endpoint values only)
set -u
strip() { sed -E 's/((KEY|TOKEN|SECRET|PASSWORD|APIK)[A-Z_]*=).*/\1[REDACTED]/'; }
for c in radio2_api rag2_api radio_api ragportal_api; do
  echo "=== $c ==="
  docker inspect "$c" -f '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'RAG|LITELLM|REGISTRY|GATEWAY|LLM|PROVIDER' | strip
done
echo "=== staging keyfwd bare process ==="
ps -eo pid,user,args | grep -E 'keyfwd|rag_keyfwd' | grep -v grep | head -5
echo "=== staging core env (litellm/gateway) ==="
docker inspect rag2-staging-core-litellm-1 -f '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E 'URL|ENDPOINT|PORT|DATABASE' | strip | head -10
docker inspect rag2-staging-core-gateway-1 -f '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E 'REGISTRY|LLM_ENDPOINT|PROVIDER' | grep -vE 'TOKEN|KEY' | head -15
