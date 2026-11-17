"""PCM-EXT-03: cross-browser single-run lock (claim / heartbeat / release + TTL).

The extension's local single-run guard (pctRun in chrome.storage.local) only
works inside one browser. Two browsers = two independent extension instances;
the only shared truth is the backend, so the "one run per project" guarantee
must live there as a lease:

* claim:      POST /api/projects/<id>/run          (atomic conditional UPDATE)
* heartbeat:  POST /api/projects/<id>/run/heartbeat
* release:    POST /api/projects/<id>/run/release

A lock without a fresh heartbeat (older than RUN_LOCK_TTL) is expired, so a
dead/closed browser cannot hold a project forever (self-healing).

RL-01 claim an unlocked project -> 200, status running, owner/token stored
RL-02 claim by a 2nd owner while the lock is live -> 409, lock unchanged
RL-03 re-claim by the SAME owner (new token) -> 200 (SW restart / retry)
RL-04 owner heartbeat refreshes the timestamp -> 200
RL-05 heartbeat from a non-owner -> 409, lock untouched
RL-06 release by the owner -> lock cleared, status paused
RL-07 release by a non-owner with a live lock -> 409, lock untouched
RL-08 expired lock (heartbeat backdated) -> another owner can claim
RL-09 expired lock -> release by anyone clears it (self-heal)
RL-10 claim on a missing project -> 404
RL-11 GET project exposes run_owner/run_token/run_heartbeat
RL-12 page save does not disturb the lock
RL-13 claim requires owner and token -> 400
RL-14 legacy DB (old projects table) is migrated in place, data preserved
"""
import os
import sqlite3
import tempfile
import time
import unittest

# PCM-12.3: shared isolated test DB (MUST precede `import server` so
# server.DB_PATH binds to the temp file, not the deployed thesaurus.db).
import pct_test_support  # noqa: F401
import server  # noqa: E402
import projects as projects_mod  # noqa: E402
from projects import RUN_LOCK_TTL  # noqa: E402


def make_project(client, name="RL", host="tasnim.hamtaa.org"):
    return client.post(
        "/api/projects", json={"name": name, "host": host}
    ).get_json()["project"]["id"]


def backdate_lock(pid, age):
    """Move the stored heartbeat into the past (simulates a dead browser)."""
    db = sqlite3.connect(server.DB_PATH)
    db.execute("UPDATE projects SET run_heartbeat=? WHERE id=?", (time.time() - age, pid))
    db.commit()
    db.close()


