#!/usr/bin/env python3
"""PCM-EXT-07 M5 — extension-shaped live round-trip against staging.

Simulates EXACTLY what the Chrome extension (v3.10-staging) sends to the
staging backend (self-signed https, same URLs as extension BACKEND override):

  1. GET  /api/khamenei/crawl-status   (popup stats panel, popup.js refreshStats)
  2. GET  /api/khamenei/stats          (popup stats panel)
  3. GET  /api/khamenei/pending        (background.js fetchPendingKhameneiIds)
  4. POST /api/phase1/seed-batch       (content_khamenei.js discoverIds)
     EXACT extension shape: {site:'khamenei',
     items:[{url, item_id, page_type:'khamenei_speech', title, source_page}]}
     using urls already present in crawl_queue -> expect added=0, duplicates=N
  5. POST /api/phase2/complete         (content_khamenei.js extractAndSubmit)
     EXACT extension shape for speech 47576 (year 1400, M4 S6 live-verified):
     {site, speech_id, url, title, date, year, content, meta_text, audio_url,
      video_url, tags, related_links, extra_links, char_count}
     content+date read VERBATIM from the staging DB (== what the extension
     would extract; M4 S6 proved text_equal=True against the live page)
     -> expect status=skipped twice (dedup vs M4 data, idempotent)
  6. Verify counts unchanged (245 total, 1400=35, 1402=56, dups=0, integrity ok)

Read-only except the idempotent write path (skipped => no row change).
Stdlib only.
"""
import json
import sqlite3
import ssl
import urllib.request

B = "https://pct-staging.ai.ismc.ir"
DB = "/home/saber/saberprojects/pct-staging/backend/thesaurus.db"
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def get(path):
    with urllib.request.urlopen(B + path, context=CTX, timeout=30) as r:
        return r.status, r.read().decode()


def post(path, obj):
    req = urllib.request.Request(
        B + path,
        data=json.dumps(obj, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return r.status, r.read().decode()


def q(sql):
    db = sqlite3.connect(DB)
    db.row_factory = sqlite3.Row
    rows = db.execute(sql).fetchall()
    db.close()
    return rows


def main():
    out = []
    P = out.append

    base = q("SELECT COUNT(*) t FROM khamenei_speeches")[0]["t"]
    y1400 = q("SELECT COUNT(*) t FROM khamenei_speeches WHERE speech_year='1400'")[0]["t"]
    y1402 = q("SELECT COUNT(*) t FROM khamenei_speeches WHERE speech_year='1402'")[0]["t"]
    dups = q("SELECT COUNT(*) - COUNT(DISTINCT speech_id) d FROM khamenei_speeches")[0]["d"]
    P(f"BASELINE total={base} y1400={y1400} y1402={y1402} dups={dups}")

    # 1-3: GET endpoints the extension actually calls
    for path, label in [
        ("/api/khamenei/crawl-status", "GET crawl-status"),
        ("/api/khamenei/stats", "GET stats"),
        ("/api/khamenei/pending?limit=50", "GET pending?limit=50"),
    ]:
        code, body = get(path)
        P(f"{label} HTTP {code}: {body[:400]}")

    # 4: seed-batch duplicate detection with already-queued urls
    rows = q(
        "SELECT item_id, url, title, source_page FROM crawl_queue "
        "WHERE site='khamenei' AND url IS NOT NULL AND url<>'' LIMIT 3"
    )
    items = [
        {
            "url": r["url"],
            "item_id": r["item_id"],
            "page_type": "khamenei_speech",
            "title": r["title"] or "",
            "source_page": r["source_page"] or "",
        }
        for r in rows
    ]
    code, body = post("/api/phase1/seed-batch", {"site": "khamenei", "items": items})
    j = json.loads(body)
    P(f"POST phase1/seed-batch ({len(items)} already-queued urls) HTTP {code}: {body}")
    exp = "PASS" if j.get("added") == 0 and j.get("duplicates") == len(items) else "FAIL"
    P(f"  -> added={j.get('added')} duplicates={j.get('duplicates')} "
      f"(expect added=0 duplicates={len(items)}) {exp}")

    # 5: phase2/complete with the EXACT extension payload shape
    r = q(
        "SELECT speech_id, speech_date, speech_year, title, content "
        "FROM khamenei_speeches WHERE speech_id='47576'"
    )[0]
    speech_id = r["speech_id"]
    payload = {
        "site": "khamenei",
        "speech_id": speech_id,
        "url": f"https://farsi.khamenei.ir/speech-content?id={speech_id}",
        "title": r["title"],
        "date": r["speech_date"],
        "year": r["speech_year"],
        "content": r["content"],
        "meta_text": "",
        "audio_url": "",
        "video_url": "",
        "tags": [],
        "related_links": [],
        "extra_links": [],
        "char_count": len(r["content"]),
    }
    for i in (1, 2):
        code, body = post("/api/phase2/complete", payload)
        j = json.loads(body)
        ok = j.get("status") == "skipped"
        P(f"POST phase2/complete attempt{i} (speech_id={speech_id}, "
          f"date={r['speech_date']}, {len(r['content'])} chars) "
          f"HTTP {code}: {body}")
        P(f"  -> status={j.get('status')} (expect skipped) "
          f"{'PASS' if ok else 'FAIL'}")

    # 6: counts unchanged
    base2 = q("SELECT COUNT(*) t FROM khamenei_speeches")[0]["t"]
    y1400b = q("SELECT COUNT(*) t FROM khamenei_speeches WHERE speech_year='1400'")[0]["t"]
    y1402b = q("SELECT COUNT(*) t FROM khamenei_speeches WHERE speech_year='1402'")[0]["t"]
    dupsb = q("SELECT COUNT(*) - COUNT(DISTINCT speech_id) d FROM khamenei_speeches")[0]["d"]
    integ = q("PRAGMA integrity_check")[0][0]
    P(f"FINAL total={base2} y1400={y1400b} y1402={y1402b} dups={dupsb} integrity={integ}")
    same = (base2 == base and y1400b == y1400 and y1402b == y1402
            and dupsb == 0 and integ == "ok")
    P(f"COUNTS-UNCHANGED: {'PASS' if same else 'FAIL'}")

    print("\n".join(out))


if __name__ == "__main__":
    main()
