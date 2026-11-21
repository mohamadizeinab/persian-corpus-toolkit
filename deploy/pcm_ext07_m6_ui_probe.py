#!/usr/bin/env python3
"""PCM-EXT-07 M6 — live verification of the human UI data path (read-only).

Simulates the EXACT fetches the dashboard (dashboard/index.html, "🎤 بیانات"
tab) makes, against the live staging edge over the self-signed URL — from a
fresh session, no cookie:

  1. GET  /api/auth/status          (checkAuth) -> expect auth_enabled=true,
                                                   authenticated=false
  2. GET  /api/khamenei/stats       (no cookie)  -> expect 401 (login overlay
                                                   would show)  [PCM-09]
  3. POST /api/auth/login           password read from staging .env (NOT
     printed) -> expect ok=true + Set-Cookie pct_session
  4. GET  /api/khamenei/stats       (with cookie) -> 200, total=245
  5. GET  /api/khamenei/recent?limit=20 (with cookie) -> first rows incl.
     date + title (the "آخرین بیانات" table the owner sees)
  6. GET  /api/khamenei/crawl-status(with cookie) -> pending_by_year
  7. GET  /dashboard/               (with cookie) -> 200 HTML (the page itself)

Stdlib only; password never printed (AGENTS §2.5).
"""
import json
import re
import ssl
import urllib.request
import urllib.error

B = "https://pct-staging.ai.ismc.ir"
ENV = "/home/saber/saberprojects/pct-staging/.env"
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

cookie = None


def req(path, method="GET", body=None):
    global cookie
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    h = {"Content-Type": "application/json"}
    if cookie:
        h["Cookie"] = cookie
    r = urllib.request.Request(B + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, context=CTX, timeout=30) as resp:
            sc = resp.status
            setc = resp.headers.get("Set-Cookie") or ""
            txt = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        sc = e.code
        setc = e.headers.get("Set-Cookie") or ""
        txt = e.read().decode("utf-8", "replace")
    if setc:
        m = re.match(r"([A-Za-z0-9._-]+=[^;]+)", setc)
        if m:
            cookie = m.group(1)
    return sc, txt


def main():
    out = []
    P = out.append

    # password from .env (never printed)
    pw = None
    with open(ENV, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("PCT_DASHBOARD_PASSWORD="):
                pw = line.split("=", 1)[1].strip().strip('"').strip("'")
    P(f"pw-loaded={'yes' if pw else 'NO'} (len={len(pw or '')}, value hidden)")

    # 1. auth status, no cookie
    sc, txt = req("/api/auth/status")
    P(f"1 GET /api/auth/status (no cookie) HTTP {sc}: {txt[:200]}")

    # 2. khamenei stats without cookie -> 401
    sc, txt = req("/api/khamenei/stats")
    P(f"2 GET /api/khamenei/stats (no cookie) HTTP {sc}: {txt[:120]} "
      f"{'PASS(401->overlay)' if sc == 401 else 'CHECK'}")

    # 3. login
    sc, txt = req("/api/auth/login", "POST", {"password": pw or ""})
    P(f"3 POST /api/auth/login HTTP {sc}: {txt[:120]} "
      f"cookie={'SET' if cookie else 'NOT-SET'} "
      f"{'PASS' if sc == 200 and cookie else 'FAIL'}")

    # 4. stats with cookie
    sc, txt = req("/api/khamenei/stats")
    P(f"4 GET /api/khamenei/stats (cookie) HTTP {sc}: {txt[:300]} "
      f"{'PASS' if sc == 200 else 'FAIL'}")

    # 5. recent table
    sc, txt = req("/api/khamenei/recent?limit=5")
    try:
        j = json.loads(txt)
        rows = j.get("items") or j.get("rows") or (j if isinstance(j, list) else [])
        P(f"5 GET /api/khamenei/recent?limit=5 (cookie) HTTP {sc}: {len(rows)} rows")
        for r in rows[:3]:
            P(f"   sid={r.get('speech_id')} date={r.get('speech_date')} "
              f"title={(r.get('title') or '')[:60]!r} chars={r.get('char_count')}")
    except Exception as e:
        P(f"5 GET /api/khamenei/recent?limit=5 (cookie) HTTP {sc}: {txt[:200]} (parse: {e})")

    # 6. crawl-status
    sc, txt = req("/api/khamenei/crawl-status")
    P(f"6 GET /api/khamenei/crawl-status (cookie) HTTP {sc}: {txt[:250]} "
      f"{'PASS' if sc == 200 else 'FAIL'}")

    # 7. dashboard page itself
    sc, txt = req("/dashboard/")
    has_tab = "tab-khamenei" in txt
    P(f"7 GET /dashboard/ (cookie) HTTP {sc}: {len(txt)} bytes, "
      f"contains 'tab-khamenei'={has_tab} "
      f"{'PASS' if sc == 200 and has_tab else 'FAIL'}")

    print("\n".join(out))


if __name__ == "__main__":
    main()