class RunLockTests(unittest.TestCase):
    def setUp(self):
        pct_test_support.reset_db()
        db = sqlite3.connect(server.DB_PATH)
        server.ensure_khamenei_schema(db)
        db.close()
        self.client = server.app.test_client()
        self.pid = make_project(self.client)

    # RL-01
    def test_RL01_claim_unlocked(self):
        r = self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        self.assertEqual(r.status_code, 200)
        body = r.get_json()
        self.assertTrue(body["ok"])
        self.assertTrue(body["claimed"])
        p = body["project"]
        self.assertEqual(p["status"], "running")
        self.assertEqual(p["run_owner"], "bA")
        self.assertEqual(p["run_token"], "r1")
        self.assertGreater(p["run_heartbeat"], 0)

    # RL-02
    def test_RL02_second_owner_409(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        r = self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bB", "token": "r2"})
        self.assertEqual(r.status_code, 409)
        body = r.get_json()
        self.assertFalse(body["ok"])
        self.assertEqual(body["locked_by"]["owner"], "bA")
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_owner"], "bA")
        self.assertEqual(p["run_token"], "r1")

    # RL-03
    def test_RL03_same_owner_reclaim(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        r = self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r2"})
        self.assertEqual(r.status_code, 200)
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_owner"], "bA")
        self.assertEqual(p["run_token"], "r2")

    # RL-04
    def test_RL04_owner_heartbeat(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        p0 = self.client.get(f"/api/projects/{self.pid}").get_json()
        r = self.client.post(
            f"/api/projects/{self.pid}/run/heartbeat", json={"owner": "bA", "token": "r1"}
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.get_json()["ok"])
        self.assertGreater(r.get_json()["heartbeat"], p0["run_heartbeat"])
        p1 = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p1["run_heartbeat"], r.get_json()["heartbeat"])

    # RL-05
    def test_RL05_nonowner_heartbeat_409(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        p0 = self.client.get(f"/api/projects/{self.pid}").get_json()
        r = self.client.post(
            f"/api/projects/{self.pid}/run/heartbeat", json={"owner": "bB", "token": "rx"}
        )
        self.assertEqual(r.status_code, 409)
        p1 = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p1["run_owner"], "bA")
        self.assertEqual(p1["run_token"], "r1")
        self.assertEqual(p1["run_heartbeat"], p0["run_heartbeat"], "non-owner heartbeat must not touch the lock")

    # RL-06
    def test_RL06_owner_release(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        r = self.client.post(
            f"/api/projects/{self.pid}/run/release", json={"owner": "bA", "token": "r1"}
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.get_json()["released"])
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_owner"], "")
        self.assertEqual(p["run_token"], "")
        self.assertEqual(p["run_heartbeat"], 0)
        self.assertEqual(p["status"], "paused")

    # RL-07
    def test_RL07_nonowner_release_409(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        r = self.client.post(
            f"/api/projects/{self.pid}/run/release", json={"owner": "bB", "token": "rx"}
        )
        self.assertEqual(r.status_code, 409)
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_owner"], "bA")
        self.assertEqual(p["run_token"], "r1")
        self.assertEqual(p["status"], "running")

    # RL-08
    def test_RL08_expired_lock_claimable(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        backdate_lock(self.pid, RUN_LOCK_TTL + 10)
        r = self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bB", "token": "r2"})
        self.assertEqual(r.status_code, 200)
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_owner"], "bB")
        self.assertEqual(p["run_token"], "r2")

    # RL-09
    def test_RL09_expired_lock_releasable(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        backdate_lock(self.pid, RUN_LOCK_TTL + 10)
        r = self.client.post(
            f"/api/projects/{self.pid}/run/release", json={"owner": "bB", "token": "rx"}
        )
        self.assertEqual(r.status_code, 200)
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_token"], "")
        self.assertEqual(p["status"], "paused")

    # RL-10
    def test_RL10_claim_missing_project_404(self):
        r = self.client.post("/api/projects/99999/run", json={"owner": "bA", "token": "r1"})
        self.assertEqual(r.status_code, 404)

    # RL-11
    def test_RL11_get_exposes_lock_fields(self):
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        for field in ("run_owner", "run_token", "run_heartbeat"):
            self.assertIn(field, p)
        self.assertEqual(p["run_owner"], "")
        self.assertEqual(p["run_token"], "")
        self.assertEqual(p["run_heartbeat"], 0)

    # RL-12
    def test_RL12_page_save_keeps_lock(self):
        self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": "r1"})
        r = self.client.post(
            f"/api/projects/{self.pid}/pages",
            json={
                "url": "https://tasnim.hamtaa.org/payload?file_id=10&item_index=400",
                "values": {"t": "متن نمونه"},
            },
        )
        self.assertEqual(r.status_code, 200)
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_owner"], "bA")
        self.assertEqual(p["run_token"], "r1")
        self.assertEqual(p["status"], "running")

    # RL-13
    def test_RL13_claim_requires_owner_token(self):
        r = self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "", "token": "r1"})
        self.assertEqual(r.status_code, 400)
        r = self.client.post(f"/api/projects/{self.pid}/run", json={"owner": "bA", "token": ""})
        self.assertEqual(r.status_code, 400)
        p = self.client.get(f"/api/projects/{self.pid}").get_json()
        self.assertEqual(p["run_token"], "", "rejected claims must not take the lock")

    # RL-14 — the production DB has the OLD projects table; the migration
    # must add the three columns in place and preserve existing rows.
    def test_RL14_legacy_schema_migration(self):
        fd, legacy = tempfile.mkstemp(prefix="pct_rlock_", suffix=".db")
        os.close(fd)
        try:
            db = sqlite3.connect(legacy)
            db.executescript(
                """CREATE TABLE projects (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    name              TEXT NOT NULL,
                    host              TEXT NOT NULL,
                    start_url         TEXT DEFAULT '',
                    next_mode         TEXT DEFAULT 'url_param',
                    next_param        TEXT DEFAULT '',
                    next_step         INTEGER DEFAULT 1,
                    pages_per_minute  INTEGER DEFAULT 4,
                    cursor_url        TEXT DEFAULT '',
                    status            TEXT DEFAULT 'draft',
                    saved_count       INTEGER DEFAULT 0,
                    skipped_count     INTEGER DEFAULT 0,
                    failed_count      INTEGER DEFAULT 0,
                    last_message      TEXT DEFAULT '',
                    tested_at         TEXT,
                    created_at        TEXT,
                    updated_at        TEXT DEFAULT (datetime('now'))
                );
                INSERT INTO projects (name, host, status) VALUES ('Legacy', 'x.org', 'running');"""
            )
            db.commit()
            projects_mod.ensure_projects_schema(db)
            cols = {r[1] for r in db.execute("PRAGMA table_info(projects)").fetchall()}
            self.assertTrue({"run_owner", "run_token", "run_heartbeat"} <= cols)
            row = db.execute(
                "SELECT name, status, run_owner, run_token, run_heartbeat FROM projects"
            ).fetchone()
            self.assertEqual(row[0], "Legacy")
            self.assertEqual(row[1], "running")
            self.assertEqual(row[2], "")
            self.assertEqual(row[3], "")
            self.assertEqual(row[4], 0)
            # idempotent: running the migration again changes nothing
            before = db.execute("SELECT * FROM projects").fetchall()
            projects_mod.ensure_projects_schema(db)
            after = db.execute("SELECT * FROM projects").fetchall()
            self.assertEqual(before, after)
            db.close()
        finally:
            for suffix in ("", "-wal", "-shm"):
                try:
                    os.remove(legacy + suffix)
                except OSError:
                    pass


if __name__ == "__main__":
    unittest.main()
