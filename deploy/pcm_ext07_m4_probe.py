"""PCM-EXT-07 M4 probe: char_count distribution + short-row source check + archive floor.
Runs on s52:  cd /home/saber/saberprojects/pct-staging && python3 deploy/pcm_ext07_m4_probe.py
"""
import re
import sqlite3
import sys

sys.path.insert(0, "corpus")
import scrape_khamenei as sk

DB = "backend/thesaurus.db"
db = sqlite3.connect(DB)
db.row_factory = sqlite3.Row

rows = db.execute(
    "SELECT speech_id, title, char_count, content FROM khamenei_speeches "
    "WHERE speech_year IN ('1400','1402') ORDER BY char_count"
).fetchall()
n = len(rows)
counts = [r["char_count"] for r in rows]
print("== char_count distribution (n=%d) ==" % n)
print("min=%d p25=%d median=%d p75=%d max=%d" % (
    counts[0], counts[n // 4], counts[n // 2], counts[3 * n // 4], counts[-1]))
print("count<50:  %d" % sum(1 for c in counts if c < 50))
print("count<100: %d" % sum(1 for c in counts if c < 100))
print("count=0:   %d" % sum(1 for c in counts if c == 0))
print("100-999:   %d" % sum(1 for c in counts if 100 <= c < 1000))
print(">=1000:    %d" % sum(1 for c in counts if c >= 1000))

print("\n== 4 shortest rows: source-true vs extraction? ==")
for r in rows[:4]:
    sid = r["speech_id"]
    print("\n--- sid=%s stored_chars=%d title=%r" % (sid, r["char_count"], r["title"][:70]))
    print("    stored content: %r" % r["content"][:200])
    # raw live page: compare the FIRST </div> cutoff against the whole div region
    import requests
    url = sk.BASE + "/speech-content?id=" + sid
    html = requests.get(url, timeout=30).text
    m = re.search(r'<div[^>]*class="Content"[^>]*>(.*)', html, re.DOTALL)
    if not m:
        print("    NO Content div in live page!")
        continue
    region = m.group(1)
    first_cut = region.split("</div>")[0]
    first_cut_text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", first_cut)).strip()
    greedy = region[:region.rfind("</div>")]
    greedy_text = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", greedy)).strip()
    print("    live first-</div> text chars: %d | live whole-div text chars: %d"
          % (len(first_cut_text), len(greedy_text)))
    print("    live first-cut: %r" % first_cut_text[:200])

print("\n== archive floor discovery (years 1372..1379) ==")
for y in range(1379, 1371, -1):
    ids = sk.discover_year(y)
    print("  year %d: %d IDs" % (y, len(ids)))

db.close()
print("\nPROBE DONE")
