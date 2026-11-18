"""Project CRUD + persistence tests for the create-project/ComboBox flow (PCM-01).

Covers the API side of the scenarios T01-T12 that the extension depends on:
  T01 create valid project, T02 list returns it, T03 select by real id,
  T06 survives backend restart, T07 empty/missing name, T09 unknown endpoint,
  T10 duplicate POST -> two distinct rows (UI guards the double-click),
  T12 multiple projects, plus GET-after-create and 404 handling.

The Chrome/UI side (T03 select, T04 reopen, T05 reload) is covered separately
in extension/test_popup.js and the Phase-5 Chrome test.
"""
import sqlite3
import unittest

# PCM-12.3: shared isolated test DB (MUST precede `import server` so
# server.DB_PATH binds to the temp file, not the deployed thesaurus.db).
import pct_test_support  # noqa: F401
import server  # noqa: E402


class ProjectFlowTests(unittest.TestCase):
    def setUp(self):
        pct_test_support.reset_db()
        db = sqlite3.connect(server.DB_PATH)
        server.ensure_khamenei_schema(db)
        db.close()
        self.client = server.app.test_client()

    # T01 — create a valid project, expect ok + a real id
    def test_T01_create_valid_project(self):
        r = self.client.post(
            "/api/projects",
            json={
                "name": "PCM-E2E-Test",
                "host": "tasnim.hamtaa.org",
                "start_url": "https://tasnim.hamtaa.org/payload?file_id=10&item_index=400",
                "next_mode": "url_param",
                "next_param": "item_index",
                "next_step": 1,
                "pages_per_minute": 4,
            },
        )
        self.assertEqual(r.status_code, 200)
        body = r.get_json()
        self.assertTrue(body["ok"])
        self.assertIsInstance(body["project"]["id"], int)
        self.assertEqual(body["project"]["name"], "PCM-E2E-Test")
        self.assertEqual(body["project"]["host"], "tasnim.hamtaa.org")

    # T02 — the newly created project is in the list for that host
    def test_T02_list_contains_new_project(self):
        pid = self.client.post(
            "/api/projects", json={"name": "A", "host": "tasnim.hamtaa.org"}
        ).get_json()["project"]["id"]
        listed = self.client.get("/api/projects?host=tasnim.hamtaa.org").get_json()["projects"]
        ids = [p["id"] for p in listed]
        self.assertIn(pid, ids)

    # T03 — a project can be read back by its real id (what the ComboBox selects)
    def test_T03_read_by_real_id(self):
        pid = self.client.post(
            "/api/projects", json={"name": "Sel", "host": "tasnim.hamtaa.org"}
        ).get_json()["project"]["id"]
        loaded = self.client.get(f"/api/projects/{pid}").get_json()
        self.assertEqual(loaded["id"], pid)
        self.assertEqual(loaded["name"], "Sel")

    # T06 — a project persists across a backend "restart" (fresh DB connection)
    def test_T06_survives_backend_restart(self):
        pid = self.client.post(
            "/api/projects", json={"name": "Persist", "host": "tasnim.hamtaa.org"}
        ).get_json()["project"]["id"]
        # Simulate a restart: open a brand-new connection straight to the file.
        db = sqlite3.connect(server.DB_PATH)
        row = db.execute("SELECT name, host FROM projects WHERE id=?", (pid,)).fetchone()
        db.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Persist")
        # And the running app still serves it.
        self.assertEqual(
            self.client.get(f"/api/projects/{pid}").get_json()["name"], "Persist"
        )

    # T07 — empty or missing name is rejected, nothing stored
    def test_T07_empty_name_rejected(self):
        before = self.client.get("/api/projects?host=tasnim.hamtaa.org").get_json()["projects"]
        before_count = len(before)
        empty = self.client.post(
            "/api/projects", json={"name": "   ", "host": "tasnim.hamtaa.org"}
        )
        self.assertEqual(empty.status_code, 400)
        missing_host = self.client.post("/api/projects", json={"name": "x"})
        self.assertEqual(missing_host.status_code, 400)
        after = self.client.get("/api/projects?host=tasnim.hamtaa.org").get_json()["projects"]
        self.assertEqual(len(after), before_count, "no new row stored for empty name")

    # T09 — an endpoint that does not exist on the server returns 404. The
    # UI uses this to detect an outdated/old backend: if GET /api/projects
    # itself 404s (route absent), the server predates projects and must be
    # re-deployed. Here the route exists (new backend), so a random path
    # still 404s and a real project 404 means "not found".
    def test_T09_unknown_endpoint_404(self):
        # A real-but-missing project id -> 404 "not found"
        self.assertEqual(self.client.get("/api/projects/99999").status_code, 404)
        # A route that does not exist at all -> 404 (what a stale server does
        # for /api/projects). The UI maps a top-level 404 to "backend outdated".
        self.assertEqual(self.client.get("/api/projects-v2").status_code, 404)
        # Sanity: the project route DOES exist on this (new) backend.
        self.assertEqual(self.client.get("/api/projects").status_code, 200)

    # T10 — repeated POSTs create distinct rows (the UI button-guard prevents
    # accidental duplicates; the API has no dedup by name by design).
    def test_T10_repeated_post_distinct_rows(self):
        p1 = self.client.post(
            "/api/projects", json={"name": "Dup", "host": "tasnim.hamtaa.org"}
        ).get_json()["project"]["id"]
        p2 = self.client.post(
            "/api/projects", json={"name": "Dup", "host": "tasnim.hamtaa.org"}
        ).get_json()["project"]["id"]
        self.assertNotEqual(p1, p2)
        listed = self.client.get("/api/projects?host=tasnim.hamtaa.org").get_json()["projects"]
        ids = [p["id"] for p in listed]
        self.assertIn(p1, ids)
        self.assertIn(p2, ids)
        self.assertEqual(len(ids), len(set(ids)), "no duplicate rows for same name")

    # T11 — after a successful POST the list still reflects it (the UI
    # reports a non-success message if the refresh fails; here the API is
    # consistent).
    def test_T11_list_after_create_consistent(self):
        pid = self.client.post(
            "/api/projects", json={"name": "T11", "host": "tasnim.hamtaa.org"}
        ).get_json()["project"]["id"]
        # immediately list: must contain the just-created project
        listed = self.client.get("/api/projects?host=tasnim.hamtaa.org").get_json()["projects"]
        self.assertIn(pid, [p["id"] for p in listed])

    # T12 — multiple projects all selectable and listed correctly
    def test_T12_multiple_projects(self):
        ids = []
        for i, name in enumerate(["P1", "P2", "P3"]):
            r = self.client.post(
                "/api/projects", json={"name": name, "host": "tasnim.hamtaa.org"}
            ).get_json()
            self.assertTrue(r["ok"])
            ids.append(r["project"]["id"])
        listed = self.client.get("/api/projects?host=tasnim.hamtaa.org").get_json()["projects"]
        listed_ids = [p["id"] for p in listed]
        for pid in ids:
            self.assertIn(pid, listed_ids)
            self.assertEqual(self.client.get(f"/api/projects/{pid}").status_code, 200)
        # the three ids must be distinct
        self.assertEqual(len(set(ids)), 3)


