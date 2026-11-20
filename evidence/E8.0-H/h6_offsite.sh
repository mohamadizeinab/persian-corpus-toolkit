#!/bin/bash
# H6: offsite-backup / remote-sync evidence sweep (read-only). Run once per host.
set -u
echo "=== host: $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "=== backup dir ==="
ls -lat /home/saber/backups 2>/dev/null | head -25
du -sh /home/saber/backups 2>/dev/null
echo "=== offsite tooling ==="
for t in rclone restic borg rsync; do
  command -v "$t" >/dev/null 2>&1 && echo "$t: $(command -v $t)" || echo "$t: absent"
done
echo "=== rclone remotes (names only) ==="
grep -E '^\[' /home/saber/.config/rclone/rclone.conf 2>/dev/null || echo "no rclone.conf"
echo "=== crontab (saber, non-comment) ==="
crontab -l 2>&1 | grep -vE '^\s*#' | head -20
echo "=== systemd timers (visible) ==="
systemctl list-timers --no-pager 2>/dev/null | head -15
echo "=== remote/network mounts ==="
mount | grep -vE 'tmpfs|proc|sysfs|cgroup|devpts|overlay|squashfs|shm|mqueue' | head -15
echo "=== established outbound connections (unique) ==="
ss -tn 2>/dev/null | grep -vE '127.0.0.1|::1|\[::1\]' | awk '{print $4, $5}' | sort -u | head -25
