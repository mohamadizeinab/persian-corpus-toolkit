"""API tests for date normalization and one khamenei save."""
import sqlite3
import unittest

# PCM-12.3: shared isolated test DB (MUST precede `import server` so
# server.DB_PATH binds to the temp file, not the deployed thesaurus.db).
import pct_test_support  # noqa: F401
import server  # noqa: E402


class ApiTests(unittest.TestCase):
    def setUp(self):
        pct_test_support.reset_db()
        db = sqlite3.connect(server.DB_PATH)
        server.ensure_khamenei_schema(db)
        db.close()
        self.client = server.app.test_client()

    def test_jalali_digits(self):
        self.assertEqual(server.normalize_jalali_date("۱۴۰۴/۰۱/۱۵"), "1404/01/15")
        self.assertEqual(server.jalali_year("۱۴۰۴/۰۱/۱۵"), "1404")

    def test_khamenei_submit_stores_date(self):
        resp = self.client.post(
            "/api/khamenei/submit",
            json={
                "speech_id": "999001",
                "title": "تست",
                "date": "۱۴۰۴/۰۱/۱۵",
                "content": "متن آزمایشی بیان",
                "url": "https://farsi.khamenei.ir/speech-content?id=999001",
            },
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.get_json()
        self.assertEqual(body["status"], "inserted")
        self.assertEqual(body["date"], "1404/01/15")
        self.assertEqual(body["year"], "1404")

        stats = self.client.get("/api/khamenei/stats").get_json()
        self.assertEqual(stats["total"], 1)
        self.assertEqual(stats["with_date"], 1)
        self.assertEqual(stats["by_year"]["1404"], 1)

    def test_stats_ok(self):
        body = self.client.get("/api/stats").get_json()
        self.assertIn("crawled_total", body)
        self.assertEqual(body["crawled_total"], 0)

    def test_hamtaa_fields_and_capture(self):
        match = self.client.get("/api/sites/match?host=tasnim.hamtaa.org").get_json()
        tags = {f["tag"]: f for f in match["fields"]}
        self.assertEqual(tags["page"]["transform"], "add_one")
        self.assertEqual(tags["page"]["selector"], "item_index")
        self.assertEqual(tags["surah"]["transform"], "before_paren")
        url = "https://tasnim.hamtaa.org/payload?file_id=10&item_index=358"
        values = {
            "surah": "آلِ عِمْرَان",
            "ayah": "66",
            "volume": "10",
            "page": "359",
            "arabic": "هَا أَنْتُمْ",
            "url": url,
        }
        saved = self.client.post(
            "/api/captures", json={"host": "tasnim.hamtaa.org", "url": url, "values": values}
        ).get_json()
        self.assertEqual(saved["status"], "inserted")
        again = self.client.post(
            "/api/captures", json={"host": "tasnim.hamtaa.org", "url": url, "values": values}
        ).get_json()
        self.assertEqual(again["status"], "skipped")
        listed = self.client.get("/api/captures?host=tasnim.hamtaa.org").get_json()
        self.assertEqual(listed["items"][0]["values"]["page"], "359")
        self.assertEqual(listed["items"][0]["values"]["ayah"], "66")

    def test_project_points_then_page_marks_tested(self):
        created = self.client.post(
            "/api/projects",
            json={
                "name": "تفسیر تسنیم",
                "host": "tasnim.hamtaa.org",
                "start_url": "https://tasnim.hamtaa.org/payload?file_id=10&item_index=400",
                "next_mode": "url_param",
                "next_param": "item_index",
                "next_step": 1,
                "pages_per_minute": 4,
            },
        ).get_json()
        self.assertTrue(created["ok"])
        project = created["project"]
        self.assertEqual(project["status"], "draft")
        self.assertEqual(project["points"], [])
        pid = project["id"]

        saved = self.client.post(
            f"/api/projects/{pid}/points",
            json={
                "tag": "tafsir",
                "source": "css",
                "selector": "main article",
                "transform": "text",
                "sample": "متن تفسیر",
            },
        ).get_json()
        self.assertEqual(saved["project"]["points"][0]["tag"], "tafsir")

        renamed = self.client.post(
            f"/api/projects/{pid}/points",
            json={
                "previous_tag": "tafsir",
                "tag": "متن",
                "source": "css",
                "selector": ".book-tafsir",
                "transform": "text",
                "sample": "تفسیر آیه",
            },
        ).get_json()
        tags = [p["tag"] for p in renamed["project"]["points"]]
        self.assertEqual(tags, ["متن"])

        empty = self.client.post(
            f"/api/projects/{pid}/pages",
            json={"url": "https://tasnim.hamtaa.org/payload?file_id=10&item_index=400", "values": {"متن": ""}},
        )
        self.assertEqual(empty.status_code, 422)

        page = self.client.post(
            f"/api/projects/{pid}/pages",
            json={
                "url": "https://tasnim.hamtaa.org/payload?file_id=10&item_index=400",
                "values": {"متن": "این متن تفسیر است"},
            },
        ).get_json()
        self.assertEqual(page["status"], "inserted")
        self.assertEqual(page["project"]["status"], "tested")
        self.assertEqual(page["project"]["saved_count"], 1)
        self.assertIsNotNone(page["project"]["tested_at"])

        report = self.client.post(
            f"/api/projects/{pid}/report",
            json={"saved": 1, "status": "running", "message": "۱ صفحه ذخیره شد", "cursor_url": "https://tasnim.hamtaa.org/payload?file_id=10&item_index=401"},
        ).get_json()
        self.assertEqual(report["project"]["saved_count"], 2)
        self.assertEqual(report["project"]["status"], "running")
        self.assertIn("item_index=401", report["project"]["cursor_url"])

    def test_create_project_validation_errors(self):
        missing = self.client.post("/api/projects", json={"name": "تست"})
        self.assertEqual(missing.status_code, 400)
        bad_mode = self.client.post(
            "/api/projects",
            json={"name": "تست", "host": "example.org", "next_mode": "bogus"},
        )
        self.assertEqual(bad_mode.status_code, 400)
        ok = self.client.post(
            "/api/projects",
            json={"name": "تست", "host": "Example.ORG", "start_url": "https://example.org/p?item_index=5#frag"},
        ).get_json()
        self.assertTrue(ok["ok"])
        self.assertEqual(ok["project"]["host"], "example.org")
        # PCM-EXT-08: backend no longer strips the hash — in SPAهای hash-based (تفسیر نور)
        # hash بخشی از «هویت» صفحه است. حذف hash تصمیم کلاینت است (فقط در حالت‌های غیر-hash).
        self.assertEqual(ok["project"]["start_url"], "https://example.org/p?item_index=5#frag")
        self.assertEqual(ok["project"]["status"], "draft")

    def test_project_read_and_report_flow(self):
        created = self.client.post(
            "/api/projects",
            json={"name": "آزمایش", "host": "tasnim.hamtaa.org"},
        ).get_json()
        pid = created["project"]["id"]
        loaded = self.client.get(f"/api/projects/{pid}").get_json()
        self.assertEqual(loaded["name"], "آزمایش")
        self.assertEqual(loaded["points"], [])
        report = self.client.post(
            f"/api/projects/{pid}/report",
            json={"failed": 1, "message": "صفحه خالی بود", "status": "paused"},
        ).get_json()
        self.assertEqual(report["project"]["failed_count"], 1)
        self.assertEqual(report["project"]["status"], "paused")
        self.assertEqual(report["project"]["last_message"], "صفحه خالی بود")
        listed = self.client.get("/api/projects?host=tasnim.hamtaa.org").get_json()
        self.assertGreaterEqual(len(listed["projects"]), 1)
        missing = self.client.get("/api/projects/99999")
        self.assertEqual(missing.status_code, 404)

    def test_define_new_site_tag(self):
        saved = self.client.post(
            "/api/sites/fields",
            json={
                "host": "example.org",
                "name": "نمونه",
                "tag": "title",
                "source": "css",
                "selector": "h1",
                "transform": "text",
                "sample": "سلام",
            },
        ).get_json()
        self.assertTrue(saved["ok"])
        self.assertEqual(saved["fields"][0]["tag"], "title")


class PCM21Tests(unittest.TestCase):
    """PCM-21: dashboard counters with explicit sources.
    /api/stats.queue_by_site, /api/thesaurus/progress,
    /api/khamenei/crawl-status.pending_by_year, /api/reset-queue
    (the "continue" button), /api/corpus/list tasnim artifacts.
    Real DB counters only — no fabricated numbers."""

    def setUp(self):
        pct_test_support.reset_db()
        db = sqlite3.connect(server.DB_PATH)
        server.ensure_khamenei_schema(db)
        db.close()
        self.client = server.app.test_client()

    def _db(self):
        return sqlite3.connect(server.DB_PATH)

    # T1 — /api/stats gains per-site breakdown (source: crawl_queue.site)
    def test_stats_queue_by_site(self):
        body = self.client.get("/api/stats").get_json()
        self.assertEqual(body["queue_by_site"], {})
        db = self._db()
        db.execute(
            "INSERT INTO crawl_queue (url, site, page_type, status, source_page) "
            "VALUES ('https://farsi.khamenei.ir/speech-content?id=1', 'khamenei', "
            "'khamenei_speech', 'pending', "
            "'https://farsi.khamenei.ir/speech?nt=2&year=1400')"
        )
        db.execute(
            "INSERT INTO crawl_queue (url, site, page_type, status, science_id) "
            "VALUES ('https://thesaurus.eiis.iki.ac.ir/fa/term/1', 'thesaurus', "
            "'term', 'done', '040')"
        )
        db.commit()
        db.close()
        body = self.client.get("/api/stats").get_json()
        self.assertEqual(body["queue_by_site"]["khamenei"],
                         {"total": 1, "pending": 1, "done": 0})
        self.assertEqual(body["queue_by_site"]["thesaurus"],
                         {"total": 1, "pending": 0, "done": 1})

    # T2 — fresh progress endpoint: 13 sciences, zero counters, not complete
    def test_thesaurus_progress_fresh(self):
        body = self.client.get("/api/thesaurus/progress").get_json()
        self.assertEqual(len(body["sciences"]), 13)
        self.assertEqual(body["list_scan"]["scanned_pages"], 0)
        self.assertEqual(body["list_scan"]["expected_pages"], 0)
        self.assertFalse(body["list_scan"]["complete"])
        self.assertEqual(body["content"]["pending"], 0)
        self.assertEqual(body["content"]["items_saved"], 0)
        self.assertIn("اصطلاح‌نامه", body["content"]["by_main_type"])

    # T3 — seeded cursor/queue/content → real per-science progress
    def test_thesaurus_progress_seeded(self):
        db = self._db()
        db.execute(
            "INSERT INTO crawl_progress (key, value) VALUES (?, ?)",
            ("thesaurus:list:040",
             '{"key": "thesaurus:list:040", "scienceId": "040", '
             '"page": 1658, "totalPages": 1658}'),
        )
        db.execute(
            "INSERT INTO crawl_queue (url, site, page_type, status, science_id) "
            "VALUES ('https://thesaurus.eiis.iki.ac.ir/fa/term/2', 'thesaurus', "
            "'term', 'pending', '040')"
        )
        db.execute(
            "INSERT INTO crawled_data (url, item_type, title, content_hash, "
            "science_field) VALUES ("
            "'https://thesaurus.eiis.iki.ac.ir/fa/term/3', 'term', 'تست', 'h1', '040')"
        )
        db.commit()
        db.close()
        body = self.client.get("/api/thesaurus/progress").get_json()
        s040 = next(s for s in body["sciences"] if s["id"] == "040")
        self.assertEqual(s040["list_scan"],
                         {"page": 1658, "total_pages": 1658, "complete": True})
        self.assertEqual(s040["queue"], {"total": 1, "pending": 1, "done": 0})
        self.assertEqual(s040["content_items"], 1)
        self.assertEqual(body["list_scan"],
                         {"expected_pages": 1658, "scanned_pages": 1658,
                          "complete": True})
        self.assertEqual(body["content"]["pending"], 1)
        self.assertEqual(body["content"]["items_saved"], 1)
        self.assertEqual(body["content"]["by_main_type"]["اصطلاح‌نامه"], 1)

    # T3b — PCM-25 DC#2: per-science content_items must attribute by the REAL
    # science id (full_data.science_id). Production rows store the science
    # *title* in the science_field column, so grouping on that column made
    # every science show 0 saved items while items_saved was 146k+.
    def test_thesaurus_progress_content_items_by_real_id(self):
        import json as _json
        fd = _json.dumps({"url": "https://x/fa/term/99", "item_id": "99",
                          "item_type": "term", "title": "ت",
                          "science_id": "040",
                          "science_field": "معرفت‌شناسی"}, ensure_ascii=False)
        db = self._db()
        # production shape: science_field = title (must NOT win attribution)
        db.execute(
            "INSERT INTO crawled_data (url, item_id, item_type, title, "
            "full_data, content_hash, science_field) "
            "VALUES ('https://thesaurus.eiis.iki.ac.ir/fa/term/99', '99', "
            "'term', 'ت', ?, 'hA', 'معرفت‌شناسی')", (fd,))
        # legacy shape: no id in full_data, science_field holds the id
        db.execute(
            "INSERT INTO crawled_data (url, item_id, item_type, title, "
            "full_data, content_hash, science_field) "
            "VALUES ('https://thesaurus.eiis.iki.ac.ir/fa/term/98', '98', "
            "'term', 'ت', NULL, 'hB', '050')")
        db.commit()
        db.close()
        body = self.client.get("/api/thesaurus/progress").get_json()
        by_id = {s["id"]: s for s in body["sciences"]}
        self.assertEqual(by_id["040"]["content_items"], 1)
        self.assertEqual(by_id["050"]["content_items"], 1)
        self.assertEqual(body["content"]["items_saved"], 2)
        self.assertEqual(sum(s["content_items"] for s in body["sciences"]), 2)

    # T3c — PCM-25 DC#2: the harvest default covers ALL 13 sciences.
    # Before the fix the hard-coded list stopped at 120, so کلام (140) and
    # 150/170/180 were never list-scanned by the server and the
    # «اسکن / ادامه اسکن» button could never finish them.
    def test_harvest_default_science_ids_all_thirteen(self):
        import os as _os
        with open(
            _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                          "server.py"), encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn(
            "data.get('science_ids') or list(THESAURUS_SCIENCE_IDS)", src)
        self.assertNotIn("'040', '050', '060', '070', '080', '090', '100', '110', '120'",
                         src)

    # T4 — pending past years (source: crawl_queue.source_page year=YYYY)
    def test_khamenei_crawl_status_pending_by_year(self):
        db = self._db()
        for i, year in enumerate(("1398", "1398", "1400")):
            db.execute(
                "INSERT INTO crawl_queue (url, site, page_type, status, source_page) "
                "VALUES (?, 'khamenei', 'khamenei_speech', 'pending', ?)",
                ("https://farsi.khamenei.ir/speech-content?id=%d" % (9000 + i),
                 "https://farsi.khamenei.ir/speech?nt=2&year=%s" % year),
            )
        db.commit()
        db.close()
        body = self.client.get("/api/khamenei/crawl-status").get_json()
        self.assertEqual(body["pending"], 3)
        self.assertEqual(body["pending_by_year"], {"1398": 2, "1400": 1})

    # T5 — the "continue" button target: crawling rows go back to pending
    def test_reset_queue_moves_crawling_to_pending(self):
        db = self._db()
        db.execute(
            "INSERT INTO crawl_queue (url, site, page_type, status) "
            "VALUES ('https://thesaurus.eiis.iki.ac.ir/fa/term/9', 'thesaurus', "
            "'term', 'crawling')"
        )
        db.commit()
        db.close()
        resp = self.client.post("/api/reset-queue")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json()["status"], "ok")
        db = self._db()
        st = db.execute(
            "SELECT status FROM crawl_queue WHERE url LIKE '%/term/9'"
        ).fetchone()[0]
        db.close()
        self.assertEqual(st, "pending")

    # T6 — /api/corpus/list exposes versioned tasnim artifacts (temp dir)
    def test_corpus_list_tasnim_artifacts(self):
        import os
        import shutil
        import tempfile
        tmp = tempfile.mkdtemp(prefix="pct_tasnim_")
        try:
            root = os.path.join(tmp, "root1")
            v = os.path.join(root, "corpus", "builds", "v0001")
            os.makedirs(v)
            with open(os.path.join(v, "corpus.json"), "w", encoding="utf-8") as fh:
                fh.write('{"x": 1}')
            with open(os.path.join(v, "pages.jsonl"), "w", encoding="utf-8") as fh:
                fh.write('{"a": 1}\n{"a": 2}\n{"a": 3}\n')
            dv = os.path.join(root, "datasets", "100pct", "v0001")
            os.makedirs(dv)
            with open(os.path.join(dv, "dataset.json"), "w", encoding="utf-8") as fh:
                fh.write('{"d": 1}')
            old = server._TASNIM_DATA_DIRS
            server._TASNIM_DATA_DIRS = (tmp,)
            try:
                body = self.client.get("/api/corpus/list").get_json()
            finally:
                server._TASNIM_DATA_DIRS = old
            mine = [f for f in body["files"] if f.get("root") == "root1"]
            self.assertEqual(len(mine), 2)
            corpus_item = next(f for f in mine if f["kind"] == "corpus")
            self.assertEqual(corpus_item["name"], "tasnim/root1 — corpus v0001")
            self.assertEqual(corpus_item["version"], "v0001")
            self.assertEqual(corpus_item["entries"], 3)
            ds_item = next(f for f in mine if f["kind"] == "dataset")
            self.assertEqual(ds_item["version"], "100pct v0001")
            self.assertEqual(ds_item["entries"], 0)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # T7 — missing tasnim dir → no tasnim rows, never an error
    def test_corpus_list_no_tasnim_dir(self):
        import os
        import tempfile
        old = server._TASNIM_DATA_DIRS
        server._TASNIM_DATA_DIRS = (
            os.path.join(tempfile.gettempdir(), "pct_missing_tasnim_dir"),
        )
        try:
            body = self.client.get("/api/corpus/list").get_json()
        finally:
            server._TASNIM_DATA_DIRS = old
        self.assertEqual([f for f in body["files"] if f.get("root")], [])


if __name__ == "__main__":
    unittest.main()
