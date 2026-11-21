"""
Khamenei.ir Speech Scraper - Standalone Python Script
Can run independently or be called by the extension backend.
Discovers and extracts all speeches from farsi.khamenei.ir/speech.

PAGINATION REALITY (verified live 2026-11-21):
- The server IGNORES ?page=N (page=1 and page=2 are byte-identical).
- Each Jalali year is ONE complete list page: /speech?nt=2&year=YYYY
  (28-79 items, dates spanning the full year; archive 1379..1404+).
- Unfiltered /speech shows only the latest year.
- Main-list items carry <span class="ltr skyText">YYYY/MM/DD</span>;
  sidebar widget anchors have NO date span (must be excluded).
So discovery is per-year: one request per year, walking backwards until
a couple of consecutive empty years are seen.
"""
import requests, re, sys, time, json, os, urllib3
urllib3.disable_warnings()
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass

BASE = "https://farsi.khamenei.ir"
DB_PATH = os.path.join(os.path.dirname(__file__), '..', 'backend', 'thesaurus.db')

# Archive facts (live-verified): first year on the site is 1379.
ARCHIVE_START_YEAR = 1379
# Auto-walk floor: stop scanning below this (safety margin below archive start).
WALK_END_YEAR = ARCHIVE_START_YEAR - 5
# Stop the auto-walk after this many consecutive empty years (future years
# or gaps count as empty).
STOP_AFTER_EMPTY = 2

# List-page item: anchor to speech-content whose inner FIRST child is a
# date span (main list). Sidebar anchors ("پیشنهاد ما" / li.hpList) have no
# date span and are excluded.
LIST_ITEM_RE = re.compile(
    r'<a\s+href="speech-content\?id=(\d+)"[^>]*>\s*'
    r'<span[^>]*class="[^"]*skyText[^"]*"[^>]*>\s*'
    r'([0-9۰-۹٠-٩]{4}/[0-9۰-۹٠-٩]{2}/[0-9۰-۹٠-٩]{2})'
    r'\s*</span>'
)

_PERSIAN_DIGITS = "۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩"
_ASCII_DIGITS = "0123456789" * 2
_DIGIT_TABLE = str.maketrans(_PERSIAN_DIGITS, _ASCII_DIGITS)


def to_ascii_digits(s):
    """Convert Persian/Arabic-Indic digits to ASCII."""
    return (s or "").translate(_DIGIT_TABLE)


