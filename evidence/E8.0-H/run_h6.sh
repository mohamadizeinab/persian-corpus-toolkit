#!/bin/bash
# E8.0-H6: observability + backup/DR sweep. READ-ONLY. Run on each host.
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== monitoring containers ==="
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | grep -iE 'prometheus|grafana|loki|node-exporter|alertmanager|dcgm|exporter' || echo "none matched"
echo "=== prometheus targets ==="
curl -s -m 8 http://127.0.0.1:9090/api/v1/targets 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    ts=d.get('data',{}).get('activeTargets',[])
    up=sum(1 for t in ts if t.get('health')=='up')
    print('active targets: %d (up=%d)' % (len(ts), up))
    for t in ts:
        if t.get('health')!='up':
            print('  DOWN:', t.get('labels',{}).get('job','?'), t.get('scrapeUrl'))
    rag=[t.get('scrapeUrl') for t in ts if any(k in (t.get('scrapeUrl') or '') for k in ('8210','8200','4101','8211','8212','8101','8102'))]
    print('RAG-core scrape targets:', rag if rag else 'NONE')
except Exception as e:
    print('targets parse-fail:', e)
"
echo "=== RAG metrics endpoints (s52 only; skip if absent) ==="
curl -s -m 5 -o /dev/null -w "gateway :8210 /metrics -> %{http_code}\n" http://127.0.0.1:8210/metrics 2>/dev/null
curl -s -m 5 -o /dev/null -w "registry :8200 /metrics -> %{http_code}\n" http://127.0.0.1:8200/metrics 2>/dev/null
echo "=== grafana auth wall ==="
curl -s -m 5 -o /dev/null -w "grafana :3001 / -> %{http_code}\n" http://127.0.0.1:3001/ 2>/dev/null
echo "=== alertmanager ==="
docker ps -a --format '{{.Names}}' | grep -i alertmanager || echo "alertmanager: ABSENT"
echo "=== backup dir ==="
du -sh /home/saber/backups 2>/dev/null
ls -lat /home/saber/backups 2>/dev/null | head -12
echo "=== offsite tooling ==="
for t in rclone restic borg rsync; do command -v "$t" >/dev/null 2>&1 && echo "$t: present" || echo "$t: absent"; done
grep -E '^\[' /home/saber/.config/rclone/rclone.conf 2>/dev/null || echo "no rclone.conf"
echo "=== cron (non-comment) ==="
crontab -l 2>&1 | grep -vE '^\s*#' | head -10
echo "=== network mounts ==="
mount | grep -E 'nfs|cifs|smb|gluster|9p' || echo "no network filesystem mounts"
echo "=== outbound 443 endpoints (peer ip counts) ==="
ss -tn 2>/dev/null | awk '$4 ~ /:443$/ {print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -8
echo "=== RAG-related backup timers (s52) ==="
systemctl list-timers --no-pager 2>/dev/null | grep -iE 'rag|litellm|backup' || echo "no RAG/backup timers visible"
echo "END H6"
