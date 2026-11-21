"""
Tests for corpus/scrape_khamenei.py — year-based discovery (no network).

Site facts (verified live against farsi.khamenei.ir, 2026-11-21):
- The server IGNORES ?page=N (page=1 and page=2 return byte-identical HTML).
- Each Jalali year is ONE complete list page: /speech?nt=2&year=YYYY
  (28-79 items, dates spanning the full year; 1379..1404 verified).
- Unfiltered /speech shows only the latest year.
- Main-list items carry <span class="ltr skyText">YYYY/MM/DD</span>;
  sidebar widget anchors ("پیشنهاد ما", li.hpList) have NO date span.

Run:  .venv\\Scripts\\python.exe -m unittest corpus.test_scrape_khamenei -v
"""
import json as json_mod
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from scrape_khamenei import (
    BASE,
    list_page_url,
    parse_list_page,
    discover_year,
    discover_all_years,
    scrape_all,
)

LIST_ITEM = (
    '<a href="speech-content?id={sid}" title="{title}">'
    '<span class="ltr skyText">{date}</span> - {title}</a>'
)
SIDEBAR = '<li class="hpList"><a href="speech-content?id={sid}">{title}</a></li>'

CONTENT_PAGE = """<html><head><title>{title} - KHAMENEI.IR</title></head><body>
<span class="oliveDate">{date}</span>
<div class="Content">{text}</div>
</body></html>"""


class FakeResponse:
    def __init__(self, text="", status_code=200):
        self.text = text
        self.status_code = status_code

    def json(self):
        return json_mod.loads(self.text) if self.text else {}


class FakeSession:
    """Network-free requests.Session stand-in.

    pages:      url -> html  (GET, default "")
    json_pages: url -> dict  (GET/POST answered as JSON)
    fail_times: first N GETs raise RuntimeError
    """

    def __init__(self, pages=None, json_pages=None, fail_times=0):
        self.pages = dict(pages or {})
        self.json_pages = dict(json_pages or {})
        self.fail_times = fail_times
        self.calls = []

    def get(self, url, timeout=None):
        self.calls.append(("GET", url))
        if self.fail_times > 0:
            self.fail_times -= 1
            raise RuntimeError("boom")
        if url in self.json_pages:
            return FakeResponse(json_mod.dumps(self.json_pages[url]), 200)
        return FakeResponse(self.pages.get(url, ""), 200)

    def post(self, url, json=None, timeout=None):
        self.calls.append(("POST", url, json))
        return FakeResponse(
            json_mod.dumps(self.json_pages.get(url, {"status": "inserted"})), 200
        )

    def urls(self, method):
        return [c[1] for c in self.calls if c[0] == method]

    def posts(self):
        return [c for c in self.calls if c[0] == "POST"]


def list_html(items, sidebar=()):
    """Build a list page: main-list items (dated) + sidebar anchors (undated)."""
    body = "".join(LIST_ITEM.format(**it) for it in items)
    body += "".join(SIDEBAR.format(**it) for it in sidebar)
    return f"<html><body>{body}</body></html>"


def year_url(year):
    return f"{BASE}/speech?nt=2&year={year}"


class TestListPageUrl(unittest.TestCase):
    def test_year_url(self):
        self.assertEqual(list_page_url(1400), f"{BASE}/speech?nt=2&year=1400")

    def test_no_year_url(self):
        self.assertEqual(list_page_url(None), f"{BASE}/speech")


class TestParseListPage(unittest.TestCase):
    def test_dated_items_only(self):
        html = list_html(
            items=[
                dict(sid="49769", date="1400/12/19", title="A"),
                dict(sid="49700", date="۱۴۰۰/۰۱/۰۱", title="B"),
            ],
            sidebar=[dict(sid="62581", title="Sidebar suggestion")],
        )
        self.assertEqual(
            parse_list_page(html),
            [("49769", "1400/12/19"), ("49700", "1400/01/01")],
        )

    def test_empty(self):
        self.assertEqual(parse_list_page(""), [])
        self.assertEqual(parse_list_page(None), [])


class TestDiscoverYear(unittest.TestCase):
    def test_single_request_no_page_param(self):
        sess = FakeSession(
            pages={
                year_url(1400): list_html(
                    [
                        dict(sid="1002", date="1400/06/06", title="B"),
                        dict(sid="1001", date="1400/01/01", title="A"),
                    ]
                )
            }
        )
        ids = discover_year(1400, session=sess, sleep=0)
        self.assertEqual(ids, ["1002", "1001"])  # deduped, descending
        self.assertEqual(len(sess.calls), 1)
        self.assertEqual(sess.calls[0], ("GET", year_url(1400)))
        self.assertNotIn("page=", sess.calls[0][1])

    def test_retry_on_error(self):
        sess = FakeSession(
            pages={
                year_url(1401): list_html(
                    [dict(sid="2001", date="1401/03/03", title="X")]
                )
            },
            fail_times=1,
        )
        ids = discover_year(1401, session=sess, sleep=0)
        self.assertEqual(ids, ["2001"])
        self.assertEqual(len(sess.calls), 2)

    def test_all_fail_returns_empty(self):
        sess = FakeSession(fail_times=10)
        self.assertEqual(discover_year(1402, session=sess, retries=2, sleep=0), [])
        self.assertEqual(len(sess.calls), 2)