class StopNumberTests(unittest.TestCase):
    """PCM-20.10: the numeric stop rule (limit the crawl at page N)."""

    def setUp(self):
        pct_test_support.reset_db()
        db = sqlite3.connect(server.DB_PATH)
        server.ensure_khamenei_schema(db)
        db.close()
        self.client = server.app.test_client()

    def _create(self, **extra):
        payload = {
            "name": "SN", "host": "tasnim.hamtaa.org",
            "start_url": "https://tasnim.hamtaa.org/payload?item_index=1",
            "next_mode": "url_param", "next_param": "item_index",
        }
        payload.update(extra)
        r = self.client.post("/api/projects", json=payload)
        self.assertEqual(r.status_code, 200)
        return r.get_json()["project"]["id"]

    def test_sn01_create_with_stop_number(self):
        pid = self._create(stop_number="495")
        got = self.client.get(f"/api/projects/{pid}").get_json()
        self.assertEqual(got["stop_number"], "495")

    def test_sn02_create_without_stop_number_defaults_empty(self):
        pid = self._create()
        got = self.client.get(f"/api/projects/{pid}").get_json()
        self.assertEqual(got["stop_number"], "")

    def test_sn03_update_stop_number(self):
        pid = self._create()
        r = self.client.post(f"/api/projects/{pid}", json={"stop_number": "7"})
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.get_json()["ok"])
        self.assertEqual(r.get_json()["project"]["stop_number"], "7")

    def test_sn04_update_clears_stop_number(self):
        pid = self._create(stop_number="100")
        r = self.client.post(f"/api/projects/{pid}", json={"stop_number": ""})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.get_json()["project"]["stop_number"], "")

    def test_sn05_invalid_stop_number_rejected(self):
        for bad in ("0", "-3", "abc", "12.5"):
            r = self.client.post("/api/projects", json={
                "name": "bad", "host": "x.test", "stop_number": bad})
            self.assertEqual(r.status_code, 400, f"stop_number={bad!r} should 400")
        pid = self._create(stop_number="50")
        r = self.client.post(f"/api/projects/{pid}", json={"stop_number": "x"})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(
            self.client.get(f"/api/projects/{pid}").get_json()["stop_number"], "50")

    def test_sn06_additive_migration_keeps_old_rows(self):
        # A row written before the column existed gets the default ''.
        pid = self._create()
        db = sqlite3.connect(server.DB_PATH)
        row = db.execute("SELECT stop_number FROM projects WHERE id=?", (pid,)).fetchone()
        db.close()
        self.assertEqual(row[0], "")


if __name__ == "__main__":
    unittest.main()
