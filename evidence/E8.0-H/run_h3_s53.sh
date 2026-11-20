#!/bin/bash
# E8.0-H3: UI source control + staging isolation. READ-ONLY.
# Secret policy: env values printed ONLY if they are URLs or bare numbers; everything else [REDACTED].
set -u
echo "=== time/host ==="
date -u +%Y-%m-%dT%H:%M:%SZ; hostname
echo "=== git repos: local vs GitLab remote ==="
for d in /home/saber/saberprojects/radio-rag-service /home/saber/saberprojects/rag-portal; do
  echo "--- $d"
  echo "local HEAD:            $(git -C "$d" rev-parse HEAD 2>&1)"
  echo "local branch:          $(git -C "$d" branch --show-current 2>&1)"
  echo "local HEAD date:       $(git -C "$d" log -1 --format='%ci' 2>&1)"
  echo "remote URL (masked):   $(git -C "$d" remote get-url origin 2>&1 | sed -E 's|(://)[^/@]+@|\1[user]@|')"
  echo "remote HEAD:           $(timeout 25 git -C "$d" ls-remote origin HEAD 2>&1 | head -1)"
  echo "remote e6.1-rag-production: $(timeout 25 git -C "$d" ls-remote origin e6.1-rag-production 2>&1 | head -1)"
  echo "untracked count:       $(git -C "$d" status --porcelain | grep -c '^??' || true)"
  echo "modified-tracked:      $(git -C "$d" status --porcelain | grep -v '^??' | head -3)"
done
echo "=== prod radio_api mounts (deployed files come from working tree) ==="
docker inspect radio_api --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
echo "=== ragportal_api mounts (empty = code baked in image) ==="
docker inspect ragportal_api --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
echo "=== UI env: RAG_/LITELLM_/PCT_ vars; non-URL/non-numeric values REDACTED ==="
for c in radio_api ragportal_api radio2_api rag2_api; do
  echo "--- $c"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E '^(RAG_|LITELLM_|PCT_)' \
    | while IFS= read -r line; do
        name="${line%%=*}"; val="${line#*=}"
        case "$val" in
          http://*|https://*) echo "$name=$val" ;;
          [0-9]*[0-9]) echo "$name=$val" ;;
          "") echo "$name=" ;;
          *) echo "$name=[REDACTED]" ;;
        esac
      done
done
echo "=== staging dirs: git? ==="
for d in /home/saber/saberprojects/radio2-staging /home/saber/saberprojects/rag2-staging /home/saber/saberprojects/rag2-staging-core; do
  if [ -d "$d" ]; then
    if [ -d "$d/.git" ]; then echo "$d: git repo (branch=$(git -C "$d" branch --show-current))"; else echo "$d: exists, NOT a git repo"; fi
  else
    echo "$d: absent"
  fi
done
echo "=== ragportal_api image ==="
docker image inspect rag-portal-ragportal_api --format 'created={{.Created}} size={{.Size}}' 2>/dev/null
echo "END H3"