class TestDiscoverAllYears(unittest.TestCase):
    @staticmethod
    def _pages(year_sids):
        pages = {}
        for y, sids in year_sids.items():
            pages[year_url(y)] = list_html(
                [dict(sid=str(s), date=f"{y}/01/01", title=f"S{s}") for s in sids]
            )
        return pages

    def test_stops_after_two_consecutive_empty(self):
        sess = FakeSession(
            self._pages({1405: [], 1404: [100], 1403: [200], 1402: [], 1401: []})
        )
        out = discover_all_years(
            session=sess, start_year=1405, end_year=1399
        )
        self.assertEqual(set(out), {1404, 1403})
        self.assertEqual(out[1404], ["100"])
        self.assertEqual(out[1403], ["200"])
        # 1405,1404,1403,1402,1401 requested, then stopped — never 1400
        self.assertEqual(len(sess.urls("GET")), 5)
        self.assertNotIn(year_url(1400), sess.urls("GET"))

    def test_single_empty_does_not_stop(self):
        sess = FakeSession(
            self._pages({1405: [], 1404: [100], 1403: [], 1402: [200]})
        )
        out = discover_all_years(
            session=sess, start_year=1405, end_year=1402
        )
        self.assertEqual(set(out), {1404, 1402})
        self.assertEqual(len(sess.urls("GET")), 4)

    def test_end_year_floor(self):
        sess = FakeSession(self._pages({1404: [100], 1403: [200]}))
        out = discover_all_years(
            session=sess, start_year=1404, end_year=1403
        )
        self.assertEqual(set(out), {1404, 1403})
        # stops at end_year even with no empty years in a row
        self.assertEqual(len(sess.urls("GET")), 2)

    def test_cross_year_dedup(self):
        sess = FakeSession(self._pages({1405: [100, 101], 1404: [101, 102]}))
        out = discover_all_years(
            session=sess, start_year=1405, end_year=1404
        )
        self.assertEqual(out[1405], ["101", "100"])  # descending within year
        self.assertEqual(out[1404], ["102"])        # 101 already seen
        self.assertEqual(len(sess.urls("GET")), 2)


class TestScrapeAll(unittest.TestCase):
    BACKEND = "http://127.0.0.1:5055"
    PENDING_URL = f"{BACKEND}/api/khamenei/pending?limit=5000"

    def _content(self, sid, date="1400/05/10", text="Full speech text"):
        return CONTENT_PAGE.format(
            sid=sid, date=date, title=f"Speech {sid}", text=text
        )

    def test_targeted_year_not_hijacked_by_pending(self):
        sess = FakeSession(
            pages={
                year_url(1400): list_html(
                    [
                        dict(sid="1001", date="1400/05/09", title="A"),
                        dict(sid="1002", date="1400/05/10", title="B"),
                    ]
                ),
                f"{BASE}/speech-content?id=1001": self._content("1001"),
                f"{BASE}/speech-content?id=1002": self._content("1002"),
            },
            json_pages={self.PENDING_URL: {"ids": ["9001", "9002"]}},
        )
        results = scrape_all(
            years=[1400], max_per_run=50, delay=0,
            backend=self.BACKEND, session=sess,
        )
        submitted = [p[2]["speech_id"] for p in sess.posts()]
        self.assertEqual(sorted(submitted), ["1001", "1002"])
        self.assertNotIn("9001", submitted)
        self.assertNotIn("9002", submitted)
        # a targeted year run must not even consult the global pending queue
        self.assertNotIn(self.PENDING_URL, sess.urls("GET"))
        self.assertEqual(results["inserted"], 2)

    def test_unfiltered_run_uses_pending_queue(self):
        sess = FakeSession(
            pages={
                f"{BASE}/speech": list_html(
                    [dict(sid="1001", date="1404/01/01", title="A")]
                ),
                f"{BASE}/speech-content?id=9001": self._content(
                    "9001", "1404/02/02"
                ),
            },
            json_pages={self.PENDING_URL: {"ids": ["9001"]}},
        )
        results = scrape_all(
            years=None, max_per_run=50, delay=0,
            backend=self.BACKEND, session=sess,
        )
        submitted = [p[2]["speech_id"] for p in sess.posts()]
        self.assertEqual(submitted, ["9001"])
        self.assertEqual(results["inserted"], 1)


if __name__ == "__main__":
    unittest.main()
