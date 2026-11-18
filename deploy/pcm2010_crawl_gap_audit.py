#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pcm2010_crawl_gap_audit.py — ممیزی read-only کامل بودن کراول + پیدا کردن گپ‌ها.

برای هر پروژه‌ای که با «عدد در آدرس» کراول شده (param / url-number / regex)
تمام صفحات ذخیره‌شده را از API زنده می‌خواند و جواب می‌دهد:

  1. گپ‌ها: چه اعدادی بین min..max در DB نیستند → فهرست بازه‌ها (chunks)
     + شماره اول هر چاک + فهرست کامل (JSON).
  2. کیفیت داده: صفحاتی که یک یا چند نقطه (point) خالی/کوچک دارند
     (این‌ها کاندیدای «ناقص» — دوباره باید کراول شوند).
  3. تکرار: رکوردهایی که values یکسان دارند یا یک عدد چند رکورد دارد.
  4. وضعیت کراول فعلی: آیا run زنده است (heartbeat تازه) + cursor کجاست.
  5. اثبات کامل بودن: --expect-max N می‌دهد → اگر همه‌ی 1..N حضور داشته
     باشند و هیچ صفحه‌ی ناقصی نباشد: **COMPLETENESS PROOF: PASS**؛
     وگرنه FAIL با لیست دقیق نقص‌ها.

STRICTLY READ-ONLY: فقط GET (login یک‌بار). هیچ چیزی در DB/سرور نمی‌نویسد.

اجرا (از هر دستگاهی که HTTPS دارد؛ فقط stdlib):
    set PCT_PASSWORD=<رمز داشبورد>
    python deploy\\pcm2010_crawl_gap_audit.py --project 2

    یا با cookie آماده:
    set PCT_COOKIE=<pct_session>
    python deploy\\pcm2010_crawl_gap_audit.py --project 2

    گزینه‌ها:
    --project 2          id پروژه (default: اولین پروژه‌ی ganjoor/tasnim فعال)
    --index-param item_index   پارامتر عددی در query (default: item_index)
    --path-number        عدد را از مسیر (pathname) بگیر (برای url-number)
    --expect-max N       اثبات کامل بودن: همه‌ی اعداد 1..N باید موجود باشند
    --min-len 20         آستانه‌ی «متن کافی» برای هر نقطه (کاراکتر)
    --out FILE           خروجی JSON کامل (گپ‌ها + نقص‌ها + تکرارها)
    --base URL           default https://corpus.ai.ismc.ir
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timezone

UA = "pcm2010-crawl-gap-audit/1.0 (read-only)"
RUN_LOCK_TTL_SEC = 180  # باید با RUN_LOCK_TTL بک‌اند یکی باشد


def force_utf8_stdio():
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass


# ── auth (same pattern as pcm208_mizan_audit.py) ─────────────────────────


def get_cookie(args):
    env = os.environ.get("PCT_COOKIE", "").strip()
    if env:
        return env
    if args.cookie_file:
        with open(args.cookie_file, "r", encoding="utf-8") as f:
            v = f.read().strip()
        if v:
            return v
    pw = os.environ.get("PCT_PASSWORD", "").strip()
    if not pw:
        print("FATAL: رمز داشبورد لازم است — set PCT_PASSWORD=... "
              "یا PCT_COOKIE / --cookie-file", file=sys.stderr)
        sys.exit(2)
    return login(args.base, pw)


