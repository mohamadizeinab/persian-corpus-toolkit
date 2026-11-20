#!/bin/bash
# E8.0-H6 gap (s53): promtail -> loki path. READ-ONLY.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== promtail container (cmd + env names) ==="
docker inspect promtail --format 'cmd={{json .Config.Cmd}}' 2>/dev/null
docker inspect promtail --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | cut -d= -f1 | head -15
echo "=== promtail config files (mounts) ==="
docker inspect promtail --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
echo "=== established connections to :3100 (loki targets) ==="
ss -tn 2>/dev/null | grep ':3100 ' | awk '{print $5}' | sort -u
echo "END H6-GAP-S53"
