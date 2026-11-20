#!/bin/bash
# H5: cloudflared tunnel mapping (s53) ; H6: monitoring inventory (s52+s53)
set -u
strip() { sed -E 's/((KEY|TOKEN|SECRET|PASSWORD|TUNNEL|CRED)[A-Z_]*=).*/\1[REDACTED]/'; }
echo "########## ON s53 ##########"
echo "=== cloudflared container ==="
docker inspect h200-public-tunnel -f 'image={{.Config.Image}} | state={{.State.Status}} started={{.State.StartedAt}} | net={{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
docker inspect h200-public-tunnel -f '{{range .Config.Env}}{{println .}}{{end}}' | strip | head -10
echo "=== cloudflared config file (host path) ==="
ls -la /etc/cloudflared/ 2>&1
cat /etc/cloudflared/config.yml 2>/dev/null | grep -vE '^\s*#|token|tunnel|credentials' | head -40
echo "=== ingress hosts (sanitized: hosts only, no creds) ==="
grep -E 'hostname|service' /etc/cloudflared/config.yml 2>/dev/null | head -30
echo "=== h200 api local listener ==="
ss -tlnp 2>/dev/null | grep -E ':(8000|8080)\s' | head -5
echo "=== vllm-qwen38 auth? (env names only) ==="
docker inspect vllm-qwen38 -f '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -iE 'api|auth|key' | strip | head -10
docker inspect vllm-qwen38 -f '{{.Config.Cmd}}' 2>/dev/null | tr ' ' '\n' | grep -vE '^$' | head -20
echo "########## H6 monitoring (s52) ##########"
echo "=== prometheus targets ==="
curl -s http://127.0.0.1:9090/api/v1/targets 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); [print(t['labels'].get('job','?'), t['scrapeUrl'], t['health'], t.get('lastError','')[:80]) for t in d['data']['activeTargets']]" 2>/dev/null | head -40
echo "=== prometheus config scrape jobs (names) ==="
curl -s http://127.0.0.1:9090/api/v1/status/config 2>/dev/null | grep -oE 'job_name: [^ ]+' | head -30
echo "=== gateway /metrics recheck ==="
curl -s -o /dev/null -w 'gateway bare /metrics -> %{http_code}\n' http://127.0.0.1:8210/metrics
curl -s -o /dev/null -w 'registry bare /metrics -> %{http_code}\n' http://127.0.0.1:8200/metrics
docker exec rag-gateway sh -c 'curl -s -o /dev/null -w "in-container /metrics -> %{http_code}\n" http://127.0.0.1:8210/metrics' 2>/dev/null || true
echo "=== grafana datasources/dashboards (no secrets) ==="
curl -s -o /dev/null -w 'grafana / -> %{http_code}\n' http://127.0.0.1:3001/ 2>/dev/null
echo "=== alertmanager? ==="
ss -tln 2>/dev/null | grep -E ':(9093|3000|3001)\s' | head -5
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -iE 'alertmanager|grafana|prometheus|node-exporter|loki|promtail'
echo "########## H6 monitoring (s53) ##########"
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -iE 'prometheus|grafana|node-exporter|dcgm|loki|promtail|alertmanager'
ss -tln 2>/dev/null | grep -E ':(9090|9100|9408|9093)\s' | head -5
