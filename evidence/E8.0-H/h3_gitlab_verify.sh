#!/bin/bash
# H3: read-only GitLab remote verification (no PAT creation, no modifications)
set -u
echo "=== ls-remote radio-rag-service (uses stored creds; read-only) ==="
timeout 25 git -C /home/saber/saberprojects/radio-rag-service ls-remote origin HEAD 2>&1 | sed -E 's|(https://[^/@]+:)[^@/]+@|\1[user]@|' | head -3
echo "=== ls-remote rag-portal ==="
timeout 25 git -C /home/saber/saberprojects/rag-portal ls-remote origin HEAD 2>&1 | sed -E 's|(https://[^/@]+:)[^@/]+@|\1[user]@|' | head -3
echo "=== deployed file vs HEAD (tracked files only) ==="
cd /home/saber/saberprojects/radio-rag-service && echo "radio-rag-service tracked status:" && git status --porcelain | grep -v '^??' | head -5 && echo "(empty above = deployed tracked files match HEAD)"
echo "api.py in git? $(git ls-files api.py | wc -l) | rag_proxy.py in git? $(git ls-files rag_proxy.py | wc -l)"
cd /home/saber/saberprojects/rag-portal && echo "rag-portal tracked status:" && git status --porcelain | grep -v '^??' | head -5
echo "=== staging dirs: git? ==="
ls -d /home/saber/saberprojects/radio2-staging/.git 2>&1
ls -d /home/saber/saberprojects/rag2-staging* 2>/dev/null
for d in /home/saber/saberprojects/rag2-staging-core /home/saber/saberprojects/rag2-staging; do
  [ -d "$d/.git" ] && echo "$d IS git: $(git -C "$d" branch --show-current) $(git -C "$d" log -1 --format=%h)" || echo "$d not a git repo"
done
echo "=== ragportal_api image (no mounts => code baked in) ==="
docker image inspect rag-portal-ragportal_api --format 'created={{.Created}} size={{.Size}}' 2>/dev/null