def login(base, password, timeout=25):
    body = json.dumps({"password": password}).encode("utf-8")
    req = urllib.request.Request(
        base + "/api/auth/login", data=body, method="POST",
        headers={"User-Agent": UA, "Content-Type": "application/json",
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read()
            setc = r.headers.get("Set-Cookie", "")
    except urllib.error.HTTPError as e:
        e.read()
        print("login failed: HTTP %d — رمز اشتباه است؟ (rate-limit: ۱۰ fail = "
              "۱۰ دقیقه block)" % e.code, file=sys.stderr)
        return None
    except Exception as e:  # noqa: BLE001
        print("login failed: %s" % e, file=sys.stderr)
        return None
    for part in setc.split(","):
        part = part.strip()
        if part.startswith("pct_session="):
            val = part.split(";", 1)[0].split("=", 1)[1]
            print("login OK (cookie len=%d)" % len(val))
            return val
    print("login 200 اما بدون cookie", file=sys.stderr)
    return None


def get(base, path, cookie, timeout=60):
    req = urllib.request.Request(
        base + path,
        headers={"User-Agent": UA, "Cookie": "pct_session=" + cookie,
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(body)
        except json.JSONDecodeError:
            return e.code, {"_raw": body[:200]}
    except Exception as e:  # noqa: BLE001
        return -1, {"error": str(e)}


# ── number extraction ────────────────────────────────────────────────────


def page_number(url, index_param, path_number):
    """شماره‌ی صفحه از URL — None اگر قابل استخراج نبود."""
    u = urllib.parse.urlparse(url or "")
    if not path_number:
        qs = urllib.parse.parse_qs(u.query)
        raw = (qs.get(index_param) or [""])[0].strip()
        return int(raw) if raw.isdigit() else None
    runs = re.findall(r"\d+", u.path)
    return int(runs[-1]) if runs else None


def chunks(missing):
    """فهرست اعداد مرتب → بازه‌های پیوسته [lo, hi]."""
    out = []
    for n in sorted(set(missing)):
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return out


# ── main ─────────────────────────────────────────────────────────────────


def main(argv=None):
    force_utf8_stdio()
    ap = argparse.ArgumentParser(
        description="Read-only crawl gap/quality/completeness audit (live API)")
    ap.add_argument("--project", type=int, default=2,
                    help="project id (default 2 = تفسیر تسنیم همتا)")
    ap.add_argument("--base", default="https://corpus.ai.ismc.ir")
    ap.add_argument("--index-param", default="item_index",
                    help="نام پارامتر عددی در query")
    ap.add_argument("--path-number", action="store_true",
                    help="عدد را از pathname بگیر (برای روش url-number)")
    ap.add_argument("--expect-max", type=int, default=0,
                    help="اثبات کامل: همه‌ی 1..N باید موجود باشند")
    ap.add_argument("--min-len", type=int, default=20,
                    help="آستانه‌ی «متن کافی» برای هر نقطه (default 20)")
    ap.add_argument("--per-page", type=int, default=100,
                    help="صفحات هر GET (حداکثر 100)")
    ap.add_argument("--out", default=None,
                    help="فایل JSON خروجی (گپ/نقص/تکرار کامل)")
    ap.add_argument("--cookie-file", default=None)
    args = ap.parse_args(argv)

    cookie = get_cookie(args)
    st, d = get(args.base, "/api/auth/status", cookie)
    if st != 200 or not d.get("authenticated"):
        print("FATAL: cookie معتبر نیست — aborting (read-only guard).")
        return 1

    # ── project meta ──
    st, proj = get(args.base, "/api/projects/%d" % args.project, cookie)
    if st != 200 or not proj.get("id"):
        print("FATAL: پروژه %d پیدا نشد (HTTP %s)" % (args.project, st))
        return 1
    print("# ممیزی کامل‌بودن کراول — read-only")
    print("پروژه : %d «%s» (%s)" % (proj["id"], proj.get("name"), proj.get("host")))
    print("قانون  : %s %s (step=%s)" % (proj.get("next_mode"),
                                        proj.get("next_param"), proj.get("next_step")))
    print("شمارندهها (DB): ذخیره=%d  تکراری-رد=%d  خطا=%d"
          % (proj.get("saved_count", 0), proj.get("skipped_count", 0),
             proj.get("failed_count", 0)))
    print("cursor  : %s" % proj.get("cursor_url"))

    # run lock state (PCM-EXT-03): آیا همین حالا کسی دارد می‌خواند؟
    hb = proj.get("run_heartbeat") or 0
    now = datetime.now(timezone.utc).timestamp()
    lock_live = bool(proj.get("run_owner")) and (now - hb) < RUN_LOCK_TTL_SEC
    print("قفل run : %s%s" % (
        "زنده — یک نشست دارد می‌خواند (heartbeat %.0f ثانیه پیش)" % (now - hb)
        if lock_live else "خاموش (کراول فعال نیست)"))

    points = proj.get("points") or []
    if not points:
        print("هشدار: هیچ نقطه‌ای تعریف نشده — بخش کیفیت داده خالی است.")

    # ── fetch ALL pages (paginated GET) ──
    per = max(1, min(100, args.per_page))
    pages = {}  # number -> record
    non_numbered = []
    page_no = 1
    total = None
    while True:
        st, d = get(args.base, "/api/dashboard/projects/%d/pages?page=%d&per_page=%d"
                    % (args.project, page_no, per), cookie)
        if st != 200:
            print("FATAL: GET pages صفحه %d → HTTP %s: %s"
                  % (page_no, st, json.dumps(d, ensure_ascii=False)[:200]))
            return 1
        total = d.get("total", 0)
        batch = d.get("pages", [])
        for r in batch:
            num = page_number(r.get("url"), args.index_param, args.path_number)
            if num is None:
                non_numbered.append(r.get("url"))
            else:
                pages[num] = r
        print("  خواندن صفحات API: %d / %d ..." % (
            min(page_no * per, total), total))
        if len(batch) < per or (page_no * per) >= total:
            break
        page_no += 1
        if page_no > 20000:  # safety valve
            print("هشدار: بیش از 20000 صفحه‌ی API — قطع پیش‌دستانه.")
            break

    if not pages:
        print("FATAL: هیچ صفحه‌ی شماره‌دار پیدا نشد (param=%s, path_number=%s)"
              % (args.index_param, args.path_number))
        return 1

    numbers = sorted(pages)
    lo, hi = numbers[0], numbers[-1]
    present = set(numbers)
    dup_extra = len(numbers) - len(present)
    missing = [n for n in range(lo, hi + 1) if n not in present]
    ch = chunks(missing)

    # duplicate values (same point-values payload on different rows)
    payload_counter = Counter()
    for n in numbers:
        payload_counter[json.dumps(pages[n].get("values", {}),
                                   sort_keys=True, ensure_ascii=False)] += 1
    dup_values = {p: c for p, c in payload_counter.items() if c > 1}

    # per-point quality: empty or too-short values
    short_pages = []  # (number, url, {tag: len})
    for n in numbers:
        rec = pages[n]
        vals = rec.get("values", {}) or {}
        bad = {}
        for p in points:
            tag = p.get("tag", "?")
            v = str(vals.get(tag) or "").strip()
            if len(v) < args.min_len:
                bad[tag] = len(v)
        if bad:
            short_pages.append({"number": n, "url": rec.get("url"),
                                "short": bad})
    short_pages.sort(key=lambda x: x["number"])

    # ── report ──
    print("\n== بازه‌ی شماره‌ی صفحه ==")
    print("min=%d  max=%d  موجود(فرد)=%d  رکورد=%d  تکراری-شماره=%d"
          % (lo, hi, len(present), len(numbers), dup_extra))
    print("فهرست غیر-شماره‌دار: %d صفحه" % len(non_numbered))

    print("\n== گپ‌ها (اعداد غایب بین %d..%d) ==" % (lo, hi))
    if not ch:
        print("  ✅ بدون گپ — بازه کامل.")
    else:
        print("  %d عدد غایب در %d بازه:" % (len(missing), len(ch)))
        for a, b in ch[:40]:
            print("    %d..%d  (%d عدد)%s" % (a, b, b - a + 1,
                  "  ← بازهٔ اول" if (a, b) == ch[0] else ""))
        if len(ch) > 40:
            print("    ... و %d بازهٔ دیگر (در فایل خروجی)" % (len(ch) - 40))

    print("\n== کیفیت داده (نقاط خالی/کوچک < %d کاراکتر) ==" % args.min_len)
    if not points:
        print("  (بدون نقطه — بررسی نمی‌شود)")
    elif not short_pages:
        print("  ✅ همه‌ی %d صفحه در همه‌ی نقاط متن کافی دارند." % len(present))
    else:
        print("  %d صفحه‌ی ناقص:" % len(short_pages))
        for s in short_pages[:25]:
            desc = ", ".join("%s=%d" % (k, v) for k, v in s["short"].items())
            print("    #%d  %s  [%s]" % (s["number"], desc, s["url"]))
        if len(short_pages) > 25:
            print("    ... و %d صفحهٔ دیگر (در فایل خروجی)" % (len(short_pages) - 25))

    print("\n== تکرار محتوا ==")
    if dup_values:
        print("  %d payload یکسان روی چند رکورد:" % len(dup_values))
        for p, c in list(dup_values.items())[:10]:
            print("    %d×  %s" % (c, p[:100]))
    else:
        print("  ✅ بدون تکرار محتوا.")

    # ── completeness proof ──
    if args.expect_max:
        N = args.expect_max
        expected = set(range(1, N + 1))
        still_missing = sorted(expected - present)
        extra = sorted(present - expected)
        ok = (not still_missing) and (not short_pages) and (not dup_values)
        print("\n== اثبات کامل بودن (1..%d) ==" % N)
        print("  غایب از 1..%d: %d" % (N, len(still_missing)))
        if still_missing:
            cm = chunks(still_missing)
            print("  بازه‌های غایب (۲۰ اول): %s"
                  % [ "%d..%d" % (a, b) for a, b in cm[:20] ])
        if extra:
            print("  اعداد بالاتر از N: %d (مثال: %s)" % (len(extra), extra[:10]))
        print("  صفحات ناقص: %d" % len(short_pages))
        print("  تکرار محتوا: %d" % len(dup_values))
        print("\n  نتیجه: **COMPLETENESS PROOF: %s**"
              % ("PASS — همه‌ی 1..%d موجود، همه‌ی صفحات کامل، بدون تکرار" % N
                 if ok else "FAIL — نقص‌های بالا را ببینید"))

    # ── JSON out ──
    out = {
        "audited_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "project": {k: proj.get(k) for k in (
            "id", "name", "host", "status", "cursor_url", "saved_count",
            "skipped_count", "failed_count", "next_mode", "next_param",
            "next_step")},
        "run_lock": {"live": lock_live, "owner": proj.get("run_owner", ""),
                     "heartbeat_age_sec": int(now - hb) if hb else None},
        "numbering": {"min": lo, "max": hi, "distinct": len(present),
                      "records": len(numbers), "dup_numbers": dup_extra,
                      "non_numbered_urls": non_numbered},
        "gaps": {"missing_count": len(missing), "chunks": ch,
                 "missing_full": missing},
        "quality": {"min_len": args.min_len, "short_page_count": len(short_pages),
                    "short_pages": short_pages},
        "duplicates": {"dup_payload_count": len(dup_values),
                       "dup_payloads": [
                           {"count": c, "sample": p[:200]}
                           for p, c in list(dup_values.items())[:50]]},
    }
    if args.expect_max:
        out["completeness"] = {
            "expect_max": args.expect_max,
            "pass": bool(not still_missing and not short_pages and not dup_values),
            "missing_from_1_to_N": still_missing,
            "beyond_N": extra,
        }
    out_path = args.out or os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "..", "evidence", "crawl-gap-audit-project%d-%s.json"
        % (args.project, datetime.now().strftime("%Y%m%d-%H%M%S")))
    out_path = os.path.normpath(out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("\nخروجی JSON: %s" % out_path)
    print("DONE — read-only; هیچ چیزی در سرور نوشته نشد.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
