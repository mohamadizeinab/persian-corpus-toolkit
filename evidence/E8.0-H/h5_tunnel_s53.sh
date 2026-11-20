#!/bin/bash
# H5 (take 2): h200-public-tunnel + vllm auth (s53), read-only
set -u
strip() { sed -E 's/((KEY|TOKEN|SECRET|PASSWORD|CRED|TUNNEL_ID)[A-Za-z_]*=).*/\1[REDACTED]/'; }
echo "=== container exact name/status ==="
docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE 'tunnel|cloudflared' || docker ps -a --format '{{.Names}}' | grep -i h200
NAME=$(docker ps --format '{{.Names}}' | grep -iE 'tunnel|cloudflare|h200' | head -1)
echo "NAME=$NAME"
if [ -n "$NAME" ]; then
  echo "=== mounts ==="
  docker inspect "$NAME" --format '{{range .Mounts}}{{.Type}}: {{.Source}} -> {{.Destination}}{{println}}{{end}}'
  echo "=== env names ==="
  docker inspect "$NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1
  echo "=== ingress config (sanitized) ==="
  docker exec "$NAME" sh -c "cat /etc/cloudflared/config.yml 2>/dev/null" | sed -E 's/(token:[[:space:]]*).*$/\1[REDACTED]/' | head -50
fi
echo "=== vllm-qwen38 full cmd (auth flags) ==="
docker inspect vllm-qwen38 --format '{{json .Config.Cmd}}' | tr ',' '\n'
echo "=== vllm-qwen38 ports/network ==="
docker inspect vllm-qwen38 --format '{{json .NetworkSettings.Networks}}' | head -5
docker port vllm-qwen38
echo "=== host-level cloudflared process (pid/cmdline) ==="
ps -eo pid,args | grep -E 'cloudflared' | grep -v grep
