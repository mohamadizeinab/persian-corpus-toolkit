#!/bin/bash
# H5+H3 take 3: cloudflared config via host bind mount; git remote branch compare (s53), read-only
set -u
echo "=== cloudflared config dir (host bind mount /home/saber/h200-api/cloudflared) ==="
ls -la /home/saber/h200-api/cloudflared/ 2>&1
echo "=== config.yml (token redacted) ==="
sed -E 's/^([[:space:]]*token:[[:space:]]*).*$/\1[REDACTED]/' /home/saber/h200-api/cloudflared/config.yml 2>&1 | head -80
echo "=== host /etc/cloudflared (used by pid 7329) ==="
ls -la /etc/cloudflared/ 2>&1
sed -E 's/^([[:space:]]*token:[[:space:]]*).*$/\1[REDACTED]/' /etc/cloudflared/config.yml 2>&1 | head -80
echo "=== git: local vs remote branch HEAD (read-only ls-remote) ==="
for d in /home/saber/saberprojects/radio-rag-service /home/saber/saberprojects/rag-portal; do
  echo "--- $d"
  echo "local HEAD:         $(git -C "$d" rev-parse HEAD 2>&1)"
  echo "local branch:       $(git -C "$d" branch --show-current 2>&1)"
  echo "remote HEAD:        $(timeout 25 git -C "$d" ls-remote origin HEAD 2>&1 | head -1)"
  echo "remote e6.1-rag-production: $(timeout 25 git -C "$d" ls-remote origin e6.1-rag-production 2>&1 | head -1)"
done