headers = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,*/*",
    "Accept-Language": "fa,en-US;q=0.9,en;q=0.8",
}
NO_PROXY = {'http': None, 'https': None}

# Robust session: ignore Windows registry/system proxy (broken VPN leftover),
# use browser-like headers so khamenei.ir doesn't 403.
_session = requests.Session()
_session.trust_env = False
_session.headers.update(headers)
_session.verify = False


def extract_speech(speech_id, session=None):
    """Extract all data from a speech content page."""
    sess = session or _session
    url = f"{BASE}/speech-content?id={speech_id}"
    try:
        r = sess.get(url, timeout=30)
    except Exception as e:
        return {"error": str(e), "speech_id": speech_id}

    if r.status_code != 200:
        return {"error": f"HTTP {r.status_code}", "speech_id": speech_id}

    text = r.text

    # Title
    title_match = re.search(r'<title>([^<]+)</title>', text)
    title = title_match.group(1).strip() if title_match else ""
    title = re.sub(r'\s*[-–|]\s*KHAMENEI\.IR.*$', '', title, flags=re.I).strip()
    title = re.sub(r'\s*[-–|]\s*پایگاه.*$', '', title).strip()

    # Date: prefer span.oliveDate (Jalali Persian digits)
    date = ""
    olive = re.search(
        r'<span[^>]*class="[^"]*oliveDate[^"]*"[^>]*>([^<]+)</span>',
        text, re.I,
    )
    if olive:
        m = re.search(r'(\d{4}/\d{2}/\d{2})', to_ascii_digits(olive.group(1)))
        if m:
            date = m.group(1)
    if not date:
        m = re.search(r'(\d{4}/\d{2}/\d{2})', to_ascii_digits(text))
        date = m.group(1) if m else ""
    year = date[:4] if date else ""

    # Main content
    content = ""
    content_div = re.search(r'<div[^>]*class="Content"[^>]*>(.*?)</div>', text, re.DOTALL)
    if content_div:
        content = re.sub(r'<[^>]+>', ' ', content_div.group(1))
        content = re.sub(r'\s+', ' ', content).strip()
    else:
        news_match = re.search(r'id="newsContentInnerSide"[^>]*>(.*?)</div>\s*</td>', text, re.DOTALL)
        if news_match:
            content = re.sub(r'<[^>]+>', ' ', news_match.group(1))
            content = re.sub(r'\s+', ' ', content).strip()

    # Clean date prefix (ASCII or Persian digits)
    if date and to_ascii_digits(content).startswith(date):
        content = content[len(date):].strip()

    # Audio
    audio_url = ""
    audio_match = re.search(r'(?:src|href)=["\']([^"\']*audio-content\?id=\d+[^"\']*)["\']', text)
    if audio_match:
        audio_url = f"{BASE}{audio_match.group(1)}" if audio_match.group(1).startswith('/') else audio_match.group(1)

    # Tags
    tags = list(set(re.findall(r'class="topmenu-tag"[^>]*title="([^"]+)"', text)))

    return {
        "speech_id": speech_id,
        "title": title,
        "date": date,
        "year": year,
        "content": content,
        "audio_url": audio_url,
        "tags": tags,
        "char_count": len(content),
        "url": url,
    }


def list_page_url(year=None):
    """One complete list page per year. The server ignores ?page=N entirely."""
    if year:
        return f"{BASE}/speech?nt=2&year={year}"
    return f"{BASE}/speech"


def parse_list_page(html):
    """Parse a year list page into [(speech_id, 'YYYY/MM/DD'), ...] in DOM order.

    Only main-list items (anchor + date span) are matched; sidebar widget
    anchors without a date span are excluded. Dates are normalized to ASCII
    digits. Deduplicated (first occurrence wins).
    """
    if not html:
        return []
    out = []
    seen = set()
    for m in LIST_ITEM_RE.finditer(html):
        sid = m.group(1)
        if sid in seen:
            continue
        seen.add(sid)
        out.append((sid, to_ascii_digits(m.group(2))))
    return out


def discover_year(year, session=None, retries=3, sleep=time.sleep):
    """Discover all speech IDs of ONE year (single list page, no pagination).

    Returns a de-duplicated list of ID strings, newest first.
    """
    sess = session or _session
    items = None
    for attempt in range(max(1, int(retries))):
        try:
            r = sess.get(list_page_url(year), timeout=30)
            if r.status_code == 200:
                items = parse_list_page(r.text)
                break
            items = []  # non-200 (e.g. 404) -> empty year, no point retrying
            break
        except Exception as e:
            if attempt + 1 < int(retries):
                wait = 2 * (attempt + 1)
                print(f"  Year {year}: fetch failed ({e}); retry in {wait}s")
                if sleep:
                    sleep(wait)
                continue
            print(f"  Year {year}: fetch failed after {retries} tries: {e}")
            return []
    ids = [sid for sid, _d in items]
    return sorted(set(ids), key=int, reverse=True)


def discover_all_years(session=None, start_year=None, end_year=None,
                       stop_after_empty=STOP_AFTER_EMPTY, sleep=time.sleep):
    """Auto-walk years backwards, discovering each year's list page.

    Starts at `start_year` (default: current Jalali year) and walks down to
    `end_year` (default WALK_END_YEAR), stopping early after
    `stop_after_empty` consecutive empty years.

    Returns {year: [ids...]} for years that yielded at least one NEW id
    (ids already seen in a later year are dropped).
    """
    sess = session or _session
    if start_year is None:
        start_year = time.gmtime().tm_year - 621  # rough Jalali current year
    if end_year is None:
        end_year = WALK_END_YEAR
    start_year = int(start_year)
    end_year = int(end_year)

    out = {}
    seen = set()
    empty_streak = 0
    y = start_year
    while y >= end_year:
        ids = discover_year(y, session=sess, sleep=sleep)
        new = [i for i in ids if i not in seen]
        if new:
            out[y] = new
            seen.update(new)
            empty_streak = 0
            print(f"  Year {y}: {len(new)} new IDs")
        else:
            empty_streak += 1
            print(f"  Year {y}: 0 IDs (empty streak {empty_streak}/{stop_after_empty})")
            if empty_streak >= stop_after_empty:
                print(f"  Stopping after {stop_after_empty} consecutive empty years")
                break
        y -= 1
    return out


def fetch_pending_ids(sess, backend_url="http://127.0.0.1:5055"):
    """Global pending queue from the backend (true resume for unfiltered runs)."""
    try:
        r = sess.get(f"{backend_url}/api/khamenei/pending?limit=5000", timeout=30)
        return [str(x) for x in (r.json().get('ids') or [])]
    except Exception:
        return []


def submit_to_backend(speech, backend_url="http://127.0.0.1:5055", session=None):
    """Submit extracted speech to the Flask backend."""
    sess = session or _session
    try:
        r = sess.post(f"{backend_url}/api/khamenei/submit", json=speech, timeout=30)
        return r.json()
    except Exception as e:
        return {"error": str(e)}


def scrape_all(years=None, start_from=None, max_per_run=200, delay=2,
               backend="http://127.0.0.1:5055", session=None, sleep=time.sleep):
    """
    Main scraping orchestrator.
    - years given: open each year's single list page (nt=2&year=Y) and crawl
      exactly those speeches (global pending queue is NOT consulted, so a
      targeted year run is never hijacked).
    - no years: resume the global pending queue if it is non-empty, otherwise
      auto-walk all years backwards and crawl everything.
    - Backend handles dedup via content_hash(content|date).
    """
    sess = session or _session

    if years:
        print(f"\n📅 Scanning years {years} (one list page per year)...")
        all_ids = []
        for year in years:
            ids = discover_year(year, session=sess, sleep=sleep)
            print(f"  Year {year}: {len(ids)} IDs")
            all_ids.extend(ids)
        all_ids = list(dict.fromkeys(all_ids))
    else:
        pending = fetch_pending_ids(sess, backend)
        if pending:
            print(f"\n⏩ Resuming {len(pending)} pending IDs from backend queue")
            all_ids = pending
        else:
            print(f"\n🔍 Auto year-walk discovery (no pending queue)...")
            year_map = discover_all_years(session=sess, sleep=sleep)
            all_ids = []
            for y in sorted(year_map, reverse=True):
                all_ids.extend(year_map[y])

    print(f"\n🎯 Total unique speech IDs: {len(all_ids)}")

    # Sort and limit
    all_ids = [str(i) for i in all_ids]
    all_ids.sort(key=int, reverse=True)
    if start_from:
        all_ids = [i for i in all_ids if int(i) <= int(start_from)]

    to_crawl = all_ids[:max_per_run]
    print(f"\n🚀 Scraping {len(to_crawl)} speeches (rate limit: {delay}s between requests)...")

    results = {"inserted": 0, "updated": 0, "skipped": 0, "errors": 0}

    for i, sid in enumerate(to_crawl):
        print(f"  [{i+1}/{len(to_crawl)}] Speech #{sid}...", end=" ", flush=True)

        speech = extract_speech(sid, session=sess)
        if "error" in speech:
            print(f"❌ {speech['error']}")
            results["errors"] += 1
            if sleep:
                sleep(delay * 2)  # Longer wait on error
            continue

        result = submit_to_backend(speech, backend, session=sess)
        status = result.get("status", "error")
        print(f"{status} - {speech['title'][:60]} ({speech['char_count']} chars)")

        if status in results:
            results[status] += 1

        if sleep:
            sleep(delay)

    print(f"\n✅ Done! Results: {json.dumps(results)}")
    return results


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Khamenei.ir Speech Scraper")
    parser.add_argument("--discover", action="store_true", help="Only discover IDs, don't scrape")
    parser.add_argument("--scrape", type=str, help="Scrape specific speech IDs (comma-separated)")
    parser.add_argument("--year", type=int, help="Target one year (e.g. 1400); one list page")
    parser.add_argument("--from-year", type=int, help="Start year for auto-walk discovery")
    parser.add_argument("--end-year", type=int, help="Floor year for auto-walk discovery")
    parser.add_argument("--max", type=int, default=200, help="Max speeches to scrape (default: 200)")
    parser.add_argument("--delay", type=float, default=2.0, help="Delay between requests in seconds")
    parser.add_argument("--backend", default="http://127.0.0.1:5055", help="Backend URL")
    args = parser.parse_args()

    if args.discover:
        if args.year:
            ids = discover_year(args.year)
            print(f"\nYear {args.year}: found {len(ids)} IDs")
            print(f"First 10: {ids[:10]}")
            print(f"Last 10: {ids[-10:]}")
        else:
            year_map = discover_all_years(
                start_year=args.from_year, end_year=args.end_year
            )
            total = sum(len(v) for v in year_map.values())
            print(f"\nAuto-walk: {len(year_map)} years, {total} total IDs")
            for y in sorted(year_map, reverse=True):
                print(f"  {y}: {len(year_map[y])}")
    elif args.scrape:
        ids = args.scrape.split(",")
        for sid in ids:
            speech = extract_speech(sid.strip())
            print(json.dumps(speech, ensure_ascii=False, indent=2))
            result = submit_to_backend(speech, args.backend)
            print(f"Submit: {result}")
            time.sleep(args.delay)
    else:
        # Full scrape (targeted years, or pending-queue resume / auto-walk)
        years = [args.year] if args.year else None
        scrape_all(years=years, max_per_run=args.max, delay=args.delay,
                   backend=args.backend)
