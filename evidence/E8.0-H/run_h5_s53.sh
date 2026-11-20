#!/bin/bash
# E8.0-H5 (s53 part): h200-public-tunnel cloudflared + vllm exposure. READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== tunnel container ==="
docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' | grep -iE 'tunnel|cloudflared'
NAME=$(docker ps --format '{{.Names}}' | grep -iE 'tunnel|cloudflare|h200' | head -1)
echo "NAME=$NAME"
if [ -n "$NAME" ]; then
  echo "=== mounts ==="
  docker inspect "$NAME" --format '{{range .Mounts}}{{.Type}}: {{.Source}} -> {{.Destination}} (mode={{.Mode}}){{println}}{{end}}'
  echo "=== env names only ==="
  docker inspect "$NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1
fi
echo "=== cloudflared config files on host (bind mount source) ==="
ls -la /home/saber/h200-api/cloudflared/ 2>&1
echo "config.yml readable as saber? $(head -c1 /home/saber/h200-api/cloudflared/config.yml >/dev/null 2>&1 && echo yes || echo no-permission)"
echo "public-url.txt: $(cat /home/saber/h200-api/cloudflared/public-url.txt 2>&1)"
echo "=== vllm-qwen38 cmd (auth flags) ==="
docker inspect vllm-qwen38 --format '{{json .Config.Cmd}}' | tr ',' '\n'
echo "=== vllm-qwen38 published ports ==="
docker port vllm-qwen38
echo "=== host cloudflared process ==="
ps -eo pid,args | grep -E 'cloudflared' | grep -v grep
echo "=== host listening sockets (0.0.0.0) ==="
ss -tln | awk '{print $4}' | grep -E '^0\.0\.0\.0:' | sort -t: -k2 -n | head -60
echo "=== docker published ports ==="
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -v '^\s*$'
echo "=== ufw/iptables state (root required) ==="
ufw status 2>&1 | head -5
iptables -S INPUT 2>&1 | head -10
echo "END H5-S53"
